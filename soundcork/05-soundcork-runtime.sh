#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/data/soundcork/soundcork.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

SOUNDCORK_STATE_DIR="${SOUNDCORK_STATE_DIR:-/data/soundcork}"
DOCKER_DAEMON_SOURCE="${DOCKER_DAEMON_SOURCE:-${SOUNDCORK_STATE_DIR}/docker-daemon.json}"
DOCKER_DAEMON_TARGET="${DOCKER_DAEMON_TARGET:-/etc/docker/daemon.json}"
DOCKER_SERVICE="${DOCKER_SERVICE:-docker}"
SOUNDCORK_RUNTIME_PREFER="${SOUNDCORK_RUNTIME_PREFER:-docker}"
SOUNDCORK_RUNTIME_AUTO_INSTALL="${SOUNDCORK_RUNTIME_AUTO_INSTALL:-0}"
SOUNDCORK_RUNTIME_APT_PACKAGE="${SOUNDCORK_RUNTIME_APT_PACKAGE:-docker.io}"
SOUNDCORK_RUNTIME_APT_UPDATE="${SOUNDCORK_RUNTIME_APT_UPDATE:-0}"

TMP_FILE=""
DAEMON_CONFIG_CHANGED=0

cleanup() {
    if [ -n "$TMP_FILE" ]; then
        rm -f "$TMP_FILE"
    fi
}

trap cleanup EXIT HUP INT TERM

log() {
    logger -t soundcork-runtime "$*" 2>/dev/null || true
    echo "soundcork-runtime: $*"
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

restore_docker_daemon_config() {
    if [ ! -f "$DOCKER_DAEMON_SOURCE" ]; then
        log "no persisted Docker daemon config at ${DOCKER_DAEMON_SOURCE}; leaving ${DOCKER_DAEMON_TARGET} unchanged"
        return 0
    fi

    target_dir=${DOCKER_DAEMON_TARGET%/*}
    if [ "$target_dir" = "$DOCKER_DAEMON_TARGET" ]; then
        target_dir=.
    fi

    mkdir -p "$target_dir"

    if [ -f "$DOCKER_DAEMON_TARGET" ] && cmp -s "$DOCKER_DAEMON_SOURCE" "$DOCKER_DAEMON_TARGET"; then
        log "Docker daemon config already matches ${DOCKER_DAEMON_SOURCE}"
        return 0
    fi

    TMP_FILE="${DOCKER_DAEMON_TARGET}.soundcork.$$"
    rm -f "$TMP_FILE"
    cp "$DOCKER_DAEMON_SOURCE" "$TMP_FILE"
    chmod 0644 "$TMP_FILE"
    mv "$TMP_FILE" "$DOCKER_DAEMON_TARGET"
    TMP_FILE=""
    DAEMON_CONFIG_CHANGED=1
    log "restored Docker daemon config from ${DOCKER_DAEMON_SOURCE}"
}

docker_has_running_containers() {
    [ -n "$(docker ps -q 2>/dev/null | sed -n '1p')" ]
}

start_or_restart_docker() {
    action=start
    if [ "$DAEMON_CONFIG_CHANGED" -eq 1 ]; then
        action=restart
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if systemctl "$action" "$DOCKER_SERVICE" >/dev/null 2>&1; then
            return 0
        fi
        log "systemctl ${action} ${DOCKER_SERVICE} failed"
    fi

    if command -v service >/dev/null 2>&1; then
        if service "$DOCKER_SERVICE" "$action" >/dev/null 2>&1; then
            return 0
        fi
        log "service ${DOCKER_SERVICE} ${action} failed"
    fi

    if [ -x "/etc/init.d/${DOCKER_SERVICE}" ]; then
        if "/etc/init.d/${DOCKER_SERVICE}" "$action" >/dev/null 2>&1; then
            return 0
        fi
        log "/etc/init.d/${DOCKER_SERVICE} ${action} failed"
    fi

    return 1
}

ensure_docker_usable() {
    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    if docker info >/dev/null 2>&1; then
        if [ "$DAEMON_CONFIG_CHANGED" -eq 1 ]; then
            if docker_has_running_containers; then
                log "Docker config changed but containers are already running; not restarting Docker automatically"
            else
                log "Docker config changed; restarting Docker to apply it"
                if ! start_or_restart_docker; then
                    log "Docker restart failed after config restore"
                    return 1
                fi
            fi
        fi

        if docker info >/dev/null 2>&1; then
            log "docker runtime is usable"
            return 0
        fi
    fi

    log "docker command found but daemon is not usable; attempting to start ${DOCKER_SERVICE}"
    if start_or_restart_docker && docker info >/dev/null 2>&1; then
        log "docker runtime is usable"
        return 0
    fi

    log "docker runtime is not usable"
    return 1
}

ensure_podman_usable() {
    if ! command -v podman >/dev/null 2>&1; then
        return 1
    fi

    if podman info >/dev/null 2>&1; then
        log "podman runtime is usable"
        return 0
    fi

    log "podman command found but runtime is not usable"
    return 1
}

ensure_runtime_usable() {
    case "$SOUNDCORK_RUNTIME_PREFER" in
        podman)
            ensure_podman_usable && return 0
            ensure_docker_usable && return 0
            ;;
        *)
            ensure_docker_usable && return 0
            ensure_podman_usable && return 0
            ;;
    esac

    return 1
}

apt_install_docker() {
    if ! is_truthy "$SOUNDCORK_RUNTIME_AUTO_INSTALL"; then
        log "runtime auto-install is disabled"
        return 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        log "apt-get is not available; cannot install ${SOUNDCORK_RUNTIME_APT_PACKAGE}"
        return 1
    fi

    log "installing ${SOUNDCORK_RUNTIME_APT_PACKAGE} with apt-get"
    export DEBIAN_FRONTEND=noninteractive

    if apt-get install -y -o Dpkg::Options::=--force-confold "$SOUNDCORK_RUNTIME_APT_PACKAGE" >/dev/null 2>&1; then
        return 0
    fi

    log "apt-get install ${SOUNDCORK_RUNTIME_APT_PACKAGE} failed"
    if is_truthy "$SOUNDCORK_RUNTIME_APT_UPDATE"; then
        log "running apt-get update before retrying ${SOUNDCORK_RUNTIME_APT_PACKAGE}"
        if apt-get update >/dev/null 2>&1 &&
            apt-get install -y -o Dpkg::Options::=--force-confold "$SOUNDCORK_RUNTIME_APT_PACKAGE" >/dev/null 2>&1; then
            return 0
        fi
        log "apt-get retry for ${SOUNDCORK_RUNTIME_APT_PACKAGE} failed"
    fi

    return 1
}

restore_docker_daemon_config

if ensure_runtime_usable; then
    exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
    if apt_install_docker && ensure_docker_usable; then
        exit 0
    fi
fi

if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
    log "container runtime command exists but no runtime is usable"
    exit 1
fi

log "no usable docker or podman runtime found for SoundCork"
exit 1
