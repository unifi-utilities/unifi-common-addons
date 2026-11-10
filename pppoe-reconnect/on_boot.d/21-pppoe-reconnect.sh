#!/usr/bin/env sh
# shellcheck shell=sh
# path: /data/on_boot.d/21-pppoe-reconnect.sh
#
# Writes the cron job that reconnects PPPoE once a day. Idempotent. /etc is
# rebuilt by firmware updates and /data survives, so the job is written again
# on every boot.
#
# The time inside the window is derived from the gateway's serial number: the
# same on every boot, and different on different gateways. All times are the
# gateway's local time, since cron runs in the system time zone, not in UTC.

set -eu

readonly addon_root='/data/unifi-common-addons/pppoe-reconnect'
# these three can be overridden, which is how tests/test-addon.sh runs the
# script against a temporary directory and a stub; on a gateway none of the
# variables is set
readonly conf="${PPPOE_RECONNECT_CONF:-${addon_root}/pppoe-reconnect.conf}"
readonly cron_file="${PPPOE_RECONNECT_CRON_FILE:-/etc/cron.d/pppoe-reconnect}"
readonly killall_bin="${PPPOE_RECONNECT_KILLALL:-/usr/bin/killall}"

RECONNECT_WINDOW='03:00-04:00'
RECONNECT_SEED=''
RECONNECT_INTERFACES='ppp0'
if [ -f "${conf}" ]; then
  # shellcheck source=/dev/null
  . "${conf}"
fi

fail() {
  echo "pppoe-reconnect: $*" >&2
  exit 1
}

valid_time() {
  case "$1" in
    [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# HH:MM to seconds since midnight; the leading zeros are stripped so that 08 and
# 09 are not read as octal.
to_seconds() {
  _h="${1%%:*}"
  _m="${1##*:}"
  _h="${_h#0}"
  _m="${_m#0}"
  echo $((${_h:-0} * 3600 + ${_m:-0} * 60))
}

machine_id() {
  _id=''
  if [ -r /proc/ubnthal/system.info ]; then
    _id="$(sed -n 's/^serialno=//p' /proc/ubnthal/system.info | head -n 1)"
  fi
  if [ -z "${_id}" ] && [ -r /etc/machine-id ]; then
    _id="$(cat /etc/machine-id)"
  fi
  if [ -z "${_id}" ] && [ -r /sys/class/net/eth0/address ]; then
    _id="$(cat /sys/class/net/eth0/address)"
  fi
  if [ -z "${_id}" ]; then
    _id="$(hostname)"
  fi
  printf '%s' "${_id}"
}

# window text "HH:MM-HH:MM" to start_s and length (seconds), or stop with a
# message naming the variable the text came from
parse_window() {
  _err="$2 in ${conf} must be HH:MM-HH:MM (24 h), got '$1'"
  case "$1" in
    ??:??-??:??) ;;
    *) fail "${_err}" ;;
  esac
  _a="${1%-*}"
  _b="${1#*-}"
  if ! valid_time "${_a}" || ! valid_time "${_b}"; then
    fail "${_err}"
  fi
  start_s="$(to_seconds "${_a}")"
  _e="$(to_seconds "${_b}")"
  [ "${start_s}" -ne "${_e}" ] || fail "$2 in ${conf} is empty: start and end are the same"
  # a window that ends before it starts runs over midnight
  [ "${_e}" -gt "${start_s}" ] || _e=$((_e + 86400))
  length=$((_e - start_s))
}

# One cron job. $1 is an interface name, or "all" for every pppd at once. A
# window or a seed set for that name (RECONNECT_WINDOW_ppp1,
# RECONNECT_SEED_ppp1) replaces the general one.
plan() {
  _if="$1"
  _window="${RECONNECT_WINDOW}"
  _wvar='RECONNECT_WINDOW'
  _seed="${RECONNECT_SEED}"
  # the name was checked to hold only letters, digits and '_'
  eval "_w=\${RECONNECT_WINDOW_${_if}:-}"
  eval "_s=\${RECONNECT_SEED_${_if}:-}"
  if [ -n "${_w}" ]; then
    _window="${_w}"
    _wvar="RECONNECT_WINDOW_${_if}"
  fi
  if [ -n "${_s}" ]; then
    _seed="${_s}"
  fi
  parse_window "${_window}" "${_wvar}"

  # cksum is a CRC-32 of the text: stable, and spread evenly enough for this.
  # The interface name is part of it, so two WANs get two different times.
  hash="$(printf '%s' "$(machine_id)${_seed}${_if}" | cksum | cut -d ' ' -f 1)"
  at=$(((start_s + hash % length) % 86400))
  hour=$((at / 3600))
  minute=$((at % 3600 / 60))
  second=$((at % 60))
  at_text="$(printf '%02d:%02d:%02d' "${hour}" "${minute}" "${second}")"

  # pppd writes /var/run/<interface>.pid. The job logs to the journal (tag
  # pppoe-reconnect), also when there is nothing to signal, so a silent no-op
  # is visible. The level is warning, not the default notice: UniFi OS gives
  # cron.service LogLevelMax=warning, and journald drops a notice from a job
  # it can tie to that unit.
  if [ "${_if}" = all ]; then
    target='all pppd'
    # killall exits with an error when there is no pppd, and the job says so
    job="if ${killall_bin} -HUP pppd 2>/dev/null; then logger -p user.warning -t pppoe-reconnect \"scheduled daily reconnect of all pppd: SIGHUP sent\"; else logger -p user.warning -t pppoe-reconnect \"scheduled daily reconnect of all pppd skipped: no pppd found\"; fi"
  else
    target="${_if}"
    # The signal goes out only if the pid file names a running pppd: a stale
    # file must never send SIGHUP to an unrelated process.
    job="pid=\$(cat /var/run/${_if}.pid 2>/dev/null); if [ -n \"\$pid\" ] && [ \"\$(basename \"\$(ps -o comm= -p \"\$pid\" 2>/dev/null)\")\" = pppd ]; then logger -p user.warning -t pppoe-reconnect \"scheduled daily reconnect of ${_if}: SIGHUP to pppd \$pid\"; kill -HUP \"\$pid\"; else logger -p user.warning -t pppoe-reconnect \"scheduled daily reconnect of ${_if} skipped: no pppd behind /var/run/${_if}.pid\"; fi"
  fi
  cron_lines="${cron_lines}# ${target}: daily at ${at_text} local time, inside ${_window}
${minute} ${hour} * * * root sleep ${second}; ${job} >/dev/null 2>&1
"
  messages="${messages}pppoe-reconnect: daily reconnect of ${target} at ${at_text} local time, inside ${_window}
"
}

case "${RECONNECT_INTERFACES}" in
  *[!A-Za-z0-9_\ ]*) fail "RECONNECT_INTERFACES in ${conf} must be interface names separated by spaces, such as 'ppp0 ppp1', or 'all'; only letters, digits, '_' and spaces are accepted (no tabs), got '${RECONNECT_INTERFACES}'" ;;
esac
# shellcheck disable=SC2086
set -- ${RECONNECT_INTERFACES}
[ "$#" -gt 0 ] || fail "RECONNECT_INTERFACES in ${conf} is empty"
for _i in "$@"; do
  if [ "${_i}" = all ]; then
    [ "$#" -eq 1 ] || fail "RECONNECT_INTERFACES in ${conf}: 'all' cannot be combined with interface names"
    [ -x "${killall_bin}" ] || fail "RECONNECT_INTERFACES=all in ${conf} needs ${killall_bin}, which is not there"
  fi
done

cron_lines=''
messages=''
for _i in "$@"; do
  plan "${_i}"
done

# nothing is written before every entry has passed its checks
printf '%s' "# Daily PPPoE reconnect (written by /data/on_boot.d/21-pppoe-reconnect.sh)
${cron_lines}" > "${cron_file}"
chmod 644 "${cron_file}"

systemctl reload cron 2>/dev/null || systemctl restart cron
printf '%s' "${messages}"
