#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_SERVICE_HOME:-/data/aftertouch-service}
CONFIG_FILE=${AFTERTOUCH_SERVICE_CONFIG:-$APP_HOME/config.env}
CURRENT_DIR=$APP_HOME/current
MANIFEST=$CURRENT_DIR/manifest
BINARY=$CURRENT_DIR/soundtouch-service
SERVICE_NAME=aftertouch-service.service
SYSTEMCTL=${AFTERTOUCH_SYSTEMCTL:-systemctl}
PROC_ROOT=${AFTERTOUCH_PROC_ROOT:-/proc}
SERVICE_UID=65532
SERVICE_GID=65532
TMP_BODY=

if [ -r "$CONFIG_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
	set +a
fi

TIMEOUT=${AFTERTOUCH_HEALTH_TIMEOUT:-60}

die() {
	echo "aftertouch-service healthcheck: ERROR: $*" >&2
	exit 1
}

cleanup() {
	[ -z "$TMP_BODY" ] || rm -f "$TMP_BODY"
}

trap cleanup EXIT HUP INT TERM

manifest_value() {
	key=$1
	awk -F= -v wanted="$key" '
        $1 == wanted { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }
    ' "$MANIFEST"
}

http_get() {
	url=$1
	output=$2

	if command -v curl >/dev/null 2>&1; then
		curl -fsS --max-time 3 -o "$output" "$url" >/dev/null 2>&1
		return
	fi

	if command -v wget >/dev/null 2>&1; then
		wget -q -T 3 -O "$output" "$url" >/dev/null 2>&1
		return
	fi

	die "curl or wget is required"
}

https_get() {
	url=$1
	output=$2
	ca_file=$3

	if command -v curl >/dev/null 2>&1; then
		curl -fsS --max-time 3 --cacert "$ca_file" -o "$output" "$url" >/dev/null 2>&1
		return
	fi

	if command -v wget >/dev/null 2>&1; then
		wget -q -T 3 --ca-certificate="$ca_file" -O "$output" "$url" >/dev/null 2>&1
		return
	fi

	die "curl or wget is required"
}

case "$TIMEOUT" in
*[!0-9]* | "") die "AFTERTOUCH_HEALTH_TIMEOUT must be an integer" ;;
esac
[ "$TIMEOUT" -gt 0 ] || die "AFTERTOUCH_HEALTH_TIMEOUT must be positive"
: "${BIND_ADDR:?BIND_ADDR must be set}"
: "${PORT:?PORT must be set}"
: "${HTTPS_PORT:?HTTPS_PORT must be set}"
: "${DATA_DIR:?DATA_DIR must be set}"

[ -f "$MANIFEST" ] || die "missing active manifest"
[ -x "$BINARY" ] || die "missing active executable"
expected=$(manifest_value sha256) || die "manifest has no unique sha256"
expected_version=$(manifest_value version) || die "manifest has no unique version"
component=$(manifest_value component) || die "manifest has no unique component"
actual=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$component" = aftertouch-service ] || die "unexpected manifest component: $component"
[ "$actual" = "$expected" ] || die "active binary checksum mismatch"

command -v ss >/dev/null 2>&1 || die "ss is required"
command -v "$SYSTEMCTL" >/dev/null 2>&1 || die "systemctl is required"
TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/aftertouch-service-health.XXXXXX") ||
	die "cannot create temporary file"
base_url=http://$BIND_ADDR:$PORT
https_url=https://$BIND_ADDR:$HTTPS_PORT
ca_cert=$DATA_DIR/certs/ca.crt
deadline=$(($(date +%s) + TIMEOUT))

while :; do
	http_listener_ok=0
	https_listener_ok=0
	health_ok=0
	https_ok=0
	version_ok=0
	player_ok=0
	inventory_ok=0
	state_ok=0
	process_ok=0

	if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Fx "$BIND_ADDR:$PORT" >/dev/null 2>&1; then
		http_listener_ok=1
	fi
	if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Fx "$BIND_ADDR:$HTTPS_PORT" >/dev/null 2>&1; then
		https_listener_ok=1
	fi
	if http_get "$base_url/health" "$TMP_BODY" &&
		grep -Eq '"status"[[:space:]]*:[[:space:]]*"up"' "$TMP_BODY"; then
		health_ok=1
	fi
	if [ -f "$ca_cert" ] && https_get "$https_url/health" "$TMP_BODY" "$ca_cert"; then
		https_ok=1
	fi
	if http_get "$base_url/api/setup/version" "$TMP_BODY" &&
		grep -F "\"version\":\"$expected_version\"" "$TMP_BODY" >/dev/null 2>&1 &&
		grep -F "\"data_dir\":\"$DATA_DIR\"" "$TMP_BODY" >/dev/null 2>&1; then
		version_ok=1
	fi
	if http_get "$base_url/app/" "$TMP_BODY"; then
		player_ok=1
	fi
	if http_get "$base_url/api/control/devices/" "$TMP_BODY"; then
		inventory_ok=1
		old_ifs=$IFS
		IFS=,
		for device_id in ${EXPECTED_DEVICE_IDS:-}; do
			IFS=$old_ifs
			[ -z "$device_id" ] || grep -F "$device_id" "$TMP_BODY" >/dev/null 2>&1 ||
				inventory_ok=0
			IFS=,
		done
		IFS=$old_ifs
	fi
	if [ -f "$DATA_DIR/settings.json" ] && [ -f "$DATA_DIR/certs/ca.key" ] &&
		[ -f "$DATA_DIR/certs/server.key" ]; then
		state_ok=1
	fi
	main_pid=${AFTERTOUCH_MAIN_PID:-}
	if [ -z "$main_pid" ]; then
		main_pid=$("$SYSTEMCTL" show --property=MainPID --value "$SERVICE_NAME" 2>/dev/null || true)
	fi
	case "$main_pid" in
	*[!0-9]* | "" | 0 | 1) ;;
	*)
		if [ -e "$PROC_ROOT/$main_pid/exe" ] && [ -r "$PROC_ROOT/$main_pid/status" ]; then
			running_sha=$(sha256sum "$PROC_ROOT/$main_pid/exe" 2>/dev/null | awk '{print $1}' || true)
			runtime_uid=$(awk '/^Uid:/ { print $2 }' "$PROC_ROOT/$main_pid/status" 2>/dev/null || true)
			runtime_gid=$(awk '/^Gid:/ { print $2 }' "$PROC_ROOT/$main_pid/status" 2>/dev/null || true)
			if [ "$running_sha" = "$expected" ] && [ "$runtime_uid" = "$SERVICE_UID" ] &&
				[ "$runtime_gid" = "$SERVICE_GID" ]; then
				process_ok=1
			fi
		fi
		;;
	esac

	if [ "$http_listener_ok" -eq 1 ] && [ "$https_listener_ok" -eq 1 ] &&
		[ "$health_ok" -eq 1 ] && [ "$https_ok" -eq 1 ] &&
		[ "$version_ok" -eq 1 ] && [ "$player_ok" -eq 1 ] &&
		[ "$inventory_ok" -eq 1 ] && [ "$state_ok" -eq 1 ] &&
		[ "$process_ok" -eq 1 ]; then
		echo "aftertouch-service healthcheck: OK ($BIND_ADDR:$PORT, TLS $HTTPS_PORT)"
		exit 0
	fi

	[ "$(date +%s)" -lt "$deadline" ] ||
		die "service did not become ready within ${TIMEOUT}s (http_listener=$http_listener_ok https_listener=$https_listener_ok health=$health_ok https=$https_ok version=$version_ok player=$player_ok inventory=$inventory_ok state=$state_ok process=$process_ok)"
	sleep 1
done
