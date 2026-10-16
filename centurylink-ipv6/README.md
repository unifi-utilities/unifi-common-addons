# centurylink-ipv6

CenturyLink (Lumen) gives PPPoE subscribers IPv6 through 6RD ([RFC 5969](https://www.rfc-editor.org/rfc/rfc5969)), not native DHCPv6-PD. The router embeds its WAN IPv4 address in CenturyLink's `2602::/24` prefix to get a `/56`. It reaches the internet through a SIT tunnel to a border relay, and advertises `/64`s from that `/56` to the LAN.

This addon runs a small systemd service that does that. Every 30 seconds, it does the following:

- creates or repairs the `6rd` tunnel, the default route and an unreachable route for the `/56`
- puts a `/64` from the `/56` on each LAN bridge you list, and removes UniFi's `fd00:` placeholder address
- adds its own firewall chains: drops unsolicited inbound IPv6, allows essential ICMPv6 and protocol 41, and clamps TCP MSS to the tunnel MTU
- writes a dnsmasq config so clients get Router Advertisements, with the tunnel MTU, and configure themselves with SLAAC

Each pass only fixes what is missing, so the service handles three things a boot-only script can't:

- a PPPoE reconnect that hands out a new IPv4, which means a new IPv6 prefix
- UniFi re-provisioning, which can wipe the firewall rules and the dnsmasq config
- firmware updates, which can remove the systemd unit; the `on_boot.d` hook reinstalls it on every boot

The defaults are CenturyLink's. Any other 6RD ISP works by changing `SIXRD_PREFIX`, `SIXRD_BR` and `SIXRD_V4MASKLEN` in the config.

## Requirements

1. The `on_boot.d` runner from [unifi-common](https://github.com/unifi-utilities/unifi-common).
2. A working CenturyLink PPPoE WAN (`ppp0`) with a public IPv4. 6RD can't work behind CGNAT or double NAT.
3. In the UniFi UI:
   - **WAN → IPv6:** Disabled. The addon handles the WAN side.
   - **Each LAN network the addon serves → IPv6 Interface Type:** Static, with a unique placeholder prefix and **Router Advertisement (RA)** enabled:
     - Default network (`br0`): `fd00:1::/64`
     - Each additional VLAN: `fd00:2::/64`, `fd00:3::/64`, and so on

     With the type set to None, UniFi creates conflicting ULA addresses of its own. With Static plus RA, UniFi keeps RA running on the bridge, and the addon swaps in the real prefix.

## Installation

```sh
workdir="$(mktemp -d)"
curl -fsSL \
  https://github.com/unifi-utilities/unifi-common-addons/archive/refs/heads/main.tar.gz \
  | tar -xz -C "$workdir"
cd "$workdir/unifi-common-addons-main/centurylink-ipv6"
./install
```

The installer does the following:

- copies the addon to `/data/centurylink-ipv6`, which survives firmware updates
- creates `/data/centurylink-ipv6/centurylink-ipv6.conf` from the example if it doesn't exist yet
- installs `/data/on_boot.d/20-centurylink-ipv6.sh`
- starts `centurylink-ipv6.service`

Running it again upgrades the addon and keeps your config.

Then set the LAN bridges in `/data/centurylink-ipv6/centurylink-ipv6.conf`:

```sh
LAN_IFACES="br0:1"              # default network only
LAN_IFACES="br0:1 br10:a br20:14"   # plus VLANs 10 and 20
```

- UniFi names the default network `br0` and each VLAN network `br<vlan-id>`. Check yours with `ip -br link show type bridge`.
- The part after the colon is the hex subnet id inside your `/56`, from `1` to `ff`. Subnet `0` belongs to the tunnel.
- The service rereads the config on its next pass, within 30 seconds.

To preview the prefix for an IPv4 address:

```sh
/data/centurylink-ipv6/centurylink-ipv6 calc 71.212.1.2
# 2602:0047:d401:0200::/56  (relay-prefix 0.0.0.0/0)
```

### Upgrading from the previous version

The previous version of this addon put `20-centurylink-6rd.sh`, `25-customipv6.sh` and `customipv6.conf` in `/data/on_boot.d`. `./install` moves those files, and `/run/dnsmasq.dhcp.conf.d/customipv6.conf`, to `/data/centurylink-ipv6/legacy/`. Reboot once afterwards to clear the addresses the old script set.

The old script gave `br0` subnet `00`. Here subnet `00` belongs to the tunnel, so `br0` moves to subnet `01` and LAN clients get a new prefix.

### Uninstall

```sh
/data/centurylink-ipv6/install --uninstall
```

This stops the service, which removes the tunnel, routes, addresses, firewall chains and dnsmasq config. It also removes the unit and the `on_boot.d` hook. `/data/centurylink-ipv6` is kept.

## Configuration

Every setting is in `centurylink-ipv6.conf`; the file comments each one.

| Setting | Default | Notes |
|---|---|---|
| `SIXRD_PREFIX` | `2602::/24` | ISP 6RD prefix |
| `SIXRD_BR` | `205.91.4.61` | Border relay. The older, widely documented CenturyLink relay is `205.171.2.64`; try it if IPv6 doesn't pass. |
| `SIXRD_V4MASKLEN` | `0` | IPv4 bits common to all subscribers |
| `WAN_IF` | auto | Interface routing to `SIXRD_BR` (`ppp0`) |
| `MTU` | auto | WAN MTU - 20, which is 1472 over PPPoE |
| `LAN_IFACES` | `br0:1` | `<bridge>:<hex subnet id> ...` |
| `DNS6` | empty | IPv6 resolvers to advertise. `::` means the gateway itself. Empty means clients keep using IPv4 DNS. |
| `RA_ENABLE` | `1` | Write the dnsmasq RA config |
| `DROP_ULA` | `1` | Remove the `fd..` placeholders from the LAN bridges |
| `INTERVAL` | `30` | Seconds between passes |

## Validation

On the gateway:

```sh
/data/centurylink-ipv6/centurylink-ipv6 status   # tunnel, addresses, routes, firewall, ping6
journalctl -u centurylink-ipv6 -f
ip -6 addr show scope global | grep ' fd'        # should print nothing
tcpdump -i br0 -c 3 -vv 'icmp6 and ip6[40] == 134'   # RAs should carry your 2602: prefix, not fd00:
```

On clients:

```sh
ip -6 addr show   # Linux/Mac: a 2602: address with the "autoconf" flag
ipconfig          # Windows: a 2602: address listed as "Autoconfiguration"
curl -6 ifconfig.co
```

## Troubleshooting

- **`'ip tunnel 6rd' failed`:** the kernel lacks `CONFIG_IPV6_SIT_6RD`.
- **`WAN IPv4 ... is not public`:** you're behind CGNAT or another router, and 6RD can't work there.
- **The tunnel is up but `ping6` fails:** try the other relay. Set `SIXRD_BR="205.171.2.64"`.
- **`removed ULA placeholder` on nearly every pass:** UniFi is actively putting the placeholder back, so the two are undoing each other. Please open an issue and include your UniFi OS version.
- **`dnsmasq did not respawn`:** LAN DHCP is down. Re-provision the gateway from UniFi Network.

## Credits

https://community.ui.com/questions/UDM-Pro-CenturyLink-6RD-IPv6-Configuration-Guide/669c1c67-9843-4b57-b685-775d95d26924
