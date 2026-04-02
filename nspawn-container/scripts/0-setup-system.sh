#!/bin/bash
# This script installs systemd-container if it's not installed.
# Also links any containers from /data/custom/machines to /var/lib/machines.
# Updates the backup .deb files for offline install.

set -e

# Update the cached .deb files for offline use
echo "Updating backup dpkg package files..."
mkdir -p /data/custom/dpkg
cd /data/custom/dpkg
apt download systemd-container libnss-mymachines debootstrap arch-test

# Install systemd-container and dependencies, fall back to cached .deb files if online install fails
if ! dpkg -l systemd-container | grep ii >/dev/null; then
    if ! apt -y install systemd-container debootstrap; then
        echo "Online install failed, attempting offline install from cached .deb files..."
        dpkg -i /data/custom/dpkg/*.deb 2>/dev/null || apt-get -f install -y
    fi
fi

# Link containers from /data/custom/machines to /var/lib/machines
mkdir -p /var/lib/machines
for machine in $(ls /data/custom/machines/); do
    if [ ! -e "/var/lib/machines/$machine" ]; then
        ln -s "/data/custom/machines/$machine" "/var/lib/machines/"
        machinectl enable $machine
        machinectl start $machine
    fi
done
echo "Setup complete."