# shellcheck shell=dash
# Legacy setups: detection, takeover, and restore. Sourced by
# att-wpa-supplicant, which defines log, die, systemctl helpers, the paths,
# supplicant_pids, pid_unit, and stop_verified. Defines functions and two
# constants only. Running it does nothing.

KNOWN_TRIGGERS="0-att-bypass.sh 10-wpa_supplicant.sh"
# Words that look like interface names. They tell "names another
# interface" apart from "names no interface".
IFACE_WORD_RE='(^|[^A-Za-z0-9_]|-i)(eth|sfp|wan|enp|ens|eno|br)[0-9][A-Za-z0-9._-]*'

# instance: a templated supplicant unit. launcher: any other legacy unit.
# A launcher can start an instance.
unit_role() {
    case "$1" in
        wpa_supplicant-wired@*.service | wpa_supplicant@*.service) echo instance ;;
        *) echo launcher ;;
    esac
}

is_known_unit() {
    case "$1" in
        wpa_supplicant.service | setup-att-bypass.service | reinstall-wpa.service | \
            "wpa_supplicant-wired@$2.service" | "wpa_supplicant@$2.service") return 0 ;;
    esac
    return 1
}

# True if the unit is enabled (any form) or running.
unit_live() {
    local en ac
    en=$(systemctl is-enabled "$1" 2>/dev/null || true)
    ac=$(systemctl is-active "$1" 2>/dev/null || true)
    case "$en" in enabled | enabled-runtime | linked | linked-runtime | alias) return 0 ;; esac
    case "$ac" in active | activating | reloading | deactivating) return 0 ;; esac
    return 1
}

# Effective commands and environment of a unit, after drop-ins. Comments
# and overridden directives are not in this output.
unit_cmds() {
    systemctl show "$1" -p ExecStartPre -p ExecStart -p ExecStartPost \
        -p ExecReload -p Environment --value 2>/dev/null || true
}
# A script without its comment lines.
script_cmds() { sed '/^[[:space:]]*#/d' "$1"; }

# Classify text that starts a supplicant: ours, other, or none.
iface_scope() {
    if printf '%s\n' "$2" | grep -Eq "$(iface_re "$1")"; then
        echo ours
    elif printf '%s\n' "$2" | grep -Eq "$IFACE_WORD_RE"; then
        echo other
    else
        echo none
    fi
}

# Join two scopes. other wins over ours, and ours wins over none.
scope_join() {
    case "$1 $2" in
        *other*) echo other ;;
        *ours*) echo ours ;;
        *) echo none ;;
    esac
}

# Prints owners of <iface>, one per line:
#   unit <name> | trigger <file> | unknown <pid> <unit> | ambiguous <what>
# A known launcher counts even when it does not run now, because a dormant
# launcher starts at the next boot.
find_owners() {
    local i out p u t f sc cmds
    i=$1
    out=''
    add() {
        printf '%s\n' "$out" | grep -qxF "$1" || out="$out$1
"
    }
    for p in $(supplicant_pids "$i"); do
        u=$(pid_unit "$p")
        [ "$u" = "$(unit_of "$i")" ] && continue
        if [ -n "$u" ] && is_known_unit "$u" "$i"; then
            add "unit $u"
        else
            add "unknown $p ${u:-?}"
        fi
    done
    for u in "wpa_supplicant-wired@$i.service" "wpa_supplicant@$i.service"; do
        if unit_live "$u"; then add "unit $u"; fi
    done
    # reinstall-wpa.service (evie-lau guide) starts no supplicant itself.
    # It installs the package and starts wpa_supplicant-wired@<iface>.
    for u in wpa_supplicant.service setup-att-bypass.service reinstall-wpa.service; do
        unit_live "$u" || continue
        cmds=$(unit_cmds "$u")
        sc=$(iface_scope "$i" "$cmds")
        # If the unit runs the boot script, the script counts too. Evidence
        # for another interface from either source wins.
        if [ -f "$ONBOOT/0-att-bypass.sh" ] &&
            printf '%s\n' "$cmds" | grep -q '0-att-bypass\.sh'; then
            sc=$(scope_join "$sc" "$(iface_scope "$i" "$(script_cmds "$ONBOOT/0-att-bypass.sh")")")
        fi
        case "$sc" in
            ours | none) add "unit $u" ;;
            other) add "ambiguous $u names another interface" ;;
        esac
    done
    for t in $KNOWN_TRIGGERS; do
        f="$ONBOOT/$t"
        [ -f "$f" ] || continue
        case "$(iface_scope "$i" "$(script_cmds "$f")")" in
            ours | none) add "trigger $t" ;;
            other) add "ambiguous $t names another interface" ;;
        esac
    done
    printf '%s' "$out"
}

# Restore what takeover.state recorded. Refuse if our instance still runs.
# Keep the ledger unless every item was restored.
restore_legacy() {
    local i d kind a b c failed
    i=$1
    d=$(inst_dir "$i")
    [ -f "$d/takeover.state" ] || return 0
    if ! stop_verified "$(unit_of "$i")" "$i"; then
        log "$i: ERROR $(unit_of "$i") did not stop. NOT restoring the legacy setup (two supplicants would run)"
        return 1
    fi
    failed=0
    while read -r kind a b c; do
        case "$kind" in
            trigger)
                if [ -f "$d/quarantine/$a" ]; then
                    if mv "$d/quarantine/$a" "$ONBOOT/$a"; then
                        log "$i: restored boot trigger $a"
                    else
                        log "$i: ERROR cannot restore boot trigger $a"
                        failed=1
                    fi
                elif [ ! -f "$ONBOOT/$a" ]; then
                    log "$i: ERROR boot trigger $a is in neither quarantine nor on_boot.d"
                    failed=1
                fi
                ;;
            unit)
                case "$b" in
                    enabled) systemctl enable --quiet "$a" || { log "$i: ERROR cannot re-enable $a"; failed=1; } ;;
                    enabled-runtime) systemctl enable --runtime --quiet "$a" || { log "$i: ERROR cannot re-enable $a"; failed=1; } ;;
                    masked) systemctl mask --quiet "$a" || { log "$i: ERROR cannot re-mask $a"; failed=1; } ;;
                esac
                case "$c" in
                    active | activating | reloading)
                        systemctl start --no-block "$a" || { log "$i: ERROR cannot start $a"; failed=1; } ;;
                esac
                log "$i: restored unit $a ($b, $c)"
                ;;
        esac
    done <"$d/takeover.state"
    if [ "$failed" -ne 0 ]; then
        log "$i: legacy restore incomplete. Ledger kept at $d/takeover.state"
        return 1
    fi
    mv "$d/takeover.state" "$d/takeover.state.restored.$(date +%s)"
}

# Take over <iface> ($1) in instance dir $2 from the owners in $3 (the
# output of find_owners). Record everything first, then quarantine and stop.
# The caller arms the activate rollback before it calls this.
takeover_owners() {
    local i d owners kind a pass _b _c
    i=$1
    d=$2
    owners=$3
    mkdir -p "$d/quarantine"
    chmod 0700 "$d/quarantine"
    : >"$d/takeover.state"
    chmod 0600 "$d/takeover.state"
    printf '%s\n' "$owners" | while read -r kind a; do
        case "$kind" in
            unit) printf 'unit %s %s %s\n' "$a" "$(enabled_state "$a")" "$(active_state "$a")" \
                >>"$d/takeover.state" ;;
            trigger) printf 'trigger %s\n' "$a" >>"$d/takeover.state" ;;
        esac
    done
    # Quarantine triggers, then stop launchers, then the template
    # instances that launchers start. A launcher that runs can enable
    # or start an instance again (reinstall-wpa.service does both).
    while read -r kind a _b _c; do
        [ "$kind" = trigger ] || continue
        mv "$ONBOOT/$a" "$d/quarantine/$a"
        log "$i: quarantined boot trigger $a"
    done <"$d/takeover.state"
    for pass in launcher instance; do
        while read -r kind a _b _c; do
            [ "$kind" = unit ] || continue
            [ "$(unit_role "$a")" = "$pass" ] || continue
            stop_verified "$a" "$i" || die "$i: $a did not stop"
            systemctl disable --quiet "$a" || die "$i: cannot disable $a"
            log "$i: stopped and disabled $a"
        done <"$d/takeover.state"
    done
    # Confirm that no legacy unit was enabled or started again.
    while read -r kind a _b _c; do
        [ "$kind" = unit ] || continue
        if unit_live "$a"; then
            die "$i: $a is enabled or running again after takeover"
        fi
    done <"$d/takeover.state"
}
