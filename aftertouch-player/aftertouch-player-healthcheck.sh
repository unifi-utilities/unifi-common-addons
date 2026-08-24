#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_PLAYER_HOME:-/data/aftertouch-player}
CONFIG_FILE=${AFTERTOUCH_PLAYER_CONFIG:-$APP_HOME/config.env}
CURRENT_DIR=$APP_HOME/current
MANIFEST=$CURRENT_DIR/manifest
BINARY=$CURRENT_DIR/soundtouch-player
TMP_BODY=

if [ -r "$CONFIG_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$CONFIG_FILE"
	set +a
fi

TIMEOUT=${AFTERTOUCH_HEALTH_TIMEOUT:-30}

die() {
	echo "aftertouch-player healthcheck: ERROR: $*" >&2
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

case "$TIMEOUT" in
*[!0-9]* | "") die "AFTERTOUCH_HEALTH_TIMEOUT must be an integer" ;;
esac
[ "$TIMEOUT" -gt 0 ] || die "AFTERTOUCH_HEALTH_TIMEOUT must be positive"
: "${BIND_ADDR:?BIND_ADDR must be set}"
: "${PORT:?PORT must be set}"

[ -f "$MANIFEST" ] || die "missing active manifest"
[ -x "$BINARY" ] || die "missing active executable"
expected=$(manifest_value sha256) || die "manifest has no unique sha256"
expected_version=$(manifest_value version) || die "manifest has no unique version"
actual=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "active binary checksum mismatch"

command -v ss >/dev/null 2>&1 || die "ss is required"
TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/aftertouch-player-health.XXXXXX") || die "cannot create temporary file"
base_url=http://$BIND_ADDR:$PORT
deadline=$(($(date +%s) + TIMEOUT))

while :; do
	listener_ok=0
	health_ok=0
	version_ok=0
	inventory_ok=0

	if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Fx "$BIND_ADDR:$PORT" >/dev/null 2>&1; then
		listener_ok=1
	fi
	if http_get "$base_url/health" "$TMP_BODY"; then
		health_ok=1
	fi
	if http_get "$base_url/api/control/version" "$TMP_BODY"; then
		if grep -F "\"version\":\"$expected_version\"" "$TMP_BODY" >/dev/null 2>&1; then
			version_ok=1
		fi
	fi
	if http_get "$base_url/api/control/devices/" "$TMP_BODY"; then
		inventory_ok=1
		old_ifs=$IFS
		IFS=,
		for device_id in ${EXPECTED_DEVICE_IDS:-}; do
			IFS=$old_ifs
			[ -z "$device_id" ] || grep -F "$device_id" "$TMP_BODY" >/dev/null 2>&1 || inventory_ok=0
			IFS=,
		done
		IFS=$old_ifs
	fi

	if [ "$listener_ok" -eq 1 ] && [ "$health_ok" -eq 1 ] &&
		[ "$version_ok" -eq 1 ] && [ "$inventory_ok" -eq 1 ]; then
		echo "aftertouch-player healthcheck: OK ($BIND_ADDR:$PORT)"
		exit 0
	fi

	[ "$(date +%s)" -lt "$deadline" ] ||
		die "service did not become ready within ${TIMEOUT}s (listener=$listener_ok health=$health_ok version=$version_ok inventory=$inventory_ok)"
	sleep 1
done
