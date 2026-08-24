#!/bin/sh
set -eu

SOUNDCORK_HOME="${SOUNDCORK_HOME:-/data/soundcork}"
SOUNDCORK_UNIT_DIR="${SOUNDCORK_UNIT_DIR:-/etc/systemd/system}"
SOUNDCORK_SYSTEMCTL="${SOUNDCORK_SYSTEMCTL:-systemctl}"
SOUNDCORK_HEALTHCHECK="${SOUNDCORK_HEALTHCHECK:-${SOUNDCORK_HOME}/soundcork-healthcheck.sh}"
UNIT_NAME="soundcork-nspawn.service"
UNIT_SOURCE="${SOUNDCORK_HOME}/${UNIT_NAME}"
UNIT_TARGET="${SOUNDCORK_UNIT_DIR}/${UNIT_NAME}"
LAUNCHER="${SOUNDCORK_HOME}/soundcork-nspawn.sh"

[ -x "$LAUNCHER" ] || {
	echo "soundcork-nspawn: missing executable launcher at $LAUNCHER" >&2
	exit 1
}
[ -r "$UNIT_SOURCE" ] || {
	echo "soundcork-nspawn: missing unit file at $UNIT_SOURCE" >&2
	exit 1
}
[ -x "$SOUNDCORK_HEALTHCHECK" ] || {
	echo "soundcork-nspawn: missing executable healthcheck at $SOUNDCORK_HEALTHCHECK" >&2
	exit 1
}

install -m 0644 "$UNIT_SOURCE" "$UNIT_TARGET"
"$SOUNDCORK_SYSTEMCTL" daemon-reload
# udm-boot owns boot ordering; the unit owns the long-running process cgroup.
"$SOUNDCORK_SYSTEMCTL" disable "$UNIT_NAME" >/dev/null 2>&1
unit_enablement="$("$SOUNDCORK_SYSTEMCTL" is-enabled "$UNIT_NAME" 2>/dev/null || true)"
case "$unit_enablement" in
disabled | static)
	;;
*)
	echo "soundcork-nspawn: unexpected unit enablement: ${unit_enablement:-unknown}" >&2
	exit 1
	;;
esac
"$SOUNDCORK_SYSTEMCTL" restart "$UNIT_NAME"
"$SOUNDCORK_SYSTEMCTL" is-active --quiet "$UNIT_NAME"
"$SOUNDCORK_HEALTHCHECK" --no-spotify --no-remux
