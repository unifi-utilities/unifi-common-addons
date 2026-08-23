#!/bin/sh
set -eu

APP_HOME=${AFTERTOUCH_SERVICE_HOME:-/data/aftertouch-service}
ON_BOOT_DIR=${AFTERTOUCH_ON_BOOT_DIR:-/data/on_boot.d}
OFFICIAL_RELEASE_BASE_URL=https://github.com/gesellix/Bose-SoundTouch/releases/download
RELEASE_BASE_URL=${AFTERTOUCH_RELEASE_BASE_URL:-$OFFICIAL_RELEASE_BASE_URL}
MACHINE=${AFTERTOUCH_MACHINE:-$(uname -m)}
SERVICE_UID=65532
SERVICE_GID=65532
CHOWN=${AFTERTOUCH_CHOWN:-chown}
DATA_DIR=$APP_HOME/data
SNAPSHOT_DIR=$APP_HOME/state-snapshots

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MODE=
VERSION=
LOCAL_FILE=
LOCAL_NAME=
RELEASE_SOURCE=
ACTIVATE=0
STAGE_DIR=
DOWNLOAD_DIR=

usage() {
	cat <<'EOF'
Usage:
  install.sh --release TAG [--activate]
  install.sh --local PATH --version ID [--activate]
  install.sh --rollback [--activate]
  install.sh --activate

Official release mode downloads and verifies the matching Linux asset.
Local mode performs no network request. --activate installs and runs the
offline boot hook.
EOF
}

die() {
	echo "aftertouch-service install: ERROR: $*" >&2
	exit 1
}

cleanup() {
	if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
		chmod -R u+w "$STAGE_DIR" 2>/dev/null || true
		rm -rf "$STAGE_DIR"
	fi
	if [ -n "$DOWNLOAD_DIR" ] && [ -d "$DOWNLOAD_DIR" ]; then
		chmod -R u+w "$DOWNLOAD_DIR" 2>/dev/null || true
		rm -rf "$DOWNLOAD_DIR"
	fi
}

trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
	case "$1" in
	--release)
		[ "$#" -ge 2 ] || die "--release requires a tag"
		[ -z "$MODE" ] || die "select only one install mode"
		MODE=release
		VERSION=$2
		shift 2
		;;
	--local)
		[ "$#" -ge 2 ] || die "--local requires a path"
		[ -z "$MODE" ] || die "select only one install mode"
		MODE=local
		LOCAL_FILE=$2
		shift 2
		;;
	--version)
		[ "$#" -ge 2 ] || die "--version requires an identifier"
		VERSION=$2
		shift 2
		;;
	--rollback)
		[ -z "$MODE" ] || die "select only one install mode"
		MODE=rollback
		shift
		;;
	--activate)
		ACTIVATE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

case "$MODE" in
release)
	printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' ||
		die "release tag must look like v0.129.0"
	case "$RELEASE_BASE_URL" in
	https://*) ;;
	*) die "release base URL must use HTTPS" ;;
	esac
	if [ "$RELEASE_BASE_URL" = "$OFFICIAL_RELEASE_BASE_URL" ]; then
		RELEASE_SOURCE=official-release
	else
		RELEASE_SOURCE=release-mirror
	fi
	;;
local)
	[ -n "$VERSION" ] || die "local mode requires --version"
	[ -f "$LOCAL_FILE" ] || die "local artifact not found: $LOCAL_FILE"
	printf '%s\n' "$VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$' ||
		die "version contains unsafe characters"
	LOCAL_NAME=$(basename "$LOCAL_FILE")
	printf '%s\n' "$LOCAL_NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$' ||
		die "local artifact filename contains unsafe characters"
	;;
rollback | "")
	;;
*)
	die "unsupported mode: $MODE"
	;;
esac

if [ -z "$MODE" ] && [ "$ACTIVATE" -ne 1 ]; then
	usage >&2
	exit 2
fi

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v cmp >/dev/null 2>&1 || die "cmp is required"
command -v flock >/dev/null 2>&1 || die "flock is required"
command -v "$CHOWN" >/dev/null 2>&1 || die "chown is required"
command -v setpriv >/dev/null 2>&1 || die "setpriv is required"

case "$APP_HOME" in
/*) ;;
*) die "AFTERTOUCH_SERVICE_HOME must be an absolute path" ;;
esac
[ "$APP_HOME" != / ] || die "refusing to use / as AFTERTOUCH_SERVICE_HOME"
case "$ON_BOOT_DIR" in
/*) ;;
*) die "AFTERTOUCH_ON_BOOT_DIR must be an absolute path" ;;
esac
[ "$ON_BOOT_DIR" != / ] || die "refusing to use / as AFTERTOUCH_ON_BOOT_DIR"

case "$MACHINE" in
aarch64 | arm64)
	ARCH=linux-arm64
	;;
armv7l | armv7 | armhf)
	ARCH=linux-armv7
	;;
x86_64 | amd64)
	ARCH=linux-amd64
	;;
*)
	die "unsupported architecture: $MACHINE"
	;;
esac

mkdir -p "$APP_HOME"
LOCK_FILE=$APP_HOME/.operation.lock
exec 9>"$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
flock -n 9 || die "another install or boot operation is already running"

mkdir -p "$APP_HOME/releases" "$DATA_DIR" "$SNAPSHOT_DIR" "$ON_BOOT_DIR"
chmod 0755 "$APP_HOME" "$APP_HOME/releases"
chmod 0700 "$DATA_DIR" "$SNAPSHOT_DIR"
"$CHOWN" 0:0 "$APP_HOME" "$APP_HOME/releases" "$SNAPSHOT_DIR"
"$CHOWN" -R 0:0 "$APP_HOME/releases"
"$CHOWN" -R "$SERVICE_UID:$SERVICE_GID" "$DATA_DIR"

copy_file() {
	copy_src=$1
	copy_dst=$2
	copy_mode=$3

	if [ -f "$copy_dst" ] && cmp -s "$copy_src" "$copy_dst"; then
		chmod "$copy_mode" "$copy_dst"
		return
	fi

	install -m "$copy_mode" "$copy_src" "$copy_dst"
}

for required in run.sh aftertouch-service-healthcheck.sh aftertouch-service-state.sh \
	aftertouch-service.service 27-aftertouch-service.sh aftertouch-service.env.example; do
	[ -f "$SCRIPT_DIR/$required" ] || die "missing addon file: $SCRIPT_DIR/$required"
done

copy_file "$SCRIPT_DIR/run.sh" "$APP_HOME/run.sh" 0755
copy_file "$SCRIPT_DIR/aftertouch-service-healthcheck.sh" "$APP_HOME/aftertouch-service-healthcheck.sh" 0755
copy_file "$SCRIPT_DIR/aftertouch-service-state.sh" "$APP_HOME/aftertouch-service-state.sh" 0755
copy_file "$SCRIPT_DIR/aftertouch-service.service" "$APP_HOME/aftertouch-service.service" 0644
"$CHOWN" 0:0 "$APP_HOME/run.sh" "$APP_HOME/aftertouch-service-healthcheck.sh" \
	"$APP_HOME/aftertouch-service-state.sh" "$APP_HOME/aftertouch-service.service"

if [ ! -f "$APP_HOME/config.env" ]; then
	install -m 0600 "$SCRIPT_DIR/aftertouch-service.env.example" "$APP_HOME/config.env"
	echo "aftertouch-service install: created $APP_HOME/config.env; review it before activation"
fi
chmod 0600 "$APP_HOME/config.env"
"$CHOWN" 0:0 "$APP_HOME/config.env"

download() {
	download_url=$1
	download_output=$2

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --tlsv1.2 -o "$download_output" "$download_url"
		return
	fi

	if command -v wget >/dev/null 2>&1; then
		wget -qO "$download_output" "$download_url"
		return
	fi

	die "curl or wget is required for release mode"
}

manifest_value() {
	manifest_key=$1
	manifest_file=$2
	awk -F= -v wanted="$manifest_key" '
        $1 == wanted { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count == 1) print value; else exit 1 }
    ' "$manifest_file"
}

release_dir_valid() {
	verify_dir=$1
	[ -d "$verify_dir" ] || return 1
	[ -f "$verify_dir/manifest" ] || return 1
	[ -x "$verify_dir/soundtouch-service" ] || return 1
	verify_expected=$(manifest_value sha256 "$verify_dir/manifest") || return 1
	verify_actual=$(sha256sum "$verify_dir/soundtouch-service" | awk '{print $1}')
	[ "$verify_actual" = "$verify_expected" ]
}

verify_release_dir() {
	verify_release_path=$1
	release_dir_valid "$verify_release_path" || die "invalid or corrupt release directory: $verify_release_path"
}

valid_release_target() {
	printf '%s\n' "$1" | grep -Eq '^releases/[A-Za-z0-9][A-Za-z0-9._+-]*$'
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
	# -T prevents mv from following an existing symlink to a directory.
	# UniFi OS ships a compatible GNU/BusyBox mv implementation.
	mv -Tf "$link_temporary" "$link_destination"
}

select_release() {
	select_target=$1
	valid_release_target "$select_target" || die "invalid release target: $select_target"

	verify_release_dir "$APP_HOME/$select_target"
	atomic_link current "$select_target"
}

stage_artifact() {
	stage_source_kind=$1
	stage_source_file=$2
	stage_source_name=$3
	stage_release_url=$4
	stage_expected=$5

	STAGE_DIR=$(mktemp -d "$APP_HOME/.install.XXXXXX") || die "cannot create staging directory"
	install -m 0755 "$stage_source_file" "$STAGE_DIR/soundtouch-service"
	stage_actual=$(sha256sum "$STAGE_DIR/soundtouch-service" | awk '{print $1}')

	if [ -n "$stage_expected" ] && [ "$stage_actual" != "$stage_expected" ]; then
		die "downloaded artifact checksum mismatch"
	fi

	stage_short_hash=$(printf '%s' "$stage_actual" | cut -c1-12)
	stage_artifact_id=${VERSION}-${ARCH}-${stage_short_hash}
	stage_release_dir=$APP_HOME/releases/$stage_artifact_id

	cat >"$STAGE_DIR/manifest" <<EOF
schema=1
component=aftertouch-service
source=$stage_source_kind
version=$VERSION
architecture=$ARCH
asset=$stage_source_name
sha256=$stage_actual
release_url=$stage_release_url
EOF
	chmod 0755 "$STAGE_DIR"
	chmod 0644 "$STAGE_DIR/manifest"

	if [ -d "$stage_release_dir" ]; then
		verify_release_dir "$stage_release_dir"
		stage_installed=$(sha256sum "$stage_release_dir/soundtouch-service" | awk '{print $1}')
		[ "$stage_installed" = "$stage_actual" ] || die "artifact ID collision at $stage_release_dir"
		cmp -s "$STAGE_DIR/manifest" "$stage_release_dir/manifest" ||
			die "artifact ID already exists with different provenance: $stage_artifact_id"
	else
		mv "$STAGE_DIR" "$stage_release_dir"
		STAGE_DIR=
	fi

	select_release "releases/$stage_artifact_id"
	echo "aftertouch-service install: selected $stage_artifact_id ($stage_actual)"
}

case "$MODE" in
release)
	asset=soundtouch-service-${VERSION}-${ARCH}
	DOWNLOAD_DIR=$(mktemp -d "$APP_HOME/.download.XXXXXX") || die "cannot create download directory"
	download "$RELEASE_BASE_URL/$VERSION/$asset" "$DOWNLOAD_DIR/$asset"
	download "$RELEASE_BASE_URL/$VERSION/$asset.sha256" "$DOWNLOAD_DIR/$asset.sha256"
	expected=$(awk 'NR == 1 { print $1 }' "$DOWNLOAD_DIR/$asset.sha256" | tr 'A-F' 'a-f')
	printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' || die "invalid release checksum file"
	candidate=$DOWNLOAD_DIR/$asset
	stage_artifact "$RELEASE_SOURCE" "$candidate" "$asset" "$RELEASE_BASE_URL/$VERSION/$asset" "$expected"
	chmod -R u+w "$DOWNLOAD_DIR" 2>/dev/null || true
	rm -rf "$DOWNLOAD_DIR"
	DOWNLOAD_DIR=
	;;
local)
	stage_artifact local "$LOCAL_FILE" "$LOCAL_NAME" "" ""
	;;
rollback)
	[ -L "$APP_HOME/current" ] || die "no current artifact is available"
	current_target=$(readlink "$APP_HOME/current")
	valid_release_target "$current_target" || die "invalid current target: $current_target"
	rollback_target=
	if [ -L "$APP_HOME/verified" ]; then
		verified_target=$(readlink "$APP_HOME/verified")
		if valid_release_target "$verified_target" &&
			[ "$current_target" != "$verified_target" ] &&
			release_dir_valid "$APP_HOME/$verified_target"; then
			rollback_target=$verified_target
		elif [ "$current_target" != "$verified_target" ]; then
			echo "aftertouch-service install: WARNING: ignoring corrupt verified target: $verified_target" >&2
		fi
	fi
	if [ -z "$rollback_target" ]; then
		[ -L "$APP_HOME/previous" ] || die "no verified rollback artifact is available"
		rollback_target=$(readlink "$APP_HOME/previous")
		valid_release_target "$rollback_target" || die "invalid previous target: $rollback_target"
	fi
	[ "$current_target" != "$rollback_target" ] || die "rollback target equals current artifact"
	verify_release_dir "$APP_HOME/$rollback_target"
	atomic_link current "$rollback_target"
	echo "aftertouch-service install: selected rollback target $rollback_target"
	;;
esac

[ -L "$APP_HOME/current" ] || die "no active artifact; install one first"

if [ "$ACTIVATE" -eq 1 ]; then
	copy_file "$SCRIPT_DIR/27-aftertouch-service.sh" "$ON_BOOT_DIR/27-aftertouch-service.sh" 0755
	AFTERTOUCH_SERVICE_HOME=$APP_HOME AFTERTOUCH_OPERATION_LOCK_HELD=1 \
		"$ON_BOOT_DIR/27-aftertouch-service.sh"
fi

if [ "$ACTIVATE" -ne 1 ]; then
	echo "aftertouch-service install: artifact selected but service not restarted; use --activate after reviewing config.env"
	if [ -e "$ON_BOOT_DIR/27-aftertouch-service.sh" ]; then
		echo "aftertouch-service install: WARNING: an existing boot hook will use the selected artifact after a reboot" >&2
	fi
fi
