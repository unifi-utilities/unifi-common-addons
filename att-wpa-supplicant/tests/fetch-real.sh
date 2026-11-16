#!/bin/sh
# shellcheck disable=SC2015 # pass and fail never fail
# Real-network test of "fetch <codename>" and "fetch --all". For each host
# release, a Debian container (the "firmware") runs fetch --all against
# Debian's mirrors with the shipped keys. The packages of each bundle must
# be the same as those of tools/build-bundle.sh, which builds the bundles
# that tests/eap-tls.sh qualifies. Then a wrong key must make fetch fail.
# Needs Docker and internet access. Run it on a disposable machine, never
# on the gateway. It uses the architecture of this machine.
# Usage: tests/fetch-real.sh [host-codename...]   (default: bullseye bookworm trixie)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ADDON=$(cd "$HERE/.." && pwd)
[ $# -gt 0 ] || set -- bullseye bookworm trixie
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK:?}"' EXIT
FAIL=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

echo "reference bundles (tools/build-bundle.sh, $ARCH)"
mkdir "$WORK/ref"
sh "$ADDON/tools/build-bundle.sh" bullseye,bookworm,trixie "$ARCH" "$WORK/ref" >"$WORK/ref.log" 2>&1 ||
    { cat "$WORK/ref.log"; echo "FAIL build-bundle.sh"; exit 1; }
for c in bullseye bookworm trixie; do
    tar -xzOf "$WORK/ref/$c-$ARCH.tgz" "$c-$ARCH/MANIFEST" | grep '^pkg=' | sort >"$WORK/ref/$c.pkgs"
done

# Runs in the container: openssl stands in for the firmware's libssl. The
# addon runs with ATT_WPA_ROOT, so it needs no systemd and no install.
# After the setup, the "firmware" gets hostile APT settings: hooks, a
# default release, and permission for unsigned repositories, in
# apt.conf.d and in APT_CONFIG. fetch must ignore all of them.
cat >"$WORK/inner.sh" <<'EOF'
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends openssl >/dev/null 2>&1
cat >/etc/apt/apt.conf.d/99hostile <<'H'
APT::Update::Pre-Invoke { "touch /hostile-ran"; };
APT::Default-Release "sid";
Acquire::AllowInsecureRepositories "true";
Acquire::AllowDowngradeToInsecureRepositories "true";
APT::Get::AllowUnauthenticated "true";
H
printf 'APT::Update::Post-Invoke { "touch /hostile-env-ran"; };\n' >/hostile.conf
export APT_CONFIG=/hostile.conf
R=/r
mkdir -p "$R/etc" "$R/tmp" "$R/run"
cp /etc/os-release "$R/etc/os-release"
export ATT_WPA_ROOT=$R
/addon/att-wpa-supplicant fetch --all >/out/fetch.log 2>&1
echo "rc=$?" >>/out/fetch.log
for c in bullseye bookworm trixie; do
    grep '^pkg=' "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/$c-$(dpkg --print-architecture)/MANIFEST" 2>/dev/null | sort >"/out/$c.pkgs"
done
ls "$R/tmp" >/out/tmp-left
ls -A "$R/data/unifi-common-addons/att-wpa-supplicant/bundles" >/out/bundles-left
# The whole trixie bundle, file by file.
b="$R/data/unifi-common-addons/att-wpa-supplicant/bundles/trixie-$(dpkg --print-architecture)"
digest() { (cd "$b" && find . -type f -o -type l | sort | while read -r f; do
    if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; else sha256sum "$f"; fi; done); }
digest >/out/trixie-before.digest
# A wrong key: the bullseye stable key only. fetch must fail and keep the bundle.
cp -r /addon /wrong
awk '/BEGIN PGP/ {n++} n == 6' /addon/keys/debian-archive.asc >/wrong/keys/debian-archive.asc
/wrong/att-wpa-supplicant fetch trixie >/out/wrong.log 2>&1
echo "rc=$?" >>/out/wrong.log
digest >/out/trixie-after.digest
ls "$R/tmp" >/out/tmp-left-wrong
ls -A "$R/data/unifi-common-addons/att-wpa-supplicant/bundles" >/out/bundles-left-wrong
ls /hostile-ran /hostile-env-ran >/out/hostile 2>/dev/null || true
EOF

for h in "$@"; do
    echo "host $h"
    out="$WORK/out-$h"
    mkdir "$out"
    docker run --rm -v "$ADDON:/addon:ro" -v "$WORK/inner.sh:/inner.sh:ro" -v "$out:/out" \
        "debian:$h" sh /inner.sh || { fail "$h: container failed"; continue; }
    if grep -q '^rc=0$' "$out/fetch.log"; then pass "$h: fetch --all succeeds"; else fail "$h: fetch --all succeeds"; cat "$out/fetch.log"; fi
    grep -q "fetch: done. Bundles ready for: bullseye bookworm trixie" "$out/fetch.log" &&
        pass "$h: fetch --all says that all three are ready" || fail "$h: fetch --all says that all three are ready"
    for c in bullseye bookworm trixie; do
        if [ -s "$out/$c.pkgs" ] && cmp -s "$out/$c.pkgs" "$WORK/ref/$c.pkgs"; then
            pass "$h: $c bundle has the packages of build-bundle.sh"
        else
            fail "$h: $c bundle has the packages of build-bundle.sh"
            diff "$WORK/ref/$c.pkgs" "$out/$c.pkgs" || true
        fi
    done
    grep -q "note: $h-" "$out/fetch.log" && fail "$h: no note for the running release" || pass "$h: no note for the running release"
    [ ! -s "$out/tmp-left" ] && pass "$h: no scratch directory left" || fail "$h: no scratch directory left"
    grep -q '^\.' "$out/bundles-left" && fail "$h: no fetch directory left" || pass "$h: no fetch directory left"
    grep -q '^rc=1$' "$out/wrong.log" && pass "$h: a wrong key makes fetch fail" || { fail "$h: a wrong key makes fetch fail"; cat "$out/wrong.log"; }
    grep -q 'cannot download or verify the package lists' "$out/wrong.log" &&
        pass "$h: the failure names the package lists" || fail "$h: the failure names the package lists"
    [ -s "$out/trixie-before.digest" ] && cmp -s "$out/trixie-after.digest" "$out/trixie-before.digest" &&
        pass "$h: a failed fetch keeps the bundle, file by file" || fail "$h: a failed fetch keeps the bundle, file by file"
    [ ! -s "$out/tmp-left-wrong" ] && pass "$h: a failed fetch leaves no scratch directory" || fail "$h: a failed fetch leaves no scratch directory"
    grep -q '^\.' "$out/bundles-left-wrong" && fail "$h: a failed fetch leaves no fetch directory" || pass "$h: a failed fetch leaves no fetch directory"
    [ ! -s "$out/hostile" ] && pass "$h: no hook of the firmware's APT settings ran" || fail "$h: no hook of the firmware's APT settings ran"
done
if [ "$FAIL" -eq 0 ]; then echo "FETCH TEST PASSED: $*"; else echo "FETCH TEST FAILED"; exit 1; fi
