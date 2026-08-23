#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_SERVICE_HOME:-/data/aftertouch-service}
CONFIG_FILE=${AFTERTOUCH_SERVICE_CONFIG:-$APP_HOME/config.env}
CURRENT_DIR=$APP_HOME/current
BINARY=$CURRENT_DIR/soundtouch-service
MANIFEST=$CURRENT_DIR/manifest
SERVICE_UID=65532
SERVICE_GID=65532

if [ -r "$CONFIG_FILE" ]; then
	set -a
	# systemd reads EnvironmentFile before changing to the service UID. This
	# fallback supports direct root invocation of the launcher.
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
	set +a
fi

die() {
	echo "aftertouch-service: ERROR: $*" >&2
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

validate_port() {
	port_name=$1
	port_value=$2
	case "$port_value" in
	*[!0-9]* | "") die "$port_name must be an integer" ;;
	esac
	[ "$port_value" -gt 1024 ] && [ "$port_value" -le 65535 ] ||
		die "$port_name must be between 1025 and 65535"
}

settings_bool_is_true() {
	settings_key=$1
	settings_file=$DATA_DIR/settings.json
	[ -f "$settings_file" ] || return 1
	tr -d '[:space:]' <"$settings_file" |
		grep -Eq "\"$settings_key\":true([,}])"
}

[ -f "$MANIFEST" ] || die "missing active manifest"
[ -x "$BINARY" ] || die "missing active executable"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v id >/dev/null 2>&1 || die "id is required"
command -v setpriv >/dev/null 2>&1 || die "setpriv is required"
command -v stat >/dev/null 2>&1 || die "stat is required"
expected=$(manifest_value sha256) || die "manifest has no unique sha256"
component=$(manifest_value component) || die "manifest has no unique component"
actual=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$component" = aftertouch-service ] || die "unexpected manifest component: $component"
[ "$actual" = "$expected" ] || die "active binary checksum mismatch"

: "${BIND_ADDR:?BIND_ADDR must be set}"
: "${PORT:?PORT must be set}"
: "${HTTPS_PORT:?HTTPS_PORT must be set}"
: "${SERVER_URL:?SERVER_URL must be set}"
: "${HTTPS_SERVER_URL:?HTTPS_SERVER_URL must be set}"
: "${DEPLOYMENT_MODE:?DEPLOYMENT_MODE must be set}"
: "${DATA_DIR:?DATA_DIR must be set}"
: "${MGMT_USERNAME:?MGMT_USERNAME must be set}"
: "${MGMT_PASSWORD:?MGMT_PASSWORD must be set}"

is_ipv4 "$BIND_ADDR" || die "BIND_ADDR must be an IPv4 address"
[ "$BIND_ADDR" != 0.0.0.0 ] || die "wildcard BIND_ADDR is forbidden"
validate_port PORT "$PORT"
validate_port HTTPS_PORT "$HTTPS_PORT"
[ "$PORT" != "$HTTPS_PORT" ] || die "PORT and HTTPS_PORT must differ"

[ "$DEPLOYMENT_MODE" = private-network ] ||
	die "DEPLOYMENT_MODE must be private-network on a UniFi gateway"
[ "$DATA_DIR" = "$APP_HOME/data" ] ||
	die "DATA_DIR must remain inside the addon at $APP_HOME/data"
[ -d "$DATA_DIR" ] || die "missing persistent data directory: $DATA_DIR"
[ "$(stat -c %u "$DATA_DIR")" = "$SERVICE_UID" ] ||
	die "persistent data directory must be owned by UID $SERVICE_UID"
[ "$(stat -c %g "$DATA_DIR")" = "$SERVICE_GID" ] ||
	die "persistent data directory must be owned by GID $SERVICE_GID"

case "$SERVER_URL" in
http://*) ;;
*) die "SERVER_URL must use http:// for the private-network deployment" ;;
esac
case "$HTTPS_SERVER_URL" in
https://*) ;;
*) die "HTTPS_SERVER_URL must use https://" ;;
esac
if printf '%s\n%s\n' "$SERVER_URL" "$HTTPS_SERVER_URL" | grep -q '[[:space:]]'; then
	die "service URLs must not contain whitespace"
fi

for bool_name in REDACT_PROXY_LOGS LOG_PROXY_BODY RECORD_INTERACTIONS \
	DISCOVERY_ENABLED UPDATE_CHECK_ENABLED ENABLE_DNS_DISCOVERY; do
	eval "bool_value=\${$bool_name:-}"
	# shellcheck disable=SC2154 # Assigned indirectly by the eval above.
	is_bool "$bool_value" || die "$bool_name must be true or false"
done

if is_true "$ENABLE_DNS_DISCOVERY" || settings_bool_is_true dns_enabled; then
	die "DNS discovery is unsupported on UniFi gateways because port 53 is controller-owned"
fi

[ "$MGMT_PASSWORD" != change_me! ] || die "replace the default MGMT_PASSWORD before activation"
[ "${#MGMT_PASSWORD}" -ge 16 ] || die "MGMT_PASSWORD must contain at least 16 characters"

if [ -n "${STOCKHOLM_DIR:-}" ]; then
	case "$STOCKHOLM_DIR" in
	"$APP_HOME"/stockholm | "$APP_HOME"/stockholm/*) ;;
	*) die "STOCKHOLM_DIR must stay below $APP_HOME/stockholm" ;;
	esac
	[ -d "$STOCKHOLM_DIR" ] || die "STOCKHOLM_DIR does not exist: $STOCKHOLM_DIR"
fi

[ "$(id -u)" -eq 0 ] || die "launcher must start as root to drop privileges"
exec setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --clear-groups "$BINARY"
