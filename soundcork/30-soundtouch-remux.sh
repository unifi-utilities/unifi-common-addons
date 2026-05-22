#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/data/soundcork/soundcork.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

SOUNDTOUCH_REMUX_ENABLED="${SOUNDTOUCH_REMUX_ENABLED:-0}"
SOUNDTOUCH_REMUX_PORT="${SOUNDTOUCH_REMUX_PORT:-8768}"
SOUNDTOUCH_REMUX_RUNTIME="${SOUNDTOUCH_REMUX_RUNTIME:-auto}"
SOUNDTOUCH_REMUX_ROOTFS="${SOUNDTOUCH_REMUX_ROOTFS:-${SOUNDCORK_ROOTFS:-/data/soundcork/nspawn-rootfs}}"
SOUNDTOUCH_REMUX_NSPAWN="${SOUNDTOUCH_REMUX_NSPAWN:-${SOUNDCORK_NSPAWN:-}}"
SOUNDTOUCH_REMUX_IMAGE="${SOUNDTOUCH_REMUX_IMAGE:-localhost/soundtouch-remux:flac}"
SOUNDTOUCH_REMUX_CONTAINER="${SOUNDTOUCH_REMUX_CONTAINER:-soundtouch-remux}"
SOUNDTOUCH_REMUX_STATE_DIR="${SOUNDTOUCH_REMUX_STATE_DIR:-/data/soundcork/remux}"
SOUNDTOUCH_REMUX_SCRIPT="${SOUNDTOUCH_REMUX_SCRIPT:-/data/soundcork/remux_stream_endpoint.py}"
SOUNDTOUCH_REMUX_PID_FILE="${SOUNDTOUCH_REMUX_PID_FILE:-/data/soundcork/soundtouch-remux-rootfs.pid}"
SOUNDTOUCH_REMUX_LOG_FILE="${SOUNDTOUCH_REMUX_LOG_FILE:-/data/soundcork/logs/soundtouch-remux-rootfs.log}"
SOUNDTOUCH_REMUX_LOG_MAX_BYTES="${SOUNDTOUCH_REMUX_LOG_MAX_BYTES:-10485760}"
SOUNDTOUCH_REMUX_LOG_ROTATIONS="${SOUNDTOUCH_REMUX_LOG_ROTATIONS:-3}"
SOUNDTOUCH_REMUX_UPSTREAM="${SOUNDTOUCH_REMUX_UPSTREAM:-https://amp.cesnet.cz:8443/cro3.flac}"
SOUNDTOUCH_REMUX_FFMPEG="${SOUNDTOUCH_REMUX_FFMPEG:-}"
SOUNDTOUCH_REMUX_RUNTIME_PATH="${SOUNDTOUCH_REMUX_RUNTIME_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
SOUNDTOUCH_REMUX_ALLOW_HOSTS="${SOUNDTOUCH_REMUX_ALLOW_HOSTS:-}"
SOUNDTOUCH_REMUX_MAX_ACTIVE_PROCESSES="${SOUNDTOUCH_REMUX_MAX_ACTIVE_PROCESSES:-}"
SOUNDTOUCH_REMUX_REBUILD="${SOUNDTOUCH_REMUX_REBUILD:-0}"
SOUNDTOUCH_REMUX_READY_TIMEOUT="${SOUNDTOUCH_REMUX_READY_TIMEOUT:-60}"
SOUNDTOUCH_REMUX_READY_INTERVAL="${SOUNDTOUCH_REMUX_READY_INTERVAL:-2}"
SOUNDTOUCH_REMUX_REQUIRED="${SOUNDTOUCH_REMUX_REQUIRED:-0}"
SOUNDCORK_CONTAINER_LOG_DRIVER="${SOUNDCORK_CONTAINER_LOG_DRIVER:-local}"
SOUNDCORK_CONTAINER_LOG_MAX_SIZE="${SOUNDCORK_CONTAINER_LOG_MAX_SIZE:-10m}"
SOUNDCORK_CONTAINER_LOG_MAX_FILE="${SOUNDCORK_CONTAINER_LOG_MAX_FILE:-3}"

log() {
    logger -t soundtouch-remux-onboot "$*" 2>/dev/null || true
    echo "soundtouch-remux-onboot: $*"
}

fatal_or_skip() {
    log "$1"
    case "$SOUNDTOUCH_REMUX_REQUIRED" in
        1|true|yes|on)
            exit 1
            ;;
        *)
            exit 0
            ;;
    esac
}

case "$SOUNDTOUCH_REMUX_ENABLED" in
    1|true|yes|on)
        ;;
    *)
        log "disabled; set SOUNDTOUCH_REMUX_ENABLED=1 to start"
        exit 0
        ;;
esac

if [ ! -f "$SOUNDTOUCH_REMUX_SCRIPT" ]; then
    log "missing remux script at $SOUNDTOUCH_REMUX_SCRIPT"
    exit 1
fi

find_nspawn() {
    if [ -n "$SOUNDTOUCH_REMUX_NSPAWN" ]; then
        NSPAWN_BIN="$SOUNDTOUCH_REMUX_NSPAWN"
    elif command -v systemd-nspawn >/dev/null 2>&1; then
        NSPAWN_BIN="$(command -v systemd-nspawn)"
    elif [ -x /data/soundcork/nspawn-tools/usr/bin/systemd-nspawn ]; then
        NSPAWN_BIN=/data/soundcork/nspawn-tools/usr/bin/systemd-nspawn
    elif [ -x /data/soundcork/nspawn-probe/extract/usr/bin/systemd-nspawn ]; then
        NSPAWN_BIN=/data/soundcork/nspawn-probe/extract/usr/bin/systemd-nspawn
    else
        NSPAWN_BIN=
    fi

    [ -n "$NSPAWN_BIN" ] && [ -x "$NSPAWN_BIN" ]
}

nspawn_ready() {
    find_nspawn \
        && [ -d "$SOUNDTOUCH_REMUX_ROOTFS" ] \
        && [ -x "$SOUNDTOUCH_REMUX_ROOTFS/usr/bin/python3" ] \
        && ffmpeg_ready_in_rootfs
}

rootfs_ready() {
    command -v chroot >/dev/null 2>&1 \
        && [ -d "$SOUNDTOUCH_REMUX_ROOTFS" ] \
        && [ -x "$SOUNDTOUCH_REMUX_ROOTFS/usr/bin/python3" ] \
        && ffmpeg_ready_in_rootfs
}

ffmpeg_ready_in_rootfs() {
    if [ -z "$SOUNDTOUCH_REMUX_FFMPEG" ]; then
        [ -x "$SOUNDTOUCH_REMUX_ROOTFS/usr/bin/ffmpeg" ]
        return
    fi

    case "$SOUNDTOUCH_REMUX_FFMPEG" in
        /*)
            [ -x "$SOUNDTOUCH_REMUX_ROOTFS$SOUNDTOUCH_REMUX_FFMPEG" ]
            ;;
        *)
            [ -x "$SOUNDTOUCH_REMUX_ROOTFS/usr/bin/$SOUNDTOUCH_REMUX_FFMPEG" ] \
                || [ -x "$SOUNDTOUCH_REMUX_ROOTFS/usr/local/bin/$SOUNDTOUCH_REMUX_FFMPEG" ]
            ;;
    esac
}

container_runtime() {
    if command -v docker >/dev/null 2>&1; then
        RUNTIME=docker
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME=podman
    else
        RUNTIME=
    fi
    [ -n "$RUNTIME" ]
}

stop_rootfs_process() {
    if [ ! -f "$SOUNDTOUCH_REMUX_PID_FILE" ]; then
        return 0
    fi

    old_pid="$(cat "$SOUNDTOUCH_REMUX_PID_FILE" 2>/dev/null || true)"
    if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
        log "stopping previous rootfs remux process $old_pid"
        kill "$old_pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$SOUNDTOUCH_REMUX_PID_FILE"
}

stop_container_if_present() {
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$SOUNDTOUCH_REMUX_CONTAINER" >/dev/null 2>&1 || true
    fi
    if command -v podman >/dev/null 2>&1; then
        podman rm -f "$SOUNDTOUCH_REMUX_CONTAINER" >/dev/null 2>&1 || true
    fi
}

normalize_log_limits() {
    case "$SOUNDTOUCH_REMUX_LOG_MAX_BYTES" in
        ''|*[!0-9]*)
            SOUNDTOUCH_REMUX_LOG_MAX_BYTES=10485760
            ;;
    esac
    case "$SOUNDTOUCH_REMUX_LOG_ROTATIONS" in
        ''|*[!0-9]*)
            SOUNDTOUCH_REMUX_LOG_ROTATIONS=3
            ;;
    esac
}

rotate_log_if_needed() {
    normalize_log_limits
    [ "$SOUNDTOUCH_REMUX_LOG_MAX_BYTES" -gt 0 ] || return 0
    [ -f "$SOUNDTOUCH_REMUX_LOG_FILE" ] || return 0

    size="$(wc -c <"$SOUNDTOUCH_REMUX_LOG_FILE" 2>/dev/null || echo 0)"
    size="$(printf '%s' "$size" | tr -d ' ')"
    case "$size" in
        ''|*[!0-9]*)
            size=0
            ;;
    esac

    [ "$size" -lt "$SOUNDTOUCH_REMUX_LOG_MAX_BYTES" ] || {
        if [ "$SOUNDTOUCH_REMUX_LOG_ROTATIONS" -eq 0 ]; then
            : >"$SOUNDTOUCH_REMUX_LOG_FILE"
            return 0
        fi

        i=$((SOUNDTOUCH_REMUX_LOG_ROTATIONS - 1))
        while [ "$i" -ge 1 ]; do
            if [ -f "${SOUNDTOUCH_REMUX_LOG_FILE}.${i}" ]; then
                mv -f "${SOUNDTOUCH_REMUX_LOG_FILE}.${i}" "${SOUNDTOUCH_REMUX_LOG_FILE}.$((i + 1))"
            fi
            i=$((i - 1))
        done
        mv -f "$SOUNDTOUCH_REMUX_LOG_FILE" "${SOUNDTOUCH_REMUX_LOG_FILE}.1"
    }
}

wait_for_ready() {
    elapsed=0
    while [ "$elapsed" -lt "$SOUNDTOUCH_REMUX_READY_TIMEOUT" ]; do
        if curl -fsS --max-time 5 "http://127.0.0.1:${SOUNDTOUCH_REMUX_PORT}/healthz" >/dev/null 2>&1; then
            log "remux endpoint ready at http://127.0.0.1:${SOUNDTOUCH_REMUX_PORT}/flac"
            return 0
        fi
        sleep "$SOUNDTOUCH_REMUX_READY_INTERVAL"
        elapsed=$((elapsed + SOUNDTOUCH_REMUX_READY_INTERVAL))
    done
    return 1
}

build_remux_args() {
    python_cmd="$1"
    set -- \
        "$python_cmd" /app/remux_stream_endpoint.py \
            --host 0.0.0.0 \
            --port "$SOUNDTOUCH_REMUX_PORT" \
            --default-upstream "$SOUNDTOUCH_REMUX_UPSTREAM"

    for allow_host in $(printf '%s\n' "$SOUNDTOUCH_REMUX_ALLOW_HOSTS" | tr ',' ' '); do
        set -- "$@" --allow-host "$allow_host"
    done

    if [ -n "$SOUNDTOUCH_REMUX_MAX_ACTIVE_PROCESSES" ]; then
        set -- "$@" --max-active-processes "$SOUNDTOUCH_REMUX_MAX_ACTIVE_PROCESSES"
    fi

    if [ -n "$SOUNDTOUCH_REMUX_FFMPEG" ]; then
        set -- "$@" --ffmpeg-bin "$SOUNDTOUCH_REMUX_FFMPEG"
    fi

    REMUX_ARGS="$*"
}

start_rootfs() {
    rootfs_ready || fatal_or_skip "rootfs remux runtime is not ready; missing chroot, rootfs, python3, or ffmpeg"

    stop_rootfs_process
    stop_container_if_present
    mkdir -p "$(dirname "$SOUNDTOUCH_REMUX_LOG_FILE")" "$SOUNDTOUCH_REMUX_ROOTFS/app"
    install -m 0644 "$SOUNDTOUCH_REMUX_SCRIPT" "$SOUNDTOUCH_REMUX_ROOTFS/app/remux_stream_endpoint.py"
    rotate_log_if_needed

    build_remux_args /usr/bin/python3
    # shellcheck disable=SC2086
    set -- $REMUX_ARGS

    log "starting rootfs remux on port ${SOUNDTOUCH_REMUX_PORT} rootfs=${SOUNDTOUCH_REMUX_ROOTFS}"
    (
        exec env PATH="$SOUNDTOUCH_REMUX_RUNTIME_PATH" chroot "$SOUNDTOUCH_REMUX_ROOTFS" "$@"
    ) >>"$SOUNDTOUCH_REMUX_LOG_FILE" 2>&1 < /dev/null &
    new_pid="$!"
    echo "$new_pid" >"$SOUNDTOUCH_REMUX_PID_FILE"

    if wait_for_ready; then
        exit 0
    fi

    log "rootfs remux endpoint did not become ready within ${SOUNDTOUCH_REMUX_READY_TIMEOUT}s"
    tail -n 80 "$SOUNDTOUCH_REMUX_LOG_FILE" 2>&1 | while IFS= read -r line; do
        log "rootfs-log: $line"
    done
    kill "$new_pid" 2>/dev/null || true
    rm -f "$SOUNDTOUCH_REMUX_PID_FILE"
    exit 1
}

start_nspawn() {
    nspawn_ready || fatal_or_skip "nspawn remux runtime is not ready; missing systemd-nspawn, rootfs, python3, or ffmpeg"

    stop_rootfs_process
    stop_container_if_present
    mkdir -p "$(dirname "$SOUNDTOUCH_REMUX_LOG_FILE")" "$SOUNDTOUCH_REMUX_ROOTFS/app"
    rotate_log_if_needed

    build_remux_args /usr/bin/python3
    # shellcheck disable=SC2086
    set -- $REMUX_ARGS

    log "starting nspawn remux on port ${SOUNDTOUCH_REMUX_PORT} rootfs=${SOUNDTOUCH_REMUX_ROOTFS}"
    (
        exec "$NSPAWN_BIN" \
            --quiet \
            --register=no \
            --setenv="PATH=${SOUNDTOUCH_REMUX_RUNTIME_PATH}" \
            --directory="$SOUNDTOUCH_REMUX_ROOTFS" \
            --bind-ro="${SOUNDTOUCH_REMUX_SCRIPT}:/app/remux_stream_endpoint.py" \
            --as-pid2 \
            "$@"
    ) >>"$SOUNDTOUCH_REMUX_LOG_FILE" 2>&1 < /dev/null &
    new_pid="$!"
    echo "$new_pid" >"$SOUNDTOUCH_REMUX_PID_FILE"

    if wait_for_ready; then
        exit 0
    fi

    log "nspawn remux endpoint did not become ready within ${SOUNDTOUCH_REMUX_READY_TIMEOUT}s"
    tail -n 80 "$SOUNDTOUCH_REMUX_LOG_FILE" 2>&1 | while IFS= read -r line; do
        log "nspawn-log: $line"
    done
    kill "$new_pid" 2>/dev/null || true
    rm -f "$SOUNDTOUCH_REMUX_PID_FILE"
    exit 1
}

start_container() {
    container_runtime || fatal_or_skip "no docker or podman runtime found; remux sidecar not started"
    stop_rootfs_process

mkdir -p "$SOUNDTOUCH_REMUX_STATE_DIR"
cat >"${SOUNDTOUCH_REMUX_STATE_DIR}/Containerfile" <<'EOF'
FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*
USER nobody:nogroup
EOF

if ! "$RUNTIME" image inspect "$SOUNDTOUCH_REMUX_IMAGE" >/dev/null 2>&1 \
    || [ "$SOUNDTOUCH_REMUX_REBUILD" = "1" ]; then
    log "building ${SOUNDTOUCH_REMUX_IMAGE}"
    "$RUNTIME" build --network host -t "$SOUNDTOUCH_REMUX_IMAGE" -f "${SOUNDTOUCH_REMUX_STATE_DIR}/Containerfile" "$SOUNDTOUCH_REMUX_STATE_DIR"
fi

if "$RUNTIME" ps -a --format '{{.Names}}' | grep -qx "$SOUNDTOUCH_REMUX_CONTAINER"; then
    "$RUNTIME" rm -f "$SOUNDTOUCH_REMUX_CONTAINER" >/dev/null 2>&1 || true
fi

CONTAINER_LOG_ARGS=""
if [ "$RUNTIME" = docker ]; then
    CONTAINER_LOG_ARGS="--log-driver ${SOUNDCORK_CONTAINER_LOG_DRIVER} --log-opt max-size=${SOUNDCORK_CONTAINER_LOG_MAX_SIZE} --log-opt max-file=${SOUNDCORK_CONTAINER_LOG_MAX_FILE}"
fi

log "starting ${SOUNDTOUCH_REMUX_CONTAINER} on port ${SOUNDTOUCH_REMUX_PORT}"
build_remux_args python3
# shellcheck disable=SC2086
set -- $REMUX_ARGS

"$RUNTIME" run -d \
    --name "$SOUNDTOUCH_REMUX_CONTAINER" \
    --network host \
    --restart unless-stopped \
    $CONTAINER_LOG_ARGS \
    -v "${SOUNDTOUCH_REMUX_SCRIPT}:/app/remux_stream_endpoint.py:ro" \
    "$SOUNDTOUCH_REMUX_IMAGE" \
    "$@" >/dev/null

if wait_for_ready; then
    exit 0
fi

log "remux endpoint did not become ready within ${SOUNDTOUCH_REMUX_READY_TIMEOUT}s"
"$RUNTIME" logs --tail 80 "$SOUNDTOUCH_REMUX_CONTAINER" 2>&1 | while IFS= read -r line; do
    log "container-log: $line"
done
exit 1
}

case "$SOUNDTOUCH_REMUX_RUNTIME" in
    rootfs|chroot)
        start_rootfs
        ;;
    nspawn)
        start_nspawn
        ;;
    container|docker|podman)
        start_container
        ;;
    auto)
        if rootfs_ready; then
            start_rootfs
        else
            start_container
        fi
        ;;
    *)
        log "unknown SOUNDTOUCH_REMUX_RUNTIME=${SOUNDTOUCH_REMUX_RUNTIME}; expected auto, rootfs, nspawn, or container"
        exit 1
        ;;
esac
