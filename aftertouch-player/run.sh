#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_PLAYER_HOME:-/data/aftertouch-player}
CONFIG_FILE=${AFTERTOUCH_PLAYER_CONFIG:-$APP_HOME/config.env}
CURRENT_DIR=$APP_HOME/current
BINARY=$CURRENT_DIR/soundtouch-player
MANIFEST=$CURRENT_DIR/manifest

if [ -r "$CONFIG_FILE" ]; then
	set -a
	# systemd reads EnvironmentFile before applying DynamicUser. This fallback
	# supports direct root invocation without requiring the transient user to
	# read a root-owned mode-0640 file.
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
	set +a
fi

die() {
	echo "aftertouch-player: ERROR: $*" >&2
	exit 1
}

manifest_value() {
	key=$1
	awk -F= -v wanted="$key" '
        $1 == wanted { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }
    ' "$MANIFEST"
}

is_ipv4() {
	printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    '
}

is_bool() {
	case "$1" in
	true | false | 1 | 0) return 0 ;;
	*) return 1 ;;
	esac
}

is_true() {
	case "$1" in
	true | 1) return 0 ;;
	*) return 1 ;;
	esac
}

[ -f "$MANIFEST" ] || die "missing active manifest"
[ -x "$BINARY" ] || die "missing active executable"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
expected=$(manifest_value sha256) || die "manifest has no unique sha256"
actual=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "active binary checksum mismatch"

: "${BIND_ADDR:?BIND_ADDR must be set}"
: "${PORT:?PORT must be set}"

is_ipv4 "$BIND_ADDR" || die "BIND_ADDR must be an IPv4 address"
[ "$BIND_ADDR" != 0.0.0.0 ] || die "wildcard BIND_ADDR is forbidden"

case "$PORT" in
*[!0-9]* | "") die "PORT must be an integer" ;;
esac
[ "$PORT" -gt 1024 ] && [ "$PORT" -le 65535 ] || die "PORT must be between 1025 and 65535"

UPNP_ENABLED=${UPNP_ENABLED:-false}
MDNS_ENABLED=${MDNS_ENABLED:-false}
is_bool "$UPNP_ENABLED" || die "UPNP_ENABLED must be true or false"
is_bool "$MDNS_ENABLED" || die "MDNS_ENABLED must be true or false"

if ! is_true "$UPNP_ENABLED" && ! is_true "$MDNS_ENABLED"; then
	[ -n "${SOUNDTOUCH_DEVICES:-}" ] || die "SOUNDTOUCH_DEVICES is required when discovery is disabled"
else
	[ -n "${DISCOVERY_INTERFACE:-}" ] || die "DISCOVERY_INTERFACE is required when discovery is enabled"
	[ -d "/sys/class/net/$DISCOVERY_INTERFACE" ] || die "discovery interface does not exist: $DISCOVERY_INTERFACE"
	command -v ip >/dev/null 2>&1 || die "ip is required to validate the discovery interface"
	ip -4 -o addr show dev "$DISCOVERY_INTERFACE" | grep -q ' inet ' ||
		die "discovery interface has no IPv4 address: $DISCOVERY_INTERFACE"
fi

[ -z "${SERVICE_URL:-}" ] || die "SERVICE_URL is outside this player-only addon"
[ -z "${SERVICE_CA:-}" ] || die "SERVICE_CA is outside this player-only addon"

exec "$BINARY"
