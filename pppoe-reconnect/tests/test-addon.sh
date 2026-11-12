#!/bin/sh
# Tests for pppoe-reconnect. Runs the hook against a temporary conf and a
# temporary cron file, then runs the command of the generated cron job with
# stubs for logger, ps, kill and sleep. Nothing is written outside the
# temporary directory, no signal is sent, no cron is reloaded.
#
#   sh pppoe-reconnect/tests/test-addon.sh          # with sh
#   SHELL_UNDER_TEST=dash sh pppoe-reconnect/tests/test-addon.sh
#
# UniFi OS runs on_boot.d scripts with dash, so run it with dash too where you
# have it.
# A test runs, then check gets its exit status as $?; that is the point.
# shellcheck disable=SC2319
set -u

ADDON_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="${ADDON_DIR}/on_boot.d/21-pppoe-reconnect.sh"
SH_BIN="${SHELL_UNDER_TEST:-sh}"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT INT TERM
CONF="${TMP}/pppoe-reconnect.conf"
CRON="${TMP}/pppoe-reconnect.cron"
OUT="${TMP}/out"
ERR="${TMP}/err"
STUBS="${TMP}/bin"
RUN="${TMP}/run"
CALLS="${TMP}/calls"
mkdir "${STUBS}" "${RUN}"

# systemctl is called last by the hook; the stub only records it
cat > "${STUBS}/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "${CALLS}"
EOF
cat > "${STUBS}/logger" <<EOF
#!/bin/sh
echo "logger \$*" >> "${CALLS}"
EOF
cat > "${STUBS}/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
# ps -o comm= -p PID: prints $PS_COMM, or nothing when it is unset (no such
# process)
# killall: records its arguments, exits with $KILLALL_RC (default 0)
cat > "${STUBS}/killall" <<EOF
#!/bin/sh
echo "killall \$*" >> "${CALLS}"
exit "\${KILLALL_RC:-0}"
EOF
cat > "${STUBS}/ps" <<'EOF'
#!/bin/sh
if [ "${PS_COMM+x}" = x ]; then echo "${PS_COMM}"; fi
EOF
chmod +x "${STUBS}"/*

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() {
  fail=$((fail + 1))
  echo "FAIL: $1"
  [ -z "${2:-}" ] || echo "      $2"
}
check() { # check NAME CONDITION-EXIT-STATUS [DETAIL]
  if [ "$2" -eq 0 ]; then ok; else bad "$1" "${3:-}"; fi
}

# run the hook with the conf text given as $1; the exit status is in RC
run_hook() {
  rm -f "${CRON}" "${CALLS}"
  printf '%s\n' "$1" > "${CONF}"
  PATH="${STUBS}:${PATH}" PPPOE_RECONNECT_CONF="${CONF}" \
    PPPOE_RECONNECT_CRON_FILE="${CRON}" \
    PPPOE_RECONNECT_KILLALL="${KILLALL_BIN:-${STUBS}/killall}" \
    "${SH_BIN}" "${SCRIPT}" > "${OUT}" 2> "${ERR}"
  RC=$?
}

# seconds since midnight of the n-th job line in the cron file
job_time() {
  sed -n 's/^\([0-9][0-9]*\) \([0-9][0-9]*\) \* \* \* root sleep \([0-9][0-9]*\);.*/\1 \2 \3/p' "${CRON}" \
    | sed -n "${1}p" | { read -r m h s && echo $((h * 3600 + m * 60 + s)); }
}
job_count() { grep -c '^[0-9][0-9]* [0-9][0-9]* \* \* \* root ' "${CRON}"; }
# from <= t < to, in seconds; a window that ends before it starts wraps midnight
in_window() { # in_window T FROM TO
  if [ "$2" -lt "$3" ]; then
    [ "$1" -ge "$2" ] && [ "$1" -lt "$3" ]
  else
    [ "$1" -ge "$2" ] || [ "$1" -lt "$3" ]
  fi
}
hms() { echo $(($1 * 3600 + $2 * 60)); }

# --- defaults ---------------------------------------------------------------
run_hook ''
[ "${RC}" -eq 0 ]
check "defaults: exit status 0" $?
[ -f "${CRON}" ] && [ "$(job_count)" -eq 1 ]
check "defaults: one job" $?
t=$(job_time 1)
in_window "${t}" "$(hms 3 0)" "$(hms 4 0)"
check "defaults: time inside 03:00-04:00" $? "got ${t} s"
grep -q '/var/run/ppp0.pid' "${CRON}"
check "defaults: the job reads /var/run/ppp0.pid" $?
grep -q 'ppp0 at [0-9:]* local time, inside 03:00-04:00' "${OUT}"
check "defaults: the hook prints the time it chose, as local time" $?
grep -q '^# ppp0: daily at [0-9:]* local time' "${CRON}"
check "defaults: the cron file says local time" $?
case "$(ls -l "${CRON}")" in -rw-r--r--*) m=0 ;; *) m=1 ;; esac
check "defaults: cron file is mode 644" "${m}"
grep -q '^systemctl ' "${CALLS}"
check "defaults: cron is reloaded or restarted" $?

# --- stable, and seed -------------------------------------------------------
cp "${CRON}" "${TMP}/first"
run_hook ''
cmp -s "${CRON}" "${TMP}/first"
check "stable: a second run gives the same file" $?

base=$(job_time 1)
moved=0
for s in a b c d e f; do
  run_hook "RECONNECT_SEED=\"${s}\""
  [ "$(job_time 1)" != "${base}" ] && moved=1
done
[ "${moved}" -eq 1 ]
check "seed: a seed moves the time" $?

# --- window -----------------------------------------------------------------
run_hook 'RECONNECT_WINDOW="22:00-23:00"'
t=$(job_time 1)
in_window "${t}" "$(hms 22 0)" "$(hms 23 0)"
check "window: 22:00-23:00" $? "got ${t} s"

# a window over midnight: every seed must land inside it, and both sides of
# midnight must be reached, or the wrap is not working
before=0
after=0
inside=0
for s in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  run_hook "RECONNECT_WINDOW=\"23:30-00:30\"
RECONNECT_SEED=\"${s}\""
  t=$(job_time 1)
  if in_window "${t}" "$(hms 23 30)" "$(hms 0 30)"; then inside=$((inside + 1)); fi
  if [ "${t}" -ge "$(hms 23 30)" ]; then before=$((before + 1)); fi
  if [ "${t}" -lt "$(hms 0 30)" ]; then after=$((after + 1)); fi
done
[ "${inside}" -eq 30 ]
check "midnight: all 30 seeds inside 23:30-00:30" $? "${inside} of 30"
[ "${before}" -gt 0 ] && [ "${after}" -gt 0 ]
check "midnight: times before and after midnight both occur" $? "before ${before}, after ${after}"

# 08 and 09 must not be read as octal
run_hook 'RECONNECT_WINDOW="08:00-09:00"'
t=$(job_time 1)
check "octal: 08:00-09:00 is accepted" $RC
in_window "${t}" "$(hms 8 0)" "$(hms 9 0)"
check "octal: time inside 08:00-09:00" $? "got ${t} s"

# --- interfaces -------------------------------------------------------------
run_hook 'RECONNECT_INTERFACES="ppp0 ppp1"'
check "interfaces: two names are accepted" $RC
[ "$(job_count)" -eq 2 ]
check "interfaces: two jobs" $?
grep -q '/var/run/ppp1.pid' "${CRON}"
check "interfaces: the second job reads /var/run/ppp1.pid" $?

run_hook 'RECONNECT_INTERFACES="ppp0 ppp1"
RECONNECT_WINDOW_ppp1="05:00-06:00"'
t0=$(job_time 1)
t1=$(job_time 2)
in_window "${t0}" "$(hms 3 0)" "$(hms 4 0)"
check "per interface: ppp0 keeps the general window" $? "got ${t0} s"
in_window "${t1}" "$(hms 5 0)" "$(hms 6 0)"
check "per interface: ppp1 uses its own window" $? "got ${t1} s"

run_hook 'RECONNECT_INTERFACES="ppp0 ppp1"'
b0=$(job_time 1)
b1=$(job_time 2)
run_hook 'RECONNECT_INTERFACES="ppp0 ppp1"
RECONNECT_SEED_ppp1="x"'
[ "$(job_time 1)" = "${b0}" ]
check "per interface seed: ppp0 does not move" $?
[ "$(job_time 2)" != "${b1}" ]
check "per interface seed: ppp1 moves" $?

# --- validation: nothing is written, the message names the variable ---------
expect_refusal() { # expect_refusal NAME CONF VARIABLE
  run_hook "$2"
  [ "${RC}" -eq 1 ]
  check "$1: exit status 1" $? "status ${RC}"
  [ ! -e "${CRON}" ]
  check "$1: no cron file written" $?
  grep -q "$3" "${ERR}"
  check "$1: the message names $3" $? "$(cat "${ERR}")"
}
expect_refusal "window 25:00" 'RECONNECT_WINDOW="25:00-26:00"' RECONNECT_WINDOW
expect_refusal "window without leading zero" 'RECONNECT_WINDOW="3:00-4:00"' RECONNECT_WINDOW
expect_refusal "window with minute 60" 'RECONNECT_WINDOW="03:60-04:00"' RECONNECT_WINDOW
expect_refusal "empty window" 'RECONNECT_WINDOW="03:00-03:00"' RECONNECT_WINDOW
expect_refusal "window with text" 'RECONNECT_WINDOW="night"' RECONNECT_WINDOW
expect_refusal "per-interface window" 'RECONNECT_INTERFACES="ppp0 ppp1"
RECONNECT_WINDOW_ppp1="9-10"' RECONNECT_WINDOW_ppp1
expect_refusal "semicolon in an interface" 'RECONNECT_INTERFACES="ppp0;reboot"' RECONNECT_INTERFACES
expect_refusal "command substitution in an interface" "RECONNECT_INTERFACES='\$(true)'" RECONNECT_INTERFACES
expect_refusal "slash in an interface" 'RECONNECT_INTERFACES="../ppp0"' RECONNECT_INTERFACES
expect_refusal "tab between interfaces" 'RECONNECT_INTERFACES="ppp0	ppp1"' RECONNECT_INTERFACES
grep -q 'spaces' "${ERR}"
check "tab between interfaces: the message says spaces" $?
expect_refusal "empty interfaces" 'RECONNECT_INTERFACES=""' RECONNECT_INTERFACES
expect_refusal "blank interfaces" 'RECONNECT_INTERFACES="   "' RECONNECT_INTERFACES

# an existing cron file survives a refused run
printf 'old\n' > "${CRON}"
printf '%s\n' 'RECONNECT_WINDOW="nope"' > "${CONF}"
PATH="${STUBS}:${PATH}" PPPOE_RECONNECT_CONF="${CONF}" PPPOE_RECONNECT_CRON_FILE="${CRON}" \
  "${SH_BIN}" "${SCRIPT}" > "${OUT}" 2> "${ERR}"
[ "$(cat "${CRON}")" = old ]
check "refused run: the old cron file is untouched" $?

# --- all --------------------------------------------------------------------
run_hook 'RECONNECT_INTERFACES="all"'
check "all: exit status 0" "${RC}"
[ "$(job_count)" -eq 1 ]
check "all: one job" $?
grep -q "${STUBS}/killall -HUP pppd" "${CRON}"
check "all: the job calls killall -HUP pppd" $?
! grep -q '/var/run/' "${CRON}"
check "all: no pid file involved" $?
t=$(job_time 1)
in_window "${t}" "$(hms 3 0)" "$(hms 4 0)"
check "all: time inside 03:00-04:00" $? "got ${t} s"
grep -q 'all pppd' "${OUT}"
check "all: the hook prints the time it chose" $?

expect_refusal "all with an interface name" 'RECONNECT_INTERFACES="ppp0 all"' RECONNECT_INTERFACES
grep -q "'all' cannot be combined" "${ERR}"
check "all with an interface name: the message says why" $?
KILLALL_BIN="${TMP}/no-such-killall"
expect_refusal "all without killall" 'RECONNECT_INTERFACES="all"' RECONNECT_INTERFACES
grep -q 'no-such-killall' "${ERR}"
check "all without killall: the message names the missing file" $?
unset KILLALL_BIN
# a missing killall is no problem for interface names
KILLALL_BIN="${TMP}/no-such-killall"
run_hook 'RECONNECT_INTERFACES="ppp0"'
check "interface names do not need killall" "${RC}"
unset KILLALL_BIN

# --- the job ----------------------------------------------------------------
# The command is the cron line without its five time fields, "root" and the
# sleep, and without the redirect at the end. /var/run is pointed at a
# temporary directory.
run_job() { # run_job PID_FILE_CONTENT(or -) PS_COMM(or -)
  run_hook ''
  job=$(sed -n 's/^[0-9][0-9]* [0-9][0-9]* \* \* \* root sleep [0-9][0-9]*; \(.*\) >\/dev\/null 2>&1$/\1/p' "${CRON}" | sed -n 1p)
  job=$(printf '%s' "${job}" | sed "s#/var/run/#${RUN}/#g")
  rm -f "${RUN}/ppp0.pid" "${CALLS}"
  [ "$1" = - ] || printf '%s\n' "$1" > "${RUN}/ppp0.pid"
  if [ "$2" = - ]; then unset PS_COMM; else PS_COMM="$2"; export PS_COMM; fi
  # kill is a shell builtin, so a file in PATH would not be used: it is
  # replaced by a function in front of the job, and no signal is ever sent
  PATH="${STUBS}:${PATH}" "${SH_BIN}" -c "kill() { echo \"kill \$*\" >> \"${CALLS}\"; }; ${job}"
  JOB_RC=$?
  unset PS_COMM
}

run_job 4242 /usr/sbin/pppd
check "job, running pppd: exit status 0" "${JOB_RC}"
grep -q '^kill -HUP 4242$' "${CALLS}"
check "job, running pppd: SIGHUP goes to the pid" $? "$(cat "${CALLS}" 2>/dev/null)"
grep -q '^logger .*scheduled daily reconnect of ppp0: SIGHUP to pppd 4242' "${CALLS}"
check "job, running pppd: logs the reconnect with the pid" $?
grep '^logger ' "${CALLS}" | grep -q -- '-p user.warning'
check "job, running pppd: logs at warning (cron.service has LogLevelMax=warning)" $?

run_job 4242 sshd
! grep -q '^kill ' "${CALLS}" 2> /dev/null
check "job, other process: no signal" $?
grep -q '^logger .*ppp0 skipped: no pppd behind' "${CALLS}"
check "job, other process: logs that nothing was reconnected" $?
grep '^logger ' "${CALLS}" | grep -q -- '-p user.warning'
check "job, other process: logs at warning" $?

run_job 4242 -
! grep -q '^kill ' "${CALLS}" 2> /dev/null
check "job, dead pid: no signal" $?

run_job - -
! grep -q '^kill ' "${CALLS}" 2> /dev/null
check "job, no pid file: no signal" $?
grep -q '^logger .*ppp0 skipped: no pppd behind' "${CALLS}"
check "job, no pid file: logs that nothing was reconnected" $?

run_job '' /usr/sbin/pppd
! grep -q '^kill ' "${CALLS}" 2> /dev/null
check "job, empty pid file: no signal" $?

# the job of "all": the command is the one in the cron line, killall is the stub
run_all_job() { # run_all_job KILLALL_EXIT_STATUS
  run_hook 'RECONNECT_INTERFACES="all"'
  job=$(sed -n 's/^[0-9][0-9]* [0-9][0-9]* \* \* \* root sleep [0-9][0-9]*; \(.*\) >\/dev\/null 2>&1$/\1/p' "${CRON}" | sed -n 1p)
  rm -f "${CALLS}"
  PATH="${STUBS}:${PATH}" KILLALL_RC="$1" "${SH_BIN}" -c "${job}"
  JOB_RC=$?
}
run_all_job 0
check "job all, pppd running: exit status 0" "${JOB_RC}"
grep -q '^killall -HUP pppd$' "${CALLS}"
check "job all, pppd running: killall -HUP pppd" $?
grep -q '^logger .*scheduled daily reconnect of all pppd: SIGHUP sent' "${CALLS}"
check "job all, pppd running: logs the reconnect" $?
grep '^logger ' "${CALLS}" | grep -q -- '-p user.warning'
check "job all, pppd running: logs at warning" $?

run_all_job 1
grep -q '^logger .*of all pppd skipped: no pppd found' "${CALLS}"
check "job all, no pppd: logs that nothing was reconnected" $?
! grep -q 'SIGHUP sent' "${CALLS}"
check "job all, no pppd: does not log a reconnect" $?
grep '^logger ' "${CALLS}" | grep -q -- '-p user.warning'
check "job all, no pppd: logs at warning" $?

echo "pppoe-reconnect tests (${SH_BIN}): ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
