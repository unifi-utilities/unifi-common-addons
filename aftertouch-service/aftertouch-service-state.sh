#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_SERVICE_HOME:-/data/aftertouch-service}
DATA_DIR=$APP_HOME/data
SNAPSHOT_DIR=$APP_HOME/state-snapshots
SERVICE_NAME=aftertouch-service.service
SYSTEMCTL=${AFTERTOUCH_SYSTEMCTL:-systemctl}
HEALTHCHECK=${AFTERTOUCH_HEALTHCHECK:-$APP_HOME/aftertouch-service-healthcheck.sh}
CHOWN=${AFTERTOUCH_CHOWN:-chown}
CP=${AFTERTOUCH_CP:-cp}
RM=${AFTERTOUCH_RM:-rm}
SERVICE_UID=65532
SERVICE_GID=65532
TEMP_PATH=
OLD_DATA=
RESTART_ON_EXIT=0
STOP_ON_EXIT=0
CREATED_SNAPSHOT_ID=

usage() {
	cat <<'EOF'
Usage:
  aftertouch-service-state.sh snapshot
  aftertouch-service-state.sh list
  aftertouch-service-state.sh restore SNAPSHOT_ID --yes

Snapshots contain AfterTouch settings, device/account data, OAuth state, and
the locally generated TLS CA and private keys. Treat them as secrets.
EOF
}

die() {
	echo "aftertouch-service state: ERROR: $*" >&2
	exit 1
}

cleanup() {
	if [ -n "$OLD_DATA" ] && [ -e "$OLD_DATA" ]; then
		if [ -e "$DATA_DIR" ]; then
			aborted_data=$APP_HOME/.state-aborted.$$
			if [ -e "$aborted_data" ]; then
				echo "aftertouch-service state: WARNING: rollback staging path already exists" >&2
			elif mv "$DATA_DIR" "$aborted_data" && mv "$OLD_DATA" "$DATA_DIR"; then
				OLD_DATA=
				"$RM" -rf "$aborted_data"
			else
				echo "aftertouch-service state: WARNING: automatic data rollback failed" >&2
			fi
		elif mv "$OLD_DATA" "$DATA_DIR"; then
			OLD_DATA=
		else
			echo "aftertouch-service state: WARNING: original data could not be restored" >&2
		fi
	fi
	if [ -n "$TEMP_PATH" ] && [ -e "$TEMP_PATH" ]; then
		"$RM" -rf "$TEMP_PATH"
	fi
	if [ "$RESTART_ON_EXIT" -eq 1 ]; then
		if ! "$SYSTEMCTL" start "$SERVICE_NAME" >/dev/null 2>&1; then
			echo "aftertouch-service state: WARNING: service restart after interruption failed" >&2
		fi
	fi
	if [ "$STOP_ON_EXIT" -eq 1 ]; then
		if ! "$SYSTEMCTL" stop "$SERVICE_NAME" >/dev/null 2>&1; then
			echo "aftertouch-service state: WARNING: temporary validation service did not stop" >&2
		fi
	fi
}

trap cleanup EXIT HUP INT TERM

case "$APP_HOME" in
/*) ;;
*) die "AFTERTOUCH_SERVICE_HOME must be an absolute path" ;;
esac
[ "$APP_HOME" != / ] || die "refusing to use / as AFTERTOUCH_SERVICE_HOME"
command -v flock >/dev/null 2>&1 || die "flock is required"
command -v "$SYSTEMCTL" >/dev/null 2>&1 || die "systemctl is required"
command -v "$CHOWN" >/dev/null 2>&1 || die "chown is required"
command -v "$CP" >/dev/null 2>&1 || die "cp is required"
command -v "$RM" >/dev/null 2>&1 || die "rm is required"

LOCK_FILE=$APP_HOME/.operation.lock
exec 9>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
flock -n 9 || die "another install, boot, or state operation is already running"

mkdir -p "$SNAPSHOT_DIR"
chmod 0700 "$SNAPSHOT_DIR"
"$CHOWN" 0:0 "$SNAPSHOT_DIR"
[ -d "$DATA_DIR" ] || die "persistent data directory is missing: $DATA_DIR"

service_is_active() {
	"$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1
}

next_snapshot_id() {
	prefix=$1
	base=$(date -u +%Y%m%dT%H%M%SZ)
	if [ -n "$prefix" ]; then
		base=$base-$prefix
	fi
	candidate=$base
	index=1
	while [ -e "$SNAPSHOT_DIR/$candidate" ]; do
		candidate=$base-$index
		index=$((index + 1))
	done
	printf '%s\n' "$candidate"
}

copy_snapshot() {
	prefix=$1
	snapshot_id=$(next_snapshot_id "$prefix")
	TEMP_PATH=$SNAPSHOT_DIR/.snapshot.$$
	[ ! -e "$TEMP_PATH" ] || die "temporary snapshot path already exists"
	mkdir -m 0700 "$TEMP_PATH" "$TEMP_PATH/data"
	if [ -d "$DATA_DIR" ]; then
		"$CP" -a "$DATA_DIR/." "$TEMP_PATH/data/"
	fi
	artifact_target=
	if [ -L "$APP_HOME/current" ]; then
		artifact_target=$(readlink "$APP_HOME/current")
	fi
	cat >"$TEMP_PATH/manifest" <<EOF
schema=1
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
artifact_target=$artifact_target
EOF
	chmod 0600 "$TEMP_PATH/manifest"
	mv "$TEMP_PATH" "$SNAPSHOT_DIR/$snapshot_id"
	TEMP_PATH=
	CREATED_SNAPSHOT_ID=$snapshot_id
}

restart_and_check() {
	"$SYSTEMCTL" restart "$SERVICE_NAME" || return 1
	AFTERTOUCH_SERVICE_HOME=$APP_HOME "$HEALTHCHECK" || return 1
	"$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" || return 1
}

command_name=${1:-}
case "$command_name" in
snapshot)
	[ "$#" -eq 1 ] || die "snapshot takes no arguments"
	was_active=0
	if service_is_active; then
		was_active=1
		"$SYSTEMCTL" stop "$SERVICE_NAME"
		RESTART_ON_EXIT=1
	fi
	copy_snapshot ""
	snapshot_id=$CREATED_SNAPSHOT_ID
	if [ "$was_active" -eq 1 ]; then
		restart_and_check || die "snapshot was created, but the service did not recover"
		RESTART_ON_EXIT=0
	fi
	echo "aftertouch-service state: created $snapshot_id"
	;;
list)
	[ "$#" -eq 1 ] || die "list takes no arguments"
	found=0
	for snapshot_path in "$SNAPSHOT_DIR"/*; do
		[ -d "$snapshot_path" ] || continue
		[ -f "$snapshot_path/manifest" ] || continue
		found=1
		printf '%s\n' "${snapshot_path##*/}"
	done
	[ "$found" -eq 1 ] || echo "aftertouch-service state: no snapshots"
	;;
restore)
	[ "$#" -eq 3 ] || die "restore requires SNAPSHOT_ID --yes"
	snapshot_id=$2
	[ "$3" = --yes ] || die "restore requires --yes"
	printf '%s\n' "$snapshot_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
		die "unsafe snapshot ID"
	source_dir=$SNAPSHOT_DIR/$snapshot_id
	[ -f "$source_dir/manifest" ] || die "snapshot manifest is missing: $snapshot_id"
	[ -d "$source_dir/data" ] || die "snapshot data is missing: $snapshot_id"
	grep -Fx 'schema=1' "$source_dir/manifest" >/dev/null || die "unsupported snapshot schema"

	was_active=0
	if service_is_active; then
		was_active=1
		"$SYSTEMCTL" stop "$SERVICE_NAME"
		RESTART_ON_EXIT=1
	fi
	copy_snapshot pre-restore
	pre_restore_id=$CREATED_SNAPSHOT_ID

	TEMP_PATH=$APP_HOME/.state-restore.$$
	OLD_DATA=$APP_HOME/.state-old.$$
	[ ! -e "$TEMP_PATH" ] || die "temporary restore path already exists"
	[ ! -e "$OLD_DATA" ] || die "temporary rollback path already exists"
	mkdir -m 0700 "$TEMP_PATH"
	"$CP" -a "$source_dir/data/." "$TEMP_PATH/"
	"$CHOWN" -R "$SERVICE_UID:$SERVICE_GID" "$TEMP_PATH"
	chmod 0700 "$TEMP_PATH"
	mv "$DATA_DIR" "$OLD_DATA"
	mv "$TEMP_PATH" "$DATA_DIR"
	TEMP_PATH=

	if [ "$was_active" -eq 0 ]; then
		STOP_ON_EXIT=1
	fi
	if ! restart_and_check; then
		"$SYSTEMCTL" stop "$SERVICE_NAME" >/dev/null 2>&1 || true
		TEMP_PATH=$APP_HOME/.state-failed.$$
		mv "$DATA_DIR" "$TEMP_PATH"
		mv "$OLD_DATA" "$DATA_DIR"
		OLD_DATA=
		"$CHOWN" -R "$SERVICE_UID:$SERVICE_GID" "$DATA_DIR"
		if ! restart_and_check; then
			die "restored state failed and the original state also failed to restart"
		fi
		if [ "$was_active" -eq 1 ]; then
			RESTART_ON_EXIT=0
		else
			"$SYSTEMCTL" stop "$SERVICE_NAME"
			STOP_ON_EXIT=0
		fi
		die "restored state failed validation; original state recovered (snapshot $pre_restore_id retained)"
	fi
	if [ "$was_active" -eq 1 ]; then
		RESTART_ON_EXIT=0
	else
		"$SYSTEMCTL" stop "$SERVICE_NAME"
		STOP_ON_EXIT=0
	fi

	committed_old_data=$OLD_DATA
	OLD_DATA=
	if ! "$RM" -rf "$committed_old_data"; then
		echo "aftertouch-service state: WARNING: restored state is active, but old data cleanup failed: $committed_old_data" >&2
	fi
	echo "aftertouch-service state: restored $snapshot_id (previous state saved as $pre_restore_id)"
	;;
-h | --help)
	usage
	;;
*)
	usage >&2
	exit 2
	;;
esac
