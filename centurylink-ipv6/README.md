# centurylink-ipv6

On CenturyLink (Lumen) IPv6, PPPoE subscribers receive a `/24` 6RD prefix (`2602::/24`) delivered via a SIT tunnel to a relay server. Rather than native DHCPv6-PD, the router must calculate its unique `/64` prefixes by embedding the WAN IPv4 address into the 6RD prefix, then advertise those prefixes to LAN clients via Router Advertisements.

This script enables the device to create and maintain a CenturyLink 6RD tunnel, assign derived `/64` prefixes to each LAN bridge interface, and configure dnsmasq to send Router Advertisements so clients can self-configure via SLAAC.

Note that IPv6 Interface Type in the UniFi UI must be set to `Static` (with a placeholder prefix) for each network - not `None` - to prevent the device from auto-generating conflicting ULA addresses. The boot script immediately overrides those placeholders with the correct 6RD-derived prefixes.

## Requirements

1. You have successfully set up the `on_boot.d` script described [here](https://github.com/unifi-utilities/unifi-common).
2. You must have a working CenturyLink PPPoE connection (`ppp0`) on the device.
3. You must set IPv6 to `Static` in the UniFi UI for each network/VLAN (not `None`), using unique placeholder prefixes:
   - Default/Home network (`br0`): `fd00:1::/64`
   - Each additional VLAN: `fd00:2::/64`, `fd00:3::/64`, etc.
   - Enable **Router Advertisement (RA)** on each network.
4. You must add firewall rules equivalent to (this can be done in the UI, select `Internet v6 Local` chain):

   ```
   -A UBIOS_WAN_LOCAL_USER -p ipv6-icmp -m icmp6 --icmpv6-type 134 -j RETURN # select IPv6 Protocol "ICMPv6" and IPv6 ICMP Type Name "Router Advertisement"
   ```

## Customization

Near the top of `20-centurylink-6rd.sh`:

```sh
RELAY="205.91.4.61"   # CenturyLink's 6RD relay server
PREFIX="2602::/24"    # CenturyLink's 6RD prefix
WAN_IF="ppp0"         # PPPoE interface name
```

And the bridge interface blocks further down:

```sh
# Configure br0 (LAN bridge) with IPv6 - flush first
ip -6 addr flush dev br0 scope global
ip -6 addr add ${IPV6_ADDR}/64 dev br0

# Configure br300 (VLAN 300) - duplicate this block for each additional VLAN
if ip link show br300 >/dev/null 2>&1; then
    IPV6_VLAN300=$(printf "2602:%02x:%02x%02x:%02x01::1" $o1 $o2 $o3 $o4)
    ip -6 addr flush dev br300 scope global
    ip -6 addr add ${IPV6_VLAN300}/64 dev br300
fi
```

Each additional VLAN gets a unique hex suffix (`01`, `02`, `03`,…) appended to the prefix. Matching `dhcp-range` lines must also be added to `customipv6.conf`:

```conf
dhcp-range=::,constructor:br300,ra-names,slaac,64,12h
```

This generates a configuration in `/data/on_boot.d/`. The files can be edited directly or reset by re-running the scripts.

## Installation

```sh
cd /data/on_boot.d
curl -LO https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/refs/heads/main/centurylink-ipv6/20-centurylink-6rd.sh
curl -LO https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/refs/heads/main/centurylink-ipv6/customipv6.conf
curl -LO https://raw.githubusercontent.com/unifi-utilities/unifi-common-addons/refs/heads/main/centurylink-ipv6/25-customipv6.sh
chmod +x 20-centurylink-6rd.sh 25-customipv6.sh
./20-centurylink-6rd.sh
./25-customipv6.sh
```

Then reboot:

```sh
reboot
```

## Validation

After reboot (2–3 minutes), SSH back in and run the following.

On the device:

```sh
$ ip -6 addr show 6rd    # should see your 6RD tunnel address
2602:xx:xxxx:xx00::1/24 dev 6rd ...

$ ip -6 addr show br0    # should see a 2602: prefix, NOT fd00:
2602:xx:xxxx:xx00::1/64 dev br0 ...

$ ip -6 route            # should see a default route via the relay on 6rd
default via ::205.91.4.61 dev 6rd metric 1024 ...
2602:xx:xxxx:xx00::/64 dev br0 proto kernel ...
```

Test outbound connectivity:

```sh
ping6 -c 3 google.com
curl -6 ifconfig.co
```

Watch Router Advertisements being sent to clients:

```sh
tcpdump -i br0 -c 5 -vvv icmp6 and 'ip6[40] == 134'
# should see RAs advertising your 2602: prefix
```

On clients:

```sh
ip -6 addr show   # Linux/Mac - should see a 2602: address with "autoconf" flag
ipconfig          # Windows   - should see a 2602: address listed as "Autoconfiguration"
```

### Troubleshooting

```sh
# Verify boot scripts are present and executable
ls -la /data/on_boot.d/

# Check that dnsmasq has loaded the RA configuration
cat /run/dnsmasq.dhcp.conf.d/customipv6.conf

# Check for conflicting ULA addresses (fd00: means UI setting is still "None")
ip -6 addr | grep fd

# Manually re-run tunnel script after a WAN reconnect (boot scripts don't run on reconnect)
/data/on_boot.d/20-centurylink-6rd.sh

# Useful commands
ip -6 route                    # verify default route is via 6rd
ip tunnel show 6rd             # verify tunnel parameters
systemctl status dnsmasq       # verify dnsmasq is running
```

## Credits

https://community.ui.com/questions/UDM-Pro-CenturyLink-6RD-IPv6-Configuration-Guide/669c1c67-9843-4b57-b685-775d95d26924
