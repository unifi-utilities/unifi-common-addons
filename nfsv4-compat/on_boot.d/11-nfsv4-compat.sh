#!/usr/bin/env sh
# shellcheck shell=sh
# path: /data/on_boot.d/11-nfsv4-compat.sh
#
# UniFi on_boot.d installer/launcher for the nfsv4-compat systemd unit. Idempotent.

set -eu

readonly addon_root='/data/unifi-common-addons/nfsv4-compat'
readonly addon_script="${addon_root}/scripts/nfsv4-compat"

if [ ! -f "${addon_script}" ]; then
  echo "required script not found: ${addon_script}" >&2
  exit 1
fi

chmod +x "${addon_script}"

for unit in 'path' 'timer' 'service'; do
  unit_file="${addon_root}/systemd/nfsv4-compat.${unit}"

  if [ ! -f "${unit_file}" ]; then
    echo "required unit file not found: ${unit_file}" >&2
    exit 1
  fi

  ln -sfn "${unit_file}" "/etc/systemd/system/nfsv4-compat.${unit}"
done

systemctl daemon-reload
systemctl enable --now nfsv4-compat.timer nfsv4-compat.path
