# att-pon-ipv6

On AT&T fiber networks, when bypassing the residential gateway entirely using an SFP+ ONT or custom media converter, the UniFi Console directly requests network credentials. While LAN clients successfully receive fully routable IPv6 allocations from the continuous `/64` subnets routed by AT&T, the UniFi Console's WAN interface itself receives a non-routable internal AT&T IPv6 address. This breaks console-level outbound IPv6 traffic, causing native features like internal speed tests to fail.

This script changes the WAN interface on boot to bind a legitimate global IPv6 address from your allotment to the console itself, restoring full IPv6 functionality. Concurrently, it maintains a persistent localized IPv4 allocation on the WAN interface to preserve management access to your external ONT hardware.

Unlike alternative solutions, this change operates non-destructively: all native UniFi Network UI features, firewall rules, and DHCP/DHCPv6 controls remain fully functional.

## Requirements

1. You have successfully set up the `on_boot.d` environment architecture described [here](https://github.com/unifi-utilities/unifi-common).
2. A completely bypassed network topology where your custom ONT module connects directly to a UniFi Console WAN interface.
3. You have determined your assigned AT&T IPv6 prefix block and isolated one `/64` subnet to use specifically for your WAN boundary.

## Customization

The script reads its settings from a standalone configuration file located at `/data/att-pon-ipv6/att-pon-ipv6.conf`. If it does not exist, you must create it.

```sh
# The WAN physical interface (e.g., eth9 for UDM Pro/SE Port 10 SFP+)
WAN_IFACE="eth9"

# The local IPv4 management address to map to the ONT/modem network
WAN_LOCAL_IP4="192.168.11.2/24"

# A routable global IPv6 address from your AT&T pool to assign to the WAN link
WAN_GLOBAL_IP6="2001:db8:xxxx:xx00::2/128"

# Diagnostics endpoints
IPV4_TEST_TARGET="192.168.11.1"
IPV6_TEST_TARGET="ifconfig.co"

```

The core script handles boot-stage race conditions automatically. Because `on_boot.d` utilities execute early in the OS sequence, the script loops and defers execution until `WAN_IFACE` is fully provisioned and up before attempting to inject the IP allocations.

## Installation

```sh
# 1. Create the persistent configuration container
mkdir -p /data/att-pon-ipv6

# 2. Populate your configuration values into the file
vi /data/att-pon-ipv6/att-pon-ipv6.conf

# 3. Pull down the boot execution script
cd /data/on_boot.d
curl -LO https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/HEAD/att-pon-ipv6/att-pon-ipv6.sh
chmod +x att-pon-ipv6.sh

# 4. Run immediately to change without a reboot
./att-pon-ipv6.sh

```

## Validation

To verify the interface has accepted the secondary IP assignments alongside your dynamic network configuration, run the following:

On your UniFi Console:

```sh
$ ip addr show dev eth9
5: eth9: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 10000
    inet xx.xx.xx.xx/22 brd xx.xx.xx.xx scope global dynamic eth9
    inet 192.168.11.2/24 scope global eth9
       valid_lft forever preferred_lft forever
    inet6 2001:db8:xxxx:xx00::2/128 scope global
       valid_lft forever preferred_lft forever
    inet6 fe80::xxxx:xxxx:xxxx:xxxx/64 scope link
       valid_lft forever preferred_lft forever

```

Inspect the system log to ensure both diagnostic checks pass and that no duplicate bindings occurred:

```sh
$ journalctl -t att-pon-ipv6 --no-pager
[...]
att-pon-ipv6[1024]: Initial network diagnostic checks:
att-pon-ipv6[1025]: IPv4 connectivity to 192.168.11.1 successful.
att-pon-ipv6[1026]: WARNING: IPv4 connectivity to ifconfig.co failed.
att-pon-ipv6[1027]: Assigning IPv4 address '192.168.11.2/24' to 'eth9'...
att-pon-ipv6[1028]: IPv4 address '192.168.11.2/24' added successfully.
att-pon-ipv6[1029]: Assigning IPv6 address '2001:db8:xxxx:xx00::2/128' to 'eth9'...
att-pon-ipv6[1030]: IPv6 address '2001:db8:xxxx:xx00::2/128' added successfully.
att-pon-ipv6[1031]: Post diagnostic checks:
att-pon-ipv6[1032]: IPv4 connectivity to 192.168.11.1 successful.
att-pon-ipv6[1033]: IPv6 connectivity to ifconfig.co successful.

```

## Useful Commands

```sh
# Read the complete execution logs for debugging link timelines
journalctl -t att-pon-ipv6 -n 50 --no-pager

# Force-run the utility manually if you change parameters in your conf file
/data/on_boot.d/att-pon-ipv6.sh

```

## Credits & Resources

- **Deep Dive Blog Post:** For a detailed exploration of the routing architecture, root causes, and user discussions behind this implementation, read [UniFi OS – AT&T XGS-PON Gateway Bypass](https://www.stevenz.blog/att-xgs-pon-gateway-bypass-for-unifi-console/).
