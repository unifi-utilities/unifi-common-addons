#!/usr/bin/env bash
set -eo pipefail

# UniFi Data Directory
DATA_DIR="/data"

# Define paths matching your custom structure
CONFIG_DIR="${DATA_DIR}/att-pon-ipv6"
CONFIG_FILE="${CONFIG_DIR}/att-pon-ipv6.conf"

# Retry settings
MAX_RETRIES=15

# Logging function for system visibility
log() {
    echo "[att-pon-ipv6] $1"
    logger -t att-pon-ipv6 "$1"
}

# Source Configuration File
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    log "ERROR: Configuration file not found at $CONFIG_FILE."
    exit 1
fi

# Connectivity validation helper functions
test_ip_connectivity() {
    local ip_version="$1"
    local mode="${2:-warn}"
    local target

    # Default mode logs final diagnostics without failing the script; retry mode
    # returns failures so post diagnostics can retry before logging a final result.
    case "$ip_version" in
        4) target="$IPV4_TEST_TARGET" ;;
        6) target="$IPV6_TEST_TARGET" ;;
        *)
            log "ERROR: Unsupported IP version '$ip_version'."
            return 1
            ;;
    esac

    if curl "-$ip_version" -m 10 -s -o /dev/null "$target"; then
        log "IPv${ip_version} connectivity to $target successful."
        return 0
    fi

    if [[ "$mode" == "retry" ]]; then
        log "WARNING: IPv${ip_version} connectivity to $target failed; retrying..."
        return 1
    fi

    log "WARNING: IPv${ip_version} connectivity to $target failed."
    return 0
}

perform_post_diagnostic_check() {
    local ip_version="$1"
    local retry_count=0

    while (( retry_count < MAX_RETRIES )); do
        if test_ip_connectivity "$ip_version" retry; then
            return 0
        fi

        sleep 2
        ((retry_count+=1))
    done

    test_ip_connectivity "$ip_version"
}

# --- Main Execution ---

# 1. Wait for the interface to initialize (Handles boot-stage race conditions)
RETRY_COUNT=0
while ! ip link show "$WAN_IFACE" >/dev/null 2>&1; do
    if (( RETRY_COUNT >= MAX_RETRIES )); then
        log "ERROR: Interface $WAN_IFACE did not become available after $MAX_RETRIES seconds."
        exit 1
    fi
    log "Waiting for interface $WAN_IFACE to initialize..."
    sleep 2
    ((RETRY_COUNT+=1))
done

log "Initial network diagnostic checks:"
test_ip_connectivity 4
test_ip_connectivity 6

# 2. Idempotent IPv4 Allocation
CLEAN_IP4="${WAN_LOCAL_IP4%%/*}"

if ip addr show dev "$WAN_IFACE" 2>/dev/null | grep -q -w "$CLEAN_IP4"; then
    log "IPv4 address '$CLEAN_IP4' is already assigned to '$WAN_IFACE'."
else
    log "Assigning IPv4 address '$WAN_LOCAL_IP4' to '$WAN_IFACE'..."
    if ip addr add "$WAN_LOCAL_IP4" dev "$WAN_IFACE"; then
        log "IPv4 address '$WAN_LOCAL_IP4' added successfully."
    else
        log "ERROR: Failed to add IPv4 address '$WAN_LOCAL_IP4' to '$WAN_IFACE'."
        exit 1
    fi
fi

# 3. Idempotent IPv6 Allocation
CLEAN_IP6="${WAN_GLOBAL_IP6%%/*}"

if ip addr show dev "$WAN_IFACE" 2>/dev/null | grep -q -w "$CLEAN_IP6"; then
    log "IPv6 address '$CLEAN_IP6' is already assigned to '$WAN_IFACE'."
else
    log "Assigning IPv6 address '$WAN_GLOBAL_IP6' to '$WAN_IFACE'..."
    if ip addr add "$WAN_GLOBAL_IP6" dev "$WAN_IFACE"; then
        log "IPv6 address '$WAN_GLOBAL_IP6' added successfully."
    else
        log "ERROR: Failed to add IPv6 address '$WAN_GLOBAL_IP6' to '$WAN_IFACE'."
        exit 1
    fi
fi

log "Post diagnostic checks:"
perform_post_diagnostic_check 4
perform_post_diagnostic_check 6

exit 0
