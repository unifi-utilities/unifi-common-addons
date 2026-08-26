#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
unrelated_pid=
old_generation_pid=

cleanup() {
	for pid_file in "$TMP_DIR/nspawn.pid" "$TMP_DIR/log.pid"; do
		if [ -f "$pid_file" ]; then
			kill "$(cat "$pid_file")" 2>/dev/null || true
		fi
	done
	if [ -n "$unrelated_pid" ]; then
		kill "$unrelated_pid" 2>/dev/null || true
	fi
	if [ -n "$old_generation_pid" ]; then
		kill "$old_generation_pid" 2>/dev/null || true
	fi
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

HOME_DIR="$TMP_DIR/soundcork"
UNIT_DIR="$TMP_DIR/systemd"
CALLS="$TMP_DIR/systemctl.calls"
HEALTH_ARGS="$TMP_DIR/healthcheck.args"
NSPAWN_ARGS="$TMP_DIR/nspawn.args"
NSPAWN_ENV="$TMP_DIR/nspawn.env"
READLINK_BIN="$(command -v readlink)"
mkdir -p "$HOME_DIR" "$UNIT_DIR" "$TMP_DIR/bin"

cp "$ROOT_DIR/soundcork-nspawn.service" "$HOME_DIR/soundcork-nspawn.service"
cp "$ROOT_DIR/soundcork-nspawn.sh" "$HOME_DIR/soundcork-nspawn.sh"
chmod +x "$HOME_DIR/soundcork-nspawn.sh"

cat >"$TMP_DIR/bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$CALLS"
if [ "\${1:-}" = is-enabled ]; then
    echo static
fi
EOF
chmod +x "$TMP_DIR/bin/systemctl"

cat >"$TMP_DIR/healthcheck" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$HEALTH_ARGS"
EOF
chmod +x "$TMP_DIR/healthcheck"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/bin/sh
if [ -n "${TEST_WAIT_FILE:-}" ]; then
	i=0
	while [ ! -s "$TEST_WAIT_FILE" ] && [ "$i" -lt 20 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ -s "$TEST_WAIT_FILE" ] || exit 1
fi
exit 0
EOF
chmod +x "$TMP_DIR/bin/curl"

cat >"$TMP_DIR/bin/systemd-nspawn" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$NSPAWN_ARGS"
cp "$TMP_DIR/rootfs/etc/soundcork-nspawn.env" "$NSPAWN_ENV"
sleep 30
EOF
chmod +x "$TMP_DIR/bin/systemd-nspawn"

SOUNDCORK_HOME="$HOME_DIR" \
	SOUNDCORK_UNIT_DIR="$UNIT_DIR" \
	SOUNDCORK_SYSTEMCTL="$TMP_DIR/bin/systemctl" \
	SOUNDCORK_HEALTHCHECK="$TMP_DIR/healthcheck" \
	"$ROOT_DIR/20-soundcork-nspawn.sh"

cmp "$ROOT_DIR/soundcork-nspawn.service" "$UNIT_DIR/soundcork-nspawn.service"
test "$(stat -c '%a' "$UNIT_DIR/soundcork-nspawn.service")" = 644

cat >"$TMP_DIR/expected.calls" <<'EOF'
daemon-reload
disable soundcork-nspawn.service
is-enabled soundcork-nspawn.service
restart soundcork-nspawn.service
is-active --quiet soundcork-nspawn.service
EOF
cmp "$TMP_DIR/expected.calls" "$CALLS"
test "$(cat "$HEALTH_ARGS")" = "--no-spotify --no-remux"

if grep -Eq '(^| )enable( |$)' "$CALLS"; then
	echo "test-nspawn-systemd: unit must not be enabled independently" >&2
	exit 1
fi

grep -q '^ExecStart=/data/soundcork/soundcork-nspawn.sh --keep-unit$' "$UNIT_DIR/soundcork-nspawn.service"
grep -q '^Restart=always$' "$UNIT_DIR/soundcork-nspawn.service"
grep -q '^Delegate=yes$' "$UNIT_DIR/soundcork-nspawn.service"
grep -q '^KillMode=control-group$' "$UNIT_DIR/soundcork-nspawn.service"
if grep -q '^\[Install\]$' "$UNIT_DIR/soundcork-nspawn.service"; then
	echo "test-nspawn-systemd: unit must remain static" >&2
	exit 1
fi

ROOTFS="$TMP_DIR/rootfs"
mkdir -p \
	"$ROOTFS/opt/soundcork/soundcork" \
	"$ROOTFS/opt/soundcork-venv/bin" \
	"$ROOTFS/etc"
touch "$ROOTFS/opt/soundcork-venv/bin/gunicorn"
chmod +x "$ROOTFS/opt/soundcork-venv/bin/gunicorn"
printf 'SOUNDCORK_NSPAWN_KEEP_UNIT=0\n' >"$TMP_DIR/launcher.env"

if PATH="$TMP_DIR/bin:$PATH" \
	ENV_FILE="$TMP_DIR/launcher.env" \
	SOUNDCORK_NSPAWN="$TMP_DIR/bin/systemd-nspawn" \
	SOUNDCORK_ROOTFS="$ROOTFS" \
	DATA_DIR="$TMP_DIR/data" \
	LOG_DIR="$TMP_DIR/logs" \
	SOUNDTOUCH_REGISTRY_DIR="$TMP_DIR/registry" \
	SOUNDTOUCH_REGISTRY_FILE='' \
	"$ROOT_DIR/soundcork-nspawn.sh" >"$TMP_DIR/incomplete-registry.log" 2>&1; then
	echo "test-nspawn-systemd: incomplete registry configuration must fail" >&2
	exit 1
fi
grep -Fq 'SOUNDTOUCH_REGISTRY_DIR and SOUNDTOUCH_REGISTRY_FILE must be set together' \
	"$TMP_DIR/incomplete-registry.log"

cp /bin/sleep "$TMP_DIR/bin/unrelated-nspawn"
"$TMP_DIR/bin/unrelated-nspawn" 30 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" >"$TMP_DIR/nspawn.pid"

PATH="$TMP_DIR/bin:$PATH" \
	ENV_FILE="$TMP_DIR/launcher.env" \
	SOUNDCORK_NSPAWN="$TMP_DIR/bin/unrelated-nspawn" \
	SOUNDCORK_NSPAWN_KEEP_UNIT=1 \
	SOUNDCORK_ROOTFS="$ROOTFS" \
	DATA_DIR="$TMP_DIR/data" \
	LOG_DIR="$TMP_DIR/logs" \
	SOUNDCORK_PID_FILE="$TMP_DIR/nspawn.pid" \
	SOUNDCORK_LOG_PID_FILE="$TMP_DIR/log.pid" \
	SOUNDCORK_LOG_FILE="$TMP_DIR/soundcork.log" \
	SOUNDCORK_LOG_PIPE="$TMP_DIR/soundcork.pipe" \
	SOUNDCORK_READY_TIMEOUT=2 \
	"$ROOT_DIR/soundcork-nspawn.sh" --keep-unit

kill -0 "$unrelated_pid"
rm -f "$TMP_DIR/nspawn.pid" "$TMP_DIR/log.pid"

rm -f "$NSPAWN_ARGS" "$NSPAWN_ENV"
"$TMP_DIR/bin/systemd-nspawn" \
	"--directory=$ROOTFS" \
	"--bind=$TMP_DIR/data:/soundcork/data" \
	"--bind=$TMP_DIR/logs:/soundcork/logs" \
	--as-pid2 >/dev/null 2>&1 &
old_generation_pid=$!
printf '%s\n' "$old_generation_pid" >"$TMP_DIR/nspawn.pid"

cat >"$TMP_DIR/bin/readlink" <<EOF
#!/bin/sh
if [ "\${1:-}" = -f ] && [ "\${2:-}" = "/proc/$old_generation_pid/exe" ]; then
    printf '%s\n' "$TMP_DIR/bin/systemd-nspawn"
    exit 0
fi
exec "$READLINK_BIN" "\$@"
EOF
chmod +x "$TMP_DIR/bin/readlink"

PATH="$TMP_DIR/bin:$PATH" \
	ENV_FILE="$TMP_DIR/launcher.env" \
	SOUNDCORK_NSPAWN="$TMP_DIR/bin/systemd-nspawn" \
	SOUNDCORK_NSPAWN_KEEP_UNIT=1 \
	SOUNDCORK_ROOTFS="$ROOTFS" \
	DATA_DIR="$TMP_DIR/data" \
	LOG_DIR="$TMP_DIR/logs" \
	SOUNDTOUCH_REGISTRY_DIR="$TMP_DIR/registry" \
	SOUNDTOUCH_REGISTRY_FILE="/soundtouch-registry/site.json" \
	TEST_WAIT_FILE="$NSPAWN_ENV" \
	SOUNDCORK_PID_FILE="$TMP_DIR/nspawn.pid" \
	SOUNDCORK_LOG_PID_FILE="$TMP_DIR/log.pid" \
	SOUNDCORK_LOG_FILE="$TMP_DIR/soundcork.log" \
	SOUNDCORK_LOG_PIPE="$TMP_DIR/soundcork.pipe" \
	SOUNDCORK_READY_TIMEOUT=2 \
	"$ROOT_DIR/soundcork-nspawn.sh" --keep-unit

i=0
while [ ! -s "$NSPAWN_ARGS" ] && [ "$i" -lt 20 ]; do
	sleep 0.1
	i=$((i + 1))
done
i=0
while [ ! -s "$NSPAWN_ENV" ] && [ "$i" -lt 20 ]; do
	sleep 0.1
	i=$((i + 1))
done
grep -qx -- '--keep-unit' "$NSPAWN_ARGS"
grep -Fqx -- "--bind-ro=$TMP_DIR/registry:/soundtouch-registry" "$NSPAWN_ARGS"
grep -Fqx -- "export SOUNDTOUCH_REGISTRY_FILE='/soundtouch-registry/site.json'" "$NSPAWN_ENV"
test -d "$TMP_DIR/registry"
kill -0 "$unrelated_pid"
if kill -0 "$old_generation_pid" 2>/dev/null; then
	echo "test-nspawn-systemd: previous launcher generation is still running" >&2
	exit 1
fi
new_pid="$(cat "$TMP_DIR/nspawn.pid")"
test "$new_pid" != "$old_generation_pid"
kill -0 "$new_pid"

echo "test-nspawn-systemd: PASS"
