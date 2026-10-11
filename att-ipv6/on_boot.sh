#!/bin/sh
set -eu

install -d -m 0755 /etc/tmpfiles.d
install -m 0644 \
    /data/att-ipv6/tmpfiles.d/att-ipv6.conf \
    /etc/tmpfiles.d/att-ipv6.conf
systemd-tmpfiles --create /etc/tmpfiles.d/att-ipv6.conf

for unit in \
    att-ipv6-acquire.service \
    att-ipv6-recover.service \
    att-ipv6-recover.path \
    att-ipv6-reconcile.service \
    att-ipv6-reconcile.path \
    att-ipv6-reconcile.timer
do
    install -m 0644 "/data/att-ipv6/systemd/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
if [ -e /data/att-ipv6/native-enabled ]; then
    systemctl enable --now \
        att-ipv6-acquire.service \
        att-ipv6-recover.path \
        att-ipv6-reconcile.path \
        att-ipv6-reconcile.timer
fi
