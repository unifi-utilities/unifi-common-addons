# ra-deprecate

Tells LAN clients to stop using the old delegated IPv6 prefix after the ISP has handed out a new one.

## Problem

Some ISPs delegate a new prefix on every PPPoE reconnect (seen: a new `/56` at 1&1 or Telefónica o2 in Germany). On a gateway with a single WAN, UniFi OS stops dnsmasq and removes the old prefix from the bridges before dnsmasq could advertise it as deprecated, so no Router Advertisement with preferred lifetime 0 for the old prefix is ever sent.

Clients keep their SLAAC addresses from the dead prefix as _preferred_ for up to 24 hours (the valid lifetime dnsmasq handed out) and may pick them as source address. Connections then stall until Wi-Fi is toggled or the address expires. Seen with iPhones, Macs, and a Home Assistant OS VM (NetworkManager).

[RFC 9096 section 3.5](https://www.rfc-editor.org/rfc/rfc9096#section-3.5) asks routers to deprecate a stale prefix in exactly this way, and [RFC 4862 section 5.5.3](https://www.rfc-editor.org/rfc/rfc4862#section-5.5.3) limits how fast hosts may shorten a valid lifetime: a valid lifetime below two hours is ignored, so the addon announces two hours.

This is a known problem for routers in general ([RFC 8978](https://www.rfc-editor.org/rfc/rfc8978)); the addon adds the missing behaviour to UniFi OS.

## Where it matters

The prefix changes when the PPPoE session is torn down and rebuilt, or when the gateway restarts and the ISP delegates a different one. The problem shows up where that happens regularly:

- **Forced disconnect by the ISP.** In Germany this is common on PPPoE lines. o2 states in its [community forum](https://hilfe.o2online.de/dsl-kabel-glasfaser-router-software-internet-telefonie-34/zwangstrennung-538361/index2.html) that DSL and fibre connections are disconnected every 24 hours (the time of day can be set, the interval cannot) and that each reconnect brings a new IPv6 prefix. Other German ISPs are reported to do the same or to use much longer intervals; check with yours.
- **A reconnect you schedule yourself,** for example a nightly cron job that restarts `pppd`.
- **Every DSL resync or line drop** that makes the modem or the gateway redial.
- **A gateway reboot** after which the ISP delegates a different prefix. A router that does not remember the old prefix across a reboot cannot deprecate it. This is not specific to UniFi, and it affects the same kind of ISPs: those that do not keep the delegated prefix stable.

Outside Germany we do not know which ISPs rotate prefixes this way. Where your ISP keeps the prefix across reconnects, the addon has nothing to do.

### Single WAN or failover WAN

Observed in the logs of two gateways (a UCG Ultra and a UCG Max, UniFi OS 5.1.x), both on PPPoE with a nightly reconnect:

- **Single WAN:** at the reconnect the DHCP/RA dnsmasq instance is stopped a moment before the old prefix is removed from the bridges, and started again afterwards. No Router Advertisement for the old prefix is sent.
- **PPPoE plus an LTE failover WAN:** dnsmasq keeps running through the reconnect and logs `router advertisement on <old /64>, old prefix for br…` for every bridge, so it deprecates the old prefix itself. Clients there held only the current address afterwards.

The reason is our reading of the logs, not of UniFi's code: when the PPPoE link drops, UniFi fails over to the second WAN and leaves dnsmasq running. With no second WAN there is nowhere to fail over to, and dnsmasq is restarted.

So the addon is mostly needed on single-WAN gateways. It should still help on a failover gateway when the reconnect happens while the second WAN is down, and after a gateway reboot, which restarts dnsmasq too: on the failover gateway, a new prefix after a reboot came without any deprecation. Neither case has been tested with the addon running.

## What it does

A small daemon (Python standard library only) polls `/proc/net/if_inet6` every 5 seconds for global `/64` prefixes on the `br*` bridges. When one disappears, it sends Router Advertisements to `ff02::1` on that bridge with the old prefix, preferred lifetime 0, and the remaining part of a two-hour valid lifetime. It sends at 0, 10, 30, 60, 120, 300 and 600 seconds, then every 10 minutes until the two hours are over. It stops early if the prefix comes back.

The header values (M/O flags, router preference, router lifetime) are read per interface from `/run/dnsmasq.dhcp.conf.d/`, so the packets match dnsmasq's own. State is kept in `state.json`, so after a reboot of the gateway the addon still knows the previous prefix and deprecates it if the gateway comes back with a different one.

The state file is written only when a prefix appears, is lost, or a deprecation RA goes out, plus one refresh of the last-seen times every six hours while a prefix is tracked. Each write is synced to disk, file and directory, so a power cut does not leave a broken file. A hard power-off is therefore handled like a reboot.

A gateway can boot with a wrong clock and step it once NTP has synced. After a start the daemon therefore does nothing until the kernel reports the clock as synchronised (the flag behind `System clock synchronized` in `timedatectl`), for 10 minutes at most. Only then does it compare the saved timestamps with the clock; ages are measured with the wall clock at that moment plus monotonic time, so a later clock step neither ends a deprecation early nor stretches it. If the clock is still not synchronised after 10 minutes (no WAN, no NTP), the daemon goes on with it and logs that. The saved timestamps can then be off. Damaged entries in `state.json` are ignored.

For the first five minutes after a start, a saved prefix is not treated as gone while its bridge has no global `/64` at all, because the WAN may not have delegated one yet. This keeps a prefix that returns unchanged from being announced as deprecated. A bridge that already carries a different `/64` is handled at once.

The same hold-down applies at runtime, for 30 seconds: a `/64` that goes missing from a bridge with no other global `/64` is only treated as gone after that, so a configuration run that removes and re-adds an address does not trigger a deprecation. Interfaces that appear or disappear at runtime (a VLAN added or deleted in UniFi Network) are picked up on the next poll, and entries of a bridge that has disappeared are dropped: 24 hours after the prefix was last seen, or, once a deprecation has started, when its 2 hours are over.

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

After the next prefix change the journal shows `prefix … disappeared, deprecating` and the `sent RA` lines for each bridge.

## Test without side effects

`--dry-run` logs the packets instead of sending them. In daemon mode it also leaves `state.json` alone, so it is safe next to the running service; it reads the saved state but never writes it.

```sh
python3 /data/unifi-common-addons/ra-deprecate/scripts/ra-deprecate --test 2001:db8:4242:1::/64 --iface br0 --dry-run
timeout 12 python3 /data/unifi-common-addons/ra-deprecate/scripts/ra-deprecate --dry-run
```

`--test` also takes `--valid`, `--preferred` and `--dest <link-local>` (unicast to one host) for a live test. See the note below before sending real test packets.

## Uninstall

```sh
systemctl disable --now ra-deprecate
rm /data/on_boot.d/30-ra-deprecate.sh /etc/systemd/system/ra-deprecate.service
systemctl daemon-reload
rm -r /data/unifi-common-addons/ra-deprecate
```

## Tested on

- UCG Ultra and UCG Max, UniFi OS 5.1.33 and 5.1.35, PPPoE at 1&1 behind a bridged modem, Python 3.9.
- One real prefix change (nightly reconnect) on one gateway: the full schedule went out on every bridge, and a Home Assistant OS VM held only the new address afterwards.

## Known limits

- Only `br*` interfaces are watched, and only global `/64` prefixes outside `fc00::/7`.
- Behaviour during a WAN failover that moves the LAN to a different prefix, and back again, has not been tested.
- The start-up grace period, the hold-down, the write behaviour, clock steps, the wait for a synchronised clock, vanishing bridges and damaged state files have been tested in a simulation with a fake clock, not yet across a real gateway reboot or power cut. The read of the kernel's clock flag (`adjtimex`) has not been run on a gateway yet; the start-up log line `clock synchronised, running` shows it worked.
- Interfaces without a dnsmasq RA configuration are skipped (`no dnsmasq RA config` in the journal).
- During a manual live test with test RAs, a Home Assistant OS VM got stuck in duplicate address detection and lost IPv6 until it was rebooted. The cause was not established: either the test RAs, or `tcpdump` switching the VM's virtio NIC to promiscuous mode at the same time. It did not happen with the RAs the daemon sends after a real prefix change.
