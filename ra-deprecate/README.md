# ra-deprecate

Tells LAN clients to stop using the old delegated IPv6 prefix after the ISP has handed out a new one.

## Problem

Some ISPs delegate a new prefix on every PPPoE reconnect (seen: a new `/56` at 1&1 or Telefónica o2 in Germany). On a gateway with a single WAN, UniFi OS stops dnsmasq and removes the old prefix from the bridges before dnsmasq could advertise it as deprecated, so no Router Advertisement with preferred lifetime 0 for the old prefix is ever sent.

Clients keep their SLAAC addresses from the dead prefix as _preferred_ for up to 24 hours (the valid lifetime dnsmasq handed out) and may pick them as source address. Connections then stall until Wi-Fi is toggled or the address expires. Seen with iPhones, Macs, and a Home Assistant OS VM (NetworkManager).

[RFC 9096 section 3.5](https://www.rfc-editor.org/rfc/rfc9096#section-3.5) asks routers to deprecate a stale prefix in exactly this way, and [RFC 4862 section 5.5.3](https://www.rfc-editor.org/rfc/rfc4862#section-5.5.3) limits how fast hosts may shorten a valid lifetime: a valid lifetime below two hours is ignored, so the addon announces two hours.

This is a known problem for routers in general ([RFC 8978](https://www.rfc-editor.org/rfc/rfc8978)); the addon adds the missing behaviour to UniFi OS.

## Where it matters

The prefix changes when the PPPoE session is torn down and rebuilt, or when the gateway restarts and the ISP delegates a different one. The problem shows up where that happens regularly:

- **Forced disconnect by the ISP.** This is a legacy of the PPPoE-based access network. In Germany, as far as we know, only Telefónica o2 and 1&1 still do it on DSL. o2 states in its [community forum](https://hilfe.o2online.de/dsl-kabel-glasfaser-router-software-internet-telefonie-34/zwangstrennung-538361/index2.html) that DSL and fibre connections are disconnected every 24 hours (the time of day can be set, the interval cannot) and that each reconnect brings a new IPv6 prefix.
- **A reconnect you schedule yourself,** for example a nightly cron job that restarts `pppd`.
- **Every DSL resync or line drop** that makes the modem or the gateway redial.
- **A gateway reboot** after which the ISP delegates a different prefix. A router that does not remember the old prefix across a reboot cannot deprecate it. This is not specific to UniFi, and it affects the same kind of ISPs: those that do not keep the delegated prefix stable.

Confirmed so far: 1&1 (UCG Ultra, single WAN: the old prefix stayed preferred on clients after a reconnect) and Telefónica o2 (UCG Max with an LTE failover: a different prefix after a gateway reboot, and the addon deprecated the old ones). Deutsche Telekom (T-Online) no longer forces a disconnect, as far as we know, so the regular case does not arise there; whether a reboot brings a new prefix is unconfirmed, as are BT and ISPs outside Germany. Where your ISP keeps the prefix across reconnects, the addon has nothing to do.

### Single WAN or failover WAN

Observed in the logs of two gateways (a UCG Ultra and a UCG Max, UniFi OS 5.1.x), both on PPPoE with a nightly reconnect:

- **Single WAN:** at the reconnect the DHCP/RA dnsmasq instance is stopped a moment before the old prefix is removed from the bridges, and started again afterwards. No Router Advertisement for the old prefix is sent.
- **PPPoE plus an LTE failover WAN:** dnsmasq keeps running through the reconnect and logs `router advertisement on <old /64>, old prefix for br…` for every bridge, so it deprecates the old prefix itself. Clients there held only the current address afterwards.

The reason is our reading of the logs, not of UniFi's code: when the PPPoE link drops, UniFi fails over to the second WAN and leaves dnsmasq running. With no second WAN there is nowhere to fail over to, and dnsmasq is restarted.

So the addon is mostly needed on single-WAN gateways. It should still help on a failover gateway when the reconnect happens while the second WAN is down, and after a gateway reboot, which restarts dnsmasq too: on the failover gateway, a new prefix after a reboot came without any deprecation. Neither case has been tested with the addon running.

## What it does

A small daemon (Python standard library only) polls `/proc/net/if_inet6` every 5 seconds for global `/64` prefixes on the `br*` bridges. When one disappears, it sends Router Advertisements to `ff02::1` on that bridge with the old prefix, preferred lifetime 0, and the remaining part of a two-hour valid lifetime. It sends at 0, 10, 30, 60, 120, 300 and 600 seconds, then every 10 minutes until the two hours are over. It stops early if the prefix comes back. A send that fails, for example while dnsmasq is rewriting its configs, is retried on every poll for 30 seconds or until the next slot is due, then the slot is given up.

The header values (M/O flags, router preference, router lifetime) are read per interface from `/run/dnsmasq.dhcp.conf.d/`, so the packets match dnsmasq's own; the router lifetime follows dnsmasq's rule (three times the interval where `ra-param` gives none). The autonomous flag (A) in the prefix option follows the range too: it is set for `ra-only`, `ra-stateless` and `slaac` ranges, and clear for a DHCPv6-only range (in UniFi: a network set to DHCPv6 with "Allow SLAAC" cleared), because a deprecation RA with A set would make hosts create a new address in the old prefix ([RFC 4862 section 5.5.3](https://www.rfc-editor.org/rfc/rfc4862#section-5.5.3) d). On the two gateways above, every IPv6 range of every bridge carries `ra-only` or `slaac`. State is kept in `state.json`, so after a reboot of the gateway the addon still knows the previous prefix and deprecates it if the gateway comes back with a different one.

The state file is written only when a prefix appears, is lost, or a deprecation RA goes out, plus one refresh of the last-seen times every six hours while a prefix is tracked. Each write is synced to disk, file and directory, so a power cut does not leave a broken file. A hard power-off is therefore handled like a reboot. If the file cannot be written, that is logged once and retried every 5 minutes.

A gateway can boot with a wrong clock and step it once NTP has synced. After a start the daemon therefore does nothing until the kernel reports the clock as synchronised (the flag behind `System clock synchronized` in `timedatectl`), for 10 minutes at most. Only then does it compare the saved timestamps with the clock; ages are measured with the wall clock at that moment plus monotonic time, so a later clock step neither ends a deprecation early nor stretches it. If the clock is still not synchronised after 10 minutes (no WAN, no NTP), the daemon goes on with it and logs that. The saved timestamps can then be off. Damaged entries in `state.json` are ignored.

For the first five minutes after a start, a saved prefix is not treated as gone while its bridge has no global `/64` at all, because the WAN may not have delegated one yet. This keeps a prefix that returns unchanged from being announced as deprecated. A bridge that already carries a different `/64` is handled at once.

The same hold-down applies at runtime, for 30 seconds: a `/64` that goes missing from a bridge with no other global `/64` is only treated as gone after that, so a configuration run that removes and re-adds an address does not trigger a deprecation. Interfaces that appear or disappear at runtime (a VLAN added or deleted in UniFi Network) are picked up on the next poll, and entries of a bridge that has disappeared are dropped: 30 hours after the prefix was last seen (the 24 hours dnsmasq advertises a prefix for, plus the 6 hours the saved time can lag behind), or, once a deprecation has started, when its 2 hours are over.

Where dnsmasq already deprecates the old prefix itself (see above), the addon is redundant. Whether running both is harmless has not been tested.

## Installation

1. [on_boot.d](https://github.com/unifi-utilities/unifi-common)
2. Copy
   - `30-ra-deprecate.sh` to `/data/on_boot.d/`
   - the systemd unit file to `/data/unifi-common-addons/ra-deprecate/systemd/`
   - the `ra-deprecate` script to `/data/unifi-common-addons/ra-deprecate/scripts/`
3. You _should_ end up with:

```text
/data
├── ...
├── on_boot.d/
    ├── ...
    ├── 30-ra-deprecate.sh
    └── ...
├── unifi-common-addons/
    └── ra-deprecate/
        ├── scripts/
            └── ra-deprecate
        └── systemd/
            └── ra-deprecate.service
└── ...
```

4. Run `/data/on_boot.d/30-ra-deprecate.sh` (or reboot)

5. Check that everything is correct:

- `systemctl status ra-deprecate.service`
- `journalctl -u ra-deprecate -n 20 --no-pager` lists one `watching prefix` line per bridge with a global `/64`

After the next prefix change the journal shows `prefix … disappeared, deprecating` and the `sent RA` lines for each bridge, each with the RA header flags, the router lifetime and whether the A flag of the prefix is set.

## Test without side effects

`--dry-run` logs the packets instead of sending them. In daemon mode it also leaves `state.json` alone, so it is safe next to the running service; it reads the saved state but never writes it.

```sh
python3 /data/unifi-common-addons/ra-deprecate/scripts/ra-deprecate --test 2001:db8:4242:1::/64 --iface br0 --dry-run
timeout 12 python3 /data/unifi-common-addons/ra-deprecate/scripts/ra-deprecate --dry-run
```

`--test` also takes `--valid`, `--preferred` and `--dest <link-local>` (unicast to one host) for a live test. See the note below before sending real test packets.

## Tests

`tests/` holds simulation tests: the loop runs against a fake clock and fake bridges, and the header flags, the A flag of the prefix option, the router lifetime and the log line of the RA are checked. Nothing is sent and no state file is touched. They need Python 3 only:

```sh
sh ra-deprecate/tests/test-addon.sh
```

## Uninstall

```sh
systemctl disable --now ra-deprecate
rm /data/on_boot.d/30-ra-deprecate.sh /etc/systemd/system/ra-deprecate.service
systemctl daemon-reload
rm -r /data/unifi-common-addons/ra-deprecate
```

## Tested on

- UCG Ultra (PPPoE at 1&1, single WAN) and UCG Max (PPPoE at Telefónica o2, LTE failover), UniFi OS 5.1.33 and 5.1.35, Python 3.9.
- One real prefix change (nightly reconnect) on the UCG Ultra, with an earlier version of the script: the full schedule went out on every bridge, and a Home Assistant OS VM held only the new address afterwards.
- A reconnect of `ppp0` on the UCG Max: Telefónica o2 delegated a new prefix, and the daemon announced the old `/64` as deprecated (preferred 0 s, valid about 2 h) on all seven bridges.
- A dry run against a test network on the UCG Max, set to DHCPv6 with "Allow SLAAC" cleared: UniFi wrote a range with neither `slaac` nor `ra-*`, and the daemon built a prefix option with L set and A clear, inside an RA with M and O set.
- A reboot of the UCG Max: new prefix after boot, dnsmasq deprecated nothing, the daemon sent RAs for all seven old `/64`s, and a Mac on the LAN showed those addresses as deprecated. The wait for a synchronised clock ended 96 seconds after the kernel start, so UniFi's time daemon does clear the flag (`timedatectl`: `System clock synchronized: yes`). On the UCG Ultra, started on a running gateway, the line `clock synchronised, running` appears at once.

## Known limits

- Only `br*` interfaces are watched, and only global `/64` prefixes outside `fc00::/7`.
- Behaviour during a WAN failover that moves the LAN to a different prefix, and back again, has not been tested.
- The start-up grace period, the hold-down, the write behaviour, clock steps, the wait for a synchronised clock, vanishing bridges and damaged state files are covered by the simulation tests (`tests/`). A real gateway reboot has been tested (see above); a power cut has not, only its effect on the state file in the simulation.
- The 24 hours assume the lease time UniFi writes into the range (`86400`); it is not read from the range. A longer lease time would make the addon forget a prefix too early.
- Only the first `dhcp-range` per interface in a file is read, and where several files match, the last one wins. UniFi writes one range per bridge.
- Interfaces without a dnsmasq RA configuration are skipped (`no dnsmasq RA config` in the journal).
- During a manual live test with test RAs, a Home Assistant OS VM got stuck in duplicate address detection and lost IPv6 until it was rebooted. The cause was not established: either the test RAs, or `tcpdump` switching the VM's virtio NIC to promiscuous mode at the same time. It did not happen with the RAs the daemon sends after a real prefix change.
