# he-ipv6

[Hurricane Electric IPv6 Tunnel Broker](https://tunnelbroker.net/) provides static 6in4 tunnels for networks where the ISP only provides IPv4. This addon creates a SIT tunnel on a UniFi OS gateway, installs the IPv6 default route, and adds runtime firewall classification so UniFi's `Internet v6 In`, `Internet v6 Local`, and `Internet v6 Out` rule chains apply to traffic entering or leaving the tunnel.

The script is intentionally runtime-based. It does not edit `/data/udapi-config/*` and it does not create UniFi Network database objects. Configure LAN IPv6 prefixes and Router Advertisements in UniFi Network UI/API when your controller exposes those settings.

## Requirements

1. You have installed the `on_boot.d` persistence mechanism from [unifi-common](https://github.com/unifi-utilities/unifi-common).
2. You have a [Hurricane Electric tunnel](https://tunnelbroker.net/) with:
   - server IPv4 address;
   - client IPv6 address, usually the tunnel `/64` `::2` address;
   - server IPv6 address, usually the tunnel `/64` `::1` address;
   - one or more routed LAN prefixes.
3. Your ISP allows [IPv6-in-IPv4 protocol 41](https://www.rfc-editor.org/rfc/rfc4213.html) between your gateway and the HE server.
4. UniFi Network LAN IPv6 settings are configured separately:
   - set each LAN to a static `/64` IPv6 prefix from your HE routed `/64` or optional routed `/48` allocation;
   - enable Router Advertisements/SLAAC as appropriate;
   - do not rely on native WAN DHCPv6-PD if your ISP does not provide it.

## Installation

```sh
cd /data/on_boot.d
curl -LO https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/refs/heads/main/he-ipv6/20-he-ipv6.sh
curl -Lo he-ipv6.conf.example https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/refs/heads/main/he-ipv6/he-ipv6.conf.example
cp he-ipv6.conf.example he-ipv6.conf
chmod +x 20-he-ipv6.sh
vi he-ipv6.conf
./20-he-ipv6.sh --apply
./20-he-ipv6.sh --check
```

Then reboot or let `on_boot.d` run the script on the next boot.

## Configuration

Edit `/data/on_boot.d/he-ipv6.conf` with values from the HE tunnel details page:

```sh
HE_SERVER_IPV4="203.0.113.1"
HE_CLIENT_IPV6="2001:db8:0:1::2/64"
HE_SERVER_IPV6="2001:db8:0:1::1"
```

Leave `HE_CLIENT_IPV4` empty unless the automatic route lookup chooses the wrong local IPv4 address:

```sh
HE_CLIENT_IPV4=""
```

HE has separate tunnel and routed IPv6 values. Put only the tunnel client address in `HE_CLIENT_IPV6`. For LANs, use one `/64` per network from HE's routed `/64` or from the optional routed `/48`; do not assign the whole `/48` to a LAN interface.

If UniFi Network manages LAN IPv6, leave runtime LAN management disabled and optionally list expected LAN addresses for validation:

```sh
HE_LAN_ADDRESSES="br0=2001:db8:100::1/64 br2=2001:db8:101::1/64"
HE_MANAGE_LAN_ADDRESSES="0"
```

If your UniFi Network version cannot express the LAN prefixes, the script can add them at runtime:

```sh
HE_LAN_ADDRESSES="br0=2001:db8:100::1/64 br2=2001:db8:101::1/64"
HE_MANAGE_LAN_ADDRESSES="1"
HE_FLUSH_LAN_GLOBAL="0"
```

Keep `HE_FLUSH_LAN_GLOBAL=0` unless you intentionally want the script to remove existing global IPv6 addresses from listed LAN interfaces before adding its own.

## Firewall Classification

UniFi's generated firewall rules classify traffic by known interfaces. A custom SIT tunnel interface may not be part of the generated WAN interface list, so traffic can otherwise bypass the expected `Internet v6` rule family.

With `HE_WAN_CLASSIFICATION=1`, the script adds these runtime jumps when the chains exist:

```sh
ip6tables -I UBIOS_INPUT_USER_HOOK 1 -i he-ipv6 -j UBIOS_WAN_LOCAL_USER
ip6tables -I UBIOS_FORWARD_IN_USER 1 -i he-ipv6 -j UBIOS_WAN_IN_USER
ip6tables -I UBIOS_FORWARD_OUT_USER 1 -o he-ipv6 -j UBIOS_WAN_OUT_USER
```

This keeps unsolicited inbound traffic on the normal Internet/WAN IPv6 policy path. Create allow rules in UniFi Network only for services you intentionally want reachable over IPv6.

UniFi Network/UDAPI reprovision events can remove runtime firewall rules, so the script starts a lightweight watchdog by default. Set `HE_WATCHDOG_INTERVAL=0` to disable it.

## Validation

On the gateway:

```sh
/data/on_boot.d/20-he-ipv6.sh --check
ip tunnel show he-ipv6
ip -6 addr show he-ipv6
ip -6 route show default
ip6tables -S UBIOS_FORWARD_IN_USER | grep he-ipv6
```

Expected `--check` output ends with:

```text
SUMMARY ok
```

From an IPv6 LAN client:

```sh
ping -6 2606:4700:4700::1111
curl -6 https://ifconfig.co
```

To verify Router Advertisements on a LAN bridge:

```sh
tcpdump -i br0 -c 5 -vvv 'icmp6 and ip6[40] == 134'
```

## Troubleshooting

Check that protocol 41 can reach HE:

```sh
tcpdump -ni eth4 'ip proto 41 and host <HE_SERVER_IPV4>'
```

If `--check` reports missing firewall classification, run:

```sh
/data/on_boot.d/20-he-ipv6.sh --apply
```

If UniFi Network later reprovisions firewall state, confirm that the watchdog is running:

```sh
cat /run/he-ipv6-watchdog.pid
```

On MediaTek-based gateways, protocol-41 traffic may produce HNAT messages such as `DSA + HNAT unsupport protocol`. That means the traffic cannot be hardware offloaded and is using the software path; it does not by itself mean the tunnel is broken.
