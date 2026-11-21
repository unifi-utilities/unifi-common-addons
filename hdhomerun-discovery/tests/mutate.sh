#!/bin/sh
# shellcheck disable=SC2016 # the sed scripts are single-quoted on purpose
# Mutation check. For each deliberate fault, run the matching suite against
# a faulty copy: tests/run.sh for the control script, tests/proxy-netns.sh
# for proxy.pl. The suite must fail, and it must name the assertion that
# this fault should break.
# Usage: tests/mutate.sh [script|proxy]   Exit 0 only when every fault is caught.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ONLY=${1:-}
TOP=$(mktemp -d) || exit 1
trap 'rm -rf -- "${TOP:?}"' EXIT
total=0
missed=0

# try KIND EXPECTED-FAILURE-TEXT SED-SCRIPT...
try() {
    kind=$1 want=$2; shift 2
    [ -z "$ONLY" ] || [ "$ONLY" = "$kind" ] || return 0
    total=$((total + 1))
    if [ "$kind" = script ]; then src="$HERE/../hdhomerun-discovery"; else src="$HERE/../proxy.pl"; fi
    cp "$src" "$TOP/m"
    for e in "$@"; do sed -i "$e" "$TOP/m"; done
    if cmp -s "$src" "$TOP/m"; then
        echo "NO-OP   $want (the sed script changed nothing)"; missed=$((missed + 1)); return
    fi
    if [ "$kind" = script ]; then
        out=$(HDHR_SCRIPT="$TOP/m" "$HERE/run.sh" 2>&1); rc=$?
        tag="FAIL: $want"
    else
        out=$(timeout 200 sh "$HERE/proxy-netns.sh" "$TOP/m" 2>&1); rc=$?
        tag="FAIL $want"
    fi
    if [ "$rc" -eq 0 ]; then
        echo "MISSED  $want (suite passed on the faulty copy)"; missed=$((missed + 1))
    elif printf '%s\n' "$out" | grep -qF -- "$tag"; then
        echo "caught  $want"
    else
        echo "WRONG   $want (suite failed, but not on this assertion)"
        printf '%s\n' "$out" | grep 'FAIL' | head -3
        missed=$((missed + 1))
    fi
}
m() { try script "$@"; }
p() { try proxy "$@"; }

# ---------- control script: config ----------
m "missing CLIENTS" 's~\[ "$count" -ge 1 \] || { err "$key is empty"; return 1; }~:~'
m "one interface as client and tuner" 's~\*" \$d "\*) set +f; err "interface~*" XX "*) set +f; err "interface~'
m "unknown key" 's~unknown key \$key"; return 1~unknown key $key"; true~'
m "a key set twice" 's~is set twice"; return 1 ;;~is set twice"; true ;;~'
m "bad interface name" 's~\*\[!A-Za-z0-9_.@-\]\*)~*[!A-Za-z0-9_.@:-]*)~'
m "interface name over 15 characters" 's~\[ "${#d}" -le 15 \] ||~true ||~'
# ---------- control script: gateway state ----------
m "interface is down" 's~\[ \$((flags \& 1)) -eq 1 \] ||~true ||~'
m "loopback interface" 's~\[ \$((flags \& 8)) -eq 0 \] ||~true ||~'
m "interface without an IPv4 address" 's~\[ -n "\$a" \] || { err "interface~true || { err "interface~'
m "proxy.pl missing" 's~\[ -f "\$PROXY" \] || {~true || {~'
m "proxy.pl does not compile" 's~perl -c "\$PROXY" >/dev/null 2>&1 ||~true ||~'
m "an interface with a default route (the WAN)" '/holds a default route/s~; return 1 ;; esac~; true ;; esac~'
m "precheck fails when ss cannot check the port" 's~held=\$(port_holder) || {~held=$(port_holder) || true || {~'
m "setup never lists an interface with a default route" 's~case "\$wans " in \*" \${name%%@\*} "\*) continue ;; esac~:~'
m "another program holds UDP 65001" 's~if \[ -n "\$held" \] \&\& ! systemctl~if false \&\& ! systemctl~'
m "UDP 65001 held while our own unit is active is fine" 's~ \&\& ! systemctl is-active --quiet "\$UNIT_NAME"; then~; then~'
m "precheck with a symlinked addon home" 's~^    \[ ! -L "\$DATA" \] ||~    true ||~'
m "enable did not write through the symlink" 's~^    \[ ! -L "\$ACTIVE" \] ||~    true ||~'
# ---------- control script: run, probe, enable, disable, boot ----------
m "run passes each client and tuner network to the proxy" 's~set -- "\$@" --client "\$d"~set -- "$@" --client br0~'
m "run checks the config again" '/# Check again: the config may have changed/{n;s~cmd_precheck || exit 1~parse_conf || exit 1~}'
m "probe asks the proxy about the tuner networks only" 's~for d in \$names; do~for d in $names br0; do~'
m "enable marks the proxy active" 's~^    : >"\$ACTIVE"$~    :~'
m "a failed enable leaves no active mark" 's~cmd_precheck || die "not enabling"~cmd_precheck || true~'
m "a failed stop keeps the active mark" 's~|| die "could not stop \$UNIT_NAME; it stays enabled"~|| true~'
m "uninstall fails when the stop fails" 's~|| die "could not stop \$UNIT_NAME; nothing was removed"~|| true~'
m "boot starts the proxy when enabled" 's~systemctl start --no-block "\$UNIT_NAME"~: start~'
m "boot starts nothing when not enabled" 's~if \[ -f "\$ACTIVE" \] \&\& \[ ! -L "\$ACTIVE" \]; then~if true; then~'
m "boot restores a unit that a firmware update removed" 's~if \[ -d "\$DATA" \] \&\& install_unit; then reload; fi~:~'
m "boot fails and writes nothing while another command holds the lock" '/^cmd_boot() {/,/^}/s~^    lock$~    :~'
m "enable fails and marks nothing while another command holds the lock" '/^cmd_enable() {/,/^}/s~^    lock$~    :~'
m "uninstall removes the addon directory" 's~rm -rf "\${DATA:?}"~:~'
# ---------- control script: install and temporary files ----------
m "install without proxy.pl writes no addon home" 's~for f in "\$self/\$PROG" "\$self/proxy.pl" ~for f in "$self/$PROG" ~'
m "install copies the proxy" 's~put 0644 "\$self/proxy.pl" "\$PROXY" || true~:~'
m "install without proxy.pl says that nothing changed" 's~ Nothing changed."~"~'
m "boot removes a stale temporary boot entry" '/^    no_args boot/,/^    clean_tmp$/{/^    clean_tmp$/d}'
m "boot removes a stale temporary proxy" 's~"\$PROXY".new.\* ~~'
m "boot keeps a file whose suffix is not a process ID" 's~\*\[!0-9\]\*) continue ;; esac~*.*) continue ;; esac~'
m "boot keeps another addon's temporary boot entry" 's~"\$ONBOOT/\$ONBOOT_NAME".new.\* "\$UNITS~"$ONBOOT"/*.new.* "$UNITS~'
m "boot keeps a file that it never writes" 's~"\$CONF".new.\*; do~"$DATA"/*.new.*; do~'
m "boot leaves no temporary unit after a failed copy" 's~        rm -f "\$tmp"$~        :~'
m "boot fails when the unit directory cannot be made" 's~|| die "cannot create the directory of \$3"~|| return 0~'
m "install links the command into /usr/local/sbin" '/^    install_onboot$/{n;s~^    install_link$~    :~}'
m "the command works through the link" 's~self=\$(cd "\$(dirname "\$(readlink -f "\$0")")" \&\& pwd -P)~self=$(cd "$(dirname "$0")" \&\& pwd -P)~'
m "boot restores the command link" 's~^    \[ ! -d "\$DATA" \] || install_link$~    :~'
m "uninstall removes the command link" 's~then rm -f "\$LINK"; fi~then :; fi~'
m "install and uninstall leave a file that is not their link" 's~if \[ -e "\$LINK" \] \&\& \[ ! -L "\$LINK" \]; then~if false; then~'
m "with umask 077 every directory in the home is 755" 's~^umask 022$~:~'
m "install warns when a parent directory is closed to other users" 's~^    check_path_open$~    :~'
m "install refuses a symlinked addon home" '/^    # The directory of the real script/,/^    clean_tmp$/s~^    need_home$~    :~'
m "boot deletes nothing through a symlinked addon home" '/^cmd_boot() {/,/^}/s~^    need_home$~    :~'
m "boot puts nothing into that directory" 's~\[ ! -d "\$3" \] || die "\$3 is a directory~true || die "$3 is a directory~'
m "boot does not change a file through that symlink" 's~\[ ! -L "\$3" \] || die "\$3 is a symlink~true || die "$3 is a symlink~'
m "with umask 077 the config from setup is 644" 's~chmod 0644 "\$CONF.new.\$\$" \&\& mv~mv~' 's~^umask 022$~:~'
# ---------- control script: setup ----------
m "setup writes the chosen client networks" 's~clients=\$picked~clients=br0~'
m "setup refuses the tuner network as an app network" 's~\[ -z "\$clash" \] \&\& break~break~'
m "setup asks again after a number not in the list or a word" 's~\[ -n "\$name" \] || { okay=0; break; }~:~'
m "setup explains the firewall rule when no tuner answers" 's~^        firewall_help "\$tuners"$~        :~'
m "setup keeps an existing config by default" 's~confirm "Replace it? \[y/N\] " n ||~confirm "Replace it? [y/N] " y ||~'
m "setup enables the proxy" 's~^        do_enable$~        :~'
m "setup without a start enables nothing" 's~if confirm "Start it now, and after each reboot? \[Y/n\] " y; then~if true; then~'
m "setup shows the tuners that answer" 's~^    perl "\$PROXY" --probe "\$@"$~    perl "$PROXY" --probe "$@" >/dev/null~'

# ---------- proxy ----------
p "2:" 's~my (\$cdev, \$csock, \$from, \$data, \$now) = @_;~&\n    $::last = $from;~' 's~MSG_DONTWAIT, \$p->{app})~MSG_DONTWAIT, $::last)~'
p "3: badcrc" 's~return undef if crc32(~return undef if 0 \&\& crc32(~'
p "3: answer" 's~unless (defined \$type \&\& \$type == TYPE_REQ) {~unless (defined $type) {~'
p "4:" 's~return 0 if \$b->\[0\] < 1;~return 1;~'
p "6:" 's~return 0 unless \$port == PORT \&\& in_nets~return 0 unless in_nets~'
p "6b:" 's~return defined \$type \&\& \$type == TYPE_RPY;~return 1;~'
p "6c:" 's~if (keys(%pending) + @tuners > \$max_pending) {~if (0) {~'
p "6d:" 's~drop_pending(\$fd) if \$pending{\$fd}{until} <= \$now~drop_pending($fd) if 0~'
p "9:" 's~if (ifindex(\$_) ne \$idx{\$_}) {~if (0) {~'

echo "$((total - missed)) of $total faults caught"
[ "$missed" -eq 0 ]
