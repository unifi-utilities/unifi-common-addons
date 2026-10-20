#!/bin/sh
# Copied to /data/on_boot.d/20-centurylink-ipv6.sh by ./install. Reinstalls the
# unit on every boot, since firmware updates can wipe /etc/systemd/system.
set -eu

install -m 0644 \
    /data/centurylink-ipv6/systemd/centurylink-ipv6.service \
    /etc/systemd/system/centurylink-ipv6.service
systemctl daemon-reload
systemctl enable --now centurylink-ipv6.service
