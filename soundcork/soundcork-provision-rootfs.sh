#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/data/soundcork/soundcork.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

SOUNDCORK_STATE_DIR="${SOUNDCORK_STATE_DIR:-/data/soundcork}"
SOUNDCORK_ROOTFS="${SOUNDCORK_ROOTFS:-${SOUNDCORK_STATE_DIR}/nspawn-rootfs}"
SOUNDCORK_ROOTFS_SUITE="${SOUNDCORK_ROOTFS_SUITE:-trixie}"
SOUNDCORK_ROOTFS_MIRROR="${SOUNDCORK_ROOTFS_MIRROR:-http://deb.debian.org/debian}"
SOUNDCORK_ROOTFS_INCLUDE="${SOUNDCORK_ROOTFS_INCLUDE:-ca-certificates,curl,git,python3,python3-pip,python3-venv}"
SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS="${SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS:-0}"
SOUNDCORK_ROOTFS_APT_UPDATE="${SOUNDCORK_ROOTFS_APT_UPDATE:-0}"
SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA="${SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA:-0}"
SOUNDCORK_ROOTFS_MIN_PYTHON="${SOUNDCORK_ROOTFS_MIN_PYTHON:-3.12}"
SOUNDCORK_ROOTFS_PYTHON="${SOUNDCORK_ROOTFS_PYTHON:-/usr/bin/python3}"
SOUNDCORK_REPO_URL="${SOUNDCORK_REPO_URL:-https://github.com/deborahgu/soundcork.git}"
SOUNDCORK_REPO_REF="${SOUNDCORK_REPO_REF:-main}"
SOUNDCORK_APP_DIR="${SOUNDCORK_APP_DIR:-/opt/soundcork/soundcork}"
SOUNDCORK_VENV="${SOUNDCORK_VENV:-/opt/soundcork-venv}"
SOUNDCORK_GUNICORN="${SOUNDCORK_GUNICORN:-${SOUNDCORK_VENV}/bin/gunicorn}"
SOUNDCORK_NSPAWN="${SOUNDCORK_NSPAWN:-}"

log() {
    logger -t soundcork-rootfs "$*" 2>/dev/null || true
    echo "soundcork-rootfs: $*"
}

die() {
    log "$*"
    exit 1
}

is_truthy() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

run_in_rootfs() {
    chroot "$SOUNDCORK_ROOTFS" "$@"
}

install_host_tools() {
    if ! is_truthy "$SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS"; then
        return 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get is not available; install debootstrap manually"
    fi

    export DEBIAN_FRONTEND=noninteractive

    if is_truthy "$SOUNDCORK_ROOTFS_APT_UPDATE"; then
        log "running apt-get update for host provisioning tools"
        apt-get update
    fi

    log "installing host provisioning tools"
    apt-get install -y -o Dpkg::Options::=--force-confold debootstrap
}

ensure_host_tools() {
    if is_truthy "$SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS" &&
        ! command -v debootstrap >/dev/null 2>&1; then
        install_host_tools
    fi

    if command -v debootstrap >/dev/null 2>&1; then
        return 0
    fi

    die "debootstrap is missing; install it or set SOUNDCORK_ROOTFS_INSTALL_HOST_TOOLS=1"
}

validate_paths() {
    [ "$(id -u)" = "0" ] || die "run this script as root on the UniFi host"
    command -v chroot >/dev/null 2>&1 || die "chroot is missing on this host"

    case "$SOUNDCORK_ROOTFS" in
        /data/*)
            ;;
        *)
            if ! is_truthy "$SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA"; then
                die "refusing rootfs outside /data; set SOUNDCORK_ROOTFS_ALLOW_OUTSIDE_DATA=1 to override"
            fi
            ;;
    esac

    case "$SOUNDCORK_APP_DIR" in
        /*)
            ;;
        *)
            die "SOUNDCORK_APP_DIR must be an absolute path inside the rootfs"
            ;;
    esac

    case "$SOUNDCORK_VENV" in
        /*)
            ;;
        *)
            die "SOUNDCORK_VENV must be an absolute path inside the rootfs"
            ;;
    esac

    case "$SOUNDCORK_GUNICORN" in
        /*)
            ;;
        *)
            die "SOUNDCORK_GUNICORN must be an absolute path inside the rootfs"
            ;;
    esac

    case "$SOUNDCORK_ROOTFS_PYTHON" in
        /*)
            ;;
        *)
            die "SOUNDCORK_ROOTFS_PYTHON must be an absolute path inside the rootfs"
            ;;
    esac
}

rootfs_has_base_system() {
    [ -f "${SOUNDCORK_ROOTFS}/etc/os-release" ] || [ -f "${SOUNDCORK_ROOTFS}/etc/debian_version" ]
}

rootfs_is_nonempty() {
    [ -d "$SOUNDCORK_ROOTFS" ] || return 1
    [ -n "$(find "$SOUNDCORK_ROOTFS" -mindepth 1 -maxdepth 1 2>/dev/null | sed -n '1p')" ]
}

create_base_rootfs() {
    if rootfs_has_base_system; then
        log "using existing rootfs at ${SOUNDCORK_ROOTFS}"
        return 0
    fi

    if rootfs_is_nonempty; then
        die "rootfs path exists but is not a recognized base system: ${SOUNDCORK_ROOTFS}"
    fi

    mkdir -p "${SOUNDCORK_ROOTFS%/*}"
    ensure_host_tools

    log "creating ${SOUNDCORK_ROOTFS_SUITE} rootfs at ${SOUNDCORK_ROOTFS}"
    if [ -n "$SOUNDCORK_ROOTFS_INCLUDE" ]; then
        debootstrap \
            --include="$SOUNDCORK_ROOTFS_INCLUDE" \
            "$SOUNDCORK_ROOTFS_SUITE" \
            "$SOUNDCORK_ROOTFS" \
            "$SOUNDCORK_ROOTFS_MIRROR"
    else
        debootstrap "$SOUNDCORK_ROOTFS_SUITE" "$SOUNDCORK_ROOTFS" "$SOUNDCORK_ROOTFS_MIRROR"
    fi
}

copy_dns_config() {
    if [ -f /etc/resolv.conf ]; then
        mkdir -p "${SOUNDCORK_ROOTFS}/etc"
        rm -f "${SOUNDCORK_ROOTFS}/etc/resolv.conf"
        cp /etc/resolv.conf "${SOUNDCORK_ROOTFS}/etc/resolv.conf"
    fi
}

ensure_rootfs_commands() {
    run_in_rootfs /bin/sh -c 'command -v git >/dev/null 2>&1' ||
        die "git is missing inside the rootfs; add it to SOUNDCORK_ROOTFS_INCLUDE and recreate the rootfs"
    [ -x "${SOUNDCORK_ROOTFS}${SOUNDCORK_ROOTFS_PYTHON}" ] ||
        die "Python is missing at ${SOUNDCORK_ROOTFS_PYTHON}; add it to SOUNDCORK_ROOTFS_INCLUDE and recreate the rootfs"
}

check_python_version() {
    [ -n "$SOUNDCORK_ROOTFS_MIN_PYTHON" ] || return 0

    if run_in_rootfs "$SOUNDCORK_ROOTFS_PYTHON" - "$SOUNDCORK_ROOTFS_MIN_PYTHON" <<'PY'
import sys

want = tuple(int(part) for part in sys.argv[1].split(".") if part)
have = sys.version_info[:len(want)]
raise SystemExit(0 if have >= want else 1)
PY
    then
        return 0
    fi

    die "rootfs Python is older than ${SOUNDCORK_ROOTFS_MIN_PYTHON}; choose a newer suite, a compatible SoundCork ref, or lower SOUNDCORK_ROOTFS_MIN_PYTHON"
}

install_soundcork_source() {
    app_parent="${SOUNDCORK_APP_DIR%/*}"
    app_path="${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}"

    mkdir -p "${SOUNDCORK_ROOTFS}${app_parent}"

    if [ -d "${app_path}/.git" ]; then
        log "updating existing SoundCork checkout at ${SOUNDCORK_APP_DIR}"
        checkout_soundcork_ref
        return 0
    fi

    if [ -e "$app_path" ]; then
        die "SoundCork app path exists but is not a git checkout: ${SOUNDCORK_APP_DIR}"
    fi

    log "cloning SoundCork source into ${SOUNDCORK_APP_DIR}"
    run_in_rootfs git clone "$SOUNDCORK_REPO_URL" "$SOUNDCORK_APP_DIR"
    checkout_soundcork_ref
}

checkout_soundcork_ref() {
    if run_in_rootfs git -C "$SOUNDCORK_APP_DIR" fetch --tags origin "$SOUNDCORK_REPO_REF"; then
        run_in_rootfs git -C "$SOUNDCORK_APP_DIR" checkout FETCH_HEAD
        return 0
    fi

    run_in_rootfs git -C "$SOUNDCORK_APP_DIR" fetch --tags origin
    run_in_rootfs git -C "$SOUNDCORK_APP_DIR" checkout "$SOUNDCORK_REPO_REF"
}

install_python_environment() {
    pip_bin="${SOUNDCORK_VENV}/bin/pip"

    log "creating Python virtualenv at ${SOUNDCORK_VENV}"
    run_in_rootfs "$SOUNDCORK_ROOTFS_PYTHON" -m venv "$SOUNDCORK_VENV"
    run_in_rootfs "$pip_bin" install --upgrade pip setuptools wheel

    if [ -f "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}/requirements.txt" ]; then
        log "installing SoundCork requirements.txt"
        run_in_rootfs "$pip_bin" install -r "${SOUNDCORK_APP_DIR}/requirements.txt"
    fi

    if [ -f "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}/pyproject.toml" ] ||
        [ -f "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}/setup.py" ]; then
        log "installing SoundCork package metadata"
        run_in_rootfs "$pip_bin" install "$SOUNDCORK_APP_DIR"
    fi

    log "installing Gunicorn"
    run_in_rootfs "$pip_bin" install gunicorn
}

verify_layout() {
    [ -d "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}" ] ||
        die "missing SoundCork app directory at ${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}"
    [ -f "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}/main.py" ] ||
        die "missing main.py under ${SOUNDCORK_APP_DIR}; check SOUNDCORK_REPO_REF and SOUNDCORK_APP_DIR"
    [ -f "${SOUNDCORK_ROOTFS}${SOUNDCORK_APP_DIR}/gunicorn_conf.py" ] ||
        die "missing gunicorn_conf.py under ${SOUNDCORK_APP_DIR}; check SOUNDCORK_REPO_REF and SOUNDCORK_APP_DIR"
    [ -x "${SOUNDCORK_ROOTFS}${SOUNDCORK_GUNICORN}" ] ||
        die "missing executable Gunicorn at ${SOUNDCORK_ROOTFS}${SOUNDCORK_GUNICORN}"
}

write_marker() {
    marker="${SOUNDCORK_ROOTFS}/etc/soundcork-rootfs-provisioned"

    {
        echo "suite=${SOUNDCORK_ROOTFS_SUITE}"
        echo "repo_url=${SOUNDCORK_REPO_URL}"
        echo "repo_ref=${SOUNDCORK_REPO_REF}"
        echo "app_dir=${SOUNDCORK_APP_DIR}"
        echo "venv=${SOUNDCORK_VENV}"
        echo "gunicorn=${SOUNDCORK_GUNICORN}"
        echo "provisioned_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$marker"
    chmod 0644 "$marker"
}

warn_runtime_tools() {
    if [ -n "$SOUNDCORK_NSPAWN" ] && [ -x "$SOUNDCORK_NSPAWN" ]; then
        return 0
    fi

    if command -v systemd-nspawn >/dev/null 2>&1 ||
        [ -x "${SOUNDCORK_STATE_DIR}/nspawn-tools/usr/bin/systemd-nspawn" ] ||
        [ -x "${SOUNDCORK_STATE_DIR}/systemd-nspawn/usr/bin/systemd-nspawn" ]; then
        return 0
    fi

    log "warning: systemd-nspawn was not found; set SOUNDCORK_NSPAWN to an extracted binary or install systemd-container before running soundcork-nspawn.sh"
}

validate_paths
create_base_rootfs
copy_dns_config
ensure_rootfs_commands
check_python_version
install_soundcork_source
install_python_environment
verify_layout
write_marker
warn_runtime_tools

log "rootfs is ready at ${SOUNDCORK_ROOTFS}"
