#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/data/soundcork/soundcork.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

SOUNDCORK_HOST="${SOUNDCORK_HOST:-${SOUNDCORK_IP:-unifi}}"
SOUNDCORK_PORT="${SOUNDCORK_PORT:-8001}"
BASE_URL="${BASE_URL:-http://${SOUNDCORK_HOST}:${SOUNDCORK_PORT}}"
GUNICORN_BIND="${GUNICORN_BIND:-0.0.0.0:${SOUNDCORK_PORT}}"
DATA_DIR="${DATA_DIR:-/data/soundcork/data}"
LOG_DIR="${LOG_DIR:-/data/soundcork/logs}"
IMAGE="${IMAGE:-ghcr.io/deborahgu/soundcork:main}"
CONTAINER_NAME="${CONTAINER_NAME:-soundcork}"
SOUNDCORK_WORKERS="${SOUNDCORK_WORKERS:-2}"
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-${spotify_client_id:-}}"
SPOTIFY_CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-${spotify_client_secret:-}}"
SPOTIFY_REDIRECT_URI="${SPOTIFY_REDIRECT_URI:-${spotify_redirect_uri:-${BASE_URL}/mgmt/spotify/callback}}"
SPOTIFY_SCOPES="${SPOTIFY_SCOPES:-${SOUNDCORK_SPOTIFY_SCOPES:-streaming user-read-email user-read-private playlist-read-private playlist-read-collaborative user-library-read user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-recently-played}}"
SOUNDCORK_SPOTIFY_SCOPES="${SOUNDCORK_SPOTIFY_SCOPES:-$SPOTIFY_SCOPES}"
SPOTIFY_ZEROCONF_PRIMER_ENABLED="${SPOTIFY_ZEROCONF_PRIMER_ENABLED:-false}"
SPOTIFY_ZEROCONF_PRIME_DEVICES="${SPOTIFY_ZEROCONF_PRIME_DEVICES:-${SOUNDCORK_SPOTIFY_PRIME_DEVICES:-}}"
SOUNDCORK_SPOTIFY_PRIME_DEVICES="${SOUNDCORK_SPOTIFY_PRIME_DEVICES:-$SPOTIFY_ZEROCONF_PRIME_DEVICES}"
SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS="${SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS:-2700}"
SOUNDCORK_READY_URL="${SOUNDCORK_READY_URL:-http://127.0.0.1:${SOUNDCORK_PORT}/bmx/registry/v1/services}"
SOUNDCORK_READY_TIMEOUT="${SOUNDCORK_READY_TIMEOUT:-90}"
SOUNDCORK_READY_INTERVAL="${SOUNDCORK_READY_INTERVAL:-2}"
SOUNDCORK_READY_LOG_LINES="${SOUNDCORK_READY_LOG_LINES:-80}"
SOUNDCORK_CONTAINER_LOG_DRIVER="${SOUNDCORK_CONTAINER_LOG_DRIVER:-local}"
SOUNDCORK_CONTAINER_LOG_MAX_SIZE="${SOUNDCORK_CONTAINER_LOG_MAX_SIZE:-10m}"
SOUNDCORK_CONTAINER_LOG_MAX_FILE="${SOUNDCORK_CONTAINER_LOG_MAX_FILE:-3}"

log() {
    logger -t soundcork-onboot "$*" 2>/dev/null || true
    echo "soundcork-onboot: $*"
}

redact_output() {
    sed \
        -e 's/\([?&]code=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]access_token=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]refresh_token=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]client_secret=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\(spotify_client_secret=\)[^ ]*/\1[REDACTED]/g' \
        -e 's/\(SPOTIFY_CLIENT_SECRET=\)[^ ]*/\1[REDACTED]/g'
}

http_ready() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "$SOUNDCORK_READY_URL" >/dev/null 2>&1
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O /dev/null "$SOUNDCORK_READY_URL" >/dev/null 2>&1
        return $?
    fi

    return 2
}

tail_container_logs() {
    log "last ${SOUNDCORK_READY_LOG_LINES} log lines for ${CONTAINER_NAME}:"

    set +e
    container_logs=$("$RUNTIME" logs --tail "$SOUNDCORK_READY_LOG_LINES" "$CONTAINER_NAME" 2>&1)
    logs_status=$?
    set -e

    if [ "$logs_status" -ne 0 ]; then
        log "unable to read container logs"
        printf '%s\n' "$container_logs" | redact_output | while IFS= read -r line; do
            log "container-log: $line"
        done
        return 0
    fi

    printf '%s\n' "$container_logs" | redact_output | while IFS= read -r line; do
        log "container-log: $line"
    done
}

wait_for_ready() {
    case "$SOUNDCORK_READY_TIMEOUT" in
        ''|*[!0-9]*)
            SOUNDCORK_READY_TIMEOUT=90
            ;;
    esac

    case "$SOUNDCORK_READY_INTERVAL" in
        ''|*[!0-9]*|0)
            SOUNDCORK_READY_INTERVAL=2
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log "no curl or wget available; cannot check HTTP readiness"
        return 1
    fi

    elapsed=0
    while [ "$elapsed" -lt "$SOUNDCORK_READY_TIMEOUT" ]; do
        if http_ready; then
            log "SoundCork ready at ${SOUNDCORK_READY_URL}"
            return 0
        fi

        sleep "$SOUNDCORK_READY_INTERVAL"
        elapsed=$((elapsed + SOUNDCORK_READY_INTERVAL))
    done

    return 1
}

if command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
else
    log "no docker or podman runtime found; SoundCork not started"
    log "run 05-soundcork-runtime.sh first, or use the direct nspawn launcher with a prepared rootfs"
    exit 1
fi

mkdir -p "$DATA_DIR" "$LOG_DIR"

if "$RUNTIME" ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    "$RUNTIME" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

log "starting ${CONTAINER_NAME} from ${IMAGE} with base_url=${BASE_URL} bind=${GUNICORN_BIND}"

CONTAINER_LOG_ARGS=""
if [ "$RUNTIME" = docker ]; then
    CONTAINER_LOG_ARGS="--log-driver ${SOUNDCORK_CONTAINER_LOG_DRIVER} --log-opt max-size=${SOUNDCORK_CONTAINER_LOG_MAX_SIZE} --log-opt max-file=${SOUNDCORK_CONTAINER_LOG_MAX_FILE}"
fi

CONTAINER_ID=$("$RUNTIME" run -d \
    --name "$CONTAINER_NAME" \
    --network host \
    --restart unless-stopped \
    $CONTAINER_LOG_ARGS \
    -e "base_url=${BASE_URL}" \
    -e "data_dir=/soundcork/data" \
    -e "spotify_client_id=${SPOTIFY_CLIENT_ID}" \
    -e "spotify_client_secret=${SPOTIFY_CLIENT_SECRET}" \
    -e "spotify_redirect_uri=${SPOTIFY_REDIRECT_URI}" \
    -e "SPOTIFY_SCOPES=${SPOTIFY_SCOPES}" \
    -e "SOUNDCORK_SPOTIFY_SCOPES=${SOUNDCORK_SPOTIFY_SCOPES}" \
    -e "SPOTIFY_ZEROCONF_PRIMER_ENABLED=${SPOTIFY_ZEROCONF_PRIMER_ENABLED}" \
    -e "SPOTIFY_ZEROCONF_PRIME_DEVICES=${SPOTIFY_ZEROCONF_PRIME_DEVICES}" \
    -e "SOUNDCORK_SPOTIFY_PRIME_DEVICES=${SOUNDCORK_SPOTIFY_PRIME_DEVICES}" \
    -e "SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS=${SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS}" \
    -e "SOUNDCORK_MODE=local" \
    -e "SOUNDCORK_LOG_DIR=/soundcork/logs/traffic" \
    -v "${DATA_DIR}:/soundcork/data" \
    -v "${LOG_DIR}:/soundcork/logs" \
    "$IMAGE" \
    sh -c "exec gunicorn -c gunicorn_conf.py \
        --bind "$GUNICORN_BIND" \
        --access-logfile - \
        --error-logfile - \
        --workers "$SOUNDCORK_WORKERS" \
        main:app")

log "SoundCork container started as ${CONTAINER_ID}; waiting for ${SOUNDCORK_READY_URL}"
if ! wait_for_ready; then
    log "SoundCork did not become ready within ${SOUNDCORK_READY_TIMEOUT}s"
    tail_container_logs
    exit 1
fi
