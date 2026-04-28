# att-static-ips

Use your full CIDR (not just the five AT&T claims) to get an extra public IP in your DHCP pool.

## How this works

I tore through how IP Passthrough and Cascaded Routers work in ATT Gateways, and I discovered how they use them. This emulates a Cascaded Router setup. Also, you get the bonus of being able to assign your DHCPv4 IP to any interface you want. I assign egress IPs to my networks and use port forwarding for the rest. Alternatively, you can create a new network with your Public IP CIDR and have the DHCP server hand out addresses.

## Steps

1. Set up your internet connection via DHCP v4 as you usually would.
2. Get your current IP:

   ```shell
   curl ifconfig.co
   108.2.2.2
   ```

3. Trace route from UDMP to get your Gateway:

   ```shell
   traceroute to 8.8.8.8 (8.8.8.8), 30 hops max, 46 byte packets
   1  108-x-x-x.lxxxxxxxx (108.2.2.2)  0.343 ms  0.492 ms  0.376 ms  <----- Default Gateway
   ```

4. Discover the subnet for your DHCP IP.
   Run `ip a`, go to your WAN IP interface. You will see your public IP with a CIDR; that CIDR denotes your subnet mask:
   - Reference: <https://docs.netgate.com/pfsense/en/latest/network/cidr.html>

   ```shell
   eth8: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
   link/ether  brd ff:ff:ff:ff:ff:ff
   inet 108.2.2.2/22 scope global eth8
   valid_lft forever preferred_lft forever
   ```

   Our subnet mask is `/22` - `255.255.252.0`.

5. Set up your internet with a static IP. Use your dynamic IP, which you usually get, and the gateway/subnet mask we found above. Also, add each one of your static IPs by hand - if you try to add them by range, the UI CIDR knows that some of those should be broadcast/router, etc.

Example:

![Example screenshot](example.png)

Save, and it should work.

However, if it does not - or later you randomly lose your internet - there is a reason for this.

Your route out to the internet is your DHCPv4 lease. You may need to renew it. To do this, switch back to DHCPv4 and save, then switch back to static IP, **or** do this from the command line:

```sh
# busybox-legacy udhcpc -i eth8
udhcpc: started, v1.34.1
udhcpc: broadcasting discover
sh: /usr/share/udhcpc/decline.script: not found
udhcpc: broadcasting select for 108.2.2.2, server 108.1.1.1
udhcpc: lease of 108.2.2.2 obtained from 108.1.1.1., lease time 3600
```
