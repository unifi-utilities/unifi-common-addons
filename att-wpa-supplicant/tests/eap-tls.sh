#!/bin/sh
# Qualification test: real systemd, real wpa_supplicant from the bundle, real
# EAP-TLS. Opt-in. Needs Docker with --privileged (systemd as PID 1, veth).
# Run it before a release that claims a Debian release.
#
# For each codename, it builds a bundle with tools/build-bundle.sh for this
# machine's architecture, starts systemd in a debian:<codename> container
# with the libraries that UniFi OS supplies (but no wpasupplicant package),
# runs hostapd as the authenticator on one end of a veth pair, and uses the
# addon (install, add-instance, import-bundle, activate) on the other end.
#
# Usage: tests/eap-tls.sh [codename...]   (default: bullseye bookworm trixie)
# Exit status 0 only if every assertion passed for every codename.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ADDON=$(cd "$HERE/.." && pwd)
[ $# -gt 0 ] || set -- bullseye bookworm trixie
case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "unsupported machine $(uname -m)" >&2; exit 2 ;;
esac
WORK=$(mktemp -d) || exit 2
CIDS=''
cleanup() {
    for c in $CIDS; do docker rm -f "$c" >/dev/null 2>&1; done
    rm -rf -- "${WORK:?}"
}
# An interrupt must end the run as a failure: a trap that only cleans up
# would let the loop go on and print PASSED.
trap cleanup EXIT
trap 'echo "interrupted" >&2; exit 130' INT TERM HUP
TOTAL_FAIL=0

# The test that runs inside the container, as root, under systemd.
cat >"$WORK/inner.sh" <<'INNER'
#!/bin/sh
# shellcheck disable=SC2015 # ok and bad never fail
set -u
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || echo "     $2"; }
U=att-wpa-supplicant@veth1.service
A=/data/unifi-common-addons/att-wpa-supplicant/att-wpa-supplicant
BUNDLES=/data/unifi-common-addons/att-wpa-supplicant/bundles
CHOICE=/run/att-wpa-supplicant/veth1/selected-runtime
mainpid() { systemctl show -p MainPID --value "$U"; }
# Every entry under /data/unifi-common-addons/att-wpa-supplicant with its inode, mode, size,
# mtime, and ctime: a write there changes it.
data_sig() { find /data/unifi-common-addons/att-wpa-supplicant -printf '%p %i %m %s %T@ %C@\n' | LC_ALL=C sort | sha256sum; }
wait_auth() { # seconds -> 0 if check passes in time
    n=0
    while [ "$n" -lt "$1" ]; do
        "$A" check veth1 >/dev/null 2>&1 && return 0
        n=$((n + 1)); sleep 1
    done
    return 1
}

# UniFi OS mounts /run noexec. The container does the same, so that a
# runtime under /run would fail here as it does on the gateway.
findmnt -no OPTIONS -T /run | grep -qw noexec && ok "/run is noexec, as on UniFi OS" || bad "/run is noexec, as on UniFi OS" "$(findmnt -no OPTIONS -T /run)"

# Certificates: SHA-1, RSA-1024, like old AT&T gateway certificates.
mkdir -p /t /src && cd /t || exit 2
mk() { openssl genrsa -out "$1.key" 1024 2>/dev/null; }
for ca in ca other; do
    mk "$ca"; openssl req -x509 -new -sha1 -key "$ca.key" -days 30 -subj "/CN=$ca" -out "$ca.pem" 2>/dev/null
done
for n in server client; do
    mk $n; openssl req -new -sha1 -key $n.key -subj /CN=$n -out $n.csr 2>/dev/null
    openssl x509 -req -sha1 -in $n.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -out $n.pem 2>/dev/null
done
cp ca.pem /src/CA_test.pem; cp client.pem /src/Client_test.pem; cp client.key /src/PrivateKey_PKCS1_test.pem
printf 'network={\n  identity="AA:BB:CC:DD:EE:FF"\n}\n' >/src/wpa_supplicant.conf

ip link add veth0 type veth peer name veth1 && ip link set veth0 up && ip link set veth1 up || exit 2
printf '* TLS\n' >eap_user
hostapd_conf() { # trusted CA file
    cat >hostapd.conf <<H
interface=veth0
driver=wired
ieee8021x=1
eap_server=1
eap_user_file=/t/eap_user
ca_cert=$1
server_cert=/t/server.pem
private_key=/t/server.key
use_pae_group_addr=1
openssl_ciphers=DEFAULT@SECLEVEL=0
H
}
printf 'openssl_conf = o\n[o]\nssl_conf = s\n[s]\nsystem_default = d\n[d]\nCipherString = DEFAULT@SECLEVEL=0\nMinProtocol = TLSv1\n' >weak.cnf
start_hostapd() { OPENSSL_CONF=/t/weak.cnf hostapd -B -P /t/hostapd.pid hostapd.conf >/t/hostapd.log 2>&1; sleep 1; }
stop_hostapd() { kill "$(cat /t/hostapd.pid)" 2>/dev/null; sleep 1; }
hostapd_conf /t/ca.pem
start_hostapd

# The addon, as a user installs it.
mkdir -p /data/on_boot.d
cd /addon && ./att-wpa-supplicant install >/dev/null 2>&1 || bad "install"
cd /
"$A" add-instance veth1 /src >/dev/null 2>&1 && ok "add-instance" || bad "add-instance"
"$A" import-bundle /bundle.tgz >/dev/null 2>&1 && ok "import-bundle" || bad "import-bundle"
dpkg-query -W wpasupplicant >/dev/null 2>&1 && bad "no wpasupplicant package installed" || ok "no wpasupplicant package installed"
B=$(ls -d "$BUNDLES"/*-*[!v])
[ -x "$(find "$B/root" -name wpa_supplicant -type f | head -n 1)" ] && ok "import-bundle: unpacks the runtime in the bundle" || bad "import-bundle: unpacks the runtime in the bundle"
# Restart faster than the shipped 30 s, so that the test is short. This
# drop-in changes nothing else.
mkdir -p /etc/systemd/system/$U.d
printf '[Service]\nRestartSec=2\n' >/etc/systemd/system/$U.d/test.conf

out=$("$A" plan veth1 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "plan: passes" || bad "plan: passes" "$out"
echo "$out" | grep -q 'loads on this firmware' && ok "plan: the runtime passes the load check" || bad "plan: the runtime passes the load check" "$out"

out=$(ATT_WPA_TAKEOVER_TIMEOUT=60 "$A" activate veth1 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "activate: authorized through the real unit" || bad "activate: authorized through the real unit" "$(echo "$out" | tail -n 5)"
out=$("$A" check veth1 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "check: exit 0" || bad "check: exit 0" "$out"
echo "$out" | grep -q 'OK veth1: 802.1X authorized' && ok "check: authorized" || bad "check: authorized" "$out"
echo "$out" | grep -q "INFO veth1: runtime at start: wpa_supplicant v2" && ok "check: names the runtime" || bad "check: names the runtime" "$out"

pid=$(mainpid)
exe=$(readlink "/proc/$pid/exe")
case "$exe" in "$B"/root/*) ok "process runs from the bundle's runtime ($exe)" ;; *) bad "process runs from the bundle's runtime" "exe=$exe" ;; esac
libdir=$(dirname "$(find "$B/root" -name 'libpcsclite.so.1' | head -n 1)")
tr '\0' '\n' <"/proc/$pid/environ" | grep -qx "LD_LIBRARY_PATH=$libdir" &&
    ok "process LD_LIBRARY_PATH is the runtime library directory" || bad "process LD_LIBRARY_PATH" "$(tr '\0' '\n' <"/proc/$pid/environ" | grep LD_)"
[ -e "/proc/$pid/fd/9" ] && bad "fd 9 is open in the supplicant" "$(readlink "/proc/$pid/fd/9")" || ok "fd 9 is not open in the supplicant"
grep -q "libpcsclite.so.1" "/proc/$pid/maps" && grep "libpcsclite" "/proc/$pid/maps" | grep -q "$B/root/" &&
    ok "libpcsclite is mapped from the runtime" || bad "libpcsclite is mapped from the runtime"
for d in /run/att-wpa-supplicant/veth1 "$B"; do
    m=$(stat -c %a "$d" 2>/dev/null)
    [ "$m" = 700 ] && ok "$d is 0700" || bad "$d is 0700" "mode=$m"
done
[ "$(head -n 1 "$CHOICE" 2>/dev/null)" = cur ] && ok "precheck: chose the bundle (cur)" || bad "precheck: chose the bundle (cur)" "$(head -n 1 "$CHOICE" 2>/dev/null)"
[ ! -e /data/unifi-common-addons/att-wpa-supplicant/runtime ] && ok "no runtime directory outside the bundles" || bad "no runtime directory outside the bundles"

# kill -9: systemd restarts the unit, reauthorizes, and writes nothing on
# /data.
before=$(data_sig)
t=$(date +%s)
kill -9 "$pid"
n=0; while [ "$n" -lt 30 ] && { [ "$(mainpid)" = 0 ] || [ "$(mainpid)" = "$pid" ]; }; do n=$((n + 1)); sleep 1; done
wait_auth 30 && ok "kill -9: reauthorized" || bad "kill -9: reauthorized"
[ "$(systemctl show -p NRestarts --value "$U")" = 1 ] && ok "kill -9: one restart" || bad "kill -9: one restart" "NRestarts=$(systemctl show -p NRestarts --value "$U")"
[ "$(data_sig)" = "$before" ] && ok "kill -9: the restart wrote nothing on /data" || bad "kill -9: the restart wrote nothing on /data"
journalctl -u "$U" --since "@$t" --no-pager 2>/dev/null | grep -q 'veth1: runtime ready: wpa_supplicant v2' &&
    ok "kill -9: the journal says runtime ready" || bad "kill -9: the journal says runtime ready"
# Count in the restarted invocation only: --since has whole seconds.
n=$(journalctl -u "$U" "_SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value "$U")" --no-pager 2>/dev/null | grep -c 'runtime ready')
[ "$n" = 1 ] && ok "kill -9: the journal has the line once (no logger copy)" || bad "kill -9: the journal has the line once (no logger copy)" "count=$n"

# A client that the server does not trust: check must fail.
stop_hostapd; hostapd_conf /t/other.pem; start_hostapd
t=$(date +%s)
systemctl restart "$U"
if wait_auth 15; then bad "untrusted client: check fails"; else ok "untrusted client: check fails"; fi
"$A" check veth1 >/dev/null 2>&1 && bad "untrusted client: check exit 1" || ok "untrusted client: check exit 1"
[ "$(systemctl is-active "$U")" = active ] && ok "untrusted client: the supplicant runs" || bad "untrusted client: the supplicant runs"
journalctl -u "$U" --since "@$t" --no-pager 2>/dev/null | grep -q 'CTRL-EVENT-EAP-FAILURE' &&
    ok "untrusted client: the server rejected it (EAP-FAILURE)" || bad "untrusted client: the server rejected it (EAP-FAILURE)"
stop_hostapd; hostapd_conf /t/ca.pem; start_hostapd
systemctl restart "$U"
wait_auth 30 && ok "trusted again: reauthorized" || bad "trusted again: reauthorized"

# A damaged runtime and no .prev: precheck fails, no supplicant starts,
# the journal says why.
[ ! -e "$B.prev" ] && ok "bad runtime: no .prev exists yet" || bad "bad runtime: no .prev exists yet"
damage() { find "$B/root" -name 'libpcsclite.so*' -exec rm -f {} +; }
damage
systemctl restart "$U"
sleep 3
pgrep -x wpa_supplicant >/dev/null && bad "bad runtime: no supplicant runs" "$(pgrep -a wpa_supplicant)" || ok "bad runtime: no supplicant runs"
# Without libpcsclite.so*, the tree has no library directory, or (trixie
# ships another library in it) the loader cannot find libpcsclite.so.1.
journalctl -u "$U" --no-pager 2>/dev/null | grep -Eq 'no usable library directory|libpcsclite\.so\.1: cannot open' && ok "bad runtime: the journal says why" || bad "bad runtime: the journal says why" "$(journalctl -u "$U" --no-pager 2>/dev/null | grep 'runtime:' | tail -n 3)"
cd / && "$A" import-bundle /bundle.tgz >/dev/null 2>&1
systemctl restart "$U"
wait_auth 30 && ok "repaired runtime: reauthorized" || bad "repaired runtime: reauthorized"

# A good .prev and a damaged runtime: the unit falls back to .prev.
"$A" import-bundle /bundle.tgz >/dev/null 2>&1
damage
t=$(date +%s)
systemctl restart "$U"
wait_auth 30 && ok "fallback: authorized from .prev" || bad "fallback: authorized from .prev"
[ "$(head -n 1 "$CHOICE" 2>/dev/null)" = prev ] && ok "fallback: precheck chose .prev" || bad "fallback: precheck chose .prev" "$(head -n 1 "$CHOICE" 2>/dev/null)"
journalctl -u "$U" --since "@$t" --no-pager 2>/dev/null | grep -q 'WARN runtime: using the previous bundle' &&
    ok "fallback: the journal warns" || bad "fallback: the journal warns"

# A swap while the supplicant runs from .prev (the bundle fails): the swap
# keeps .prev and replaces the bundle. The next start uses the new bundle.
pid=$(mainpid)
"$A" import-bundle /bundle.tgz >/dev/null 2>&1 && ok "swap from .prev: import succeeds" || bad "swap from .prev: import succeeds"
case "$(readlink "/proc/$pid/exe")" in "$B".prev/root/*) ok "swap from .prev: the tree in use stays" ;; *) bad "swap from .prev: the tree in use stays" "$(readlink "/proc/$pid/exe")" ;; esac
sleep 2
[ "$(mainpid)" = "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "swap from .prev: the supplicant runs on" || bad "swap from .prev: the supplicant runs on"
"$A" check veth1 >/dev/null 2>&1 && ok "swap from .prev: still authorized" || bad "swap from .prev: still authorized"
systemctl restart "$U"
wait_auth 30 && ok "swap from .prev: the next start authorizes" || bad "swap from .prev: the next start authorizes"
[ "$(head -n 1 "$CHOICE" 2>/dev/null)" = cur ] && ok "swap from .prev: the next start chose the new bundle" || bad "swap from .prev: the next start chose the new bundle"

# Two swaps while the supplicant runs from the bundle: its tree moves to
# .prev, then is deleted.
pid=$(mainpid)
"$A" import-bundle /bundle.tgz >/dev/null 2>&1 && "$A" import-bundle /bundle.tgz >/dev/null 2>&1 &&
    ok "swap from cur: two imports succeed" || bad "swap from cur: two imports succeed"
case "$(readlink "/proc/$pid/exe")" in *'(deleted)') ok "swap from cur: the tree in use was deleted" ;; *) bad "swap from cur: the tree in use was deleted" "$(readlink "/proc/$pid/exe")" ;; esac
sleep 2
[ "$(mainpid)" = "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "swap from cur: the supplicant runs on" || bad "swap from cur: the supplicant runs on"
"$A" check veth1 >/dev/null 2>&1 && ok "swap from cur: still authorized" || bad "swap from cur: still authorized"
systemctl restart "$U"
wait_auth 30 && ok "swap from cur: the next start authorizes" || bad "swap from cur: the next start authorizes"

# The interface appears after the unit starts (a late SFP or USB NIC). The
# precheck fails, and Restart=always retries it until the interface exists.
systemctl stop "$U"
ip link del veth0
t=$(date +%s)
systemctl start --no-block "$U"
sleep 7
# systemd logs "Scheduled restart job" each time Restart= applies.
n=$(journalctl -u "$U" --since "@$t" --no-pager 2>/dev/null | grep -c 'Scheduled restart job')
journalctl -u "$U" --since "@$t" --no-pager 2>/dev/null | grep -q 'veth1: interface not present yet' &&
    ok "late interface: precheck fails while the interface is missing" || bad "late interface: precheck fails while the interface is missing"
[ "$n" -ge 1 ] && ok "late interface: systemd restarts after a failed precheck ($n restarts)" || bad "late interface: systemd restarts after a failed precheck" "restarts=$n state=$(systemctl is-active "$U")"
ip link add veth0 type veth peer name veth1 && ip link set veth0 up && ip link set veth1 up
stop_hostapd; start_hostapd
wait_auth 30 && ok "late interface: authorized once it exists" || bad "late interface: authorized once it exists"

# deactivate: the unit stops. systemd deletes the control socket
# directory; the runtime in the bundle stays for the next start.
"$A" deactivate veth1 >/dev/null 2>&1 && ok "deactivate" || bad "deactivate"
[ ! -e /run/att-wpa-supplicant/veth1 ] && ok "stop: systemd deleted the control socket directory" || bad "stop: systemd deleted the control socket directory"
[ -x "$(find "$B/root" -name wpa_supplicant -type f | head -n 1)" ] && ok "stop: the runtime stays on /data" || bad "stop: the runtime stays on /data"
pgrep -x wpa_supplicant >/dev/null && bad "stop: no supplicant runs" || ok "stop: no supplicant runs"
sleep 3
[ "$(systemctl is-active "$U")" = inactive ] && ok "stop: the unit does not restart" || bad "stop: the unit does not restart" "$(systemctl is-active "$U")"

"$A" uninstall >/dev/null 2>&1 && ok "uninstall" || bad "uninstall"
[ -d "$B/root" ] && ok "uninstall: keeps the bundles and their runtime" || bad "uninstall: keeps the bundles and their runtime"

echo "RESULT $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER

for c; do
    case "$c" in *[!a-z]* | '') echo "invalid codename '$c'" >&2; exit 2 ;; esac
    echo "=== $c-$ARCH"
    sh "$ADDON/tools/build-bundle.sh" "$c" "$ARCH" "$WORK" >"$WORK/build-$c.log" 2>&1 ||
        { echo "FAIL bundle build for $c"; tail -n 5 "$WORK/build-$c.log"; TOTAL_FAIL=1; continue; }
    sources=''
    case "$c" in buster | bullseye)
        sources="rm -f /etc/apt/sources.list.d/*; printf 'deb http://archive.debian.org/debian $c main\ndeb http://archive.debian.org/debian $c-updates main\ndeb http://archive.debian.org/debian-security $c-security main\n' >/etc/apt/sources.list;" ;;
    esac
    # The firmware's libraries, the test server, and systemd. No wpasupplicant.
    cat >"$WORK/Dockerfile.$c" <<EOF
FROM debian:$c
RUN $sources apt-get update -qq && \\
    (apt-get install -y -qq --no-install-recommends libreadline8t64 || apt-get install -y -qq --no-install-recommends libreadline8) && \\
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \\
      systemd systemd-sysv dbus libdbus-1-3 libnl-3-200 libnl-genl-3-200 libnl-route-3-200 \\
      hostapd openssl iproute2 procps util-linux ca-certificates && \\
    ! dpkg-query -W wpasupplicant 2>/dev/null && \\
    systemctl mask getty@tty1.service systemd-udevd.service systemd-networkd.service 2>/dev/null; true
EOF
    img="att-eap-tls-test:$c"
    docker build -q -t "$img" -f "$WORK/Dockerfile.$c" "$WORK" >"$WORK/image-$c.log" 2>&1 ||
        { echo "FAIL image build for $c"; tail -n 5 "$WORK/image-$c.log"; TOTAL_FAIL=1; continue; }
    # /run noexec, as UniFi OS 6.0.17 mounts it (gateway test G0).
    cid=$(docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run:rw,noexec,nosuid,nodev,mode=755 --tmpfs /run/lock --tmpfs /tmp "$img" /lib/systemd/systemd) ||
        { echo "FAIL container start for $c"; TOTAL_FAIL=1; continue; }
    CIDS="$CIDS $cid"
    n=0
    until docker exec "$cid" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do
        n=$((n + 1)); [ "$n" -lt 60 ] || break; sleep 1
    done
    docker cp "$ADDON" "$cid:/addon" >/dev/null
    docker cp "$WORK/$c-$ARCH.tgz" "$cid:/bundle.tgz" >/dev/null
    docker cp "$WORK/inner.sh" "$cid:/inner.sh" >/dev/null
    # A release passes only if the inner test exits 0 and ran to its end
    # with no failure: the exit status alone does not show a test cut
    # short.
    docker exec "$cid" sh /inner.sh >"$WORK/inner-$c.out" 2>&1 || TOTAL_FAIL=1
    cat "$WORK/inner-$c.out"
    grep -Eq '^RESULT [0-9]+ passed, 0 failed$' "$WORK/inner-$c.out" || TOTAL_FAIL=1
    docker rm -f "$cid" >/dev/null 2>&1
done
[ "$TOTAL_FAIL" -eq 0 ] && echo "EAP-TLS QUALIFICATION PASSED: $*" || echo "EAP-TLS QUALIFICATION FAILED"
[ "$TOTAL_FAIL" -eq 0 ]
