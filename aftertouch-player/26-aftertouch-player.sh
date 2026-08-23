#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_PLAYER_HOME:-/data/aftertouch-player}
UNIT_DIR=${AFTERTOUCH_UNIT_DIR:-/etc/systemd/system}
SYSTEMCTL=${AFTERTOUCH_SYSTEMCTL:-systemctl}
SERVICE_NAME=aftertouch-player.service
MANIFEST=$APP_HOME/current/manifest
BINARY=$APP_HOME/current/soundtouch-player
HEALTHCHECK=${AFTERTOUCH_HEALTHCHECK:-$APP_HOME/aftertouch-player-healthcheck.sh}

die() {
	echo "aftertouch-player boot: ERROR: $*" >&2
	exit 1
}

[ -d "$APP_HOME" ] || die "missing $APP_HOME"
command -v flock >/dev/null 2>&1 || die "flock is required"
LOCK_FILE=$APP_HOME/.operation.lock
if [ "${AFTERTOUCH_OPERATION_LOCK_HELD:-0}" = 1 ]; then
	flock -n 9 || die "inherited operation lock is unavailable"
else
	exec 9>"$LOCK_FILE"
	chmod 0600 "$LOCK_FILE"
	flock -n 9 || die "another install or boot operation is already running"
fi

manifest_value() {
	key=$1
	file=${2:-$MANIFEST}
	awk -F= -v wanted="$key" '
        $1 == wanted { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }
    ' "$file"
}

valid_release_target() {
	printf '%s\n' "$1" | grep -Eq '^releases/[A-Za-z0-9][A-Za-z0-9._+-]*$'
}

release_target_valid() {
	verify_target=$1
	valid_release_target "$verify_target" || return 1
	verify_dir=$APP_HOME/$verify_target
	[ -f "$verify_dir/manifest" ] || return 1
	[ -x "$verify_dir/soundtouch-player" ] || return 1
	verify_expected=$(manifest_value sha256 "$verify_dir/manifest") || return 1
	verify_actual=$(sha256sum "$verify_dir/soundtouch-player" | awk '{print $1}')
	[ "$verify_actual" = "$verify_expected" ]
}

verify_release_target() {
	strict_target=$1
	release_target_valid "$strict_target" || die "invalid or corrupt release target: $strict_target"
}

atomic_link() {
	link_name=$1
	link_target=$2
	link_destination=$APP_HOME/$link_name
	link_temporary=$APP_HOME/.${link_name}.$$
	if [ -e "$link_destination" ] && [ ! -L "$link_destination" ]; then
		die "$link_destination exists and is not a symlink"
	fi
	rm -f "$link_temporary"
	ln -s "$link_target" "$link_temporary"
	mv -Tf "$link_temporary" "$link_destination"
}

for path in "$APP_HOME/config.env" "$APP_HOME/run.sh" "$APP_HOME/aftertouch-player.service" "$HEALTHCHECK" "$MANIFEST" "$BINARY"; do
	[ -e "$path" ] || die "missing $path"
done
[ -x "$BINARY" ] || die "binary is not executable: $BINARY"
[ -x "$APP_HOME/run.sh" ] || die "launcher is not executable"
[ -x "$HEALTHCHECK" ] || die "healthcheck is not executable"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
expected=$(manifest_value sha256) || die "manifest has no unique sha256"
actual=$(sha256sum "$BINARY" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "active binary checksum mismatch"
current_target=$(readlink "$APP_HOME/current") || die "cannot read current release target"
verify_release_target "$current_target"

verified_target=
if [ -L "$APP_HOME/verified" ]; then
	verified_candidate=$(readlink "$APP_HOME/verified")
	if release_target_valid "$verified_candidate"; then
		verified_target=$verified_candidate
	else
		echo "aftertouch-player boot: WARNING: ignoring corrupt verified target: $verified_candidate" >&2
	fi
fi

mkdir -p "$UNIT_DIR"
install -m 0644 "$APP_HOME/aftertouch-player.service" "$UNIT_DIR/$SERVICE_NAME"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable "$SERVICE_NAME" >/dev/null
"$SYSTEMCTL" restart "$SERVICE_NAME"
AFTERTOUCH_PLAYER_HOME=$APP_HOME "$HEALTHCHECK"
"$SYSTEMCTL" is-active --quiet "$SERVICE_NAME"
[ "$(readlink "$APP_HOME/current")" = "$current_target" ] ||
	die "current artifact changed during activation"

if [ "$current_target" != "$verified_target" ]; then
	if [ -n "$verified_target" ]; then
		atomic_link previous "$verified_target"
	fi
	atomic_link verified "$current_target"
fi
