#!/usr/bin/env sh
# shellcheck shell=sh
# path: /data/on_boot.d/11-nfsv4-compat.sh
#
# UniFi on_boot.d installer/launcher for the nfsv4-compat systemd units. Idempotent.

set -eu

readonly addon_root='/data/unifi-common-addons/nfsv4-compat'
readonly components='nfsv4-compat nfsv4-enable' # nfsv4-compat builds the v4 tree, nfsv4-enable keeps nfsd serving v4

for component in ${components}; do
  addon_script="${addon_root}/scripts/${component}"

  if [ ! -f "${addon_script}" ]; then
    echo "required script not found: ${addon_script}" >&2
    exit 1
  fi

  chmod +x "${addon_script}"

  for unit in 'path' 'timer' 'service'; do
    unit_file="${addon_root}/systemd/${component}.${unit}"

    if [ ! -f "${unit_file}" ]; then
      echo "required unit file not found: ${unit_file}" >&2
      exit 1
    fi

    ln -sfn "${unit_file}" "/etc/systemd/system/${component}.${unit}"
  done
done

systemctl daemon-reload

for component in ${components}; do
  systemctl enable --now "${component}.timer" "${component}.path"
done
