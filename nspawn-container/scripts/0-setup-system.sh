#!/bin/bash
# This script installs systemd-container if it's not installed.
# Also links any containers from /data/custom/machines to /var/lib/machines.
# Updates the backup .deb files for offline install.

# Exits script if errors are encountered
set -e

# Retry apt-get update while the WAN comes up (up to ~50 seconds)
online=false
for i in $(seq 1 10); do
  if apt-get update -qq; then
    online=true
    break
  fi
  sleep 5
done

apt-get --fix-broken install -y || true

# Refresh the offline cache only after a successful download, so a failure never leaves it empty
if $online; then
  echo "Updating backup dpkg package files..."
  tmp=$(mktemp -d)
  if (cd "$tmp" && apt download systemd-container libnss-mymachines debootstrap arch-test); then
    mkdir -p /data/custom/dpkg
    rm -f /data/custom/dpkg/*.deb
    mv "$tmp"/*.deb /data/custom/dpkg/
  else
    echo "Download failed, keeping existing cached .deb files"
  fi
  rm -rf "$tmp"
fi

# Always make sure systemd-container is installed, online or offline
if ! dpkg -l systemd-container 2>/dev/null | grep -q '^ii'; then
  if ! $online || ! apt-get -y install systemd-container debootstrap; then
    echo "Online install unavailable or failed, installing from cached .deb files..."
    dpkg -i /data/custom/dpkg/*.deb 2>/dev/null || apt-get -f install -y
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
