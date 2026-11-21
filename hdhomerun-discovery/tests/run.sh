#!/bin/sh
# Off-box tests for the hdhomerun-discovery control script. Needs: sh,
# coreutils, awk, flock. Stubs systemctl, ip, ss, and perl. Runs on a
# fixture root (HDHR_ROOT), so it touches no real path.
# Usage: tests/run.sh      (HDHR_SCRIPT overrides the script under test)
# No set -e, so that a failing command under test does not stop the suite.
# shellcheck disable=SC2016 # sh -c scripts are single-quoted on purpose
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${HDHR_SCRIPT:-$HERE/../hdhomerun-discovery}"
PASS=0
FAIL=0
TOP=$(mktemp -d) || { echo "cannot create a temp dir; aborting" >&2; exit 1; }
case "$TOP" in /?*/?*) ;; *) echo "unsafe temp dir '$TOP'; aborting" >&2; exit 1 ;; esac
trap 'rm -rf -- "${TOP:?}"' EXIT
ORIG_PATH=$PATH
UNIT=hdhomerun-discovery.service
ENTRY=20-hdhomerun-discovery.sh

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
# check LABEL CMD...: pass when the command succeeds.
check() { l=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$l"; fi; }
# refuse LABEL CMD...: pass when the command fails.
refuse() { l=$1; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok; fi; }
has() { grep -q -- "$2" "$1" 2>/dev/null; }

# ---------- fixture ----------

# iface NAME FLAGS CIDR: a fake interface.
iface() {
    mkdir -p "$R/sys/class/net/$1"
    printf '%s\n' "$2" >"$R/sys/class/net/$1/flags"
    printf '7: %s    inet %s scope global %s\\       valid_lft forever\n' "$1" "$3" "$1" >"$S/ip-$1"
}

conf() { printf '%s\n' "$1" >"$H/hdhomerun-discovery.conf"; }
GOOD='CLIENTS="br0"
TUNERS="br30"'

setup() {
    T="$TOP/$1"
    R="$T/root"
    S="$T/state"
    B="$T/bin"
    H="$R/data/unifi-common-addons/hdhomerun-discovery"
    mkdir -p "$R/data/on_boot.d" "$R/etc/systemd/system" "$S" "$B" "$H/systemd" "$H/on_boot.d"
    cp "$HERE/../systemd/$UNIT" "$H/systemd/"
    cp "$HERE/../on_boot.d/$ENTRY" "$H/on_boot.d/"
    cp "$HERE/../proxy.pl" "$H/proxy.pl"
    cp "$SCRIPT" "$H/hdhomerun-discovery"
    chmod 755 "$H/hdhomerun-discovery"
    cat >"$B/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_STATE/systemctl.log"
[ ! -e "$STUB_STATE/fail-$1" ] || exit 1
case "$1" in is-active)
    [ ! -e "$STUB_STATE/inactive" ] || { echo inactive; exit 3; }
    echo active ;;
esac
exit 0
STUB
    cat >"$B/ip" <<'STUB'
#!/bin/sh
case "$*" in
"-4 route show table all") cat "$STUB_STATE/routes" 2>/dev/null ;;
"-4 -o addr show dev "*) cat "$STUB_STATE/ip-$6" 2>/dev/null || exit 1 ;;
"-4 -o addr show") for f in "$STUB_STATE"/ip-*; do cat "$f"; done ;;
*) exit 1 ;;
esac
STUB
    cat >"$B/ss" <<'STUB'
#!/bin/sh
[ ! -e "$STUB_STATE/ss-fails" ] || exit 1
cat "$STUB_STATE/ss" 2>/dev/null || true
STUB
    # perl: -c passes unless perl-c-fails exists. --probe prints the tuners
    # in "probe" and exits 0, or exits 3 when that file is missing. Other
    # calls record their arguments.
    cat >"$B/perl" <<'STUB'
#!/bin/sh
case "$1" in
-c) [ ! -e "$STUB_STATE/perl-c-fails" ] ;;
*) shift
   printf '%s\n' "$@" >"$STUB_STATE/perl-args"
   case "$1" in --probe) [ -f "$STUB_STATE/probe" ] || exit 3; cat "$STUB_STATE/probe" ;; esac ;;
esac
STUB
    chmod 755 "$B/systemctl" "$B/ip" "$B/ss" "$B/perl"
    iface br0 0x1003 192.168.1.1/24
    iface br30 0x1003 192.168.30.1/24
    # eth8 faces the internet: a default route in a policy table, as on a
    # multi-WAN gateway. 203.0.113.0/24 is a documentation network.
    iface eth8 0x1003 203.0.113.5/24
    printf '%s\n' 'default via 203.0.113.1 dev eth8 table 201 proto static' \
        '192.168.1.0/24 dev br0 proto kernel scope link src 192.168.1.1' >"$S/routes"
    : >"$S/inactive"
    export HDHR_ROOT="$R" STUB_STATE="$S"
    PATH="$B:$ORIG_PATH"
    export PATH
}

# hd ARGS...: run the script under test from the fixture's own home.
hd() { "$H/hdhomerun-discovery" "$@"; }

# ---------- precheck: config ----------

setup good
conf "$GOOD"
check "precheck passes on the good config" hd precheck

setup two-each
conf 'CLIENTS="br0 br40"
TUNERS="br30 br50"'
iface br40 0x1003 192.168.40.1/24
iface br50 0x1003 192.168.50.1/24
check "precheck passes with two client and two tuner networks" hd precheck

setup no-config
refuse "no config" hd precheck
check "precheck without a config names setup" sh -c '"$1" precheck 2>&1 | grep -q "Run: hdhomerun-discovery setup"' sh "$H/hdhomerun-discovery"

setup missing-clients
conf 'TUNERS="br30"'
refuse "missing CLIENTS" hd precheck

setup missing-tuners
conf 'CLIENTS="br0"'
refuse "missing TUNERS" hd precheck

setup empty-clients
conf 'CLIENTS=""
TUNERS="br30"'
refuse "empty CLIENTS" hd precheck

setup unknown-key
conf "$GOOD
PORT=65001"
refuse "unknown key" hd precheck

# The second value is valid on its own, so only the duplicate check refuses it.
setup dup-key
conf "$GOOD
TUNERS=\"br40\""
iface br40 0x1003 192.168.40.1/24
refuse "a key set twice" hd precheck

setup not-kv
conf "$GOOD
br0"
refuse "a line that is not KEY=VALUE" hd precheck

setup both
conf 'CLIENTS="br0 br30"
TUNERS="br30"'
refuse "one interface as client and tuner" hd precheck

setup dup-iface
conf 'CLIENTS="br0 br0"
TUNERS="br30"'
refuse "the same client interface twice" hd precheck

# An interface with that name exists, so only the name check can refuse it.
setup bad-name
conf 'CLIENTS="br0:x"
TUNERS="br30"'
iface 'br0:x' 0x1003 192.168.2.1/24
refuse "bad interface name" hd precheck

setup long-name
conf 'CLIENTS="abcdefghijklmnop"
TUNERS="br30"'
iface abcdefghijklmnop 0x1003 192.168.2.1/24
refuse "interface name over 15 characters" hd precheck

setup code-in-conf
conf "CLIENTS=\"br0 \$(touch $T/pwned)\"
TUNERS=\"br30\""
hd precheck >/dev/null 2>&1
check "the config is data and never runs as shell" test ! -e "$T/pwned"

# ---------- precheck: gateway state ----------

setup no-iface
conf 'CLIENTS="br0"
TUNERS="br9"'
refuse "named interface does not exist" hd precheck

setup down-iface
conf "$GOOD"
iface br30 0x1002 192.168.30.1/24
refuse "interface is down" hd precheck

setup loopback
conf 'CLIENTS="lo"
TUNERS="br30"'
iface lo 0x9 127.0.0.1/8
refuse "loopback interface" hd precheck

setup no-ipv4
conf "$GOOD"
: >"$S/ip-br0"
refuse "interface without an IPv4 address" hd precheck

setup no-proxy
conf "$GOOD"
rm -f "$H/proxy.pl"
refuse "proxy.pl missing" hd precheck

setup proxy-broken
conf "$GOOD"
: >"$S/perl-c-fails"
refuse "proxy.pl does not compile" hd precheck

setup port-held
conf "$GOOD"
echo 'UNCONN 0 0 0.0.0.0:65001 0.0.0.0:*' >"$S/ss"
refuse "another program holds UDP 65001" hd precheck
check "the port message names the old relay" sh -c '"$1" precheck 2>&1 | grep -q "udp-broadcast-relay"' sh "$H/hdhomerun-discovery"
rm -f "$S/inactive"
check "UDP 65001 held while our own unit is active is fine" hd precheck

setup wan
conf 'CLIENTS="br0 eth8"
TUNERS="br30"'
refuse "an interface with a default route (the WAN)" hd precheck

setup ss-fails
conf "$GOOD"
: >"$S/ss-fails"
refuse "precheck fails when ss cannot check the port" hd precheck

setup symlink-home
conf "$GOOD"
mv "$H" "$T/real-home"
ln -s "$T/real-home" "$H"
refuse "precheck with a symlinked addon home" "$T/real-home/hdhomerun-discovery" precheck
refuse "disable with a symlinked addon home" "$T/real-home/hdhomerun-discovery" disable

setup symlink-active
conf "$GOOD"
echo keep >"$T/victim"
ln -s "$T/victim" "$H/active"
refuse "enable with an active symlink" hd enable
check "enable did not write through the symlink" has "$T/victim" '^keep$'
refuse "disable with an active symlink" hd disable
check "disable did not delete the symlink target" test -f "$T/victim"

# precheck, status, and probe change nothing
setup readonly
conf "$GOOD"
before=$(cd "$R" && find . -type f -exec sha256sum {} + | sort | sha256sum)
hd precheck >/dev/null 2>&1
hd status >/dev/null 2>&1
hd probe >/dev/null 2>&1
after=$(cd "$R" && find . -type f -exec sha256sum {} + | sort | sha256sum)
check "precheck, status, and probe change no file" test "$before" = "$after"
refuse "precheck, status, and probe never change a unit" grep -Eq '^(start|stop|restart|enable|disable|daemon-reload)' "$S/systemctl.log"

# ---------- run and probe ----------

setup run
conf 'CLIENTS="br0 br40"
TUNERS="br30"'
iface br40 0x1003 192.168.40.1/24
hd run >/dev/null 2>&1
printf '%s\n' --client br0 --client br40 --tuner br30 >"$T/want"
check "run passes each client and tuner network to the proxy" cmp "$S/perl-args" "$T/want"

setup run-recheck
conf 'CLIENTS="br0"
TUNERS="br9"'
refuse "run checks the config again" hd run
check "run starts no proxy on a bad config" test ! -e "$S/perl-args"

setup probe
conf "$GOOD"
echo 'tuner 192.168.30.100 on br30, device ID 1234ABCD' >"$S/probe"
check "probe passes when a tuner answers" hd probe
printf '%s\n' --probe --tuner br30 >"$T/want"
check "probe asks the proxy about the tuner networks only" cmp "$S/perl-args" "$T/want"
rm -f "$S/probe"
refuse "probe fails when no tuner answers" hd probe

# ---------- enable, disable, boot ----------

setup enable
conf "$GOOD"
hd enable >/dev/null 2>&1
check "enable marks the proxy active" test -f "$H/active"
check "enable starts the unit" has "$S/systemctl.log" "^restart $UNIT\$"

setup enable-bad
conf 'CLIENTS="br0"
TUNERS="br9"'
refuse "enable fails on a bad config" hd enable
check "a failed enable leaves no active mark" test ! -e "$H/active"
refuse "a failed enable starts nothing" has "$S/systemctl.log" '^restart'

setup disable
conf "$GOOD"
hd enable >/dev/null 2>&1
hd disable >/dev/null 2>&1
check "disable removes the active mark" test ! -e "$H/active"
check "disable keeps the config" test -f "$H/hdhomerun-discovery.conf"
check "disable stops the unit" has "$S/systemctl.log" "^stop $UNIT\$"

setup disable-stopfail
conf "$GOOD"
hd enable >/dev/null 2>&1
: >"$S/fail-stop"
refuse "disable fails when the stop fails" hd disable
check "a failed stop keeps the active mark" test -f "$H/active"
refuse "uninstall fails when the stop fails" hd uninstall
check "a failed stop keeps the addon directory" test -d "$H"

snapshot() { (cd "$R" && find . -type f ! -name '*.log' -exec sha256sum {} + | sort; find . | sort); }
setup boot
conf "$GOOD"
hd enable >/dev/null 2>&1
hd boot >/dev/null 2>&1
check "boot installs the unit" test -f "$R/etc/systemd/system/$UNIT"
check "boot starts the proxy when enabled" has "$S/systemctl.log" "^start --no-block $UNIT\$"
snapshot >"$T/snap1"
hd boot >/dev/null 2>&1
snapshot >"$T/snap2"
check "boot twice gives the same files" cmp "$T/snap1" "$T/snap2"
rm -f "$R/etc/systemd/system/$UNIT"
hd boot >/dev/null 2>&1
check "boot restores a unit that a firmware update removed" test -f "$R/etc/systemd/system/$UNIT"
rm -f "$R/usr/local/sbin/hdhomerun-discovery"
hd boot >/dev/null 2>&1
check "boot restores the command link" test -L "$R/usr/local/sbin/hdhomerun-discovery"

setup boot-inactive
conf "$GOOD"
hd boot >/dev/null 2>&1
refuse "boot starts nothing when not enabled" has "$S/systemctl.log" '^start'

# ---------- lock and arguments ----------

# locked ARGS...: run the script while another process holds the lock, with
# no wait. Sets rc to its exit status.
locked() {
    mkdir -p "$R/run"
    flock "$R/run/hdhomerun-discovery.lock" sleep 5 &
    holder=$!
    sleep 1
    HDHR_LOCK_WAIT=0 hd "$@" >/dev/null 2>&1
    rc=$?
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
}

setup lock-boot
conf "$GOOD"
locked boot
check "boot fails and writes nothing while another command holds the lock" \
    test "$rc" -ne 0 -a ! -e "$R/etc/systemd/system/$UNIT"

setup lock-install
locked install
check "install fails and writes nothing while another command holds the lock" \
    test "$rc" -ne 0 -a ! -e "$R/etc/systemd/system/$UNIT"

setup lock-enable
conf "$GOOD"
locked enable
check "enable fails and marks nothing while another command holds the lock" \
    test "$rc" -ne 0 -a ! -e "$H/active"

setup lock-disable
conf "$GOOD"
: >"$H/active"
locked disable
check "disable fails and keeps the mark while another command holds the lock" \
    test "$rc" -ne 0 -a -e "$H/active"

setup lock-uninstall
conf "$GOOD"
locked uninstall
check "uninstall fails and removes nothing while another command holds the lock" \
    test "$rc" -ne 0 -a -d "$H"

setup lock-free
conf "$GOOD"
check "boot runs when no other command holds the lock" hd boot

setup args
conf "$GOOD"
for c in status boot enable disable precheck probe run install uninstall setup; do
    refuse "$c rejects an extra argument" hd "$c" extra
done
refuse "an unknown command fails" hd frobnicate

U="$HERE/../systemd/$UNIT"
check "the unit waits for /data" grep -qx 'RequiresMountsFor=/data' "$U"
check "the unit runs precheck before the proxy" grep -qx 'ExecStartPre=/data/unifi-common-addons/hdhomerun-discovery/hdhomerun-discovery precheck' "$U"
check "the unit starts the proxy with run" grep -qx 'ExecStart=/data/unifi-common-addons/hdhomerun-discovery/hdhomerun-discovery run' "$U"
check "the unit runs the proxy as a throwaway user" grep -qx 'DynamicUser=yes' "$U"
check "the unit allows CAP_NET_RAW and no other capability" grep -qx 'CapabilityBoundingSet=CAP_NET_RAW' "$U"
refuse "the unit never names a User" grep -q '^User=' "$U"
check "the unit gives the proxy CAP_NET_RAW (SO_BINDTODEVICE on Linux before 5.7)" grep -qx 'AmbientCapabilities=CAP_NET_RAW' "$U"

# ---------- install and uninstall ----------

# src: a full copy of the addon in $SRC, as downloaded.
src() {
    SRC="$T/src"
    mkdir -p "$SRC/systemd" "$SRC/on_boot.d"
    cp "$SCRIPT" "$SRC/hdhomerun-discovery"
    cp "$HERE/../proxy.pl" "$SRC/"
    cp "$HERE/../systemd/$UNIT" "$SRC/systemd/"
    cp "$HERE/../on_boot.d/$ENTRY" "$SRC/on_boot.d/"
    chmod 755 "$SRC/hdhomerun-discovery"
}

setup install
src
rm -rf "${H:?}"
"$SRC/hdhomerun-discovery" install >/dev/null 2>&1
check "install copies the script" test -x "$H/hdhomerun-discovery"
check "install copies the proxy" cmp "$SRC/proxy.pl" "$H/proxy.pl"
check "install writes the boot entry" test -x "$R/data/on_boot.d/$ENTRY"
check "install writes the unit" test -f "$R/etc/systemd/system/$UNIT"
check "install links the command into /usr/local/sbin" test "$(readlink "$R/usr/local/sbin/hdhomerun-discovery")" = "$H/hdhomerun-discovery"
check "the command works through the link" "$R/usr/local/sbin/hdhomerun-discovery" install
refuse "install starts nothing" grep -Eq '^(start|restart)' "$S/systemctl.log"
conf "# mine
$GOOD"
"$SRC/hdhomerun-discovery" install >/dev/null 2>&1
check "install keeps an existing config" has "$H/hdhomerun-discovery.conf" '^# mine$'

for part in proxy.pl systemd/$UNIT on_boot.d/$ENTRY; do
    setup "install-no-${part%%/*}"
    src
    rm -f "$SRC/$part"
    rm -rf "${H:?}"
    out=$("$SRC/hdhomerun-discovery" install 2>&1)
    refuse "install fails when the copy has no $part" "$SRC/hdhomerun-discovery" install
    check "install without $part says that nothing changed" sh -c 'printf "%s" "$1" | grep -q "missing .*Nothing changed"' sh "$out"
    check "install without $part writes no addon home" test ! -e "$H"
    check "install without $part writes no boot entry" test ! -e "$R/data/on_boot.d/$ENTRY"
done

# With root's umask 077, the files must still be readable by the
# temporary user that runs the proxy.
setup umask
src
rm -rf "${H:?}"
(umask 077; printf '%s\n' 2 1 n | "$SRC/hdhomerun-discovery" setup) >/dev/null 2>&1
check "with umask 077 the addon home is 755" test "$(stat -c %a "$H")" = 755
check "with umask 077 the proxy is 644" test "$(stat -c %a "$H/proxy.pl")" = 644
check "with umask 077 the command is 755" test "$(stat -c %a "$H/hdhomerun-discovery")" = 755
check "with umask 077 the config from setup is 644" test "$(stat -c %a "$H/hdhomerun-discovery.conf")" = 644
check "with umask 077 every directory in the home is 755" sh -c 'test -z "$(find "$1" -type d ! -perm 755)"' sh "$H"

setup closed-parent
src
rm -rf "${H:?}"
mkdir -p "$R/data/unifi-common-addons"
chmod 700 "$R/data/unifi-common-addons"
out=$("$SRC/hdhomerun-discovery" install 2>&1)
check "install warns when a parent directory is closed to other users" sh -c 'printf "%s" "$1" | grep -q "WARNING: .*unifi-common-addons is closed"' sh "$out"
check "install does not change a shared parent directory" test "$(stat -c %a "$R/data/unifi-common-addons")" = 700
chmod 755 "$R/data/unifi-common-addons"

# A symlinked home could point into another addon.
for c in install boot; do
    setup "symlink-home-$c"
    src
    rm -rf "${H:?}"
    mkdir -p "$T/other"
    ln -s "$T/other" "$H"
    [ "$c" = install ] || : >"$T/other/hdhomerun-discovery.new.4242"
    if [ "$c" = install ]; then refuse "install refuses a symlinked addon home" "$SRC/hdhomerun-discovery" install
    else refuse "boot refuses a symlinked addon home" "$SRC/hdhomerun-discovery" boot; fi
    if [ "$c" = install ]; then check "install writes nothing through a symlinked addon home" test -z "$(ls -A "$T/other")"
    else check "boot deletes nothing through a symlinked addon home" test -e "$T/other/hdhomerun-discovery.new.4242"; fi
done

setup unit-is-dir
conf "$GOOD"
mkdir -p "$R/etc/systemd/system/$UNIT"
refuse "boot fails when a directory stands in place of the unit" hd boot
check "boot puts nothing into that directory" test -z "$(ls -A "$R/etc/systemd/system/$UNIT")"

# Same content as the unit: put() would chmod through the link.
setup unit-is-link
conf "$GOOD"
cp "$H/systemd/$UNIT" "$T/victim"
chmod 600 "$T/victim"
ln -s "$T/victim" "$R/etc/systemd/system/$UNIT"
refuse "boot fails when a symlink stands in place of the unit" hd boot
check "boot does not change a file through that symlink" test "$(stat -c %a "$T/victim")" = 600

# A power loss during put() leaves a temporary copy. boot and install
# remove this addon's copies, and only those.
for c in boot install; do
    setup "stale-tmp-$c"
    conf "$GOOD"
    : >"$R/data/on_boot.d/$ENTRY.new.4242"
    : >"$R/etc/systemd/system/$UNIT.new.4242"
    : >"$H/hdhomerun-discovery.new.4242"
    : >"$H/proxy.pl.new.4242"
    : >"$R/data/on_boot.d/01-att-wpa-supplicant.sh.new.4242"
    : >"$R/etc/systemd/system/att-wpa-supplicant@.service.new.4242"
    : >"$H/hdhomerun-discovery.new.1-backup"
    : >"$H/notes.new.4242"
    hd "$c" >/dev/null 2>&1
    check "$c removes a stale temporary boot entry" test ! -e "$R/data/on_boot.d/$ENTRY.new.4242"
    check "$c removes a stale temporary unit" test ! -e "$R/etc/systemd/system/$UNIT.new.4242"
    check "$c removes a stale temporary script" test ! -e "$H/hdhomerun-discovery.new.4242"
    check "$c removes a stale temporary proxy" test ! -e "$H/proxy.pl.new.4242"
    check "$c keeps another addon's temporary boot entry" test -e "$R/data/on_boot.d/01-att-wpa-supplicant.sh.new.4242"
    check "$c keeps another addon's temporary unit" test -e "$R/etc/systemd/system/att-wpa-supplicant@.service.new.4242"
    check "$c keeps a file whose suffix is not a process ID" test -e "$H/hdhomerun-discovery.new.1-backup"
    check "$c keeps a file that it never writes" test -e "$H/notes.new.4242"
done

setup uninstall
conf "$GOOD"
hd install >/dev/null 2>&1
hd enable >/dev/null 2>&1
hd uninstall >/dev/null 2>&1
check "uninstall removes the addon directory" test ! -e "$H"
check "uninstall removes the unit" test ! -e "$R/etc/systemd/system/$UNIT"
check "uninstall removes the boot entry" test ! -e "$R/data/on_boot.d/$ENTRY"
check "uninstall stops the proxy" has "$S/systemctl.log" "^stop $UNIT\$"
check "uninstall removes the command link" test ! -e "$R/usr/local/sbin/hdhomerun-discovery" -a ! -L "$R/usr/local/sbin/hdhomerun-discovery"

setup foreign-link
mkdir -p "$R/usr/local/sbin"
echo mine >"$R/usr/local/sbin/hdhomerun-discovery"
hd install >/dev/null 2>&1
hd uninstall >/dev/null 2>&1
check "install and uninstall leave a file that is not their link" has "$R/usr/local/sbin/hdhomerun-discovery" '^mine$'

# Make the copy of the unit fail. A stub cp fails for that file only, so
# this works as root too (root ignores a read-only mode).
setup write-fail
conf "$GOOD"
cat >"$B/cp" <<STUB
#!/bin/sh
case "\$*" in *$UNIT.new.*) : >"\$2"; exit 1 ;; esac
PATH='$ORIG_PATH' exec cp "\$@"
STUB
chmod 755 "$B/cp"
refuse "boot fails when the unit cannot be written" hd boot
check "boot leaves no temporary unit after a failed copy" sh -c '! ls "$1"/*.service.new.* >/dev/null 2>&1' sh "$R/etc/systemd/system"

setup write-fail-dir
conf "$GOOD"
rm -rf "$R/etc/systemd/system"
: >"$R/etc/systemd/system"
refuse "boot fails when the unit directory cannot be made" hd boot

# ---------- setup ----------

# guided ANSWERS: run setup from a downloaded copy, with ANSWERS as input.
guided() {
    src
    rm -rf "${H:?}"
    printf '%s\n' "$@" | "$SRC/hdhomerun-discovery" setup >"$T/out" 2>&1
    rc=$?
}
# The networks setup lists, in order: br0 (1), br30 (2), br40 (3).
three() { iface br40 0x1003 192.168.40.1/24; }

setup guided
three
echo 'tuner 192.168.30.100 on br30, device ID 1234ABCD' >"$S/probe"
guided 2 "1 3" y
check "setup succeeds" test "$rc" -eq 0
check "setup installs the addon" test -x "$H/hdhomerun-discovery"
check "setup writes the chosen client networks" has "$H/hdhomerun-discovery.conf" '^CLIENTS="br0 br40"$'
check "setup writes the chosen tuner network" has "$H/hdhomerun-discovery.conf" '^TUNERS="br30"$'
check "setup lists the networks by number" has "$T/out" ' 2) br30 *192.168.30.1/24'
refuse "setup never lists an interface with a default route" has "$T/out" 'eth8'
refuse "setup never prints the WAN address" has "$T/out" '203.0.113'
check "setup shows the tuners that answer" has "$T/out" 'tuner 192.168.30.100 on br30'
check "setup enables the proxy" test -f "$H/active"
check "setup starts the unit" has "$S/systemctl.log" "^restart $UNIT\$"
check "the config from setup passes precheck" hd precheck
refuse "setup leaves no network list behind" sh -c 'ls -a "$1" | grep -q networks' sh "$H"

setup guided-no-start
three
echo 'tuner 192.168.30.100 on br30, device ID 1234ABCD' >"$S/probe"
guided 2 1 n
check "setup without a start writes the config" has "$H/hdhomerun-discovery.conf" '^CLIENTS="br0"$'
check "setup without a start enables nothing" test ! -e "$H/active"
refuse "setup without a start starts nothing" has "$S/systemctl.log" '^restart'

setup guided-retry
three
guided "1 9" x 2 "2" "1" y
check "setup asks again after a number not in the list or a word" has "$H/hdhomerun-discovery.conf" '^TUNERS="br30"$'
check "setup refuses the tuner network as an app network" has "$T/out" 'br30 is the tuner network'
check "setup then takes the app networks" has "$H/hdhomerun-discovery.conf" '^CLIENTS="br0"$'

setup guided-firewall
three
guided 2 1 "" skip y
check "setup explains the firewall rule when no tuner answers" has "$T/out" 'Source port: *65001'
check "the firewall help names the Gateway zone" has "$T/out" 'Destination zone: *Gateway'
check "setup still enables after skip" test -f "$H/active"

setup guided-keep
three
mkdir -p "$H"
conf "# mine
$GOOD"
src
printf '%s\n' 2 1 "" | "$SRC/hdhomerun-discovery" setup >"$T/out" 2>&1
check "setup keeps an existing config by default" has "$H/hdhomerun-discovery.conf" '^# mine$'
refuse "setup stopped at the existing config starts nothing" has "$S/systemctl.log" '^restart'

setup guided-eof
three
guided 2
refuse "setup stops at the end of input" test "$rc" -eq 0
check "setup at the end of input writes no config" test ! -e "$H/hdhomerun-discovery.conf"

# ---------- isolation from other addons ----------

setup isolation
ATT="$R/data/unifi-common-addons/att-wpa-supplicant"
mkdir -p "$ATT/instances/eth8"
echo sentinel >"$ATT/att-wpa-supplicant"
echo sentinel >"$ATT/instances/eth8/active"
echo sentinel >"$R/data/on_boot.d/01-att-wpa-supplicant.sh"
echo sentinel >"$R/etc/systemd/system/att-wpa-supplicant@.service"
other_state() {
    (cd "$R" && find . -path '*att-wpa-supplicant*' -exec sh -c 'for f; do if [ -f "$f" ]; then sha256sum "$f"; else echo "$f"; fi; done' sh {} + | sort)
}
a1=$(other_state)
conf "$GOOD"
hd install >/dev/null 2>&1
hd enable >/dev/null 2>&1
hd boot >/dev/null 2>&1
hd status >/dev/null 2>&1
hd disable >/dev/null 2>&1
hd uninstall >/dev/null 2>&1
a2=$(other_state)
check "no file of another addon changed or disappeared" test "$a1" = "$a2"
refuse "no systemctl call names another addon" has "$S/systemctl.log" 'att-wpa'
refuse "the script reaches no path outside its own directories" grep -q '/\.\.' "$SCRIPT"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
