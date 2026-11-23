#!/bin/sh
# Functional test of proxy.pl in private network namespaces. Needs no sudo
# where unprivileged user namespaces are allowed (Debian), and sudo where they
# are blocked (Ubuntu 24.04). It runs itself again under `unshare -rn` (the
# "gateway"), and puts each app and the fake tuner in a namespace of its own.
# Needs perl and python3.
#
# Usage: tests/proxy-netns.sh [path-to-proxy.pl]
set -eu

if [ "${NETNS_INNER:-}" != 1 ]; then
    here=$(cd "$(dirname "$0")" && pwd)
    proxy=${1:-$here/../proxy.pl}
    [ -f "$proxy" ] || { echo "no proxy at $proxy" >&2; exit 2; }
    # Copy the proxy to a new directory first. Root in the user namespace
    # cannot open a path under a directory that an unmapped user owns with
    # mode 750 (for example /home/runner on GitHub's runners, under sudo).
    stage=$(mktemp -d)
    cp "$proxy" "$stage/proxy.pl"
    # A mount namespace too, for a /sys that shows this network namespace.
    NETNS_INNER=1 exec unshare -rnm sh -c 'mount -t sysfs sysfs /sys && exec "$0" "$1"' "$0" "$stage/proxy.pl"
fi

proxy=$1
command -v python3 >/dev/null || { echo "python3 needed" >&2; exit 2; }
tmp=$(mktemp -d)
pids=
proxy_pid=
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
    for p in $proxy_pid $pids; do kill "$p" 2>/dev/null || true; done
    rm -rf "$tmp" "$(dirname "$proxy")"
}
trap cleanup EXIT

fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

# Each namespace is held open by a sleeper; its PID names it.
ns() {
    unshare -n sleep 600 >/dev/null 2>&1 &
    pids="$pids $!"
    last_ns=$!
}
in_ns() { p=$1; shift; nsenter -t "$p" -n --preserve-credentials "$@"; }

ip link set lo up
ns; appA=$last_ns; ns; appB=$last_ns; ns; tuner=$last_ns
sleep 0.3
# br1: the client network (two apps). br3: the tuner network.
for n in 1 3; do
    ip link add br$n type bridge
    ip addr add 10.99.$n.1/24 dev br$n
    ip link set br$n up
done
i=0
for p in $appA $appB $tuner; do
    i=$((i + 1))
    case $p in "$tuner") br=br3; addr=10.99.3.100; gw=10.99.3.1 ;; "$appA") br=br1; addr=10.99.1.50; gw=10.99.1.1 ;; *) br=br1; addr=10.99.1.51; gw=10.99.1.1 ;; esac
    ip link add h$i type veth peer name g$i
    ip link set g$i master $br
    ip link set g$i up
    ip link set h$i netns "$p"
    in_ns "$p" sh -c "ip link set lo up; ip link set h$i up; ip addr add $addr/24 dev h$i; ip route add default via $gw"
done

# The fake tuner: answers each discovery request with a discovery answer
# (device ID 1234ABCD) and logs each request. TUNER_SPORT sets the port it
# answers from (65001 like a real tuner).
cat >"$tmp/hdhr.py" <<'PY'
import socket, struct, sys, zlib
def frame(t, payload):
    p = struct.pack("!HH", t, len(payload)) + payload
    return p + struct.pack("<I", zlib.crc32(p) & 0xffffffff)
def request(dev=b"\xff" * 4):
    return frame(2, bytes([1, 4]) + b"\xff" * 4 + bytes([2, 4]) + dev)
def answer(dev=bytes.fromhex("1234ABCD")):
    return frame(3, bytes([1, 4]) + struct.pack("!I", 1) + bytes([2, 4]) + dev)
def asked_id(d):
    # The device ID that a request asks for (tag 0x02), or None.
    i, end = 4, 4 + struct.unpack("!H", d[2:4])[0]
    while i + 2 <= end:
        t, l = d[i], d[i + 1]; i += 2
        if t == 2 and l == 4: return d[i:i + 4]
        i += l
def answer_id(d):
    return asked_id(d).hex().upper()
def ok(d, t):
    if len(d) < 8: return False
    tt, ln = struct.unpack("!HH", d[:4])
    return tt == t and len(d) == ln + 8 and struct.unpack("<I", d[-4:])[0] == zlib.crc32(d[:-4]) & 0xffffffff
PY
cat >"$tmp/tuner.py" <<'PY'
import socket, sys
sys.path.insert(0, sys.argv[1]); from hdhr import *
log, sport = sys.argv[2], int(sys.argv[3])
junk = len(sys.argv) > 4   # answer with a packet that is not an answer
r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
r.bind(("0.0.0.0", 65001))
w = r
if sport != 65001:
    w = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); w.bind(("0.0.0.0", sport))
while True:
    d, src = r.recvfrom(2048)
    open(log, "a").write("%s %d %s\n" % (src[0], src[1], "req" if ok(d, 2) else "other"))
    if ok(d, 2):
        a = asked_id(d)
        # A wildcard request gets the tuner's own ID; a specific one is
        # echoed, so that each app can tell its own answer.
        if junk:
            w.sendto(frame(4, b"\x03\x01\x00"), src)
        elif a and a != b"\xff" * 4:
            w.sendto(answer(a), src)
        else:
            w.sendto(answer(), src)
PY
# app.py LOG KIND COUNT [SOURCE]: send COUNT packets of KIND as broadcasts
# from one socket (bound to SOURCE, an address of the app, if given), then log every answer for 3 s: "from-ip from-port valid".
cat >"$tmp/app.py" <<'PY'
import socket, sys, time
sys.path.insert(0, sys.argv[1]); from hdhr import *
log, kind, count = sys.argv[2], sys.argv[3], int(sys.argv[4])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.bind((sys.argv[5] if len(sys.argv) > 5 else "0.0.0.0", 0)); s.settimeout(0.2)
pkt = {"req": request(), "reqA": request(bytes.fromhex("AAAAAAAA")), "reqB": request(bytes.fromhex("BBBBBBBB")),
       "badcrc": request()[:-1] + b"\x00", "answer": answer(),
       "control": frame(4, b"\x03\x01\x00")}[kind]
for _ in range(count):
    s.sendto(pkt, ("255.255.255.255", 65001))
rows, end = [], time.time() + 3
while time.time() < end:
    try: d, src = s.recvfrom(2048)
    except socket.timeout: continue
    rows.append("%s %d %s" % (src[0], src[1], ("valid " + answer_id(d)) if ok(d, 3) else "invalid"))
open(log, "w").write("".join(r + "\n" for r in rows))
PY

start_tuner() {
    : >"$tmp/tuner.log"
    # nsenter directly, not in_ns: $! must be the tuner process itself.
    nsenter -t "$tuner" -n --preserve-credentials python3 "$tmp/tuner.py" "$tmp" "$tmp/tuner.log" "${1:-65001}" ${2:+"$2"} &
    tuner_pid=$!
    pids="$pids $tuner_pid"
    sleep 0.5
}
stop_tuner() { kill "$tuner_pid" 2>/dev/null || true; wait "$tuner_pid" 2>/dev/null || true; }
start_proxy() {
    perl "$proxy" --client br1 --tuner br3 >"$tmp/proxy.log" 2>&1 &
    proxy_pid=$!
    sleep 1
    kill -0 "$proxy_pid" 2>/dev/null || { cat "$tmp/proxy.log"; echo "FAIL the proxy exited at start"; exit 1; }
}
app() { in_ns "$1" python3 "$tmp/app.py" "$tmp" "$2" "$3" "$4" ${5:+"$5"}; }
lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

start_tuner
start_proxy

# 1. One request: one valid answer, from the gateway's address on br1.
app "$appA" "$tmp/a1" req 1
if [ "$(grep -cx '10.99.1.1 65001 valid 1234ABCD' "$tmp/a1")" -eq 1 ] && [ "$(lines "$tmp/a1")" -eq 1 ]; then
    pass "1: the app gets one valid answer from 10.99.1.1:65001"
else bad "1: answers: $(tr '\n' ';' <"$tmp/a1")"; fi
if grep -qx '10.99.3.1 [0-9]* req' "$tmp/tuner.log"; then
    pass "1: the tuner gets the request from the gateway's address 10.99.3.1"
else bad "1: tuner log: $(tr '\n' ';' <"$tmp/tuner.log")"; fi

# 2. Two apps at once: each gets only the answers to its own request.
# Each app asks for its own device ID, which the fake tuner echoes, so a
# swapped answer shows.
app "$appA" "$tmp/a2" reqA 1 & x=$!
app "$appB" "$tmp/b2" reqB 1 & y=$!
wait $x $y
if [ "$(cat "$tmp/a2")" = "10.99.1.1 65001 valid AAAAAAAA" ] && [ "$(cat "$tmp/b2")" = "10.99.1.1 65001 valid BBBBBBBB" ]; then
    pass "2: two apps at once each get exactly their own answer"
else bad "2: app A got [$(tr '\n' ';' <"$tmp/a2")], app B got [$(tr '\n' ';' <"$tmp/b2")]"; fi

# 3. Packets that are not a whole discovery request reach no tuner.
for kind in badcrc answer control; do
    : >"$tmp/tuner.log"
    app "$appA" "$tmp/a3" "$kind" 1
    if [ "$(lines "$tmp/tuner.log")" -eq 0 ] && [ "$(lines "$tmp/a3")" -eq 0 ]; then
        pass "3: a $kind packet is dropped"
    else bad "3: $kind: tuner saw $(lines "$tmp/tuner.log"), app got $(lines "$tmp/a3")"; fi
done

# 4. Rate limit: 40 requests at once from one app reach the tuner at most
# SRC_BURST (10) times.
: >"$tmp/tuner.log"
app "$appA" "$tmp/a4" req 40
n=$(lines "$tmp/tuner.log")
if [ "$n" -ge 1 ] && [ "$n" -le 10 ]; then pass "4: 40 requests at once reach the tuner $n times (limit 10)"
else bad "4: 40 requests reached the tuner $n times"; fi
sleep 3   # let the bucket fill again

# 5. A request from the tuner network goes nowhere: br3 is not a client.
: >"$tmp/tuner.log"
app "$tuner" "$tmp/t5" req 1
app "$appA" "$tmp/a5" req 0
if [ "$(grep -c 'req' "$tmp/tuner.log")" -le 1 ] && [ "$(lines "$tmp/a5")" -eq 0 ]; then
    pass "5: a request from the tuner network is not relayed"
else bad "5: tuner log $(lines "$tmp/tuner.log"), app got $(lines "$tmp/a5")"; fi

# 6. An answer from another source port is not passed on.
stop_tuner
start_tuner 65002
app "$appA" "$tmp/a6" req 1
if [ "$(lines "$tmp/a6")" -eq 0 ] && grep -q req "$tmp/tuner.log"; then
    pass "6: an answer from a port other than 65001 is dropped"
else bad "6: app got $(lines "$tmp/a6"), tuner log $(lines "$tmp/tuner.log")"; fi
stop_tuner
start_tuner 65001 junk
app "$appA" "$tmp/a6b" req 1
if [ "$(lines "$tmp/a6b")" -eq 0 ] && grep -q req "$tmp/tuner.log"; then
    pass "6b: a packet from port 65001 that is not a discovery answer is dropped"
else bad "6b: app got $(lines "$tmp/a6b"), tuner log $(lines "$tmp/tuner.log")"; fi
stop_tuner
start_tuner

# 6c. The cap on waiting requests, and recovery once they expire.
kill "$proxy_pid" 2>/dev/null; wait "$proxy_pid" 2>/dev/null
HDHR_MAX_PENDING=4 perl "$proxy" --client br1 --tuner br3 >"$tmp/proxy.log" 2>&1 &
proxy_pid=$!
sleep 1
: >"$tmp/tuner.log"
app "$appB" "$tmp/b6c" req 10
n=$(lines "$tmp/tuner.log")
if [ "$n" -ge 1 ] && [ "$n" -le 4 ]; then pass "6c: with the cap at 4, 10 requests reach the tuner $n times"
else bad "6c: with the cap at 4, 10 requests reached the tuner $n times"; fi
app "$appA" "$tmp/a6c" req 1
if [ "$(lines "$tmp/a6c")" -eq 1 ]; then pass "6d: after the waiting requests expire, a new request gets its answer"
else bad "6d: after expiry, the app got $(lines "$tmp/a6c") answers"; fi
kill "$proxy_pid" 2>/dev/null; wait "$proxy_pid" 2>/dev/null
start_proxy

# 6e. The source of a request must lie in a network of the app interface.
# appA also has 10.99.9.50, outside every network of br1: that request is
# dropped. 10.99.8.0/24 is added to br1 while the proxy runs: the proxy
# reads the addresses again within CHECK_EVERY (10 s), then accepts it.
# The kernel's reverse-path filter would drop such a packet before the proxy
# sees it. Turn it off, so that the test checks the proxy.
echo 0 >/proc/sys/net/ipv4/conf/all/rp_filter
echo 0 >/proc/sys/net/ipv4/conf/br1/rp_filter
in_ns "$appA" ip addr add 10.99.9.50/24 dev h1
in_ns "$appB" ip addr add 10.99.8.50/24 dev h2
: >"$tmp/tuner.log"
app "$appA" "$tmp/a6e" req 1 10.99.9.50
if [ "$(lines "$tmp/tuner.log")" -eq 0 ] && [ "$(lines "$tmp/a6e")" -eq 0 ]; then
    pass "6e: a request from a source outside the app network is dropped"
else bad "6e: tuner saw $(lines "$tmp/tuner.log"), app got $(lines "$tmp/a6e")"; fi
app "$appA" "$tmp/a6f" req 1
if [ "$(lines "$tmp/a6f")" -eq 1 ]; then pass "6f: a request from the network itself still gets its answer"
else bad "6f: app got $(lines "$tmp/a6f") answers"; fi
: >"$tmp/tuner.log"
app "$appB" "$tmp/b6g" req 1 10.99.8.50
if [ "$(lines "$tmp/b6g")" -eq 0 ] && [ "$(lines "$tmp/tuner.log")" -eq 0 ]; then pass "6g: a source in a network that br1 does not have yet is dropped"
else bad "6g: app got $(lines "$tmp/b6g") answers"; fi
ip addr add 10.99.8.1/24 dev br1
sleep 12
app "$appB" "$tmp/b6h" req 1 10.99.8.50
if [ "$(lines "$tmp/b6h")" -eq 1 ]; then pass "6h: a second network on br1 is accepted after the proxy reads the addresses again"
else bad "6h: app got $(lines "$tmp/b6h") answers"; fi
ip addr del 10.99.8.1/24 dev br1
sleep 12
: >"$tmp/tuner.log"
app "$appB" "$tmp/b6i" req 1 10.99.8.50
if [ "$(lines "$tmp/b6i")" -eq 0 ] && [ "$(lines "$tmp/tuner.log")" -eq 0 ]; then pass "6i: a network removed from br1 is no longer accepted"
else bad "6i: app got $(lines "$tmp/b6i") answers"; fi

# 7. probe lists the tuner with its device ID.
rc=0; out=$(perl "$proxy" --probe --tuner br3 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "tuner 10.99.3.100 on br3, device ID 1234ABCD" ]; then pass "7: probe lists the tuner and exits 0"
else bad "7: probe exit $rc, printed: $out"; fi
stop_tuner
rc=0; out=$(perl "$proxy" --probe --tuner br3 2>&1) || rc=$?
if [ "$rc" -eq 3 ] && [ -z "$out" ]; then pass "8: probe with no tuner prints nothing and exits 3"
else bad "8: probe exit $rc, printed: $out"; fi

cat /sys/class/net/br1/ifindex >"$tmp/idx-before"
# 9. A bridge created again: the proxy exits (systemd starts it again).
ip link del br1
ip link add br1 type bridge
ip addr add 10.99.1.1/24 dev br1
ip link set br1 up
i=0
while kill -0 "$proxy_pid" 2>/dev/null && [ $i -lt 25 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$proxy_pid" 2>/dev/null; then bad "9: the proxy still runs after br1 was created again (ifindex $(cat "$tmp/idx-before") -> $(cat /sys/class/net/br1/ifindex))"
else
    rc=0; wait "$proxy_pid" || rc=$?
    proxy_pid=
    if [ "$rc" -eq 1 ] && grep -q 'br1 changed' "$tmp/proxy.log"; then pass "9: the proxy exits 1 after br1 is created again"
    else bad "9: exit $rc; log: $(tr '\n' ';' <"$tmp/proxy.log")"; fi
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit "$fail"
