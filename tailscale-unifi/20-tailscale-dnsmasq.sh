#!/bin/bash
set -euo pipefail

mkdir -p /run/dnsmasq.dhcp.conf.d
cat > /run/dnsmasq.dhcp.conf.d/tailscale0.conf <<'EOC'
interface=tailscale0
EOC

for i in $(seq 1 10); do
  ip link show tailscale0 >/dev/null 2>&1 && break
  sleep 1
done

pkill dnsmasq || true