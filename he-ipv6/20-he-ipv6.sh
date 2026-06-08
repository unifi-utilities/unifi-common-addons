#!/bin/sh
set -eu

SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
CONFIG=${HE_CONFIG:-"$SCRIPT_DIR/he-ipv6.conf"}
MODE=apply
START_WATCHDOG=1

usage() {
    cat <<'EOF'
Usage: 20-he-ipv6.sh [--apply|--check|--watch] [--no-watch]

  --apply      Configure the HE 6in4 tunnel. This is the default for boot use.
  --check      Report current state without changing the system.
  --watch      Re-run --check periodically and repair with --apply if needed.
  --no-watch   Do not start the background watchdog after --apply.

Set HE_CONFIG=/path/to/he-ipv6.conf to use a non-default config path.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply|apply)
            MODE=apply
            ;;
        --check|check)
            MODE=check
            START_WATCHDOG=0
            ;;
        --watch|watch)
            MODE=watch
            START_WATCHDOG=0
            ;;
        --no-watch)
            START_WATCHDOG=0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ ! -f "$CONFIG" ]; then
    echo "Missing config file: $CONFIG" >&2
    echo "Copy he-ipv6.conf.example to he-ipv6.conf and edit it first." >&2
    exit 2
fi

# shellcheck source=/dev/null
. "$CONFIG"

HE_SERVER_IPV4=${HE_SERVER_IPV4:-}
HE_CLIENT_IPV6=${HE_CLIENT_IPV6:-}
HE_TUNNEL_IF=${HE_TUNNEL_IF:-he-ipv6}
HE_CLIENT_IPV4=${HE_CLIENT_IPV4:-}
HE_TUNNEL_MTU=${HE_TUNNEL_MTU:-1480}
HE_TUNNEL_TTL=${HE_TUNNEL_TTL:-255}
HE_DEFAULT_ROUTE=${HE_DEFAULT_ROUTE:-1}
HE_DEFAULT_ROUTE_METRIC=${HE_DEFAULT_ROUTE_METRIC:-512}
HE_ENABLE_FORWARDING=${HE_ENABLE_FORWARDING:-1}
HE_WAN_CLASSIFICATION=${HE_WAN_CLASSIFICATION:-1}
HE_TCP_MSS_CLAMP=${HE_TCP_MSS_CLAMP:-1}
HE_TCP_MSS=${HE_TCP_MSS:-}
HE_WATCHDOG_INTERVAL=${HE_WATCHDOG_INTERVAL:-60}
HE_WATCHDOG_PIDFILE=${HE_WATCHDOG_PIDFILE:-/run/he-ipv6-watchdog.pid}
HE_MANAGE_LAN_ADDRESSES=${HE_MANAGE_LAN_ADDRESSES:-0}
HE_FLUSH_LAN_GLOBAL=${HE_FLUSH_LAN_GLOBAL:-0}
HE_LAN_ADDRESSES=${HE_LAN_ADDRESSES:-}
HE_CHECK_CONNECTIVITY=${HE_CHECK_CONNECTIVITY:-1}
HE_SERVER_IPV6=${HE_SERVER_IPV6:-}

config_value() {
    eval "printf '%s\n' \"\${$1:-}\""
}

is_placeholder() {
    case "$1" in
        ""|CHANGE_ME|CHANGE_ME_*|changeme|changeme_*)
            return 0
            ;;
    esac
    return 1
}

require_config() {
    missing=0
    for name in HE_SERVER_IPV4 HE_CLIENT_IPV6; do
        value=$(config_value "$name")
        if is_placeholder "$value"; then
            echo "Config value $name is missing or still uses CHANGE_ME" >&2
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 2
    fi
}

get_client_ipv4() {
    if [ -n "$HE_CLIENT_IPV4" ] && ! is_placeholder "$HE_CLIENT_IPV4"; then
        printf '%s\n' "$HE_CLIENT_IPV4"
        return 0
    fi

    ip -4 route get "$HE_SERVER_IPV4" 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

tcp_mss_value() {
    if [ -n "$HE_TCP_MSS" ] && ! is_placeholder "$HE_TCP_MSS"; then
        case "$HE_TCP_MSS" in
            *[!0-9]*)
                return 1
                ;;
        esac
        printf '%s\n' "$HE_TCP_MSS"
        return 0
    fi

    case "$HE_TUNNEL_MTU" in
        ""|*[!0-9]*)
            return 1
            ;;
    esac

    mss=$((HE_TUNNEL_MTU - 60))
    [ "$mss" -gt 0 ] || return 1
    printf '%s\n' "$mss"
}

run() {
    "$@"
}

ensure_tunnel() {
    client_ipv4=$1
    current=$(ip tunnel show "$HE_TUNNEL_IF" 2>/dev/null || true)

    if printf '%s\n' "$current" | grep -q "remote $HE_SERVER_IPV4" &&
       printf '%s\n' "$current" | grep -q "local $client_ipv4"; then
        :
    else
        ip tunnel del "$HE_TUNNEL_IF" 2>/dev/null || true
        run ip tunnel add "$HE_TUNNEL_IF" mode sit remote "$HE_SERVER_IPV4" local "$client_ipv4" ttl "$HE_TUNNEL_TTL"
    fi

    run ip link set "$HE_TUNNEL_IF" mtu "$HE_TUNNEL_MTU" up

    if ! ip -6 addr show dev "$HE_TUNNEL_IF" 2>/dev/null | grep -Fq "$HE_CLIENT_IPV6"; then
        run ip -6 addr add "$HE_CLIENT_IPV6" dev "$HE_TUNNEL_IF"
    fi
}

ensure_default_route() {
    [ "$HE_DEFAULT_ROUTE" = "1" ] || return 0
    run ip -6 route replace default dev "$HE_TUNNEL_IF" metric "$HE_DEFAULT_ROUTE_METRIC"
}

ensure_forwarding() {
    [ "$HE_ENABLE_FORWARDING" = "1" ] || return 0
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
}

ensure_lan_addresses() {
    [ -n "$HE_LAN_ADDRESSES" ] || return 0
    [ "$HE_MANAGE_LAN_ADDRESSES" = "1" ] || return 0

    for entry in $HE_LAN_ADDRESSES; do
        iface=${entry%%=*}
        addr=${entry#*=}
        [ -n "$iface" ] && [ "$iface" != "$entry" ] || continue

        if [ "$HE_FLUSH_LAN_GLOBAL" = "1" ]; then
            run ip -6 addr flush dev "$iface" scope global
        fi

        if ! ip -6 addr show dev "$iface" 2>/dev/null | grep -Fq "$addr"; then
            run ip -6 addr add "$addr" dev "$iface"
        fi
    done
}

ensure_ip6tables_rule() {
    chain=$1
    direction=$2
    target=$3

    command_exists ip6tables || return 0
    ip6tables -nL "$chain" >/dev/null 2>&1 || return 0
    ip6tables -nL "$target" >/dev/null 2>&1 || return 0

    if ! ip6tables -C "$chain" "$direction" "$HE_TUNNEL_IF" -j "$target" 2>/dev/null; then
        run ip6tables -I "$chain" 1 "$direction" "$HE_TUNNEL_IF" -j "$target"
    fi
}

ensure_wan_classification() {
    [ "$HE_WAN_CLASSIFICATION" = "1" ] || return 0
    ensure_ip6tables_rule UBIOS_INPUT_USER_HOOK -i UBIOS_WAN_LOCAL_USER
    ensure_ip6tables_rule UBIOS_FORWARD_IN_USER -i UBIOS_WAN_IN_USER
    ensure_ip6tables_rule UBIOS_FORWARD_OUT_USER -o UBIOS_WAN_OUT_USER
}

ensure_tcp_mss_clamp() {
    [ "$HE_TCP_MSS_CLAMP" = "1" ] || return 0
    command_exists ip6tables || return 0

    mss=$(tcp_mss_value) || {
        echo "Could not determine a valid TCP MSS from HE_TCP_MSS or HE_TUNNEL_MTU" >&2
        exit 1
    }

    chain=UBIOS_FORWARD_TCPMSS
    if ! ip6tables -t mangle -nL "$chain" >/dev/null 2>&1; then
        chain=FORWARD
    fi

    if ! ip6tables -t mangle -C "$chain" -o "$HE_TUNNEL_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null; then
        run ip6tables -t mangle -I "$chain" 1 -o "$HE_TUNNEL_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss"
    fi
}

apply_config() {
    require_config
    client_ipv4=$(get_client_ipv4)
    if is_placeholder "$client_ipv4"; then
        echo "Could not determine the local IPv4 address for $HE_SERVER_IPV4" >&2
        exit 1
    fi

    ensure_forwarding
    ensure_tunnel "$client_ipv4"
    ensure_default_route
    ensure_lan_addresses
    ensure_wan_classification
    ensure_tcp_mss_clamp
}

CHECK_FAILS=0
CHECK_WARNS=0

check_ok() {
    echo "OK    $1"
}

check_warn() {
    echo "WARN  $1"
    CHECK_WARNS=$((CHECK_WARNS + 1))
}

check_fail() {
    echo "FAIL  $1"
    CHECK_FAILS=$((CHECK_FAILS + 1))
}

check_config_value() {
    name=$1
    value=$(config_value "$name")
    if is_placeholder "$value"; then
        check_fail "config: $name is missing or still uses CHANGE_ME"
    else
        check_ok "config: $name is set"
    fi
}

check_ip6tables_rule() {
    chain=$1
    direction=$2
    target=$3
    label=$4

    if ! command_exists ip6tables; then
        check_warn "runtime glue: ip6tables missing, cannot check $label"
        return
    fi
    if ! ip6tables -nL "$chain" >/dev/null 2>&1; then
        check_fail "runtime glue: chain $chain missing for $label"
        return
    fi
    if ! ip6tables -nL "$target" >/dev/null 2>&1; then
        check_warn "runtime glue: chain $target missing, skipping $label classification check"
        return
    fi
    if ip6tables -C "$chain" "$direction" "$HE_TUNNEL_IF" -j "$target" 2>/dev/null; then
        check_ok "runtime glue: $label classification present"
    else
        check_fail "runtime glue: $label classification missing"
    fi
}

check_tcp_mss_clamp() {
    [ "$HE_TCP_MSS_CLAMP" = "1" ] || return 0

    if ! command_exists ip6tables; then
        check_warn "runtime glue: ip6tables missing, cannot check TCP MSS clamp"
        return
    fi

    mss=$(tcp_mss_value) || {
        check_fail "runtime glue: invalid TCP MSS from HE_TCP_MSS or HE_TUNNEL_MTU"
        return
    }

    chain=UBIOS_FORWARD_TCPMSS
    if ! ip6tables -t mangle -nL "$chain" >/dev/null 2>&1; then
        chain=FORWARD
    fi

    if ip6tables -t mangle -C "$chain" -o "$HE_TUNNEL_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null; then
        check_ok "runtime glue: TCP MSS clamp present on $chain for $HE_TUNNEL_IF at $mss"
    else
        check_fail "runtime glue: TCP MSS clamp missing on $chain for $HE_TUNNEL_IF at $mss"
    fi
}

check_state() {
    check_config_value HE_SERVER_IPV4
    check_config_value HE_CLIENT_IPV6

    client_ipv4=$(get_client_ipv4)
    if is_placeholder "$client_ipv4"; then
        check_fail "runtime glue: could not determine local IPv4 for $HE_SERVER_IPV4"
    else
        check_ok "runtime glue: IPv4 source for $HE_SERVER_IPV4 is $client_ipv4"
    fi

    if [ "$HE_ENABLE_FORWARDING" = "1" ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)" = "1" ]; then
            check_ok "net.ipv6.conf.all.forwarding=1"
        else
            check_fail "net.ipv6.conf.all.forwarding is not 1"
        fi
    fi

    if ip link show "$HE_TUNNEL_IF" >/dev/null 2>&1; then
        check_ok "runtime glue: tunnel interface $HE_TUNNEL_IF exists"
    else
        check_fail "runtime glue: tunnel interface $HE_TUNNEL_IF missing"
    fi

    tunnel=$(ip tunnel show "$HE_TUNNEL_IF" 2>/dev/null || true)
    if printf '%s\n' "$tunnel" | grep -q "remote $HE_SERVER_IPV4"; then
        check_ok "runtime glue: $HE_TUNNEL_IF remote is $HE_SERVER_IPV4"
    else
        check_fail "runtime glue: $HE_TUNNEL_IF remote is not $HE_SERVER_IPV4"
    fi
    if [ -n "$client_ipv4" ] && printf '%s\n' "$tunnel" | grep -q "local $client_ipv4"; then
        check_ok "runtime glue: $HE_TUNNEL_IF local IPv4 is $client_ipv4"
    else
        check_fail "runtime glue: $HE_TUNNEL_IF local IPv4 is not $client_ipv4"
    fi

    if ip -6 addr show dev "$HE_TUNNEL_IF" 2>/dev/null | grep -Fq "$HE_CLIENT_IPV6"; then
        check_ok "runtime glue: $HE_TUNNEL_IF has $HE_CLIENT_IPV6"
    else
        check_fail "runtime glue: $HE_TUNNEL_IF missing $HE_CLIENT_IPV6"
    fi

    if [ "$HE_DEFAULT_ROUTE" = "1" ]; then
        if ip -6 route show default 2>/dev/null | grep -q " dev $HE_TUNNEL_IF"; then
            check_ok "runtime glue: IPv6 default route uses $HE_TUNNEL_IF"
        else
            check_fail "runtime glue: IPv6 default route does not use $HE_TUNNEL_IF"
        fi
    fi

    for entry in $HE_LAN_ADDRESSES; do
        iface=${entry%%=*}
        addr=${entry#*=}
        [ -n "$iface" ] && [ "$iface" != "$entry" ] || continue

        if ip -6 addr show dev "$iface" 2>/dev/null | grep -Fq "$addr"; then
            check_ok "LAN: $iface has $addr"
        else
            check_fail "LAN: $iface missing $addr"
        fi
    done

    if [ "$HE_WAN_CLASSIFICATION" = "1" ]; then
        check_ip6tables_rule UBIOS_INPUT_USER_HOOK -i UBIOS_WAN_LOCAL_USER "wan local"
        check_ip6tables_rule UBIOS_FORWARD_IN_USER -i UBIOS_WAN_IN_USER "wan in"
        check_ip6tables_rule UBIOS_FORWARD_OUT_USER -o UBIOS_WAN_OUT_USER "wan out"
    fi

    check_tcp_mss_clamp

    if [ "$HE_CHECK_CONNECTIVITY" = "1" ] && [ -n "$HE_SERVER_IPV6" ] && ! is_placeholder "$HE_SERVER_IPV6"; then
        if ping -6 -c 1 -W 3 "$HE_SERVER_IPV6" >/dev/null 2>&1; then
            check_ok "runtime glue: HE server $HE_SERVER_IPV6 replies"
        else
            check_fail "runtime glue: HE server $HE_SERVER_IPV6 does not reply"
        fi
    fi

    if [ "$CHECK_FAILS" -eq 0 ]; then
        if [ "$CHECK_WARNS" -eq 0 ]; then
            echo "SUMMARY ok"
        else
            echo "SUMMARY ok with $CHECK_WARNS warning(s)"
        fi
        return 0
    fi

    echo "SUMMARY failed with $CHECK_FAILS failure(s), $CHECK_WARNS warning(s)"
    return 1
}

watchdog_log() {
    if command_exists logger; then
        logger -t he-ipv6-watchdog "$*"
    else
        echo "he-ipv6-watchdog: $*"
    fi
}

start_watchdog() {
    [ "${HE_WATCHDOG_INTERVAL:-0}" -gt 0 ] 2>/dev/null || return 0

    if [ -f "$HE_WATCHDOG_PIDFILE" ]; then
        old_pid=$(cat "$HE_WATCHDOG_PIDFILE" 2>/dev/null || true)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            if tr '\0' ' ' <"/proc/$old_pid/cmdline" 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
                return 0
            fi
        fi
    fi

    HE_CONFIG=$CONFIG nohup "$SCRIPT_PATH" --watch >/dev/null 2>&1 &
}

watch_loop() {
    require_config
    if ! [ "$HE_WATCHDOG_INTERVAL" -gt 0 ] 2>/dev/null; then
        echo "HE_WATCHDOG_INTERVAL must be greater than 0 for --watch" >&2
        exit 2
    fi

    echo "$$" >"$HE_WATCHDOG_PIDFILE"
    trap 'rm -f "$HE_WATCHDOG_PIDFILE"' EXIT INT TERM

    while true; do
        sleep "$HE_WATCHDOG_INTERVAL"
        tmp=/tmp/he-ipv6-watchdog.$$
        if ! HE_CONFIG=$CONFIG "$SCRIPT_PATH" --check >"$tmp" 2>&1; then
            watchdog_log "check failed; applying HE IPv6 runtime state"
            while IFS= read -r line; do
                watchdog_log "$line"
            done <"$tmp"
            HE_CONFIG=$CONFIG "$SCRIPT_PATH" --apply --no-watch >/dev/null 2>&1 || watchdog_log "apply failed"
        fi
        rm -f "$tmp"
    done
}

case "$MODE" in
    apply)
        apply_config
        [ "$START_WATCHDOG" = "1" ] && start_watchdog
        ;;
    check)
        check_state
        ;;
    watch)
        watch_loop
        ;;
esac
