#! /bin/bash
set -eo pipefail

# UniFi Data Directory
DATA_DIR="/data"

# Check if the directory exists
if [ ! -d "$DATA_DIR/att-ipv6" ]; then
  # If it does not exist, create the directory
  mkdir -p "$DATA_DIR/att-ipv6"
  echo "Directory '$DATA_DIR/att-ipv6' created."
else
  # If it already exists, print a message
  echo "Directory '$DATA_DIR/att-ipv6' already exists. Moving on."
fi

wan_iface="eth8"                                     # "eth9" for UDM Pro WAN2
vlans="br0"                                          # "br0 br100 br101..."
domain="example.invalid"                             # DNS domain
dns6="[2001:4860:4860::8888],[2001:4860:4860::8844]" # Google

confdir=${DATA_DIR}/att-ipv6

# main
test -f "${confdir}/dhcpcd.conf" || {
  : >"${confdir}/dhcpcd.conf.tmp"
  cat >>"${confdir}/dhcpcd.conf.tmp" <<EOF
allowinterfaces ${wan_iface}
nodev
noup
ipv6only
nooption domain_name_servers
nooption domain_name
duid
persistent
option rapid_commit
option interface_mtu
require dhcp_server_identifier
slaac private
noipv6rs

interface ${wan_iface}
  ipv6rs
  ia_na 0
EOF

  ix=0
  for vv in $vlans; do
    echo "  ia_pd ${ix} ${vv}/0"
    ix=$((ix + 1))
  done >>"${confdir}/dhcpcd.conf.tmp"
  mv "${confdir}/dhcpcd.conf.tmp" "${confdir}/dhcpcd.conf"
}

test -f "${confdir}/att-ipv6-dnsmasq.conf" || {
  : >"${confdir}/att-ipv6-dnsmasq.conf.tmp"
  cat >>"${confdir}/att-ipv6-dnsmasq.conf.tmp" <<EOF
#
# via att-ipv6
#
enable-ra
no-dhcp-interface=lo
no-ping
EOF

  for vv in $vlans; do
    cat <<EOF

interface=${vv}
dhcp-range=set:att-ipv6-${vv},::2,::7d1,constructor:${vv},slaac,ra-names,64,86400
dhcp-option=tag:att-ipv6-${vv},option6:dns-server,${dns6}
domain=${domain}|${vv}
ra-param=${vv},high,0
EOF
  done >>"${confdir}/att-ipv6-dnsmasq.conf.tmp"
  mv "${confdir}/att-ipv6-dnsmasq.conf.tmp" "${confdir}/att-ipv6-dnsmasq.conf"
}

if ! dpkg -s dhcpcd5 >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y dhcpcd5
fi

restart_dhcpcd=0
if [ ! -f /etc/dhcpcd.conf ] || ! cmp -s "${confdir}/dhcpcd.conf" /etc/dhcpcd.conf; then
  cp "${confdir}/dhcpcd.conf" /etc/dhcpcd.conf
  restart_dhcpcd=1
fi

if [ "$restart_dhcpcd" -eq 1 ]; then
  start-stop-daemon -K -x /usr/sbin/dhcpcd
fi

# Warn if UniFi's DHCPv6 client is still active; this setup expects it disabled in UI.
if pgrep -x odhcp6c >/dev/null 2>&1; then
  echo "WARNING: odhcp6c is running. Disable WAN/network DHCPv6 in the UniFi UI to avoid conflicts with att-ipv6." >&2
fi

# Fix DHCP
if [ -d /run/dnsmasq.dhcp.conf.d ]; then
  # UniFi Network > 9.3.29 (commonly on UniFi OS 5.x)
  cp "${confdir}/att-ipv6-dnsmasq.conf" /run/dnsmasq.dhcp.conf.d/att-ipv6.conf
else
  # older versions
  cp "${confdir}/att-ipv6-dnsmasq.conf" /run/dnsmasq.conf.d/att-ipv6.conf
fi
start-stop-daemon -K -q -x /usr/sbin/dnsmasq
