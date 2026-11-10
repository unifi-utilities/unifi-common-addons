"""Simulation tests for ra-deprecate: its run() loop with a fake clock and fake
bridges, and the parts that build the Router Advertisement.

Nothing here sends a packet or touches the real state file. Run it from
anywhere:

  sh ra-deprecate/tests/test-addon.sh

or give another copy of the script as the argument:

  python3 simulate.py /path/to/ra-deprecate
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import types

PATH = (sys.argv[1] if len(sys.argv) > 1 else
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts",
                     "ra-deprecate"))
P = "2001:db8:1::/64"
Q = "2001:db8:2::/64"
H = 3600


class Stop(Exception):
  pass


def load():
  loader = importlib.machinery.SourceFileLoader("ra_deprecate", PATH)
  spec = importlib.util.spec_from_loader("ra_deprecate", loader)
  mod = importlib.util.module_from_spec(spec)
  loader.exec_module(mod)
  return mod


def report(ok, name):
  print("%-4s %s" % ("OK" if ok else "FAIL", name))
  return bool(ok)


ATTEMPTS = []                    # every call of send_ra in the last simulation: (t, result)


def simulate(name, state_at, bridge_at, end, expect, step=None, synced=None, dry=False,
             send=None):
  """state_at(t0) -> initial state; bridge_at(t) -> set of global prefixes;
  send(t) -> what send_ra returns at t (or raises OSError), default True."""
  m = load()
  d = tempfile.mkdtemp()
  m.STATE_FILE = os.path.join(d, "state.json")
  clock = [1_790_000_000]          # 2026, a plausible wall clock
  offset = [0]
  t0 = clock[0]
  with open(m.STATE_FILE, "w") as f:
    json.dump(state_at(t0), f)
  logs, sends, saves = [], [], []
  real_save = m.save_state

  stepped = []

  def fake_sleep(s):
    clock[0] += s
    if step and not stepped and clock[0] - t0 >= step[0]:
      offset[0] += step[1]
      stepped.append(1)
    if clock[0] - t0 >= end:
      raise Stop

  def counting_save(state):
    saves.append(round(clock[0] - t0))
    real_save(state)

  m.time = types.SimpleNamespace(time=lambda: clock[0] + offset[0],
                                 monotonic=lambda: clock[0], sleep=fake_sleep)
  def fake_read():
    g = bridge_at(clock[0] - t0)
    return {} if g is None else {"br0": {"index": 1, "ll": "fe80::1",
                                         "global": set(g)}}

  m.read_addrs = fake_read
  del ATTEMPTS[:]

  def fake_send(iface, info, prefix, valid, dry=False, *a, **k):
    t = round(clock[0] - t0)
    r = send(t) if send else True
    ATTEMPTS.append((t, r))
    if r:
      sends.append((t, prefix))
    return r

  m.send_ra = fake_send
  m.log = lambda msg: logs.append((round(clock[0] - t0), msg))
  m.save_state = counting_save
  m.clock_synced = (lambda: synced(clock[0] - t0)) if synced else (lambda: True)
  try:
    m.run(dry)
  except Stop:
    pass
  ok = report(expect(logs, sends, saves), name)
  if not ok:
    for l in logs:
      print("      log:", l)
    print("      sends:", sends, "saves:", saves)
  return ok


def st(age, lost=None):
  return lambda t0: {"br0": {P: {"seen": t0 - age, "lost": lost, "sent": 0}}}


results = [
    # --- start-up grace
    simulate("A same prefix returns within grace",
             st(1000), lambda t: [] if t < 120 else [P], 600,
             lambda logs, sends, saves: not sends
             and not any("disappeared" in x[1] for x in logs)
             and any("waiting" in x[1] for x in logs)),
    simulate("B no prefix after grace -> deprecated",
             st(1000), lambda t: [], 600,
             lambda logs, sends, saves: sends and sends[0][0] >= 300
             and sends[0][1] == P),
    simulate("C different prefix at boot -> immediate",
             st(1000), lambda t: [Q], 120,
             lambda logs, sends, saves: sends and sends[0][0] <= 5
             and sends[0][1] == P),
    simulate("D vanish at runtime, nothing replaces it -> after 30 s debounce",
             st(1000), lambda t: [P] if t < 400 else [], 500,
             lambda logs, sends, saves: sends and 430 <= sends[0][0] <= 440
             and sends[0][1] == P),
    # --- writes
    simulate("E steady state, fresh file: no write in 5 h",
             st(100), lambda t: [P], 5 * H,
             lambda logs, sends, saves: saves == []),
    simulate("F steady state: one refresh after 6 h, not more in 7 h",
             st(100), lambda t: [P], 7 * H,
             lambda logs, sends, saves: len(saves) == 1
             and 21500 <= saves[0] <= 21700),
    simulate("G nothing tracked: never written",
             lambda t0: {"br0": {}}, lambda t: [], 8 * H,
             lambda logs, sends, saves: saves == []),
    simulate("H stale file (10 h) at start: refreshed once at start",
             st(10 * H), lambda t: [P], 2 * H,
             lambda logs, sends, saves: len(saves) == 1 and saves[0] <= 10),
    simulate("I new prefix appears: written once, soon",
             lambda t0: {"br0": {}}, lambda t: [P], 2 * H,
             lambda logs, sends, saves: len(saves) == 1 and saves[0] <= 40),
]


results += [
    # the prefix vanishes at 400 s, after the 300 s start-up grace
    simulate("K wall clock steps +3 h during a deprecation: not cut short",
             st(1000), lambda t: [P] if t < 400 else [], 7800,
             lambda logs, sends, saves: not any(
                 "done deprecating" in x[1] and x[0] < 7600 for x in logs)
             and any("done deprecating" in x[1] and 7600 <= x[0] <= 7700 for x in logs)
             and any(460 <= s_[0] <= 480 for s_ in sends),
             step=(460, 3 * H)),
    simulate("K2 wall clock steps back 3 h during a deprecation: not stretched",
             st(1000), lambda t: [P] if t < 400 else [], 7800,
             lambda logs, sends, saves: any(
                 "done deprecating" in x[1] and 7600 <= x[0] <= 7700 for x in logs),
             step=(460, -3 * H)),
]

results += [
    simulate("N 10 s flap of the only prefix: nothing sent",
             st(1000), lambda t: [] if 400 <= t < 410 else [P], 900,
             lambda logs, sends, saves: not sends
             and not any("disappeared" in x[1] for x in logs)),
    simulate("O prefix replaced at runtime: deprecated at once",
             st(1000), lambda t: [P] if t < 400 else [Q], 500,
             lambda logs, sends, saves: sends and 400 <= sends[0][0] <= 410
             and sends[0][1] == P),
    simulate("P 80 s gap: deprecated after 30 s, stops when it is back",
             st(1000), lambda t: [] if 400 <= t < 480 else [P], 700,
             lambda logs, sends, saves: sends and 430 <= sends[0][0] <= 440
             and any("is back" in x[1] for x in logs)),
    simulate("Q bridge absent for 31 h: entry dropped once, no refresh writes",
             st(100), lambda t: None, 31 * H,
             lambda logs, sends, saves: not sends and len(saves) == 1
             and any("bridge gone" in x[1] and x[0] > 29 * H for x in logs)),
    simulate("Q2 bridge absent for 25 h: entry kept (seen can lag by 6 h)",
             st(100), lambda t: None, 25 * H,
             lambda logs, sends, saves: not sends
             and not any("dropping" in x[1] for x in logs)),
    simulate("R bridge absent for 1 h, then back: entry kept",
             st(100), lambda t: None if t < H else [P], 2 * H,
             lambda logs, sends, saves: not sends
             and not any("dropping" in x[1] for x in logs)),
]

results.append(simulate(
    "S bridge gone while a prefix was missing, back without it: hold-off restarts",
    st(1000),
    lambda t: [P] if t < 400 else [] if t < 410 else None if t < 7200 else [],
    7400,
    lambda logs, sends, saves: sends and 7230 <= sends[0][0] <= 7240))

results += [
    simulate("T1 clock unsynced for 120 s: nothing decided, grace counts from sync",
             st(1000), lambda t: [], 700,
             lambda logs, sends, saves: sends and 420 <= sends[0][0] <= 430
             and any("clock synchronised, running" in x[1] and 115 <= x[0] <= 125 for x in logs),
             synced=lambda t: t >= 120),
    simulate("T2 clock never synced: goes on after 600 s, grace from there",
             st(1000), lambda t: [], 1000,
             lambda logs, sends, saves: sends and 900 <= sends[0][0] <= 910
             and any("not synchronised after 600s" in x[1] for x in logs),
             synced=lambda t: False),
    simulate("T3 --dry-run never writes the state file",
             lambda t0: {"br0": {}}, lambda t: [P], 2 * H,
             lambda logs, sends, saves: saves == [],
             dry=True),
]

def malformed(t0):
  return {"br0": {P: {"seen": t0 - 100, "lost": None, "sent": 0},
                  "not-a-prefix": {"seen": 1, "lost": None, "sent": 0},
                  Q: {"seen": t0 - 100, "sent": 0}},           # no "lost"
          "br1": ["not", "a", "dict"],
          "br2": {Q: {"seen": "x", "lost": None, "sent": 0}}}

results.append(simulate(
    "L malformed state entries are dropped, valid one kept, no crash",
    malformed, lambda t: [P], 120,
    lambda logs, sends, saves: sum("ignoring malformed" in x[1] for x in logs) == 3
    and not sends))

for label, content in (("list at top level", [1, 2]), ("string", "x"), ("null", None)):
  results.append(simulate(
      "L2 state file is %s: no crash" % label, lambda t0, c=content: c,
      lambda t: [P], 60, lambda logs, sends, saves: not sends))

# --- a failed send is not a sent RA (dnsmasq may be rewriting its configs)
def gone_at_400(t):
  return [P] if t < 400 else []


# The prefix is lost at 430 s (30 s debounce), the RA slots follow at 0, 10, 30,
# 60 s ... after that. The send for the slot at 30 s (t = 460) fails; the next
# slot is 30 s later, so the RA must go out on a later poll, not wait for it.
def fails_460_to_470(raising):
  def f(t):
    if 460 <= t < 470:
      if raising:
        raise OSError("network is unreachable")
      return False
    return True
  return f


results.append(simulate(
    "V1 send fails at the 30 s slot: retried on the next polls, RA goes out at 470",
    st(1000), gone_at_400, 520,
    lambda logs, sends, saves: any(470 <= t < 480 for t, _ in sends)
    and [t for t, r in ATTEMPTS if r is False] == [460, 465],
    send=fails_460_to_470(False)))
results.append(simulate(
    "V2 same with OSError: retried, logged, no crash",
    st(1000), gone_at_400, 520,
    lambda logs, sends, saves: any(470 <= t < 480 for t, _ in sends)
    and any("send failed" in x[1] for x in logs),
    send=fails_460_to_470(True)))
results.append(simulate(
    "V3 send never works: each slot gives up after 30 s, no retry on every poll",
    st(1000), gone_at_400, 7700,
    lambda logs, sends, saves: not sends
    and any("done deprecating" in x[1] for x in logs)
    and len(ATTEMPTS) <= 7 * 20,        # about 20 slots, at most 7 tries each
    send=lambda t: False))

# --- the A flag in the prefix information option follows dnsmasq's range
def pio_flags(range_tail):
  mod = load()
  d = tempfile.mkdtemp()
  with open(os.path.join(d, "a.conf"), "w") as f:
    f.write("dhcp-range=set:x,::2,::7d1,constructor:br0,%s\n" % range_tail)
  mod.DNSMASQ_GLOB = os.path.join(d, "*.conf")
  params = mod.ra_params("br0")
  pkt = mod.build_ra(params, bytes(6), P, 7200, 0)
  return params, pio_flag_byte(pkt)


def pio_flag_byte(pkt):
  """The L|A byte of the prefix information option (type 3) of an RA."""
  o = 16                                   # after the 16-byte RA header
  while o < len(pkt):
    if pkt[o] == 3:
      return pkt[o + 3]
    o += pkt[o + 1] * 8                    # option length is in units of 8 bytes
  raise ValueError("no prefix information option")


for label, tail, want_a, want_hdr in (("ra-only", "ra-only,64,86400", True, 0x00),
                                      ("ra-stateless", "ra-stateless,64,86400", True, 0x40),
                                      ("slaac", "slaac,64,86400", True, 0xC0),
                                      ("plain DHCPv6 range", "64,86400", False, 0xC0)):
  params, pio = pio_flags(tail)
  ok = pio == (0xC0 if want_a else 0x80) and (params["flags"] & 0xC0) == want_hdr
  results.append(report(ok, "W A flag for %s: %s" % (label, "set" if want_a else "clear")))

# --- router lifetime as dnsmasq computes it (radv.c calc_interval, calc_lifetime)
mod = load()
for nums, want in (([], 1800),              # no ra-param: interval 600, lifetime 3 x 600
                   ([600, 1800], 1800),      # what UniFi writes
                   ([300], 900),             # interval only: 3 x interval
                   ([0], 1800),              # interval 0 means the default 600
                   ([10000], 5400),          # interval limited to 1800, 3 x 1800
                   ([2], 12),                # interval raised to 4
                   ([600, 300], 600),        # lifetime below the interval: the interval
                   ([600, 0], 0),            # 0 stays 0
                   ([600, 20000], 9000)):    # capped
  got = mod.router_lifetime(nums)
  results.append(report(got == want, "X router lifetime %s -> %d (want %d)" % (nums, got, want)))

# ra_params reads the numbers from the ra-param line
d = tempfile.mkdtemp()
with open(os.path.join(d, "a.conf"), "w") as f:
  f.write("dhcp-range=set:x,::,constructor:br0,ra-only,64,86400\nra-param=br0,high,300\n")
mod.DNSMASQ_GLOB = os.path.join(d, "*.conf")
results.append(report(mod.ra_params("br0")["lifetime"] == 900,
                      "X2 ra-param with an interval and no lifetime gives 3 x interval"))

# --- the journal line names the A flag (dry run, so no socket is opened)
for label, tail, want in (("ra-only", "ra-only,64,86400", "A set"),
                          ("slaac", "slaac,64,86400", "A set"),
                          ("plain DHCPv6 range", "64,86400", "A clear")):
  mod = load()
  d = tempfile.mkdtemp()
  with open(os.path.join(d, "a.conf"), "w") as f:
    f.write("dhcp-range=set:x,::2,::7d1,constructor:br0,%s\n" % tail)
  mod.DNSMASQ_GLOB = os.path.join(d, "*.conf")
  mod.mac_of = lambda iface: bytes(6)
  out = []
  mod.log = out.append
  mod.send_ra("br0", {"ll": "fe80::1", "index": 1}, P, 7200, dry_run=True)
  results.append(report(len(out) == 1 and want in out[0],
                        "Y log line for %s says '%s'" % (label, want)))

# ra_params: a vanished file is silent, an unreadable one is logged
m = load()
msgs = []
m.log = msgs.append
m.glob = types.SimpleNamespace(glob=lambda pat: ["/nonexistent-dir/x.conf"])
r1 = m.ra_params("br0")
ok1 = r1 is None and msgs == []
d2 = tempfile.mkdtemp()
cfg = os.path.join(d2, "a.conf")
open(cfg, "w").write("dhcp-range=x,constructor:br0,ra-only,64,86400\n")
os.chmod(cfg, 0)
m.glob = types.SimpleNamespace(glob=lambda pat: [cfg])
r2 = m.ra_params("br0")
os.chmod(cfg, 0o600)
unreadable_logged = any("cannot read" in x for x in msgs)
ok2 = (os.geteuid() == 0) or unreadable_logged       # root can read mode 0
results.append(report(ok1, "M vanished config file is silent"))
results.append(report(ok2, "M2 unreadable config file is logged"))

import ctypes
ctypes_size = ctypes.sizeof(load().Timex)

ok = ctypes_size == 208
results.append(report(ok, "U struct timex is 208 bytes (glibc, 64-bit)"))

# --- save_state fsyncs the file and the directory
m = load()
d = tempfile.mkdtemp()
m.STATE_FILE = os.path.join(d, "state.json")
calls = []
real_fsync = os.fsync
os.fsync = lambda fd: (calls.append(fd), real_fsync(fd))[1]
try:
  m.save_state({"br0": {P: {"seen": 1.0, "lost": None, "sent": 0}}})
finally:
  os.fsync = real_fsync
ok = (len(calls) == 2 and json.load(open(m.STATE_FILE))["br0"][P]["seen"] == 1.0
      and not os.path.exists(m.STATE_FILE + ".tmp"))
results.append(report(ok, "J save_state fsyncs file and directory"))

sys.exit(0 if all(results) else 1)
