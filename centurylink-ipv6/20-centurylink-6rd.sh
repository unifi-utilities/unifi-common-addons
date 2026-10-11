#!/bin/bash

# CenturyLink 6RD Parameters - change these to your ISP's values
RELAY="205.91.4.61"
PREFIX="2602::/24"

# Get WAN interface (PPPoE)
WAN_IF="ppp0"

# Get your WAN IPv4 address from PPPoE interface
WAN_IP=$(ip -4 addr show $WAN_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

# If ppp0 doesn't exist yet, wait for it (up to 60 seconds)
RETRIES=0
while [ -z "$WAN_IP" ] && [ $RETRIES -lt 30 ]; do
    sleep 2
    WAN_IP=$(ip -4 addr show $WAN_IF 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    RETRIES=$((RETRIES + 1))
done

if [ -z "$WAN_IP" ]; then
    echo "Error: Could not determine WAN IP address"
    exit 1
fi

echo "WAN IP: $WAN_IP"

# Calculate 6RD IPv6 address using CenturyLink's format
# Format: 2602:aa:bbcc:dd00::1 where aa.bb.cc.dd is your IPv4
IFS='.' read -r o1 o2 o3 o4 <<< "$WAN_IP"
IPV6_ADDR=$(printf "2602:%02x:%02x%02x:%02x00::1" $o1 $o2 $o3 $o4)
IPV6_PREFIX=$(printf "2602:%02x:%02x%02x:%02x00::" $o1 $o2 $o3 $o4)

echo "IPv6 Address: $IPV6_ADDR"
echo "IPv6 Prefix: ${IPV6_PREFIX}/64"

# Remove existing 6rd tunnel if it exists
ip tunnel del 6rd 2>/dev/null

# Create 6RD tunnel (SIT tunnel)
ip tunnel add 6rd mode sit local $WAN_IP ttl 255
ip tunnel 6rd dev 6rd 6rd-prefix $PREFIX
ip link set 6rd mtu 1472 up

# Add IPv6 address to tunnel
ip -6 addr add ${IPV6_ADDR}/24 dev 6rd

# Add default IPv6 route through relay
ip -6 route add default via ::$RELAY dev 6rd metric 1024 2>/dev/null

# Enable IPv6 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

# Configure br0 (LAN bridge) with IPv6 - flush first to remove any ULA addresses
ip -6 addr flush dev br0 scope global
ip -6 addr add ${IPV6_ADDR}/64 dev br0

# Configure br300 (VLAN 300) with IPv6 if it exists
# Duplicate and modify this block for each additional VLAN, incrementing the suffix (01, 02, 03...)
if ip link show br300 >/dev/null 2>&1; then
    IPV6_VLAN300=$(printf "2602:%02x:%02x%02x:%02x01::1" $o1 $o2 $o3 $o4)
    ip -6 addr flush dev br300 scope global
    ip -6 addr add ${IPV6_VLAN300}/64 dev br300
    echo "VLAN 300: ${IPV6_VLAN300}/64 on br300"
fi

echo ""
echo "6RD tunnel configured successfully!"
echo "Tunnel: $IPV6_ADDR/24 on 6rd"
echo "LAN:    $IPV6_ADDR/64 on br0"
echo ""
echo "Testing connectivity..."
if ping6 -c 2 -W 3 google.com >/dev/null 2>&1; then
    echo "✓ IPv6 is working!"
    curl -6 -s ifconfig.co 2>/dev/null && echo ""
else
    echo "✗ IPv6 connectivity test failed"
    echo "Check routing table: ip -6 route"
fi
