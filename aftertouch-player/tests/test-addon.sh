#!/bin/sh
set -eu

ADDON_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aftertouch-player-test.XXXXXX")
APP_HOME=$TEST_ROOT/app
ON_BOOT_DIR=$TEST_ROOT/on-boot
FIXTURE=$TEST_ROOT/player
BIN_DIR=$TEST_ROOT/bin
RELEASE_FIXTURES=$TEST_ROOT/release-fixtures

cleanup() {
	chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
	rm -rf "$TEST_ROOT"
}

trap cleanup EXIT HUP INT TERM

fail() {
	echo "test-addon: FAIL: $*" >&2
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected '$1' to equal '$2'"
}

for script in install.sh run.sh aftertouch-player-healthcheck.sh 26-aftertouch-player.sh tests/test-addon.sh; do
	sh -n "$ADDON_DIR/$script"
done

# Activation uses deterministic service-manager and healthcheck fakes. The
# state-machine tests therefore exercise the real boot hook without touching
# the host systemd instance.
SYSTEMCTL_LOG=$TEST_ROOT/systemctl.log
HEALTH_LOG=$TEST_ROOT/health.log
UNIT_DIR=$TEST_ROOT/systemd
cat >"$TEST_ROOT/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$AFTERTOUCH_SYSTEMCTL_LOG"
EOF
cat >"$TEST_ROOT/healthcheck" <<'EOF'
#!/bin/sh
printf 'called\n' >"$AFTERTOUCH_HEALTH_LOG"
EOF
cat >"$TEST_ROOT/healthcheck-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TEST_ROOT/healthcheck-switch" <<'EOF'
#!/bin/sh
set -eu
temporary=$AFTERTOUCH_PLAYER_HOME/.current-race.$$
ln -s "$AFTERTOUCH_SWITCH_TARGET" "$temporary"
mv -Tf "$temporary" "$AFTERTOUCH_PLAYER_HOME/current"
EOF
chmod 0755 "$TEST_ROOT/systemctl" "$TEST_ROOT/healthcheck" \
	"$TEST_ROOT/healthcheck-fail" "$TEST_ROOT/healthcheck-switch"

run_main_installer_with_health() {
	test_healthcheck=$1
	shift
	env AFTERTOUCH_PLAYER_HOME="$APP_HOME" AFTERTOUCH_ON_BOOT_DIR="$ON_BOOT_DIR" AFTERTOUCH_MACHINE=x86_64 \
		AFTERTOUCH_UNIT_DIR="$UNIT_DIR" AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" \
		AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" AFTERTOUCH_HEALTHCHECK="$test_healthcheck" \
		AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" "$ADDON_DIR/install.sh" "$@"
}

run_main_installer() {
	run_main_installer_with_health "$TEST_ROOT/healthcheck" "$@"
}

cat >"$FIXTURE" <<'EOF'
#!/bin/sh
echo fixture-one
EOF
chmod 0755 "$FIXTURE"

run_main_installer --local "$FIXTURE" --version dev-one --activate

[ -L "$APP_HOME/current" ] || fail "current symlink was not created"
first=$(readlink "$APP_HOME/current")
assert_eq "$(readlink "$APP_HOME/verified")" "$first"
[ ! -e "$APP_HOME/previous" ] || fail "first verified install unexpectedly created previous"
[ -x "$APP_HOME/current/soundtouch-player" ] || fail "first binary is not executable"
[ -f "$APP_HOME/current/manifest" ] || fail "first manifest is missing"
[ "$(stat -Lc '%a' "$APP_HOME/current")" = 755 ] || fail "release directory is not traversable"
grep -Fx 'source=local' "$APP_HOME/current/manifest" >/dev/null || fail "local source missing from manifest"
grep -Fx 'architecture=linux-amd64' "$APP_HOME/current/manifest" >/dev/null || fail "architecture missing from manifest"

# The installer and boot hook must reject a concurrent operation sharing the
# same application state.
exec 8>"$APP_HOME/.operation.lock"
flock -n 8 || fail "test could not acquire operation lock"
if run_main_installer --local /bin/true --version lock-test >/dev/null 2>&1; then
	fail "installer ignored an existing operation lock"
fi
if env AFTERTOUCH_PLAYER_HOME="$APP_HOME" AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
	"$ON_BOOT_DIR/26-aftertouch-player.sh" >/dev/null 2>&1; then
	fail "boot hook ignored an existing operation lock"
fi
assert_eq "$(readlink "$APP_HOME/current")" "$first"
flock -u 8
exec 8>&-

cat >"$FIXTURE" <<'EOF'
#!/bin/sh
echo fixture-two
EOF
chmod 0755 "$FIXTURE"

run_main_installer --local "$FIXTURE" --version dev-two --activate

second=$(readlink "$APP_HOME/current")
[ "$first" != "$second" ] || fail "upgrade did not select a new artifact"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"

run_main_installer --rollback --activate
assert_eq "$(readlink "$APP_HOME/current")" "$first"
assert_eq "$(readlink "$APP_HOME/verified")" "$first"
assert_eq "$(readlink "$APP_HOME/previous")" "$second"

run_main_installer --rollback --activate
assert_eq "$(readlink "$APP_HOME/current")" "$second"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"

# A failed candidate and a later retry must not displace the last verified
# generation or the verified generation preceding it.
cat >"$FIXTURE" <<'EOF'
#!/bin/sh
echo fixture-failed
EOF
chmod 0755 "$FIXTURE"
if run_main_installer_with_health "$TEST_ROOT/healthcheck-fail" \
	--local "$FIXTURE" --version dev-failed --activate >/dev/null 2>&1; then
	fail "failed activation unexpectedly succeeded"
fi
failed=$(readlink "$APP_HOME/current")
[ "$failed" != "$second" ] || fail "failed candidate was not selected"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"

cat >"$FIXTURE" <<'EOF'
#!/bin/sh
echo fixture-retry
EOF
chmod 0755 "$FIXTURE"
run_main_installer --local "$FIXTURE" --version dev-retry
retry=$(readlink "$APP_HOME/current")
[ "$retry" != "$failed" ] || fail "retry did not select a new artifact"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"

run_main_installer --rollback
assert_eq "$(readlink "$APP_HOME/current")" "$second"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"

# Even an out-of-band current change during activation must not promote the
# generation snapshotted by the boot hook.
run_main_installer --local "$FIXTURE" --version dev-retry
if env AFTERTOUCH_PLAYER_HOME="$APP_HOME" AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck-switch" AFTERTOUCH_SWITCH_TARGET="$first" \
	"$ON_BOOT_DIR/26-aftertouch-player.sh" >/dev/null 2>&1; then
	fail "boot hook promoted a target after current changed"
fi
assert_eq "$(readlink "$APP_HOME/current")" "$first"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"
run_main_installer --rollback
assert_eq "$(readlink "$APP_HOME/current")" "$second"

cat >"$APP_HOME/config.env" <<'EOF'
BIND_ADDR=0.0.0.0
PORT=18080
SOUNDTOUCH_DEVICES=192.0.2.10
UPNP_ENABLED=false
MDNS_ENABLED=false
SERVICE_URL=
SERVICE_CA=
EOF

if env AFTERTOUCH_PLAYER_HOME="$APP_HOME" "$APP_HOME/run.sh" >/dev/null 2>&1; then
	fail "wildcard bind was accepted"
fi

printf 'tampered\n' >>"$APP_HOME/current/soundtouch-player"
if env AFTERTOUCH_PLAYER_HOME="$APP_HOME" "$APP_HOME/run.sh" >/dev/null 2>&1; then
	fail "tampered binary was accepted"
fi

# A corrupt verified generation must not block a valid replacement. If that
# replacement is later corrupt too, rollback must still recover through the
# older valid previous generation.
run_main_installer --local "$FIXTURE" --version dev-retry --activate
assert_eq "$(readlink "$APP_HOME/current")" "$retry"
assert_eq "$(readlink "$APP_HOME/verified")" "$retry"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"
printf 'tampered\n' >>"$APP_HOME/current/soundtouch-player"
run_main_installer --rollback --activate
assert_eq "$(readlink "$APP_HOME/current")" "$first"
assert_eq "$(readlink "$APP_HOME/verified")" "$first"

# Exercise the official-release path without network access. The fake curl
# preserves the real asset naming and checksum contract.
RELEASE_HOME=$TEST_ROOT/release-app
RELEASE_ON_BOOT=$TEST_ROOT/release-on-boot
OFFICIAL_RELEASE_HOME=$TEST_ROOT/official-release-app
OFFICIAL_RELEASE_ON_BOOT=$TEST_ROOT/official-release-on-boot
BAD_RELEASE_HOME=$TEST_ROOT/bad-release-app
BAD_RELEASE_ON_BOOT=$TEST_ROOT/bad-release-on-boot
mkdir -p "$BIN_DIR" "$RELEASE_FIXTURES"
cat >"$BIN_DIR/curl" <<'EOF'
#!/bin/sh
set -eu
output=
url=
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		output=$2
		shift 2
		;;
	-*) shift ;;
	*)
		url=$1
		shift
		;;
	esac
done
[ -n "$output" ] && [ -n "$url" ]
cp "$FAKE_RELEASE_DIR/${url##*/}" "$output"
EOF
chmod 0755 "$BIN_DIR/curl"

release_asset=soundtouch-player-v9.8.7-linux-amd64
cat >"$RELEASE_FIXTURES/$release_asset" <<'EOF'
#!/bin/sh
echo release-fixture
EOF
chmod 0755 "$RELEASE_FIXTURES/$release_asset"
sha256sum "$RELEASE_FIXTURES/$release_asset" >"$RELEASE_FIXTURES/$release_asset.sha256"

cp "$RELEASE_FIXTURES/$release_asset.sha256" "$RELEASE_FIXTURES/$release_asset.sha256.good"
printf '%064d  %s\n' 0 "$release_asset" >"$RELEASE_FIXTURES/$release_asset.sha256"
if env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_RELEASE_BASE_URL=https://fixtures.invalid/releases \
	AFTERTOUCH_PLAYER_HOME="$BAD_RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$BAD_RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7 >/dev/null 2>&1; then
	fail "release with a bad checksum was accepted"
fi
[ ! -e "$BAD_RELEASE_HOME/current" ] || fail "bad release created a current symlink"
[ ! -e "$BAD_RELEASE_ON_BOOT/26-aftertouch-player.sh" ] || fail "bad release enabled the boot hook"
mv "$RELEASE_FIXTURES/$release_asset.sha256.good" "$RELEASE_FIXTURES/$release_asset.sha256"

env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_RELEASE_BASE_URL=https://fixtures.invalid/releases \
	AFTERTOUCH_PLAYER_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7

[ ! -e "$RELEASE_ON_BOOT/26-aftertouch-player.sh" ] ||
	fail "non-activating first install enabled the boot hook"
grep -Fx 'source=release-mirror' "$RELEASE_HOME/current/manifest" >/dev/null ||
	fail "overridden release source was not identified as a mirror"
grep -Fx 'release_url=https://fixtures.invalid/releases/v9.8.7/soundtouch-player-v9.8.7-linux-amd64' \
	"$RELEASE_HOME/current/manifest" >/dev/null || fail "release URL missing from manifest"

# The unmodified upstream release origin must retain official provenance even
# though the fake curl keeps this test offline.
env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_PLAYER_HOME="$OFFICIAL_RELEASE_HOME" \
	AFTERTOUCH_ON_BOOT_DIR="$OFFICIAL_RELEASE_ON_BOOT" AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7

grep -Fx 'source=official-release' "$OFFICIAL_RELEASE_HOME/current/manifest" >/dev/null ||
	fail "official release source missing from manifest"
grep -Fx 'release_url=https://github.com/gesellix/Bose-SoundTouch/releases/download/v9.8.7/soundtouch-player-v9.8.7-linux-amd64' \
	"$OFFICIAL_RELEASE_HOME/current/manifest" >/dev/null ||
	fail "official release URL missing from manifest"

# Reusing identical bytes under conflicting provenance must fail instead of
# retaining whichever manifest happened to be installed first.
if env AFTERTOUCH_PLAYER_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 "$ADDON_DIR/install.sh" \
	--local "$RELEASE_FIXTURES/$release_asset" --version v9.8.7 >/dev/null 2>&1; then
	fail "conflicting artifact provenance was accepted"
fi
grep -Fx 'source=release-mirror' "$RELEASE_HOME/current/manifest" >/dev/null ||
	fail "provenance conflict changed the installed manifest"

# An explicit activation installs the boot hook and commits the selected release
# to verified.
: >"$SYSTEMCTL_LOG"
rm -f "$HEALTH_LOG"

env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_RELEASE_BASE_URL=https://fixtures.invalid/releases \
	AFTERTOUCH_PLAYER_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
	"$ADDON_DIR/install.sh" --activate

[ -f "$UNIT_DIR/aftertouch-player.service" ] || fail "boot hook did not restore the unit"
[ -x "$RELEASE_ON_BOOT/26-aftertouch-player.sh" ] || fail "activation did not install the boot hook"
expected_systemctl_log=$(
	cat <<'EOF'
daemon-reload
disable aftertouch-player.service
restart aftertouch-player.service
is-active --quiet aftertouch-player.service
EOF
)
assert_eq "$(cat "$SYSTEMCTL_LOG")" "$expected_systemctl_log"
[ -f "$HEALTH_LOG" ] || fail "boot hook skipped healthcheck"
assert_eq "$(readlink "$RELEASE_HOME/verified")" "$(readlink "$RELEASE_HOME/current")"

echo "test-addon: PASS"
