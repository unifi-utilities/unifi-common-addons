#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/data/soundcork/soundcork.env}"
QUIET=0
FORCE_SPOTIFY=""
FORCE_REMUX=""

usage() {
    cat <<'EOF'
Usage: soundcork-healthcheck.sh [--spotify|--no-spotify] [--remux|--no-remux] [--quiet]

Checks SoundCork's local registry endpoint and, when requested or configured,
the Spotify accounts endpoint and FLAC remux sidecar. Response bodies and
OAuth secrets are not printed.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spotify)
            FORCE_SPOTIFY=1
            ;;
        --no-spotify)
            FORCE_SPOTIFY=0
            ;;
        --remux)
            FORCE_REMUX=1
            ;;
        --no-remux)
            FORCE_REMUX=0
            ;;
        --quiet)
            QUIET=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "soundcork-healthcheck: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

umask 077

SOUNDCORK_PORT="${SOUNDCORK_PORT:-8001}"
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-${spotify_client_id:-}}"
SPOTIFY_CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-${spotify_client_secret:-}}"
SOUNDCORK_HEALTHCHECK_TIMEOUT="${SOUNDCORK_HEALTHCHECK_TIMEOUT:-5}"
SOUNDCORK_HEALTHCHECK_SPOTIFY="${SOUNDCORK_HEALTHCHECK_SPOTIFY:-auto}"
SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT="${SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT:-}"
SOUNDCORK_HEALTHCHECK_REMUX="${SOUNDCORK_HEALTHCHECK_REMUX:-auto}"
SOUNDTOUCH_REMUX_ENABLED="${SOUNDTOUCH_REMUX_ENABLED:-0}"
SOUNDTOUCH_REMUX_PORT="${SOUNDTOUCH_REMUX_PORT:-8768}"
REGISTRY_URL="${SOUNDCORK_HEALTHCHECK_REGISTRY_URL:-http://127.0.0.1:${SOUNDCORK_PORT}/bmx/registry/v1/services}"
SPOTIFY_ACCOUNTS_URL="${SOUNDCORK_HEALTHCHECK_SPOTIFY_URL:-http://127.0.0.1:${SOUNDCORK_PORT}/mgmt/spotify/accounts}"
TMP_BODY=""

cleanup() {
    if [ -n "$TMP_BODY" ]; then
        rm -f "$TMP_BODY"
    fi
}

trap cleanup EXIT HUP INT TERM

log() {
    logger -t soundcork-healthcheck "$*" 2>/dev/null || true
    if [ "$QUIET" -ne 1 ]; then
        echo "soundcork-healthcheck: $*"
    fi
}

redact_text() {
    sed \
        -e 's/\([?&]code=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]access_token=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]refresh_token=\)[^& ]*/\1[REDACTED]/g' \
        -e 's/\([?&]client_secret=\)[^& ]*/\1[REDACTED]/g'
}

safe_text() {
    printf '%s\n' "$1" | redact_text
}

fail() {
    log "ERROR: $*"
    exit 1
}

make_tmp_body() {
    if command -v mktemp >/dev/null 2>&1; then
        TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/soundcork-healthcheck.XXXXXX") || fail "cannot create temporary file"
        return 0
    fi

    TMP_BODY="${TMPDIR:-/tmp}/soundcork-healthcheck.$$"
    : >"$TMP_BODY" || fail "cannot create temporary file"
    chmod 0600 "$TMP_BODY" 2>/dev/null || true
}

http_get() {
    url=$1
    output=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time "$SOUNDCORK_HEALTHCHECK_TIMEOUT" -o "$output" "$url" >/dev/null 2>&1
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -T "$SOUNDCORK_HEALTHCHECK_TIMEOUT" -O "$output" "$url" >/dev/null 2>&1
        return $?
    fi

    fail "neither curl nor wget is available for HTTP checks"
}

check_endpoint() {
    name=$1
    url=$2

    : >"$TMP_BODY"
    if ! http_get "$url" "$TMP_BODY"; then
        fail "${name} endpoint failed at $(safe_text "$url")"
    fi

    log "${name} endpoint OK"
}

should_check_spotify() {
    if [ "$FORCE_SPOTIFY" = "1" ]; then
        return 0
    fi

    if [ "$FORCE_SPOTIFY" = "0" ]; then
        return 1
    fi

    case "$SOUNDCORK_HEALTHCHECK_SPOTIFY" in
        1|true|TRUE|yes|YES|required|REQUIRED|on|ON)
            return 0
            ;;
        0|false|FALSE|no|NO|off|OFF)
            return 1
            ;;
        auto|AUTO)
            if [ -n "$SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT" ] ||
                [ -n "$SPOTIFY_CLIENT_ID" ] ||
                [ -n "$SPOTIFY_CLIENT_SECRET" ]; then
                return 0
            fi
            return 1
            ;;
        *)
            log "unknown SOUNDCORK_HEALTHCHECK_SPOTIFY=${SOUNDCORK_HEALTHCHECK_SPOTIFY}; treating it as auto"
            if [ -n "$SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT" ] ||
                [ -n "$SPOTIFY_CLIENT_ID" ] ||
                [ -n "$SPOTIFY_CLIENT_SECRET" ]; then
                return 0
            fi
            return 1
            ;;
    esac
}

is_remux_enabled() {
    case "$SOUNDTOUCH_REMUX_ENABLED" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

should_check_remux() {
    if [ "$FORCE_REMUX" = "1" ]; then
        return 0
    fi

    if [ "$FORCE_REMUX" = "0" ]; then
        return 1
    fi

    case "$SOUNDCORK_HEALTHCHECK_REMUX" in
        1|true|TRUE|yes|YES|required|REQUIRED|on|ON)
            return 0
            ;;
        0|false|FALSE|no|NO|off|OFF)
            return 1
            ;;
        auto|AUTO)
            is_remux_enabled
            return $?
            ;;
        *)
            log "unknown SOUNDCORK_HEALTHCHECK_REMUX=${SOUNDCORK_HEALTHCHECK_REMUX}; treating it as auto"
            is_remux_enabled
            return $?
            ;;
    esac
}

check_spotify_accounts() {
    check_endpoint "spotify accounts" "$SPOTIFY_ACCOUNTS_URL"

    compact_body=$(tr -d '[:space:]' <"$TMP_BODY")
    case "$compact_body" in
        ""|"[]"|"{}")
            fail "spotify accounts endpoint returned no linked accounts"
            ;;
    esac

    if printf '%s\n' "$compact_body" | grep -Eq '"accounts":\[\]|"accounts":\{\}'; then
        fail "spotify accounts endpoint returned no linked accounts"
    fi

    if [ -n "$SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT" ] &&
        ! grep -F "$SOUNDCORK_HEALTHCHECK_SPOTIFY_ACCOUNT" "$TMP_BODY" >/dev/null 2>&1; then
        fail "spotify accounts endpoint did not include expected account marker"
    fi

    log "spotify accounts check OK"
}

check_remux() {
    check_endpoint "remux healthz" "http://127.0.0.1:${SOUNDTOUCH_REMUX_PORT}/healthz"
    check_endpoint "remux metrics" "http://127.0.0.1:${SOUNDTOUCH_REMUX_PORT}/metrics"
    log "remux check OK"
}

make_tmp_body

check_endpoint "registry" "$REGISTRY_URL"

if should_check_spotify; then
    check_spotify_accounts
else
    log "spotify accounts check skipped"
fi

if should_check_remux; then
    check_remux
else
    log "remux check skipped"
fi

log "SoundCork healthcheck OK"
