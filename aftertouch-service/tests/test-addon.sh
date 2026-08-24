#!/bin/sh
set -eu

ADDON_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aftertouch-service-test.XXXXXX")
APP_HOME=$TEST_ROOT/app
ON_BOOT_DIR=$TEST_ROOT/on-boot
FIXTURE=$TEST_ROOT/player
BIN_DIR=$TEST_ROOT/bin
RUN_BIN=$TEST_ROOT/run-bin
RELEASE_FIXTURES=$TEST_ROOT/release-fixtures
export AFTERTOUCH_CHOWN=true

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

for script in install.sh run.sh aftertouch-service-healthcheck.sh aftertouch-service-state.sh \
	27-aftertouch-service.sh tests/test-addon.sh; do
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
temporary=$AFTERTOUCH_SERVICE_HOME/.current-race.$$
ln -s "$AFTERTOUCH_SWITCH_TARGET" "$temporary"
mv -Tf "$temporary" "$AFTERTOUCH_SERVICE_HOME/current"
EOF
cat >"$TEST_ROOT/healthcheck-fail-once" <<'EOF'
#!/bin/sh
set -eu
count=0
if [ -f "$AFTERTOUCH_HEALTH_COUNT" ]; then
	count=$(cat "$AFTERTOUCH_HEALTH_COUNT")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$AFTERTOUCH_HEALTH_COUNT"
[ "$count" -gt 1 ]
EOF
cat >"$TEST_ROOT/cp-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$TEST_ROOT/rm-fail-old" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -rf ]
target=$2
/bin/rm -f "$target/state-probe"
exit 1
EOF
cat >"$TEST_ROOT/systemctl-state" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$AFTERTOUCH_SYSTEMCTL_LOG"
case "$1" in
is-active)
	[ "$(cat "$AFTERTOUCH_SYSTEMCTL_STATE")" = active ]
	;;
restart | start)
	printf '%s\n' active >"$AFTERTOUCH_SYSTEMCTL_STATE"
	;;
stop)
	printf '%s\n' inactive >"$AFTERTOUCH_SYSTEMCTL_STATE"
	;;
esac
EOF
chmod 0755 "$TEST_ROOT/systemctl" "$TEST_ROOT/healthcheck" \
	"$TEST_ROOT/healthcheck-fail" "$TEST_ROOT/healthcheck-switch" \
	"$TEST_ROOT/healthcheck-fail-once" "$TEST_ROOT/cp-fail" \
	"$TEST_ROOT/rm-fail-old" "$TEST_ROOT/systemctl-state"

mkdir -p "$RUN_BIN"
cat >"$RUN_BIN/id" <<'EOF'
#!/bin/sh
case "${1:-}" in
-u | -g) echo 0 ;;
*) exec /usr/bin/id "$@" ;;
esac
EOF
cat >"$RUN_BIN/stat" <<'EOF'
#!/bin/sh
case "${1:-}:${2:-}" in
-c:%u | -c:%g) echo 65532 ;;
*) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$RUN_BIN/setpriv" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
	--reuid=* | --regid=* | --clear-groups) shift ;;
	*) exec "$@" ;;
	esac
done
exit 2
EOF
chmod 0755 "$RUN_BIN/id" "$RUN_BIN/stat" "$RUN_BIN/setpriv"

run_main_installer_with_health() {
	test_healthcheck=$1
	shift
	env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_ON_BOOT_DIR="$ON_BOOT_DIR" AFTERTOUCH_MACHINE=x86_64 \
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
[ -x "$APP_HOME/current/soundtouch-service" ] || fail "first binary is not executable"
[ -f "$APP_HOME/current/manifest" ] || fail "first manifest is missing"
[ -x "$APP_HOME/aftertouch-service-state.sh" ] || fail "state helper is missing"
[ "$(stat -c '%a' "$APP_HOME/config.env")" = 600 ] || fail "config.env is not root-only"
[ "$(stat -c '%a' "$APP_HOME/data")" = 700 ] || fail "data directory mode is not 0700"
[ "$(stat -Lc '%a' "$APP_HOME/current")" = 755 ] || fail "release directory is not traversable"
grep -Fx 'source=local' "$APP_HOME/current/manifest" >/dev/null || fail "local source missing from manifest"
grep -Fx 'architecture=linux-amd64' "$APP_HOME/current/manifest" >/dev/null || fail "architecture missing from manifest"

# The installer and boot hook must reject a concurrent operation sharing the
# same application state.
exec 8>"$APP_HOME/.operation.lock"
flock -n 8 || fail "test could not acquire operation lock"
mv "$APP_HOME/data" "$APP_HOME/data-lock-test"
if run_main_installer --local /bin/true --version lock-test >/dev/null 2>&1; then
	fail "installer ignored an existing operation lock"
fi
[ ! -e "$APP_HOME/data" ] || fail "losing installer mutated data before acquiring the lock"
if env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
	"$ON_BOOT_DIR/27-aftertouch-service.sh" >/dev/null 2>&1; then
	fail "boot hook ignored an existing operation lock"
fi
if env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" \
	AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	"$APP_HOME/aftertouch-service-state.sh" list >/dev/null 2>&1; then
	fail "state helper ignored an existing operation lock"
fi
assert_eq "$(readlink "$APP_HOME/current")" "$first"
mv "$APP_HOME/data-lock-test" "$APP_HOME/data"
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
if env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck-switch" AFTERTOUCH_SWITCH_TARGET="$first" \
	"$ON_BOOT_DIR/27-aftertouch-service.sh" >/dev/null 2>&1; then
	fail "boot hook promoted a target after current changed"
fi
assert_eq "$(readlink "$APP_HOME/current")" "$first"
assert_eq "$(readlink "$APP_HOME/verified")" "$second"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"
run_main_installer --rollback
assert_eq "$(readlink "$APP_HOME/current")" "$second"

write_runtime_config() {
	config_bind=$1
	config_password=$2
	config_dns=$3
	cat >"$APP_HOME/config.env" <<EOF
BIND_ADDR=$config_bind
PORT=18000
HTTPS_PORT=18443
SERVER_URL=http://$config_bind:18000
HTTPS_SERVER_URL=https://$config_bind:18443
DEPLOYMENT_MODE=private-network
DATA_DIR=$APP_HOME/data
REDACT_PROXY_LOGS=true
LOG_PROXY_BODY=false
RECORD_INTERACTIONS=false
DISCOVERY_ENABLED=false
UPDATE_CHECK_ENABLED=false
ENABLE_DNS_DISCOVERY=$config_dns
MGMT_USERNAME=admin
MGMT_PASSWORD=$config_password
STOCKHOLM_DIR=
EOF
}

run_launcher() {
	env PATH="$RUN_BIN:$PATH" AFTERTOUCH_SERVICE_HOME="$APP_HOME" "$APP_HOME/run.sh"
}

write_runtime_config 127.0.0.1 0123456789abcdef false
assert_eq "$(run_launcher)" fixture-two

write_runtime_config 127.0.0.1 change_me! false
if run_launcher >/dev/null 2>&1; then
	fail "published default management password was accepted"
fi

write_runtime_config 0.0.0.0 0123456789abcdef false

if run_launcher >/dev/null 2>&1; then
	fail "wildcard bind was accepted"
fi

write_runtime_config 127.0.0.1 0123456789abcdef true
if run_launcher >/dev/null 2>&1; then
	fail "embedded DNS was accepted"
fi

write_runtime_config 127.0.0.1 0123456789abcdef false
printf '%s\n' '{"dns_enabled": true}' >"$APP_HOME/data/settings.json"
if run_launcher >/dev/null 2>&1; then
	fail "persisted DNS enablement was accepted"
fi
cat >"$APP_HOME/data/settings.json" <<'EOF'
{
  "dns_enabled":
  true
}
EOF
if run_launcher >/dev/null 2>&1; then
	fail "multiline persisted DNS enablement was accepted"
fi
cat >"$APP_HOME/data/settings.json" <<'EOF'
{
  "dns_enabled":
  false
}
EOF
assert_eq "$(run_launcher)" fixture-two
rm -f "$APP_HOME/data/settings.json"

printf 'tampered\n' >>"$APP_HOME/current/soundtouch-service"
if run_launcher >/dev/null 2>&1; then
	fail "tampered binary was accepted"
fi

# A corrupt verified generation must not block a valid replacement. If that
# replacement is later corrupt too, rollback must still recover through the
# older valid previous generation.
run_main_installer --local "$FIXTURE" --version dev-retry --activate
assert_eq "$(readlink "$APP_HOME/current")" "$retry"
assert_eq "$(readlink "$APP_HOME/verified")" "$retry"
assert_eq "$(readlink "$APP_HOME/previous")" "$first"
printf 'tampered\n' >>"$APP_HOME/current/soundtouch-service"
run_main_installer --rollback --activate
assert_eq "$(readlink "$APP_HOME/current")" "$first"
assert_eq "$(readlink "$APP_HOME/verified")" "$first"

# State snapshots are separate from artifact rollback. A restore retains a
# pre-restore generation, and a failed healthcheck puts the original live data
# back before returning an error.
run_state_with_health() {
	test_healthcheck=$1
	shift
	env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" \
		AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" AFTERTOUCH_HEALTHCHECK="$test_healthcheck" \
		AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" "$APP_HOME/aftertouch-service-state.sh" "$@"
}

printf '%s\n' state-one >"$APP_HOME/data/state-probe"
snapshot_output=$(run_state_with_health "$TEST_ROOT/healthcheck" snapshot)
snapshot_one=${snapshot_output##* }
[ -f "$APP_HOME/state-snapshots/$snapshot_one/manifest" ] || fail "snapshot manifest is missing"
[ "$(stat -c '%a' "$APP_HOME/state-snapshots/$snapshot_one")" = 700 ] ||
	fail "snapshot directory is not root-only"
[ "$(stat -c '%a' "$APP_HOME/state-snapshots/$snapshot_one/manifest")" = 600 ] ||
	fail "snapshot manifest is not root-only"
run_state_with_health "$TEST_ROOT/healthcheck" list | grep -Fx "$snapshot_one" >/dev/null ||
	fail "snapshot list omitted a valid snapshot"

printf '%s\n' state-two >"$APP_HOME/data/state-probe"
run_state_with_health "$TEST_ROOT/healthcheck" restore "$snapshot_one" --yes >/dev/null
assert_eq "$(cat "$APP_HOME/data/state-probe")" state-one
find "$APP_HOME/state-snapshots" -mindepth 1 -maxdepth 1 -type d -name '*-pre-restore*' |
	grep -q . || fail "restore did not retain a pre-restore snapshot"

# Cleanup begins only after the restored state has passed validation. If old
# data deletion then fails, cleanup must retain the healthy restored state
# rather than rolling a partially deleted original tree back into place.
printf '%s\n' state-two >"$APP_HOME/data/state-probe"
rm_failure_output=$(
	env AFTERTOUCH_RM="$TEST_ROOT/rm-fail-old" AFTERTOUCH_SERVICE_HOME="$APP_HOME" \
		AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
		AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
		"$APP_HOME/aftertouch-service-state.sh" restore "$snapshot_one" --yes 2>&1
)
assert_eq "$(cat "$APP_HOME/data/state-probe")" state-one
printf '%s\n' "$rm_failure_output" | grep -F 'restored state is active, but old data cleanup failed:' >/dev/null ||
	fail "old data cleanup failure was not reported"
find "$APP_HOME" -mindepth 1 -maxdepth 1 -type d -name '.state-old.*' | grep -q . ||
	fail "failed old data cleanup did not retain the recoverable staging tree"
find "$APP_HOME" -mindepth 1 -maxdepth 1 -type d -name '.state-old.*' -exec rm -rf {} +

printf '%s\n' state-two >"$APP_HOME/data/state-probe"
SYSTEMCTL_STATE=$TEST_ROOT/systemctl-state-value
printf '%s\n' inactive >"$SYSTEMCTL_STATE"
: >"$SYSTEMCTL_LOG"
env AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl-state" \
	AFTERTOUCH_SYSTEMCTL_STATE="$SYSTEMCTL_STATE" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
	"$APP_HOME/aftertouch-service-state.sh" restore "$snapshot_one" --yes >/dev/null
assert_eq "$(cat "$APP_HOME/data/state-probe")" state-one
assert_eq "$(cat "$SYSTEMCTL_STATE")" inactive
grep -Fx 'restart aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null ||
	fail "inactive restore was not health-validated"

printf '%s\n' state-three >"$APP_HOME/data/state-probe"
snapshot_output=$(run_state_with_health "$TEST_ROOT/healthcheck" snapshot)
snapshot_three=${snapshot_output##* }
printf '%s\n' state-four >"$APP_HOME/data/state-probe"
HEALTH_COUNT=$TEST_ROOT/health-count
export HEALTH_COUNT
if env AFTERTOUCH_HEALTH_COUNT="$HEALTH_COUNT" \
	AFTERTOUCH_SERVICE_HOME="$APP_HOME" AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" \
	AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck-fail-once" \
	"$APP_HOME/aftertouch-service-state.sh" restore "$snapshot_three" --yes >/dev/null 2>&1; then
	fail "state restore ignored a failing healthcheck"
fi
assert_eq "$(cat "$APP_HOME/data/state-probe")" state-four
assert_eq "$(cat "$HEALTH_COUNT")" 2

if run_state_with_health "$TEST_ROOT/healthcheck" restore ../unsafe --yes >/dev/null 2>&1; then
	fail "unsafe snapshot ID was accepted"
fi

: >"$SYSTEMCTL_LOG"
if env AFTERTOUCH_CP="$TEST_ROOT/cp-fail" AFTERTOUCH_SERVICE_HOME="$APP_HOME" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" \
	"$APP_HOME/aftertouch-service-state.sh" snapshot >/dev/null 2>&1; then
	fail "snapshot unexpectedly survived a copy failure"
fi
grep -Fx 'stop aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null ||
	fail "copy-failed snapshot did not stop the active service"
grep -Fx 'start aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null ||
	fail "copy-failed snapshot did not recover the active service"

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

release_asset=soundtouch-service-v9.8.7-linux-amd64
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
	AFTERTOUCH_SERVICE_HOME="$BAD_RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$BAD_RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7 >/dev/null 2>&1; then
	fail "release with a bad checksum was accepted"
fi
[ ! -e "$BAD_RELEASE_HOME/current" ] || fail "bad release created a current symlink"
[ ! -e "$BAD_RELEASE_ON_BOOT/27-aftertouch-service.sh" ] || fail "bad release enabled the boot hook"
mv "$RELEASE_FIXTURES/$release_asset.sha256.good" "$RELEASE_FIXTURES/$release_asset.sha256"

env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_RELEASE_BASE_URL=https://fixtures.invalid/releases \
	AFTERTOUCH_SERVICE_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7

[ ! -e "$RELEASE_ON_BOOT/27-aftertouch-service.sh" ] ||
	fail "non-activating first install enabled the boot hook"
grep -Fx 'source=release-mirror' "$RELEASE_HOME/current/manifest" >/dev/null ||
	fail "overridden release source was not identified as a mirror"
grep -Fx 'release_url=https://fixtures.invalid/releases/v9.8.7/soundtouch-service-v9.8.7-linux-amd64' \
	"$RELEASE_HOME/current/manifest" >/dev/null || fail "release URL missing from manifest"

# The unmodified upstream release origin must retain official provenance even
# though the fake curl keeps this test offline.
env PATH="$BIN_DIR:$PATH" FAKE_RELEASE_DIR="$RELEASE_FIXTURES" \
	AFTERTOUCH_SERVICE_HOME="$OFFICIAL_RELEASE_HOME" \
	AFTERTOUCH_ON_BOOT_DIR="$OFFICIAL_RELEASE_ON_BOOT" AFTERTOUCH_MACHINE=x86_64 \
	"$ADDON_DIR/install.sh" --release v9.8.7

grep -Fx 'source=official-release' "$OFFICIAL_RELEASE_HOME/current/manifest" >/dev/null ||
	fail "official release source missing from manifest"
grep -Fx 'release_url=https://github.com/gesellix/Bose-SoundTouch/releases/download/v9.8.7/soundtouch-service-v9.8.7-linux-amd64' \
	"$OFFICIAL_RELEASE_HOME/current/manifest" >/dev/null ||
	fail "official release URL missing from manifest"

# Reusing identical bytes under conflicting provenance must fail instead of
# retaining whichever manifest happened to be installed first.
if env AFTERTOUCH_SERVICE_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
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
	AFTERTOUCH_SERVICE_HOME="$RELEASE_HOME" AFTERTOUCH_ON_BOOT_DIR="$RELEASE_ON_BOOT" \
	AFTERTOUCH_MACHINE=x86_64 AFTERTOUCH_UNIT_DIR="$UNIT_DIR" \
	AFTERTOUCH_SYSTEMCTL="$TEST_ROOT/systemctl" AFTERTOUCH_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
	AFTERTOUCH_HEALTHCHECK="$TEST_ROOT/healthcheck" AFTERTOUCH_HEALTH_LOG="$HEALTH_LOG" \
	"$ADDON_DIR/install.sh" --activate

[ -f "$UNIT_DIR/aftertouch-service.service" ] || fail "boot hook did not restore the unit"
[ -x "$RELEASE_ON_BOOT/27-aftertouch-service.sh" ] || fail "activation did not install the boot hook"
grep -Fx 'daemon-reload' "$SYSTEMCTL_LOG" >/dev/null || fail "boot hook skipped daemon-reload"
grep -Fx 'disable aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null || fail "boot hook skipped disable"
if grep -Fx 'enable aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null; then
	fail "boot hook enabled a competing systemd boot path"
fi
grep -Fx 'restart aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null || fail "boot hook skipped restart"
grep -Fx 'is-active --quiet aftertouch-service.service' "$SYSTEMCTL_LOG" >/dev/null || fail "boot hook skipped active-state check"
[ -f "$HEALTH_LOG" ] || fail "boot hook skipped healthcheck"
assert_eq "$(readlink "$RELEASE_HOME/verified")" "$(readlink "$RELEASE_HOME/current")"

# The healthcheck must bind readiness to the exact running bytes, not only a
# listener and a version label that another build can reuse.
HEALTH_HOME=$TEST_ROOT/health-app
HEALTH_BIN=$TEST_ROOT/health-bin
HEALTH_PROC=$TEST_ROOT/health-proc
mkdir -p "$HEALTH_HOME/current" "$HEALTH_HOME/data/certs" "$HEALTH_BIN" "$HEALTH_PROC/4242"
cat >"$HEALTH_HOME/current/soundtouch-service" <<'EOF'
#!/bin/sh
echo expected-runtime
EOF
chmod 0755 "$HEALTH_HOME/current/soundtouch-service"
health_sha=$(sha256sum "$HEALTH_HOME/current/soundtouch-service" | awk '{print $1}')
cat >"$HEALTH_HOME/current/manifest" <<EOF
schema=1
component=aftertouch-service
source=local
version=same-version
architecture=linux-amd64
asset=health-fixture
sha256=$health_sha
release_url=
EOF
cat >"$HEALTH_HOME/config.env" <<EOF
BIND_ADDR=127.0.0.1
PORT=19000
HTTPS_PORT=19443
DATA_DIR=$HEALTH_HOME/data
AFTERTOUCH_HEALTH_TIMEOUT=1
EOF
printf '%s\n' '{}' >"$HEALTH_HOME/data/settings.json"
touch "$HEALTH_HOME/data/certs/ca.crt" "$HEALTH_HOME/data/certs/ca.key" \
	"$HEALTH_HOME/data/certs/server.key"
ln -s "$HEALTH_HOME/current/soundtouch-service" "$HEALTH_PROC/4242/exe"
cat >"$HEALTH_PROC/4242/status" <<'EOF'
Name:	soundtouch-service
Uid:	65532	65532	65532	65532
Gid:	65532	65532	65532	65532
EOF
cat >"$HEALTH_BIN/ss" <<'EOF'
#!/bin/sh
printf '%s\n' \
	'LISTEN 0 4096 127.0.0.1:19000' \
	'LISTEN 0 4096 127.0.0.1:19443'
EOF
cat >"$HEALTH_BIN/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
show) echo 4242 ;;
is-active) exit 0 ;;
*) exit 0 ;;
esac
EOF
cat >"$HEALTH_BIN/curl" <<'EOF'
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
	--max-time | --cacert)
		shift 2
		;;
	-*) shift ;;
	*)
		url=$1
		shift
		;;
	esac
done
case "$url" in
*/api/setup/version)
	printf '{"version":"same-version","data_dir":"%s"}\n' "$FAKE_HEALTH_DATA_DIR" >"$output"
	;;
*/api/control/devices/) printf '%s\n' '[]' >"$output" ;;
*/health) printf '%s\n' '{"status":"up"}' >"$output" ;;
*/app/) printf '%s\n' '<html></html>' >"$output" ;;
*) exit 22 ;;
esac
EOF
chmod 0755 "$HEALTH_BIN/ss" "$HEALTH_BIN/systemctl" "$HEALTH_BIN/curl"

env PATH="$HEALTH_BIN:$PATH" AFTERTOUCH_SERVICE_HOME="$HEALTH_HOME" \
	AFTERTOUCH_PROC_ROOT="$HEALTH_PROC" AFTERTOUCH_SYSTEMCTL="$HEALTH_BIN/systemctl" \
	FAKE_HEALTH_DATA_DIR="$HEALTH_HOME/data" \
	"$ADDON_DIR/aftertouch-service-healthcheck.sh" >/dev/null

cat >"$HEALTH_HOME/stale-same-version" <<'EOF'
#!/bin/sh
echo stale-runtime
EOF
chmod 0755 "$HEALTH_HOME/stale-same-version"
ln -sfn "$HEALTH_HOME/stale-same-version" "$HEALTH_PROC/4242/exe"
if env PATH="$HEALTH_BIN:$PATH" AFTERTOUCH_SERVICE_HOME="$HEALTH_HOME" \
	AFTERTOUCH_PROC_ROOT="$HEALTH_PROC" AFTERTOUCH_SYSTEMCTL="$HEALTH_BIN/systemctl" \
	FAKE_HEALTH_DATA_DIR="$HEALTH_HOME/data" \
	"$ADDON_DIR/aftertouch-service-healthcheck.sh" >/dev/null 2>&1; then
	fail "healthcheck accepted stale same-version process bytes"
fi

if grep -Eq '^(User|Group)=' "$ADDON_DIR/aftertouch-service.service"; then
	fail "systemd must not resolve a nonexistent numeric service account"
fi
grep -Fx 'CapabilityBoundingSet=CAP_SETUID CAP_SETGID' \
	"$ADDON_DIR/aftertouch-service.service" >/dev/null ||
	fail "systemd unit lacks the bounded launcher privileges"
# shellcheck disable=SC2016 # The grep pattern intentionally matches literals.
grep -F 'exec setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --clear-groups "$BINARY"' \
	"$ADDON_DIR/run.sh" >/dev/null || fail "launcher does not drop to the fixed service identity"
grep -Fx 'ProtectSystem=strict' "$ADDON_DIR/aftertouch-service.service" >/dev/null ||
	fail "systemd unit does not protect the host filesystem"
grep -Fx 'ReadWritePaths=/data/aftertouch-service/data' \
	"$ADDON_DIR/aftertouch-service.service" >/dev/null ||
	fail "systemd unit lacks the explicit persistent-state write path"
if grep -q '^DynamicUser=' "$ADDON_DIR/aftertouch-service.service"; then
	fail "dynamic UID would break ownership of persistent state"
fi

echo "test-addon: PASS"
