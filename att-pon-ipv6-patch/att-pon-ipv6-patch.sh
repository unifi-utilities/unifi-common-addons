#!/usr/bin/env bash
set -eo pipefail

# Determine persistent data directory location across UniFi generations
case "$(ubnt-device-info firmware || true)" in
1*)
    DATA_DIR="/mnt/data"
    ;;
2* | 3* | 4* | 5*)
    DATA_DIR="/data"
    ;;
*)
    echo "ERROR: No persistent storage found." >&2
    exit 1
    ;;
esac

# Define paths matching your custom structure
CONFIG_DIR="${DATA_DIR}/att-pon-ipv6-patch"
CONFIG_FILE="${CONFIG_DIR}/att-ipv6-patch.conf"

# Logging function for system visibility
log() {
    echo "[att-pon-ipv6-patch] $1"
    logger -t att-pon-ipv6-patch "$1"
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
test_ipv4_connectivity() {
    if curl -4 -m 10 -s -o /dev/null "$IPV4_TEST_TARGET"; then
        log "IPv4 connectivity to $IPV4_TEST_TARGET successful."
    else
        log "WARNING: IPv4 connectivity to $IPV4_TEST_TARGET failed."
    fi
}

test_ipv6_connectivity() {
    if curl -6 -m 10 -s -o /dev/null "$IPV6_TEST_TARGET"; then
        log "IPv6 connectivity to $IPV6_TEST_TARGET successful."
    else
        log "WARNING: IPv6 connectivity to $IPV6_TEST_TARGET failed."
    fi
}

# --- Main Execution ---

# 1. Wait for the interface to initialize (Handles boot-stage race conditions)
MAX_RETRIES=15
RETRY_COUNT=0
while ! ip link show "$WAN_IFACE" >/dev/null 2>&1; do
    if (( RETRY_COUNT >= MAX_RETRIES )); then
        log "ERROR: Interface $WAN_IFACE did not become available after $MAX_RETRIES seconds."
        exit 1
    fi
    log "Waiting for interface $WAN_IFACE to initialize..."
    sleep 2
    ((RETRY_COUNT++))
done

log "Initial network diagnostic checks:"
test_ipv4_connectivity
test_ipv6_connectivity

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

log "Post-patch diagnostic checks:"
test_ipv4_connectivity
test_ipv6_connectivity

exit 0
