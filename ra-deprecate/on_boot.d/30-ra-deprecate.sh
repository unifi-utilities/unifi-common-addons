#!/usr/bin/env sh
# shellcheck shell=sh
# path: /data/on_boot.d/30-ra-deprecate.sh
#
# UniFi on_boot.d installer/launcher for the ra-deprecate systemd unit. Idempotent.
# /etc is rebuilt by firmware updates and /data survives, so the unit lives in
# /data and is linked into place on every boot.

set -eu

readonly addon_root='/data/unifi-common-addons/ra-deprecate'
readonly addon_script="${addon_root}/scripts/ra-deprecate"
readonly unit_file="${addon_root}/systemd/ra-deprecate.service"

for required in "${addon_script}" "${unit_file}"; do
  if [ ! -f "${required}" ]; then
    echo "required file not found: ${required}" >&2
    exit 1
  fi
done

ln -sfn "${unit_file}" /etc/systemd/system/ra-deprecate.service

systemctl daemon-reload
systemctl enable ra-deprecate.service
systemctl restart ra-deprecate.service
