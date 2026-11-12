# pppoe-reconnect

Reconnects PPPoE once a day, at a time inside a window you choose. The exact minute and second differ from gateway to gateway.

Without any configuration it reconnects `ppp0` between 03:00 and 04:00 **local time**, that is the time zone set on the gateway (`timedatectl`), not UTC, which suits a gateway with one PPPoE WAN. A config file is only needed to change the window or the interface.

## Why

Some ISPs disconnect a PPPoE line every 24 hours, and the time of day follows from when the line was last connected. In Germany, as far as we know, only Telefónica o2 and 1&1 still do this on DSL. o2 states in its [community forum](https://hilfe.o2online.de/dsl-kabel-glasfaser-router-software-internet-telefonie-34/zwangstrennung-538361/index2.html) that the interval cannot be changed but the time of day can. A reconnect you start yourself at a quiet hour puts that disconnect where it does the least harm, instead of in the middle of the day.

## What it does

`on_boot.d` runs a small script at every boot. It picks a time inside the window (`03:00-04:00` by default, **local time** of the gateway) and writes `/etc/cron.d/pppoe-reconnect` with one job per interface (one by default).

`SIGHUP` makes pppd terminate the link and dial again; UniFi OS starts it with `persist`, so it comes back after the hold-off. By default the job signals only the `pppd` of `ppp0`, found through the pid file pppd writes (`/var/run/ppp0.pid`):

```text
<minute> <hour> * * * root sleep <second>; pid=$(cat /var/run/ppp0.pid 2>/dev/null); if [ -n "$pid" ] && [ "$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")" = pppd ]; then logger -p user.warning -t pppoe-reconnect "scheduled daily reconnect of ppp0: SIGHUP to pppd $pid"; kill -HUP "$pid"; else logger -p user.warning -t pppoe-reconnect "scheduled daily reconnect of ppp0 skipped: no pppd behind /var/run/ppp0.pid"; fi >/dev/null 2>&1
```

The job writes one line to the journal under the tag `pppoe-reconnect`, also when there is nothing to signal. It logs at level warning because UniFi OS limits the journal entries of `cron.service` to warning (`LogLevelMax=warning`), and a notice from a cron job can be dropped. The signal goes out only if the pid file names a running `pppd`, so a stale pid file never hits another process. `/etc` is rebuilt by firmware updates, so the file is written again on every boot.

### Which time

The time is not random and not the same for everyone. It is calculated from the serial number of the gateway (`serialno` in `/proc/ubnthal/system.info`; `/etc/machine-id`, the address of `eth0` and the host name are the fallbacks): a CRC-32 of the text, taken modulo the length of the window. So:

- the same gateway gets the same time after every boot and every firmware update, which keeps the daily rhythm of the reconnect stable;
- different gateways get different times with a high probability. In a one-hour window there are 3600 seconds; two gateways land in the same minute with a chance of about 1 in 60 and in the same second with 1 in 3600.

If two of your gateways land too close to each other, for example because their tunnels connect to each other, set `RECONNECT_SEED` to any text. It is mixed into the calculation and moves the time to a new fixed one.

## Installation

1. [on_boot.d](https://github.com/unifi-utilities/unifi-common)
2. Copy `21-pppoe-reconnect.sh` to `/data/on_boot.d/`
3. Optional: to change the window or to set a seed, copy `pppoe-reconnect.conf.example` to `/data/unifi-common-addons/pppoe-reconnect/pppoe-reconnect.conf` and edit it. Without that file the defaults apply.
4. You _should_ end up with:

```text
/data
├── ...
├── on_boot.d/
    ├── ...
    ├── 21-pppoe-reconnect.sh
    └── ...
├── unifi-common-addons/
    └── pppoe-reconnect/
        └── pppoe-reconnect.conf   (optional)
└── ...
```

5. Run `/data/on_boot.d/21-pppoe-reconnect.sh` (or reboot). It prints the time it chose.

6. Check that everything is correct:

- `cat /etc/cron.d/pppoe-reconnect` shows the time and the window
- after the next reconnect, `journalctl -t pppoe-reconnect --since yesterday` shows that the job ran, and `journalctl --since yesterday | grep -E "Hangup \(SIGHUP\)|Connect time"` shows the termination of `ppp0` and how long it was connected

## Configuration

`/data/unifi-common-addons/pppoe-reconnect/pppoe-reconnect.conf`, a shell file. The script runs as root and sources it, so everything in it is executed as root: only put the settings below in it, and keep it writable for root only.

- `RECONNECT_WINDOW="HH:MM-HH:MM"`: the window, 24 hours, in **local time** of the gateway. A window that ends before it starts runs over midnight (`23:30-00:30`). Default `03:00-04:00`.
- `RECONNECT_SEED=""`: optional text that changes the calculated time.
- `RECONNECT_INTERFACES="ppp0"`: the PPPoE interfaces to reconnect, separated by spaces, not tabs (`"ppp0 ppp1"`). `ls /var/run/ppp*.pid` lists them; look there first. `all` reconnects every `pppd` on the gateway at one time with a single `/usr/bin/killall -HUP pppd`. It has to be chosen on purpose, it stands alone (not with interface names), the script stops at boot if `/usr/bin/killall` is missing, and it signals every `pppd`, whatever the process serves. Names may hold letters, digits and `_` only. If an interface does not exist, its job does nothing and says so in the journal, so on a gateway whose PPPoE WAN is not `ppp0`, set it.
- `RECONNECT_WINDOW_<interface>="HH:MM-HH:MM"` and `RECONNECT_SEED_<interface>`: a window or a seed for one interface, for example `RECONNECT_WINDOW_ppp1="05:00-06:00"`. They replace `RECONNECT_WINDOW` and `RECONNECT_SEED` for that interface only. Without them every interface uses the general window and gets its own time inside it, because the interface name is part of the calculation.

**All times are local time of the gateway.** Cron runs in the system time zone (`timedatectl`), not in UTC, so `03:00-04:00` means 03:00 to 04:00 on the gateway's clock, and nothing has to be converted. On the gateways tested it is Europe/Berlin, and the job ran at the local time the script had printed. Where the clocks change between 02:00 and 03:00 (Europe, North America), a window inside that hour can be skipped or run twice on the day of the change; the default `03:00-04:00` is not affected.

The script stops with a message and writes nothing if a window or an interface name is not valid; the message names the variable.

## Uninstall

```sh
rm /data/on_boot.d/21-pppoe-reconnect.sh /etc/cron.d/pppoe-reconnect
systemctl reload cron
rm -r /data/unifi-common-addons/pppoe-reconnect
```

## What to expect from a reconnect

- Every connection over the WAN drops. VPN tunnels and anything else that runs through the gateway reconnect on their own, which can take a moment.
- The public IPv4 address can change, and so can a delegated IPv6 prefix. After a new prefix, clients can keep addresses from the old one for up to 24 hours on a single-WAN gateway, until a Router Advertisement deprecates it. The [ra-deprecate](../ra-deprecate/README.md) add-on sends that Router Advertisement, so with IPv6 you will want both.
- If you move the time later, the provider can still cut once at the old time before the job runs at the new one. Reconnect by hand once after the change (`kill -HUP "$(cat /var/run/ppp0.pid)"`) to avoid that.
- With a failover WAN, the gateway switches to it while the PPPoE link is down. On one gateway with an LTE failover, switching back to DSL cut every connection that had been built over LTE, and an IPsec tunnel stayed on LTE until it was restarted in the UniFi UI.

## Tested on

- UCG Max, UniFi OS 5.1.x, PPPoE at Telefónica o2 in Germany: after a reboot the script wrote the cron job, and cron started it the next night at the time the script had printed, in the gateway's time zone. The journal shows the line of the job (tag `pppoe-reconnect`), pppd's `Hangup (SIGHUP)`, and the new session six seconds later.
- UCG Ultra, UniFi OS 5.1.x, PPPoE at 1&1: the cron-started run reconnected `ppp0` at the printed time, in the gateway's time zone.

## Known limits

- One reconnect time per interface, every day. The seconds come from a `sleep` in the cron job.
- Several interfaces are reconnected by separate jobs, each at its own time. Only `all` signals every `pppd` at once.
- The interface is found through the pid file. It was checked on a UCG Max with one PPPoE WAN (`pppd call ppp0`, `/var/run/ppp0.pid` holds the pid of that `pppd`); a gateway with two PPPoE WANs has not been looked at, so `ppp1.pid` for a second WAN is an assumption from how pppd names its pid file.
- Only UniFi OS with `systemd` and `cron` (5.1.x tested). Older versions are not covered.
