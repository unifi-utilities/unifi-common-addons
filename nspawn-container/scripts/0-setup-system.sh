#!/bin/bash
# This script installs systemd-container if it's not installed.
# Also links any containers from /data/custom/machines to /var/lib/machines.
# Updates the backup .deb files for offline install.

# Exits script if errors are encountered
set -e

# Wait up to 45 seconds for an active internet connection. Bypasses instantly if already online, or stops waiting after 15 tries if completely offline.
count=0
while [ $count -lt 15 ] && ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; do
    sleep 3
    count=$((count + 1))
done

# Update the cached .deb files for offline use IF online
if apt-get --fix-broken install -y && apt-get update -qq && apt download systemd-container libnss-mymachines debootstrap arch-test; then
  echo "Updating backup dpkg package files..."
  mkdir -p /data/custom/dpkg
  rm -f /data/custom/dpkg/*.deb
  cd /data/custom/dpkg
  apt download systemd-container libnss-mymachines debootstrap arch-test
else
  # Install systemd-container and dependencies, fall back to cached .deb files if online install fails
  if ! dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
    if ! apt -y install systemd-container debootstrap; then
      echo "Online install failed, attempting offline install from cached .deb files..."
      dpkg -i /data/custom/dpkg/*.deb 2>/dev/null || apt-get -f install -y
    fi
  fi
fi

# Link containers from /data/custom/machines to /var/lib/machines
mkdir -p /var/lib/machines
for machine_dir in /data/custom/machines/*/; do
[ -d "$machine_dir" ] || continue
machine=$(basename "$machine_dir")
if [ ! -e "/var/lib/machines/$machine" ]; then
ln -s "/data/custom/machines/$machine" "/var/lib/machines/"
machinectl enable "$machine"
machinectl start "$machine"
fi
done
echo "Setup complete."
