#!/bin/sh
set -eu

FORCE_KEEP_UNIT=0
case "${1:-}" in
    --keep-unit)
        FORCE_KEEP_UNIT=1
        shift
        ;;
esac
[ "$#" -eq 0 ] || {
    echo "soundcork-nspawn: unexpected argument: $1" >&2
    exit 2
}

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
SOUNDTOUCH_REGISTRY_DIR="${SOUNDTOUCH_REGISTRY_DIR:-}"
SOUNDTOUCH_REGISTRY_FILE="${SOUNDTOUCH_REGISTRY_FILE:-}"
ROOTFS="${SOUNDCORK_ROOTFS:-/data/soundcork/nspawn-rootfs}"
NSPAWN_BIN="${SOUNDCORK_NSPAWN:-}"
APP_DIR="${SOUNDCORK_APP_DIR:-/opt/soundcork/soundcork}"
APP_PYTHONPATH="${SOUNDCORK_PYTHONPATH:-/opt/soundcork}"
GUNICORN_BIN="${SOUNDCORK_GUNICORN:-/opt/soundcork-venv/bin/gunicorn}"
PID_FILE="${SOUNDCORK_PID_FILE:-/data/soundcork/soundcork-nspawn.pid}"
LOG_FILE="${SOUNDCORK_LOG_FILE:-/data/soundcork/logs/soundcork-nspawn.log}"
LOG_PID_FILE="${SOUNDCORK_LOG_PID_FILE:-/data/soundcork/soundcork-nspawn-log.pid}"
LOG_PIPE="${SOUNDCORK_LOG_PIPE:-/tmp/soundcork-nspawn-${SOUNDCORK_PORT}.log.pipe}"
SOUNDCORK_LOG_MAX_BYTES="${SOUNDCORK_LOG_MAX_BYTES:-10485760}"
SOUNDCORK_LOG_ROTATIONS="${SOUNDCORK_LOG_ROTATIONS:-3}"
SOUNDCORK_WORKERS="${SOUNDCORK_WORKERS:-2}"
SOUNDCORK_READY_URL="${SOUNDCORK_READY_URL:-http://127.0.0.1:${SOUNDCORK_PORT}/bmx/registry/v1/services}"
SOUNDCORK_READY_TIMEOUT="${SOUNDCORK_READY_TIMEOUT:-90}"
SOUNDCORK_READY_INTERVAL="${SOUNDCORK_READY_INTERVAL:-2}"
SOUNDCORK_READY_LOG_LINES="${SOUNDCORK_READY_LOG_LINES:-80}"
SOUNDCORK_NSPAWN_KEEP_UNIT="${SOUNDCORK_NSPAWN_KEEP_UNIT:-0}"
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-${spotify_client_id:-}}"
SPOTIFY_CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-${spotify_client_secret:-}}"
SPOTIFY_REDIRECT_URI="${SPOTIFY_REDIRECT_URI:-${spotify_redirect_uri:-${BASE_URL}/mgmt/spotify/callback}}"
SPOTIFY_SCOPES="${SPOTIFY_SCOPES:-${SOUNDCORK_SPOTIFY_SCOPES:-streaming user-read-email user-read-private playlist-read-private playlist-read-collaborative user-library-read user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-recently-played}}"
SOUNDCORK_SPOTIFY_SCOPES="${SOUNDCORK_SPOTIFY_SCOPES:-$SPOTIFY_SCOPES}"
SPOTIFY_ZEROCONF_PRIMER_ENABLED="${SPOTIFY_ZEROCONF_PRIMER_ENABLED:-false}"
SPOTIFY_ZEROCONF_PRIME_DEVICES="${SPOTIFY_ZEROCONF_PRIME_DEVICES:-${SOUNDCORK_SPOTIFY_PRIME_DEVICES:-}}"
SOUNDCORK_SPOTIFY_PRIME_DEVICES="${SOUNDCORK_SPOTIFY_PRIME_DEVICES:-$SPOTIFY_ZEROCONF_PRIME_DEVICES}"
SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS="${SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS:-2700}"

log() {
    logger -t soundcork-nspawn "$*" 2>/dev/null || true
    echo "soundcork-nspawn: $*"
}

normalize_log_limits() {
    case "$SOUNDCORK_LOG_MAX_BYTES" in
        ''|*[!0-9]*)
            SOUNDCORK_LOG_MAX_BYTES=10485760
            ;;
    esac

    case "$SOUNDCORK_LOG_ROTATIONS" in
        ''|*[!0-9]*)
            SOUNDCORK_LOG_ROTATIONS=3
            ;;
    esac

    if [ "$SOUNDCORK_LOG_ROTATIONS" -gt 20 ]; then
        SOUNDCORK_LOG_ROTATIONS=20
    fi
}

rotate_log_if_needed() {
    [ "$SOUNDCORK_LOG_MAX_BYTES" -gt 0 ] || return 0
    [ -f "$LOG_FILE" ] || return 0

    size="$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)"
    size="$(printf '%s' "$size" | tr -d ' ')"
    case "$size" in
        ''|*[!0-9]*)
            size=0
            ;;
    esac

    [ "$size" -lt "$SOUNDCORK_LOG_MAX_BYTES" ] || {
        if [ "$SOUNDCORK_LOG_ROTATIONS" -eq 0 ]; then
            : >"$LOG_FILE"
            return 0
        fi

        i=$((SOUNDCORK_LOG_ROTATIONS - 1))
        while [ "$i" -ge 1 ]; do
            if [ -f "${LOG_FILE}.${i}" ]; then
                mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
            fi
            i=$((i - 1))
        done
        mv -f "$LOG_FILE" "${LOG_FILE}.1"
    }
}

append_log_stream() {
    while IFS= read -r line; do
        rotate_log_if_needed
        printf '%s\n' "$line" >>"$LOG_FILE"
    done
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

shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

write_env_var() {
    name="$1"
    value="$2"
    printf 'export %s=' "$name"
    shell_quote "$value"
    printf '\n'
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

        if [ -f "$PID_FILE" ]; then
            current_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [ -n "${current_pid:-}" ] && ! kill -0 "$current_pid" 2>/dev/null; then
                log "SoundCork nspawn process exited before readiness"
                return 1
            fi
        fi

        sleep "$SOUNDCORK_READY_INTERVAL"
        elapsed=$((elapsed + SOUNDCORK_READY_INTERVAL))
    done

    return 1
}

tail_logs() {
    log "last ${SOUNDCORK_READY_LOG_LINES} log lines from ${LOG_FILE}:"
    tail -n "$SOUNDCORK_READY_LOG_LINES" "$LOG_FILE" 2>&1 | redact_output | while IFS= read -r line; do
        log "nspawn-log: $line"
    done
}

stop_log_writer() {
    should_kill="${1:-1}"
    if [ ! -f "$LOG_PID_FILE" ]; then
        return 0
    fi

    old_log_pid="$(cat "$LOG_PID_FILE" 2>/dev/null || true)"
    if [ "$should_kill" = "1" ] && [ -n "${old_log_pid:-}" ] && kill -0 "$old_log_pid" 2>/dev/null; then
        old_log_fd="$(readlink "/proc/${old_log_pid}/fd/0" 2>/dev/null || true)"
        case "$old_log_fd" in
            "$LOG_PIPE"|"$LOG_PIPE (deleted)")
                kill "$old_log_pid" 2>/dev/null || true
                ;;
            *)
                log "ignoring stale log PID $old_log_pid owned by another process"
                ;;
        esac
    fi
    rm -f "$LOG_PID_FILE"
}

process_start_time() {
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '
        NF >= 20 { print $20; found = 1 }
        END { if (!found) exit 1 }
    '
}

process_has_arg() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' '\n' <"/proc/$1/cmdline" | grep -Fqx -e "$2"
}

nspawn_pid_matches() {
    # Optional mounts may change between generations; the core SoundCork binds
    # identify a launcher-owned process that is safe to replace.
    identity_exe="$(readlink -f "/proc/$1/exe" 2>/dev/null || true)"
    configured_exe="$(readlink -f "$NSPAWN_BIN" 2>/dev/null || true)"
    [ -n "$identity_exe" ] && [ "$identity_exe" = "$configured_exe" ] || return 1
    process_has_arg "$1" "--directory=$ROOTFS" || return 1
    process_has_arg "$1" "--bind=${DATA_DIR}:/soundcork/data" || return 1
    process_has_arg "$1" "--bind=${LOG_DIR}:/soundcork/logs"
}

stop_previous() {
    if [ ! -f "$PID_FILE" ]; then
        stop_log_writer 0
        rm -f "$LOG_PIPE"
        return 0
    fi

    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "${old_pid:-}" ] || ! kill -0 "$old_pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        stop_log_writer 0
        rm -f "$LOG_PIPE"
        return 0
    fi

    old_start_time="$(process_start_time "$old_pid" || true)"
    if [ -z "$old_start_time" ] || ! nspawn_pid_matches "$old_pid"; then
        log "ignoring stale nspawn PID $old_pid owned by another process"
        rm -f "$PID_FILE"
        stop_log_writer
        rm -f "$LOG_PIPE"
        return 0
    fi

    log "stopping previous nspawn process $old_pid"
    kill "$old_pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$old_pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$old_pid" 2>/dev/null; then
        current_start_time="$(process_start_time "$old_pid" || true)"
        if [ "$current_start_time" = "$old_start_time" ] && nspawn_pid_matches "$old_pid"; then
            kill -9 "$old_pid" 2>/dev/null || true
        else
            log "refusing to signal reused or changed nspawn PID $old_pid"
        fi
    fi
    rm -f "$PID_FILE"
    stop_log_writer
    rm -f "$LOG_PIPE"
}

if [ -z "$NSPAWN_BIN" ]; then
    if command -v systemd-nspawn >/dev/null 2>&1; then
        NSPAWN_BIN="$(command -v systemd-nspawn)"
    elif [ -x /data/soundcork/nspawn-tools/usr/bin/systemd-nspawn ]; then
        NSPAWN_BIN=/data/soundcork/nspawn-tools/usr/bin/systemd-nspawn
    elif [ -x /data/soundcork/systemd-nspawn/usr/bin/systemd-nspawn ]; then
        NSPAWN_BIN=/data/soundcork/systemd-nspawn/usr/bin/systemd-nspawn
    else
        log "systemd-nspawn not found"
        exit 1
    fi
fi

[ -x "$NSPAWN_BIN" ] || { log "systemd-nspawn is not executable at $NSPAWN_BIN"; exit 1; }
[ -d "$ROOTFS" ] || { log "missing rootfs at $ROOTFS"; exit 1; }
[ -d "$ROOTFS$APP_DIR" ] || { log "missing SoundCork app dir at $ROOTFS$APP_DIR"; exit 1; }
[ -x "$ROOTFS$GUNICORN_BIN" ] || { log "missing gunicorn at $ROOTFS$GUNICORN_BIN"; exit 1; }
if [ -n "$SOUNDTOUCH_REGISTRY_DIR" ] || [ -n "$SOUNDTOUCH_REGISTRY_FILE" ]; then
    [ -n "$SOUNDTOUCH_REGISTRY_DIR" ] && [ -n "$SOUNDTOUCH_REGISTRY_FILE" ] || {
        log "SOUNDTOUCH_REGISTRY_DIR and SOUNDTOUCH_REGISTRY_FILE must be set together"
        exit 1
    }
fi

mkdir -p \
    "$DATA_DIR" \
    "$LOG_DIR" \
    "$ROOTFS/soundcork/data" \
    "$ROOTFS/soundcork/logs"
if [ -n "$SOUNDTOUCH_REGISTRY_DIR" ]; then
    mkdir -p "$SOUNDTOUCH_REGISTRY_DIR" "$ROOTFS/soundtouch-registry"
fi
ENV_IN_ROOTFS="$ROOTFS/etc/soundcork-nspawn.env"
umask 077
{
    write_env_var PYTHONPATH "$APP_PYTHONPATH"
    write_env_var base_url "$BASE_URL"
    write_env_var data_dir "/soundcork/data"
    write_env_var spotify_client_id "$SPOTIFY_CLIENT_ID"
    write_env_var spotify_client_secret "$SPOTIFY_CLIENT_SECRET"
    write_env_var spotify_redirect_uri "$SPOTIFY_REDIRECT_URI"
    write_env_var SPOTIFY_SCOPES "$SPOTIFY_SCOPES"
    write_env_var SOUNDCORK_SPOTIFY_SCOPES "$SOUNDCORK_SPOTIFY_SCOPES"
    write_env_var SPOTIFY_ZEROCONF_PRIMER_ENABLED "$SPOTIFY_ZEROCONF_PRIMER_ENABLED"
    write_env_var SPOTIFY_ZEROCONF_PRIME_DEVICES "$SPOTIFY_ZEROCONF_PRIME_DEVICES"
    write_env_var SOUNDCORK_SPOTIFY_PRIME_DEVICES "$SOUNDCORK_SPOTIFY_PRIME_DEVICES"
    write_env_var SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS "$SPOTIFY_ZEROCONF_PRIMER_INTERVAL_SECONDS"
    if [ -n "$SOUNDTOUCH_REGISTRY_FILE" ]; then
        write_env_var SOUNDTOUCH_REGISTRY_FILE "$SOUNDTOUCH_REGISTRY_FILE"
    fi
    write_env_var SOUNDCORK_MODE "local"
    write_env_var SOUNDCORK_LOG_DIR "/soundcork/logs/traffic"
    write_env_var SOUNDCORK_APP_DIR "$APP_DIR"
    write_env_var SOUNDCORK_GUNICORN "$GUNICORN_BIN"
    write_env_var GUNICORN_BIND "$GUNICORN_BIND"
    write_env_var SOUNDCORK_WORKERS "$SOUNDCORK_WORKERS"
} >"$ENV_IN_ROOTFS"
umask 022
chmod 600 "$ENV_IN_ROOTFS"

if [ "$FORCE_KEEP_UNIT" = "1" ]; then
    SOUNDCORK_NSPAWN_KEEP_UNIT=1
fi
case "$SOUNDCORK_NSPAWN_KEEP_UNIT" in
    0|1)
        ;;
    *)
        log "SOUNDCORK_NSPAWN_KEEP_UNIT must be 0 or 1"
        exit 1
        ;;
esac

normalize_log_limits
stop_previous

mkdir -p "$(dirname "$LOG_FILE")"
rm -f "$LOG_PIPE"
mkfifo "$LOG_PIPE"
append_log_stream <"$LOG_PIPE" >/dev/null 2>&1 &
log_pid="$!"
echo "$log_pid" >"$LOG_PID_FILE"

log "starting SoundCork nspawn rootfs=${ROOTFS} base_url=${BASE_URL} bind=${GUNICORN_BIND}"
set -- \
    "$NSPAWN_BIN" \
    --quiet \
    --register=no
if [ "$SOUNDCORK_NSPAWN_KEEP_UNIT" = "1" ]; then
    set -- "$@" --keep-unit
fi
set -- \
    "$@" \
    --directory="$ROOTFS" \
    --bind="${DATA_DIR}:/soundcork/data" \
    --bind="${LOG_DIR}:/soundcork/logs"
if [ -n "$SOUNDTOUCH_REGISTRY_DIR" ]; then
    set -- "$@" --bind-ro="${SOUNDTOUCH_REGISTRY_DIR}:/soundtouch-registry"
fi
set -- "$@" --as-pid2
(
    # Variables in this command are expanded by the shell inside the rootfs.
    # shellcheck disable=SC2016
    exec "$@" \
        /bin/sh -c '. /etc/soundcork-nspawn.env && cd "$SOUNDCORK_APP_DIR" && exec "$SOUNDCORK_GUNICORN" -c gunicorn_conf.py --bind "$GUNICORN_BIND" --access-logfile - --error-logfile - --workers "$SOUNDCORK_WORKERS" main:app'
) >"$LOG_PIPE" 2>&1 < /dev/null &
new_pid="$!"
echo "$new_pid" >"$PID_FILE"

if ! wait_for_ready; then
    tail_logs
    kill "$new_pid" 2>/dev/null || true
    stop_log_writer
    rm -f "$PID_FILE" "$ENV_IN_ROOTFS" "$LOG_PIPE"
    exit 1
fi

rm -f "$ENV_IN_ROOTFS" "$LOG_PIPE"
