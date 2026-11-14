#!/bin/sh
# shellcheck disable=SC2015,SC2155 # ok/bad never fail; test-only exports
# Off-box tests for att-wpa-supplicant. Needs: sh, coreutils, dpkg-deb,
# flock, openssl. Stubs systemctl, apt-get, dpkg, and dpkg-query. The bundle
# packages hold fake wpa_supplicant and wpa_cli scripts that act like the
# loader: they fail unless LD_LIBRARY_PATH finds libpcsclite.so.1.
# Usage: tests/run.sh
# No set -e, so that a failing command under test does not stop the suite.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../att-wpa-supplicant"
REAL_DPKG=$(command -v dpkg)
PASS=0
FAIL=0
TOP=$(mktemp -d) || { echo "cannot create a temp dir; aborting" >&2; exit 1; }
case "$TOP" in /?*/?*) ;; *) echo "unsafe temp dir '$TOP'; aborting" >&2; exit 1 ;; esac
[ -d "$TOP" ] && [ -w "$TOP" ] || { echo "temp dir not writable; aborting" >&2; exit 1; }
trap 'rm -rf -- "${TOP:?}"' EXIT

# ---------- fixture ----------

setup() {
    T="$TOP/$1"
    R="$T/root"
    S="$T/state"
    B="$T/bin"
    mkdir -p "$R/data/on_boot.d" "$R/etc/systemd/system" "$R/proc" "$R/sys/class/net/eth8" \
        "$R/usr/sbin" "$R/sbin" "$R/run" "$S/pkgs" "$S/ver" "$S/units" "$S/fail" "$B" "$T/src"
    printf 'PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"\nVERSION_CODENAME=bullseye\n' >"$R/etc/os-release"
    export ATT_WPA_ROOT="$R" ATT_WPA_OWNER_UID="$(id -u)" ATT_WPA_TAKEOVER_TIMEOUT=2 \
        ATT_WPA_POLL=1 ATT_WPA_STOP_WAIT=1 \
        STUB_STATE="$S" STUB_ROOT="$R" STUB_REAL_DPKG="$REAL_DPKG" STUB_SCRIPT="$SCRIPT"
    PATH="$B:$ORIG_PATH"
    export PATH
    write_stubs
    # Base packages that the "firmware" has.
    pkg libc6 ii 2.31-13
    pkg libssl1.1 ii 1.1.1w-0
    "$SCRIPT" install >/dev/null 2>&1 || true
    # Credentials, as extracted from a BGW.
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/src/PrivateKey_PKCS1_001E46-1.pem" \
        -out "$T/src/Client_001E46-1.pem" -days 30 -subj /CN=test >/dev/null 2>&1
    cp "$T/src/Client_001E46-1.pem" "$T/src/CA_001E46-1.pem"
    printf 'eapol_version=1\nnetwork={\n  identity="AA:BB:CC:DD:EE:FF"\n}\n' >"$T/src/wpa_supplicant.conf"
}

pkg() { printf '%s' "$2" >"$S/pkgs/$1"; printf '%s' "$3" >"$S/ver/$1"; }
unit() { printf '%s' "$2" >"$S/units/$1.enabled"; printf '%s' "$3" >"$S/units/$1.active"; }
state_of() { cat "$S/units/$1.$2" 2>/dev/null || echo none; }
fail_next() { : >"$S/fail/$1-$2"; } # verb unit

# A Debian wpasupplicant package installed on the system, as the firmware
# or a legacy setup left it. The addon must never run this binary.
system_supplicant() {
    pkg wpasupplicant ii 2:2.9.0-21
    printf '/sbin/wpa_supplicant wpasupplicant\n' >"$S/owners"
    cp "$B/fake-wpa_supplicant" "$R/sbin/wpa_supplicant"
    cp "$B/fake-wpa_cli" "$R/sbin/wpa_cli"
}

# A bundle for this release with the two runtime packages.
bundle_ready() {
    mkbundle "$(mkdeb libpcsclite1 1.9.1-1)" "$(mkdeb wpasupplicant 2:2.9.0-21)"
}

# mkdeb name version [extra control lines] -> path. Environment:
# DEB_SBIN (sbin or usr/sbin), DEB_ARCH, DEB_WPA and DEB_CLI (the fake
# binaries to pack),
# DEB_UMASK (default 022, as in Debian packages), DEB_NOLIB (libpcsclite1
# without a library file).
mkdeb() (
    umask "${DEB_UMASK:-022}"
    d="$T/debs/$1"
    rm -rf "$d"
    mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@t>\nDescription: t\n%s' \
        "$1" "$2" "${DEB_ARCH:-arm64}" "${3:-}" >"$d/DEBIAN/control"
    case "$1" in
        wpasupplicant)
            mkdir -p "$d/${DEB_SBIN:-usr/sbin}" "$d/lib/systemd/system"
            cp "${DEB_WPA:-$B/fake-rt-wpa_supplicant}" "$d/${DEB_SBIN:-usr/sbin}/wpa_supplicant"
            cp "${DEB_CLI:-$B/fake-rt-wpa_cli}" "$d/${DEB_SBIN:-usr/sbin}/wpa_cli"
            : >"$d/lib/systemd/system/wpa_supplicant.service"
            ;;
        libpcsclite1)
            mkdir -p "$d/usr/lib/aarch64-linux-gnu" "$d/usr/share/doc/libpcsclite1"
            if [ -z "${DEB_NOLIB:-}" ]; then
                : >"$d/usr/lib/aarch64-linux-gnu/libpcsclite.so.1.0.0"
                ln -s libpcsclite.so.1.0.0 "$d/usr/lib/aarch64-linux-gnu/libpcsclite.so.1"
            fi
            ;;
        *)
            mkdir -p "$d/usr/lib/aarch64-linux-gnu"
            : >"$d/usr/lib/aarch64-linux-gnu/$1.so"
            ;;
    esac
    dpkg-deb --root-owner-group -b "$d" "$T/debs/$1_$2_arm64.deb" >/dev/null
    printf '%s' "$T/debs/$1_$2_arm64.deb"
)

# mkbundle debs... A bundle as import-bundle leaves it: the packages,
# SHA256SUMS, MANIFEST, and root (the runtime packages unpacked, with no
# check). MKB_NOROOT=1: no root (never unpacked).
mkbundle() {
    b="$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64"
    mkdir -p "$b"
    for f in "$@"; do cp "$f" "$b/"; done
    (cd "$b" && sha256sum -- *.deb >SHA256SUMS)
    {
        printf 'codename=bullseye\narch=arm64\n'
        for f in "$b"/*.deb; do printf 'pkg=%s %s\n' "$(dpkg-deb -f "$f" Package)" "$(dpkg-deb -f "$f" Version)"; done
    } >"$b/MANIFEST"
    [ -z "${MKB_NOROOT:-}" ] || return 0
    mkdir -m 0700 "$b/root"
    for f in "$b"/*.deb; do
        case "$(dpkg-deb -f "$f" Package)" in wpasupplicant | libpcsclite1) dpkg-deb -x "$f" "$b/root" ;; esac
    done
}

fake_proc() { # pid cgroup-unit args...
    p="$R/proc/$1"
    mkdir -p "$p"
    printf '0::/system.slice/%s\n' "$2" >"$p/cgroup"
    shift 2
    printf '%s\0' "$@" >"$p/cmdline"
}

write_stubs() {
    cat >"$B/logger" <<'EOF'
#!/bin/sh
echo "$*" >>"$STUB_STATE/logger.log"
EOF
    cat >"$B/dpkg-query" <<'EOF'
#!/bin/sh
S=$STUB_STATE
case "$1" in
  -W)
    fmt=$2; name=${3:-}
    if [ -z "$name" ]; then
      for f in "$S"/pkgs/*; do
        [ -e "$f" ] || continue
        n=${f##*/}; printf '%s %s %s\n' "$n" "$(cat "$S/ver/$n" 2>/dev/null)" "$(cat "$f")"
      done
      exit 0
    fi
    case "$fmt" in
      *Status*) [ -f "$S/pkgs/$name" ] || exit 1; cat "$S/pkgs/$name"; printf ' \n' ;;
      *Version*) [ -f "$S/ver/$name" ] || exit 1; cat "$S/ver/$name" ;;
    esac ;;
  -S)
    [ -f "$S/owners" ] || exit 1
    m=$(awk -v p="$2" '$1==p {print $2}' "$S/owners")
    [ -n "$m" ] || exit 1
    printf '%s: %s\n' "$m" "$2" ;;
esac
EOF
    cat >"$B/dpkg" <<'EOF'
#!/bin/sh
case "$1" in
  --print-architecture) echo arm64 ;;
  --compare-versions) exec "$STUB_REAL_DPKG" "$@" ;;
  --audit) cat "$STUB_STATE/audit" 2>/dev/null; exit 0 ;;
  --configure)
    echo "dpkg $*" >>"$STUB_STATE/dpkg.log"
    # $S/configure-fixes: dpkg --configure finishes an unpacked wpasupplicant.
    if [ -f "$STUB_STATE/configure-fixes" ]; then
      printf ii >"$STUB_STATE/pkgs/wpasupplicant"
      printf '/sbin/wpa_supplicant wpasupplicant\n' >"$STUB_STATE/owners"
      cp "$(dirname "$0")/fake-wpa_supplicant" "$STUB_ROOT/sbin/wpa_supplicant"
      cp "$(dirname "$0")/fake-wpa_cli" "$STUB_ROOT/sbin/wpa_cli"
    fi ;;
  *) echo "dpkg $*" >>"$STUB_STATE/dpkg.log" ;;
esac
EOF
    # systemctl: real exit codes. stop and --now kill the fake processes of
    # the unit. $S/fail/<verb>-<unit> makes that verb fail for that unit.
    cat >"$B/systemctl" <<'EOF'
#!/bin/sh
S=$STUB_STATE
echo "$*" >>"$S/systemctl.log"
q=0; now=0; rt=0; args=''
for a in "$@"; do
  case "$a" in --quiet|-q) q=1 ;; --now) now=1 ;; --runtime) rt=1 ;; --no-block) ;; *) args="$args $a" ;; esac
done
set -- $args
cmd=$1; shift
killprocs() {
  for p in "$STUB_ROOT"/proc/[0-9]*; do
    [ -f "$p/cgroup" ] || continue
    case "$(cat "$p/cgroup")" in */"$1") rm -r -- "${p:?}" ;; esac
  done
}
stopu() {
  [ ! -f "$S/fail/stop-$1" ] || return 1
  [ ! -f "$S/hook/stop-$1" ] || sh "$S/hook/stop-$1"
  [ ! -f "$S/units/$1.active" ] || echo inactive >"$S/units/$1.active"
  killprocs "$1"
  # RuntimeDirectory (the control socket): systemd deletes it at stop.
  case "$1" in att-wpa-supplicant@*.service)
    i=${1#att-wpa-supplicant@}; i=${i%.service}
    rm -rf -- "$STUB_ROOT/run/att-wpa-supplicant/$i" ;;
  esac
}
rc=0
case "$cmd" in
  is-enabled)
    [ -f "$S/units/$1.enabled" ] || exit 1
    st=$(cat "$S/units/$1.enabled"); [ "$q" = 1 ] || echo "$st"
    case "$st" in enabled|enabled-runtime|static|alias) exit 0 ;; *) exit 1 ;; esac ;;
  is-active)
    st=inactive; [ ! -f "$S/units/$1.active" ] || st=$(cat "$S/units/$1.active")
    [ "$q" = 1 ] || echo "$st"
    [ "$st" = active ] && exit 0 || exit 3 ;;
  cat) [ -f "$S/units/$1.cat" ] && cat "$S/units/$1.cat" || exit 1 ;;
  show)
    if [ -f "$S/units/$1.show" ]; then cat "$S/units/$1.show"
    elif [ -f "$S/units/$1.cat" ]; then
      sed -n 's/^\(ExecStartPre\|ExecStart\|ExecStartPost\|ExecReload\|Environment\)=//p' "$S/units/$1.cat"
    fi ;;
  enable)
    for u; do
      [ ! -f "$S/fail/enable-$u" ] || { rc=1; continue; }
      [ "$rt" = 1 ] && echo enabled-runtime >"$S/units/$u.enabled" || echo enabled >"$S/units/$u.enabled"
    done ;;
  disable)
    for u; do
      [ ! -f "$S/units/$u.enabled" ] || echo disabled >"$S/units/$u.enabled"
      [ "$now" = 0 ] || stopu "$u" || rc=1
    done ;;
  mask) for u; do echo masked >"$S/units/$u.enabled"; done ;;
  start)
    for u; do
      [ ! -f "$S/fail/start-$u" ] || { rc=1; continue; }
      case "$u" in
        att-wpa-supplicant@*.service)
          # ExecStartPre. A failure leaves the unit failed; start --no-block
          # still returns 0.
          i=${u#att-wpa-supplicant@}; i=${i%.service}
          # Does the caller still hold the bundle lock? A swap must be able
          # to take it exclusive now.
          if flock -n -x "$STUB_ROOT/run/att-wpa-supplicant.bundle.lock" true 2>/dev/null; then
            echo "lock free at start of $u" >>"$S/lock.log"
          else
            echo "lock HELD at start of $u" >>"$S/lock.log"
          fi
          mkdir -p "$STUB_ROOT/run/att-wpa-supplicant/$i"
          if "$STUB_SCRIPT" precheck "$i" >>"$S/precheck.log" 2>&1; then
            echo active >"$S/units/$u.active"
          else
            echo failed >"$S/units/$u.active"
          fi ;;
        *) echo active >"$S/units/$u.active" ;;
      esac
    done ;;
  stop) for u; do stopu "$u" || rc=1; done ;;
  *) ;;
esac
exit "$rc"
EOF
    # apt-get: update and download serve fetch. Every other call is logged
    # and fails, so a test sees any attempt to install a package.
    cat >"$B/apt-get" <<'EOF'
#!/bin/sh
S=$STUB_STATE
echo "apt-get $*" >>"$S/apt.log"
for a in "$@"; do
  case "$a" in
    update) [ ! -f "$S/fail/apt-update" ] || exit 100; exit 0 ;;
    download) break ;;
    -*) ;;
    *) echo "E: stub refuses apt-get $*"; exit 100 ;;
  esac
done
shift
for a; do
  case "$a" in -*|download) continue ;; esac
  [ -f "$S/repo/$a.deb" ] || { echo "E: Can't find a source to download '$a'"; exit 100; }
  cp "$S/repo/$a.deb" .
done
EOF
    cat >"$B/fake-wpa_supplicant" <<'EOF'
#!/bin/sh
case "$1" in -h) printf 'drivers:\n  wired = Wired Ethernet driver\n  nl80211 = Linux nl80211\n'; exit 255 ;; esac
echo "wpa_supplicant $*" >>"$STUB_STATE/run.log"
EOF
    cat >"$B/fake-wpa_cli" <<'EOF'
#!/bin/sh
cat "$STUB_STATE/wpa_status" 2>/dev/null || true
EOF
    # The runtime binaries. Like the loader, they fail with exit 127
    # unless a directory in LD_LIBRARY_PATH holds libpcsclite.so.1.
    cat >"$B/fake-rt-wpa_supplicant" <<'EOF'
#!/bin/sh
# $STUB_STATE/firmware-hio: -h fails with an I/O error (a bad read).
if [ -e "$STUB_STATE/firmware-hio" ] && [ "${1:-}" = -h ]; then
  echo "$0: error while loading shared libraries: libnl-3.so.200: cannot read file data: Input/output error" >&2
  exit 127
fi
# $STUB_STATE/firmware-fork: timeout(1) cannot fork (no free processes).
if [ -e "$STUB_STATE/firmware-fork" ]; then
  echo "timeout: fork system call failed: Resource temporarily unavailable" >&2
  exit 125
fi
# $STUB_STATE/firmware-hcrash: -h prints the drivers, then crashes.
if [ -e "$STUB_STATE/firmware-hcrash" ] && [ "${1:-}" = -h ]; then
  printf 'drivers:\n  wired = Wired Ethernet driver\n'
  kill -SEGV $$
fi
# $STUB_STATE/firmware-hmap: the loader cannot map a library (no memory).
if [ -e "$STUB_STATE/firmware-hmap" ]; then
  echo "$0: error while loading shared libraries: libnl-3.so.200: failed to map segment from shared object" >&2
  exit 127
fi
# $STUB_STATE/firmware-hslow: -h prints the drivers, then hangs.
if [ -e "$STUB_STATE/firmware-hslow" ] && [ "${1:-}" = -h ]; then
  printf 'drivers:\n  wired = Wired Ethernet driver\n'
  exec sleep 30
fi
# $STUB_STATE/firmware-hang: the load check times out (a busy gateway).
[ ! -e "$STUB_STATE/firmware-hang" ] || exec sleep 30
# $STUB_STATE/firmware-broken: a firmware update removed a library.
if [ -e "$STUB_STATE/firmware-broken" ]; then
  echo "$0: error while loading shared libraries: libdbus-1.so.3: cannot open shared object file: No such file or directory" >&2
  exit 127
fi
found=0
old_ifs=$IFS; IFS=:
for d in ${LD_LIBRARY_PATH:-}; do [ -e "$d/libpcsclite.so.1" ] && found=1; done
IFS=$old_ifs
if [ "$found" = 0 ]; then
  echo "$0: error while loading shared libraries: libpcsclite.so.1: cannot open shared object file: No such file or directory" >&2
  exit 127
fi
case "${1:-}" in
  -v) printf 'wpa_supplicant v2.10-test\nCopyright (c) test\n'; exit 0 ;;
  -h) printf 'drivers:\n  wired = Wired Ethernet driver\n  nl80211 = Linux nl80211\n'; exit 255 ;;
esac
fd9=closed; [ ! -e /proc/$$/fd/9 ] || fd9=open
echo "wpa_supplicant $* exe=$0 fd9=$fd9 LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >>"$STUB_STATE/run.log"
EOF
    # A runtime binary whose library the firmware lacks.
    cat >"$B/fake-rt-broken" <<'EOF'
#!/bin/sh
echo "$0: error while loading shared libraries: libdbus-1.so.3: cannot open shared object file: No such file or directory" >&2
exit 127
EOF
    # A runtime binary that hangs and ignores TERM (sleep inherits that).
    cat >"$B/fake-rt-hang" <<'EOF'
#!/bin/sh
trap '' TERM
exec sleep 30
EOF
    # A wpa_cli whose library the firmware lacks.
    cat >"$B/fake-rt-cli-broken" <<'EOF'
#!/bin/sh
echo "$0: error while loading shared libraries: libreadline.so.8: cannot open shared object file: No such file or directory" >&2
exit 127
EOF
    # A runtime binary without the wired driver.
    cat >"$B/fake-rt-nowired" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -v) echo 'wpa_supplicant v2.10-nowired'; exit 0 ;;
  -h) printf 'drivers:\n  nl80211 = Linux nl80211\n'; exit 255 ;;
esac
EOF
    cat >"$B/fake-rt-wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_cli $* LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}" >>"$STUB_STATE/cli.log"
case "${1:-}" in -v) echo 'wpa_cli v2.10-test'; exit 0 ;; esac
cat "$STUB_STATE/wpa_status" 2>/dev/null || true
EOF
    chmod +x "$B"/*
}

authorized() { printf 'Supplicant PAE state=AUTHENTICATED\nsuppPortStatus=Authorized\n' >"$S/wpa_status"; }
unauthorized() { printf 'Supplicant PAE state=CONNECTING\nsuppPortStatus=Unauthorized\n' >"$S/wpa_status"; }

# ---------- assertions ----------

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
run() { OUT=$("$SCRIPT" "$@" 2>&1) && RC=0 || RC=$?; }
expect_rc() { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2" "rc=$RC out: $(printf '%s' "$OUT" | tail -n 3 | tr '\n' '|')"; fi; }
expect_out() { if printf '%s' "$OUT" | grep -q -- "$1"; then ok "$2"; else bad "$2" "missing '$1' in: $(printf '%s' "$OUT" | tail -n 4 | tr '\n' '|')"; fi; }
expect_file() { if [ -e "$1" ]; then ok "$2"; else bad "$2" "missing $1"; fi; }
expect_nofile() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2" "unexpected $1"; fi; }
expect_grep() { if grep -q -- "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3" "'$1' not in $2"; fi; }
expect_nogrep() { if ! grep -q -- "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3" "'$1' found in $2"; fi; }
expect_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "got '$1', want '$2'"; fi; }

ORIG_PATH=$PATH
INSTD() { printf '%s/data/unifi-common-addons/att-wpa-supplicant/instances/%s' "$R" "$1"; }

# ---------- tests: install, add-instance, validate ----------

repo() { # name version: a downloadable package
    mkdir -p "$S/repo"
    cp "$(mkdeb "$1" "$2")" "$S/repo/$1.deb"
}

t_fetch() {
    setup fetch
    repo wpasupplicant 2:2.9.0-21+deb11u3
    repo libpcsclite1 1.9.1-1
    run fetch
    expect_rc 0 "fetch: succeeds"
    m="$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64/MANIFEST"
    expect_grep '^pkg=wpasupplicant 2:2.9.0-21+deb11u3$' "$m" "fetch: bundles wpasupplicant"
    expect_grep '^pkg=libpcsclite1 1.9.1-1$' "$m" "fetch: bundles libpcsclite1"
    expect_eq "$(grep -c '^pkg=' "$m")" 2 "fetch: bundles the two runtime packages only"
    expect_grep 'download -qq wpasupplicant libpcsclite1$' "$S/apt.log" "fetch: downloads the packages by name"
    other=$(grep -v '^apt-get \(update\|download\) ' "$S/apt.log")
    expect_eq "$other" "" "fetch: no apt-get call other than update and download"
    expect_out 'ready: .*wpasupplicant 2:2.9.0-21+deb11u3' "fetch: names the wpasupplicant version"
    expect_out 'ready: .*libpcsclite1 1.9.1-1' "fetch: names the libpcsclite1 version"
    # A failed download keeps the bundle.
    rm "$S/repo/libpcsclite1.deb"
    repo wpasupplicant 2:2.9.0-21+deb11u4
    run fetch
    expect_rc 1 "fetch: fails when a package cannot be downloaded"
    expect_grep '^pkg=wpasupplicant 2:2.9.0-21+deb11u3$' "$m" "fetch: keeps the bundle after a failed download"
    : >"$S/fail/apt-update"
    run fetch
    expect_rc 1 "fetch: fails when apt-get update fails"
    expect_out 'Existing bundle kept' "fetch: says that it kept the bundle"
    [ -z "$(find "$R/data/unifi-common-addons/att-wpa-supplicant/bundles" -name '.fetch.*')" ] && ok "fetch: no temp dir left" || bad "fetch: no temp dir left"
}

t_install_inert() {
    setup install
    expect_file "$R/data/on_boot.d/01-att-wpa-supplicant.sh" "install: boot entry placed"
    expect_file "$R/etc/systemd/system/att-wpa-supplicant@.service" "install: instance unit placed"
    [ -L "$R/usr/local/sbin/att-wpa-supplicant" ] && ok "install: command linked into PATH" || bad "install: command linked into PATH"
    expect_nogrep 'start' "$S/systemctl.log" "install: starts nothing"
    [ ! -f "$S/apt.log" ] && ok "install: installs no packages" || bad "install: installs no packages"
    [ "$(stat -c %a "$R/data/unifi-common-addons")" = 755 ] && ok "install: makes the shared parent 0755" || bad "install: makes the shared parent 0755" "$(stat -c %a "$R/data/unifi-common-addons")"
    [ "$(stat -c %a "$R/data/unifi-common-addons/att-wpa-supplicant")" = 700 ] && ok "install: its own home is 0700" || bad "install: its own home is 0700"
    chmod 0750 "$R/data/unifi-common-addons"
    run install
    [ "$(stat -c %a "$R/data/unifi-common-addons")" = 750 ] && ok "install: leaves the mode of an existing shared parent" || bad "install: leaves the mode of an existing shared parent"
    chmod 0755 "$R/data/unifi-common-addons"
    rm -rf "$R/data/unifi-common-addons"
    (umask 077 && "$SCRIPT" install >/dev/null 2>&1)
    [ "$(stat -c %a "$R/data/unifi-common-addons")" = 755 ] && ok "install: makes the shared parent 0755 under umask 077" || bad "install: makes the shared parent 0755 under umask 077" "$(stat -c %a "$R/data/unifi-common-addons")"
    expect_out 'next: add-instance' "install: with no instance, points to add-instance"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run install
    expect_out 'next: plan <iface>, then activate' "install: with an idle instance, points to plan and activate"
    expect_out 'Instances: eth8' "install: names the idle instance"
    bundle_ready
    : >"$(INSTD eth8)/active"
    : >"$S/systemctl.log"
    run install
    expect_out 'Activated interfaces were not restarted: eth8' "install: with an active instance, says that it was not restarted"
    expect_out 'next: att-wpa-supplicant check' "install: with an active instance, points to check"
    if printf '%s' "$OUT" | grep -q 'Nothing is running yet'; then bad "install: no 'nothing is running' message while active"; else ok "install: no 'nothing is running' message while active"; fi
    expect_nogrep '^\(start\|stop\|restart\|try-restart\)' "$S/systemctl.log" "install: upgrade in place restarts nothing"
}

t_add_instance() {
    setup addinst
    bundle_ready
    run add-instance eth8 "$T/src"
    expect_rc 0 "add-instance: succeeds"
    c="$(INSTD eth8)/wpa_supplicant.conf"
    expect_grep '^ctrl_interface=/run/att-wpa-supplicant/eth8$' "$c" "add-instance: ctrl_interface per instance"
    expect_grep '^openssl_ciphers=DEFAULT@SECLEVEL=0$' "$c" "add-instance: SECLEVEL global line"
    expect_grep 'identity="AA:BB:CC:DD:EE:FF"' "$c" "add-instance: identity copied"
    expect_grep 'private_key="/data/unifi-common-addons/att-wpa-supplicant/instances/eth8/certs/PrivateKey.pem"' "$c" "add-instance: absolute production paths"
    expect_eq "$(stat -c %a "$(INSTD eth8)/certs/PrivateKey.pem" 2>/dev/null)" 600 "add-instance: key 0600"
    run validate eth8
    expect_rc 0 "validate: passes on fresh instance"
    run add-instance eth8 "$T/src"
    expect_rc 1 "add-instance: refuses to overwrite"
    setup addinst-comment
    printf 'network={\n  identity="AA:BB:CC:DD:EE:FF"  # gateway MAC\n}\n' >"$T/src/wpa_supplicant.conf"
    run add-instance eth8 "$T/src"
    expect_rc 0 "add-instance: accepts a trailing comment on the identity line"
    c="$(INSTD eth8)/wpa_supplicant.conf"
    expect_grep '^[[:space:]]*identity="AA:BB:CC:DD:EE:FF"$' "$c" "add-instance: drops the trailing comment"
}

t_validate_rejects() {
    setup validate
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    chmod 644 "$(INSTD eth8)/certs/PrivateKey.pem"
    run validate eth8
    expect_rc 1 "validate: rejects world-readable key"
    expect_out 'must not be accessible' "validate: says why"
    chmod 600 "$(INSTD eth8)/certs/PrivateKey.pem"
    sed -i 's#ca_cert=.*#ca_cert="/etc/ssl/evil.pem"#' "$(INSTD eth8)/wpa_supplicant.conf"
    run validate eth8
    expect_rc 1 "validate: rejects cert path outside instance"
    run validate 'eth8;rm'
    expect_rc 1 "validate: rejects bad interface name"
    run validate eth8/../x
    expect_rc 1 "validate: rejects path in interface name"
}

# ---------- tests: runtime ----------

BND="bundles/bullseye-arm64"
BD() { printf '%s/data/unifi-common-addons/att-wpa-supplicant/%s' "$R" "$BND"; }
# The runtime that precheck chose for instance $1 (cur or prev).
CHOICE() { printf '%s/run/att-wpa-supplicant/%s/selected-runtime' "$R" "$1"; }
# Every entry under /data with its inode, mode, size, mtime, and ctime: a
# write on /data changes it.
data_sig() { (cd "$R/data" && find . -printf '%p %i %m %s %T@ %C@\n' | LC_ALL=C sort | sha256sum); }

t_runtime_start() {
    setup rt-start
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    before=$(data_sig)
    run precheck eth8
    expect_rc 0 "precheck: passes with an unpacked bundle"
    expect_out 'eth8: runtime ready: wpa_supplicant v2.10-test from bundle bullseye-arm64$' "precheck: names the version and the bundle"
    expect_eq "$(head -n 1 "$(CHOICE eth8)" 2>/dev/null)" cur "precheck: records its choice in /run"
    expect_eq "$(data_sig)" "$before" "precheck: writes nothing on /data"
    run precheck eth8
    expect_eq "$(data_sig)" "$before" "precheck: a restart writes nothing on /data"
    run run eth8
    expect_rc 0 "run: starts the runtime binary"
    expect_grep "exe=$(BD)/root/usr/sbin/wpa_supplicant" "$S/run.log" "run: execs the binary from the bundle's runtime"
    expect_grep "LD_LIBRARY_PATH=$(BD)/root/usr/lib/aarch64-linux-gnu\$" "$S/run.log" "run: LD_LIBRARY_PATH holds only the runtime library directory"
    expect_grep "fd9=closed" "$S/run.log" "run: the bundle lock fd is not open in the supplicant"
    expect_grep "-D wired -i eth8 -c $(INSTD eth8)/wpa_supplicant.conf" "$S/run.log" "run: passes driver, interface, and config"
    expect_eq "$(data_sig)" "$before" "run: writes nothing on /data"
    [ -z "$(cat "$S/apt.log" "$S/dpkg.log" 2>/dev/null)" ] && ok "runtime: no apt-get or dpkg call that changes packages" || bad "runtime: no apt-get or dpkg call that changes packages" "$(cat "$S/apt.log" "$S/dpkg.log" 2>/dev/null)"
    # A system package is never used.
    system_supplicant
    : >"$S/run.log"
    run precheck eth8
    run run eth8
    expect_grep "exe=$(BD)/root/usr/sbin/wpa_supplicant" "$S/run.log" "run: uses the runtime when a system wpa_supplicant exists"
    expect_eq "$(grep -c . "$S/run.log")" 1 "run: one supplicant ran"
    expect_nogrep ' -c [^ ]*conf$' "$S/run.log" "run: the system binary did not run (its log line has no exe=)"
    # run reads the choice of precheck.
    rm -f "$(CHOICE eth8)"
    run run eth8
    expect_rc 1 "run: fails when precheck chose nothing"
    expect_out 'no runtime chosen in' "run: says that precheck chooses the runtime"
    echo bogus >"$(CHOICE eth8)"
    run run eth8
    expect_rc 1 "run: refuses an unknown choice"
    echo cur >"$(CHOICE eth8)"
    rm -f "$(BD)"/root/usr/lib/aarch64-linux-gnu/libpcsclite.so*
    run run eth8
    expect_rc 1 "run: refuses a runtime with no library directory"
    expect_out 'no usable library directory' "run: says that the library directory is missing"
    rm -rf "$(BD)/root"
    run run eth8
    expect_rc 1 "run: fails without a runtime"
    expect_out "no runtime at $(BD)/root" "run: names the missing runtime"
    # bullseye and bookworm packages use sbin/.
    setup rt-sbin
    DEB_SBIN=sbin bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 0 "precheck: sbin layout passes"
    run run eth8
    expect_grep "exe=$(BD)/root/sbin/wpa_supplicant" "$S/run.log" "run: finds the binary in sbin"
}

# The load check at start. mkbundle unpacks what it is given, so these
# trees are what a firmware change can make of a good bundle.
t_runtime_refusals() {
    setup rt-nobundle
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: fails without a bundle"
    expect_out "no bundle at $(BD)" "precheck: names the missing bundle"
    expect_nofile "$(CHOICE eth8)" "precheck: chooses nothing without a bundle"

    setup rt-noroot
    MKB_NOROOT=1 bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    before=$(data_sig)
    run precheck eth8
    expect_rc 1 "precheck: fails on a bundle without a runtime"
    expect_out 'bundle bullseye-arm64 has no unpacked runtime. Run fetch or import-bundle' "precheck: says how to unpack it"
    expect_eq "$(data_sig)" "$before" "precheck: does not unpack a bundle itself"

    setup rt-load
    mkbundle "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: the load check fails on a missing firmware library"
    expect_out 'wpa_supplicant does not start: .*libdbus-1.so.3: cannot open shared object file' "precheck: logs the loader's line"
    expect_nofile "$(CHOICE eth8)" "precheck: chooses nothing after a failed load check"
    run validate eth8
    expect_rc 1 "validate: fails when the runtime does not load"
    expect_out 'supplicant: the runtime failed its check' "validate: says that the runtime failed"

    setup rt-nowired
    mkbundle "$(DEB_WPA="$B/fake-rt-nowired" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: refuses a binary without the wired driver"
    expect_out 'no wired driver' "precheck: says why (wired)"

    setup rt-hang
    mkbundle "$(DEB_WPA="$B/fake-rt-hang" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    t0=$(date +%s)
    OUT=$(ATT_WPA_LOAD_TIMEOUT=1 "$SCRIPT" precheck eth8 2>&1) && RC=0 || RC=$?
    expect_rc 1 "precheck: a binary that hangs fails the load check"
    # 1 s, then KILL 5 s after TERM. Without -k, sleep 30 runs to the end.
    [ $(($(date +%s) - t0)) -lt 15 ] && ok "precheck: the load check kills a binary that ignores TERM" || bad "precheck: the load check kills a binary that ignores TERM" "took $(($(date +%s) - t0)) s"

    setup rt-cli
    mkbundle "$(DEB_CLI="$B/fake-rt-cli-broken" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: refuses a wpa_cli that does not load"
    expect_out 'wpa_cli does not start: .*libreadline.so.8' "precheck: logs the wpa_cli loader line"

    # -h exits outside 0 and 255: a crash after the driver list, a time-out
    # after it, or an I/O error.
    setup rt-h
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    for f in hcrash:139 hslow:124 hio:127; do
        : >"$S/firmware-${f%%:*}"
        OUT=$(ATT_WPA_LOAD_TIMEOUT=1 "$SCRIPT" precheck eth8 2>&1) && RC=0 || RC=$?
        rm -f "$S/firmware-${f%%:*}"
        expect_rc 1 "precheck: -h ${f%%:*} fails the load check"
        expect_out "wpa_supplicant -h failed (exit ${f#*:})" "precheck: -h ${f%%:*} gives the exit status"
    done
    run precheck eth8
    expect_rc 0 "precheck: passes again once the cause is gone"

    setup rt-mode
    mkbundle "$(mkdeb wpasupplicant 2:2.9.0-21)" "$(DEB_UMASK=002 mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: refuses a tree with group-writable files"
    expect_out 'is writable by group or other' "precheck: names the writable file"

    setup rt-nolib
    mkbundle "$(mkdeb wpasupplicant 2:2.9.0-21)" "$(DEB_NOLIB=1 mkdeb libpcsclite1 1.9.1-1)"
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run precheck eth8
    expect_rc 1 "precheck: refuses packages with no library directory"
    expect_out "no usable library directory in the packages ('')" "precheck: never runs with an empty LD_LIBRARY_PATH"

    # A noexec mount looks like a file without the x bit.
    setup rt-noexec
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    d="$T/debs/wpasupplicant"
    (umask 022; mkdeb wpasupplicant 2:2.9.0-21 >/dev/null; chmod -x "$d/usr/sbin/wpa_supplicant"; dpkg-deb --root-owner-group -b "$d" "$T/noexec.deb" >/dev/null)
    mkbundle "$T/noexec.deb" "$(mkdeb libpcsclite1 1.9.1-1)"
    run precheck eth8
    expect_rc 1 "precheck: refuses binaries that cannot execute"
    expect_out 'cannot execute files in .* mounted noexec?' "precheck: points to a noexec mount"

    # wpa_cli missing, wpa_supplicant fine: not a noexec message.
    setup rt-nocli
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    d="$T/debs/wpasupplicant"
    (umask 022; mkdeb wpasupplicant 2:2.9.0-21 >/dev/null; rm "$d/usr/sbin/wpa_cli"; dpkg-deb --root-owner-group -b "$d" "$T/nocli.deb" >/dev/null)
    mkbundle "$T/nocli.deb" "$(mkdeb libpcsclite1 1.9.1-1)"
    run precheck eth8
    expect_rc 1 "precheck: refuses packages without wpa_cli"
    expect_out 'hold no wpa_supplicant or no wpa_cli' "precheck: says that a binary is missing"
    if printf '%s' "$OUT" | grep -q noexec; then bad "precheck: a missing wpa_cli is not reported as noexec"; else ok "precheck: a missing wpa_cli is not reported as noexec"; fi

    setup rt-space
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    d="$T/debs/libpcsclite1"
    (umask 022; mkdeb libpcsclite1 1.9.1-1 >/dev/null; : >"$d/usr/lib/aarch64-linux-gnu/a b"; dpkg-deb --root-owner-group -b "$d" "$T/space.deb" >/dev/null)
    mkbundle "$(mkdeb wpasupplicant 2:2.9.0-21)" "$T/space.deb"
    run precheck eth8
    expect_rc 1 "precheck: refuses names with white space"
    expect_out 'has white space: .*a b' "precheck: names the file with white space"

    setup rt-noiface
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    rmdir "$R/sys/class/net/eth8"
    run precheck eth8
    expect_rc 1 "precheck: fails without the interface"
    expect_nofile "$(CHOICE eth8)" "precheck: chooses nothing without the interface"
}

t_runtime_prev() {
    setup rt-prev
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    bundle_ready
    mv "$(BD)" "$(BD).prev"
    mkbundle "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.10-1)" "$(mkdeb libpcsclite1 1.9.1-1)"
    before=$(data_sig)
    run precheck eth8
    expect_rc 0 "prev: falls back to .prev when the bundle fails its load check"
    expect_out 'WARN runtime: using the previous bundle bullseye-arm64.prev' "prev: warns about the fallback"
    expect_out 'libdbus-1.so.3' "prev: logs why the current bundle failed"
    expect_out 'runtime ready: .* from bundle bullseye-arm64.prev$' "prev: names the .prev bundle"
    expect_eq "$(head -n 1 "$(CHOICE eth8)" 2>/dev/null)" prev "prev: records the choice"
    expect_eq "$(data_sig)" "$before" "prev: the fallback writes nothing on /data"
    run run eth8
    expect_grep "exe=$(BD).prev/root/usr/sbin/wpa_supplicant" "$S/run.log" "prev: run execs from .prev"
    expect_grep "LD_LIBRARY_PATH=$(BD).prev/root/usr/lib/aarch64-linux-gnu\$" "$S/run.log" "prev: run uses the libraries of .prev"
    # A new bundle arrives: the next start uses it, not .prev.
    rm -rf "$(BD)"
    bundle_ready
    run precheck eth8
    expect_eq "$(head -n 1 "$(CHOICE eth8)" 2>/dev/null)" cur "prev: a start after a repair chooses the bundle again"
    if printf '%s' "$OUT" | grep -q WARN; then bad "prev: no warning when the bundle passes"; else ok "prev: no warning when the bundle passes"; fi
    # A swap cut short leaves only .prev. A start uses it in place.
    rm -rf "$(BD).prev"
    mv "$(BD)" "$(BD).prev"
    run precheck eth8
    expect_rc 0 "prev: a start uses .prev after an interrupted swap"
    expect_out 'because bullseye-arm64 is missing (a swap that did not finish)' "prev: says that the bundle is missing, not that it failed"
    expect_nofile "$(BD)" "prev: a start does not rename .prev"
    run validate eth8
    expect_rc 0 "validate: accepts a bundle that is only .prev"
    expect_out 'supplicant: wpa_supplicant v2.10-test from bundle bullseye-arm64.prev loads on this firmware' "validate: tests the runtime of the .prev bundle"
    # Both bad: try both, then fail.
    mkbundle "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.10-1)" "$(mkdeb libpcsclite1 1.9.1-1)"
    rm -rf "$(BD).prev"
    cp -a "$(BD)" "$(BD).prev"
    rm -f "$(CHOICE eth8)"
    run precheck eth8
    expect_rc 1 "prev: fails when the bundle and .prev both fail"
    expect_eq "$(printf '%s' "$OUT" | grep -c 'libdbus-1.so.3')" 2 "prev: reports why each one failed"
    expect_nofile "$(CHOICE eth8)" "prev: chooses nothing when both fail"
}

mktgz() { # version -> path of a bullseye-arm64 bundle archive. MKTGZ_CTRL:
    # extra control lines for both packages.
    d="$T/tgz-$1/bullseye-arm64"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$(mkdeb wpasupplicant "$1" "${MKTGZ_CTRL:-}")" "$(mkdeb libpcsclite1 1.9.1-1 "${MKTGZ_CTRL:-}")" "$d/"
    (cd "$d" && sha256sum -- *.deb >SHA256SUMS)
    printf 'codename=bullseye\narch=arm64\npkg=wpasupplicant %s\npkg=libpcsclite1 1.9.1-1\n' "$1" >"$d/MANIFEST"
    tar -czf "$T/tgz-$1.tgz" -C "$T/tgz-$1" bullseye-arm64
    printf '%s' "$T/tgz-$1.tgz"
}

# import-bundle and fetch unpack the runtime and check it before the swap.
t_import_unpacks() {
    setup imp
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run import-bundle "$(mktgz 2:2.9.0-21)"
    expect_rc 0 "import: succeeds"
    expect_file "$(BD)/root/usr/sbin/wpa_supplicant" "import: unpacks the binary"
    expect_file "$(BD)/root/usr/lib/aarch64-linux-gnu/libpcsclite.so.1" "import: unpacks the library"
    expect_eq "$(stat -c %a "$(BD)")" 700 "import: the bundle directory is 0700"
    run precheck eth8
    expect_rc 0 "import: the next start passes"
    # A load check that fails for this release fails the import.
    keep=$(cat "$(BD)/MANIFEST")
    run import-bundle "$(DEB_WPA="$B/fake-rt-broken" mktgz 2:2.10-1)"
    expect_rc 1 "import: refuses a bundle whose runtime fails the load check"
    expect_out 'libdbus-1.so.3' "import: logs the loader's line"
    expect_out 'the runtime failed its check (above). Existing bundle kept' "import: says that it kept the bundle"
    expect_eq "$(cat "$(BD)/MANIFEST")" "$keep" "import: the bundle in use is unchanged"
    expect_nofile "$(BD).prev" "import: a refused bundle does not move the bundle in use to .prev"
    [ -z "$(find "$R/data/unifi-common-addons/att-wpa-supplicant/bundles" -name '.import.*')" ] && ok "import: no temp dir left after a refusal" || bad "import: no temp dir left after a refusal"
    # The tree check runs at import too.
    run import-bundle "$(DEB_UMASK=002 mktgz 2:2.10-2)"
    expect_rc 1 "import: refuses a tree with group-writable files"
    expect_out 'is writable by group or other' "import: names the writable file"
    # A package for another architecture.
    d="$T/tgz-arch/bullseye-arm64"
    mkdir -p "$d"
    cp "$(DEB_ARCH=amd64 mkdeb wpasupplicant 2:2.10-3)" "$(mkdeb libpcsclite1 1.9.1-1)" "$d/"
    (cd "$d" && sha256sum -- *.deb >SHA256SUMS)
    printf 'codename=bullseye\narch=arm64\n' >"$d/MANIFEST"
    tar -czf "$T/tgz-arch.tgz" -C "$T/tgz-arch" bullseye-arm64
    run import-bundle "$T/tgz-arch.tgz"
    expect_rc 1 "import: refuses a package for another architecture"
    expect_out 'wpasupplicant is for amd64, not arm64' "import: names the architecture"
    # An archive that holds a runtime: only the gateway unpacks one.
    d="$T/tgz-2:2.10-4/bullseye-arm64"
    mktgz 2:2.10-4 >/dev/null
    mkdir -p "$d/root/usr/sbin"
    tar -czf "$T/tgz-root.tgz" -C "$T/tgz-2:2.10-4" bullseye-arm64
    run import-bundle "$T/tgz-root.tgz"
    expect_rc 1 "import: refuses an archive that holds a root directory"
    expect_out 'the archive holds a root directory' "import: says why"
    expect_eq "$(cat "$(BD)/MANIFEST")" "$keep" "import: the bundle in use is unchanged after the refusals"
    # Another release: unpacked and tree-checked, but not run.
    run import-bundle "$(DEB_WPA="$B/fake-rt-broken" mktgz_rel trixie 2:2.10-5)"
    expect_rc 0 "import: accepts another release whose binary cannot run here"
    expect_file "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/trixie-arm64/root/usr/sbin/wpa_supplicant" "import: unpacks the runtime of another release"
    expect_out "note: trixie-arm64 is not this gateway's release (bullseye-arm64). Kept for a future firmware. Its load check runs there" "import: says that the load check runs after a firmware update"
    run import-bundle "$(DEB_UMASK=002 mktgz_rel trixie 2:2.10-6)"
    expect_rc 1 "import: the tree check fails another release too"
    expect_grep 'wpasupplicant 2:2.10-5' "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/trixie-arm64/MANIFEST" "import: keeps the other release's bundle after a refusal"

    setup fetch-unpack
    repo wpasupplicant 2:2.9.0-21+deb11u3
    repo libpcsclite1 1.9.1-1
    run fetch
    expect_rc 0 "fetch: succeeds"
    expect_file "$(BD)/root/usr/sbin/wpa_supplicant" "fetch: unpacks the runtime"
    keep=$(cat "$(BD)/MANIFEST")
    mkdir -p "$S/repo"
    cp "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.9.0-21+deb11u4)" "$S/repo/wpasupplicant.deb"
    run fetch
    expect_rc 1 "fetch: refuses packages whose runtime fails the load check"
    expect_out 'Existing bundle kept' "fetch: says that it kept the bundle"
    expect_eq "$(cat "$(BD)/MANIFEST")" "$keep" "fetch: the bundle in use is unchanged"
}

# A swap while the supplicant runs: the bundle it runs from moves to .prev,
# or is deleted. Each start reads the choice of its own precheck.
t_swap_while_running() {
    setup swap-run
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    "$SCRIPT" import-bundle "$(mktgz 2:2.9.0-21)" >/dev/null 2>&1
    # The supplicant runs from cur: it holds its binary open, as a running
    # process holds its mapped files.
    run precheck eth8
    exec 3<"$(BD)/root/usr/sbin/wpa_supplicant"
    run import-bundle "$(mktgz 2:2.10-1)"
    expect_rc 0 "swap: import succeeds while the supplicant runs from cur"
    run import-bundle "$(mktgz 2:2.10-2)"
    expect_rc 0 "swap: a second import deletes the tree in use"
    head -n 1 <&3 | grep -q '^#!/bin/sh' && ok "swap: a file of the deleted tree stays readable through an open descriptor" || bad "swap: a file of the deleted tree stays readable through an open descriptor"
    exec 3<&-
    run precheck eth8
    expect_rc 0 "swap: the next start passes on the new bundle"
    expect_eq "$(head -n 1 "$(CHOICE eth8)")" cur "swap: the next start chooses the new bundle"
    # The bundle fails and the start uses .prev: a swap keeps .prev and
    # replaces the bundle that fails.
    rm -f "$(BD)"/root/usr/lib/aarch64-linux-gnu/libpcsclite.so*
    run precheck eth8
    expect_eq "$(head -n 1 "$(CHOICE eth8)")" prev "swap: a start falls back to .prev"
    run import-bundle "$(mktgz 2:2.10-3)"
    expect_rc 0 "swap: import succeeds while the start uses .prev"
    expect_out 'bundle bullseye-arm64 fails its load check. Replacing it; bullseye-arm64.prev stays' "swap: says that it keeps .prev"
    expect_grep 'wpasupplicant 2:2.10-1' "$(BD).prev/MANIFEST" "swap: .prev, which loads, stays"
    expect_grep 'wpasupplicant 2:2.10-3' "$(BD)/MANIFEST" "swap: the new bundle replaces the one that fails"
    run precheck eth8
    expect_rc 0 "swap: the next start passes"
    expect_eq "$(head -n 1 "$(CHOICE eth8)")" cur "swap: the next start chooses the new bundle, not .prev"
    # The same, with the swap cut short after it deleted the bundle that
    # fails: .prev, which loads, is what remains.
    rm -f "$(BD)"/root/usr/lib/aarch64-linux-gnu/libpcsclite.so*
    # shellcheck disable=SC2016 # expands in the stub
    printf '#!/bin/sh\ncase "$2" in */bundles/bullseye-arm64) echo "mv: stub failure" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' >"$B/mv"
    chmod +x "$B/mv"
    run import-bundle "$(mktgz 2:2.10-4)"
    rm -f "$B/mv"
    expect_rc 1 "swap: a failed rename fails the import"
    expect_grep 'wpasupplicant 2:2.10-1' "$(BD).prev/MANIFEST" "swap: after a failed rename, .prev (which loads) remains"
    run precheck eth8
    expect_rc 0 "swap: the next start passes after a failed swap"
    : >"$S/run.log"
    run run eth8
    expect_grep "exe=$(BD).prev/root/usr/sbin/wpa_supplicant" "$S/run.log" "swap: after the failed swap, run execs .prev"
}

t_bundle_swap_keeps_previous() {
    setup swap
    bd=$(BD)
    run import-bundle "$(mktgz 2:2.9.0-21)"
    expect_rc 0 "import-bundle: first import"
    expect_nofile "$bd.prev" "import-bundle: no previous bundle after the first import"
    run import-bundle "$(mktgz 2:2.10-1)"
    expect_rc 0 "import-bundle: second import"
    expect_grep 'wpasupplicant 2:2.10-1' "$bd/MANIFEST" "import-bundle: the new bundle is current"
    expect_grep 'wpasupplicant 2:2.9.0-21' "$bd.prev/MANIFEST" "import-bundle: the old bundle is kept as .prev"
    expect_file "$bd.prev/root/usr/sbin/wpa_supplicant" "import-bundle: .prev keeps its runtime"
    run import-bundle "$(mktgz 2:2.10-2)"
    expect_grep 'wpasupplicant 2:2.10-1' "$bd.prev/MANIFEST" "import-bundle: .prev holds only the last bundle"
    # A swap cut short between its two renames leaves only .prev. The next
    # import puts it back first.
    rm -rf "$bd"
    run import-bundle "$(mktgz 2:2.10-3)"
    expect_out 'Restored the previous bundle' "import-bundle: restores .prev after an interrupted swap"
    expect_grep 'wpasupplicant 2:2.10-3' "$bd/MANIFEST" "import-bundle: then installs the new bundle"
    expect_grep 'wpasupplicant 2:2.10-1' "$bd.prev/MANIFEST" "import-bundle: the restored bundle becomes .prev"
    # A bundle without libpcsclite1 is refused at import.
    d="$T/tgz-bad/bullseye-arm64"
    mkdir -p "$d"
    cp "$(mkdeb wpasupplicant 2:2.10-9)" "$d/"
    (cd "$d" && sha256sum -- *.deb >SHA256SUMS)
    printf 'codename=bullseye\narch=arm64\n' >"$d/MANIFEST"
    tar -czf "$T/tgz-bad.tgz" -C "$T/tgz-bad" bullseye-arm64
    run import-bundle "$T/tgz-bad.tgz"
    expect_rc 1 "import-bundle: refuses a bundle without the runtime packages"
    expect_out 'needs one libpcsclite1 package, has 0' "import-bundle: names the missing package"
    expect_grep 'wpasupplicant 2:2.10-3' "$bd/MANIFEST" "import-bundle: keeps the bundle after a refusal"
    [ -z "$(find "$R/data/unifi-common-addons/att-wpa-supplicant/bundles" -name '.import.*')" ] && ok "import-bundle: no temp dir left" || bad "import-bundle: no temp dir left"
}

# Load checks take the lock shared; swaps and install's unpack exclusive.
t_bundle_lock() {
    setup lock
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    lk="$R/run/att-wpa-supplicant.bundle.lock"
    ( flock -x 9; sleep 4 ) 9>"$lk" &
    holder=$!
    sleep 1
    OUT=$(ATT_WPA_LOCK_WAIT=1 "$SCRIPT" precheck eth8 2>&1) && RC=0 || RC=$?
    expect_rc 1 "lock: a start waits for a swap and gives up"
    expect_out 'holds the bundle lock' "lock: the start says why"
    OUT=$(ATT_WPA_LOCK_WAIT=1 "$SCRIPT" import-bundle "$(mktgz 2:2.10-3)" 2>&1) && RC=0 || RC=$?
    expect_rc 1 "lock: a swap waits for another swap and gives up"
    expect_file "$(BD)/wpasupplicant_2:2.9.0-21_arm64.deb" "lock: the bundle is unchanged when the swap cannot lock"
    wait "$holder"
    ( flock -s 9; sleep 4 ) 9>"$lk" &
    holder=$!
    sleep 1
    OUT=$(ATT_WPA_LOCK_WAIT=1 "$SCRIPT" precheck eth8 2>&1) && RC=0 || RC=$?
    expect_rc 0 "lock: starts do not block each other"
    OUT=$(ATT_WPA_LOCK_WAIT=1 "$SCRIPT" import-bundle "$(mktgz 2:2.10-3)" 2>&1) && RC=0 || RC=$?
    expect_rc 1 "lock: a swap waits for a start"
    OUT=$(ATT_WPA_LOCK_WAIT=1 "$SCRIPT" install 2>&1) && RC=0 || RC=$?
    expect_rc 1 "lock: install waits for a start"
    expect_out 'holds the bundle lock (waited 1s). Nothing changed' "lock: install says that nothing changed"
    wait "$holder"
    run install
    expect_rc 0 "lock: install succeeds once the lock is free"
    run precheck eth8
    expect_rc 0 "lock: no stale lock after the holder exits"
}

# The files of an installed version that install replaces, with stand-in
# contents.
old_layout() {
    dd="$R/data/unifi-common-addons/att-wpa-supplicant"
    echo 'old script' >"$dd/att-wpa-supplicant"
    echo 'old legacy' >"$dd/legacy.sh"
    echo 'old unit' >"$dd/systemd/att-wpa-supplicant@.service"
    echo 'old unit' >"$R/etc/systemd/system/att-wpa-supplicant@.service"
    echo 'old boot' >"$dd/on_boot.d/01-att-wpa-supplicant.sh"
    echo 'old boot' >"$R/data/on_boot.d/01-att-wpa-supplicant.sh"
}
old_sig() {
    dd="$R/data/unifi-common-addons/att-wpa-supplicant"
    cat "$dd/att-wpa-supplicant" "$dd/legacy.sh" "$dd/systemd/att-wpa-supplicant@.service" \
        "$R/etc/systemd/system/att-wpa-supplicant@.service" "$dd/on_boot.d/01-att-wpa-supplicant.sh" \
        "$R/data/on_boot.d/01-att-wpa-supplicant.sh" 2>&1 | sha256sum
}

# install over an installed version: it stops before it changes anything
# when the new code cannot run, and a copy cut short leaves the old files.
t_install_upgrade() {
    # An activated interface needs a runtime that loads. Without one,
    # install stops before it changes anything.
    for how in nobundle broken; do
        setup "inst-active-$how"
        "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
        : >"$(INSTD eth8)/active"
        [ "$how" = nobundle ] || mkbundle "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
        old_layout
        before=$(old_sig)
        run install
        expect_rc 1 "install ($how): stops when an activated interface has no runtime that loads"
        expect_out 'eth8 is activated, and no runtime for this release loads (above). Nothing changed' "install ($how): says why and that nothing changed"
        expect_eq "$(old_sig)" "$before" "install ($how): the installed files are unchanged"
    done
    # The bundle still fails, but .prev loads: install goes on.
    mv "$(BD)" "$T/broken"
    bundle_ready
    mv "$(BD)" "$(BD).prev"
    mv "$T/broken" "$(BD)"
    run install
    expect_rc 0 "install: goes on when the bundle fails but .prev loads"
    expect_out 'WARN runtime: using the previous bundle' "install: warns that only .prev loads"
    # A copy cut short (install(1) writes part of the file, then fails)
    # leaves the installed script as it was.
    setup inst-cut
    old_layout
    before=$(old_sig)
    real=$(PATH=$ORIG_PATH command -v install)
    # shellcheck disable=SC2016 # expands in the stub
    printf '#!/bin/sh\nfor a; do t=$a; done\ncase "$t" in */att-wpa-supplicant/att-wpa-supplicant*) echo partial >"$t"; exit 1 ;; esac\nexec %s "$@"\n' "$real" >"$B/install"
    chmod +x "$B/install"
    run install
    rm -f "$B/install"
    expect_rc 1 "install: a failed copy fails install"
    expect_eq "$(old_sig)" "$before" "install: a failed copy leaves the installed script whole"
    run install
    expect_rc 0 "install: the next install succeeds"
    expect_nofile "$R/data/unifi-common-addons/att-wpa-supplicant/att-wpa-supplicant.new" "install: no temp copy left"
    # The same for the unit in /etc/systemd/system.
    echo 'old unit' >"$R/etc/systemd/system/att-wpa-supplicant@.service"
    # shellcheck disable=SC2016 # expands in the stub
    printf '#!/bin/sh\nfor a; do t=$a; done\ncase "$t" in */etc/systemd/system/att-wpa-supplicant@.service*) echo partial >"$t"; exit 1 ;; esac\nexec %s "$@"\n' "$real" >"$B/install"
    chmod +x "$B/install"
    run install
    rm -f "$B/install"
    expect_rc 1 "install: a failed copy of the unit fails install"
    expect_grep '^old unit$' "$R/etc/systemd/system/att-wpa-supplicant@.service" "install: a failed copy leaves the installed unit whole"

    # A new, inert install needs no bundle.
    setup inst-inert-nobundle
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    run install
    expect_rc 0 "install: an install with no activated interface needs no bundle"

}

# ---------- tests: ownership, activate, rollback ----------

legacy_box() {
    system_supplicant
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    cp "$HERE/fixtures/legacy-0-att-bypass.sh" "$R/data/on_boot.d/0-att-bypass.sh"
    printf '#!/bin/sh\npodman start wpa_supplicant-udmpro\n' >"$R/data/on_boot.d/10-wpa_supplicant.sh"
    unit wpa_supplicant.service enabled active
    printf 'ExecStart=/sbin/wpa_supplicant -u -s -Dwired -ieth8 -c/etc/x.conf\n' >"$S/units/wpa_supplicant.service.cat"
    unit setup-att-bypass.service enabled failed
    printf 'ExecStart=/data/on_boot.d/0-att-bypass.sh\n' >"$S/units/setup-att-bypass.service.cat"
    fake_proc 900 wpa_supplicant.service /sbin/wpa_supplicant -u -s -Dwired -ieth8 -c/etc/x.conf
}

# A drop-in points setup-att-bypass.service at eth9. The boot script it
# runs still names eth8. Conflicting evidence: refuse.
t_activate_setup_dropin_other() {
    setup setup-dropin
    legacy_box
    printf "/bin/sh -c 'WAN=eth9 /data/on_boot.d/0-att-bypass.sh'\n" >"$S/units/setup-att-bypass.service.show"
    authorized
    : >"$S/systemctl.log"
    run activate eth8 --takeover
    expect_rc 1 "setup drop-in: refused"
    expect_out 'ambiguous setup-att-bypass.service' "setup drop-in: names the launcher"
    expect_nogrep '^\(stop\|disable\)' "$S/systemctl.log" "setup drop-in: nothing stopped or disabled"
    expect_nofile "$(INSTD eth8)/active" "setup drop-in: no flag"
}

t_activate_refuses_unknown() {
    setup unknown
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    fake_proc 4242 libpod-abc.scope /usr/sbin/wpa_supplicant -Dwired -ieth8 -c/x.conf
    run activate eth8 --takeover
    expect_rc 1 "activate: refuses unknown owner"
    expect_out 'unknown 4242' "activate: names the unknown process"
    expect_nofile "$(INSTD eth8)/active" "activate: no flag after refusal"
}

t_activate_dormant_launchers() {
    setup dormant
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    unit setup-att-bypass.service enabled inactive
    printf 'ExecStart=/data/wpa_supplicant/install.sh\n' >"$S/units/setup-att-bypass.service.cat"
    run activate eth8
    expect_rc 1 "activate: dormant launcher with no interface text blocks plain activate"
    expect_out 'unit setup-att-bypass.service' "activate: dormant launcher listed as owner"
    setup other-iface
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    printf '#!/bin/sh\nwpa_supplicant -Dwired -ieth9 -c/x\n' >"$R/data/on_boot.d/0-att-bypass.sh"
    run activate eth8 --takeover
    expect_rc 1 "activate: trigger naming another interface is refused as ambiguous"
    expect_out 'ambiguous 0-att-bypass.sh' "activate: says which launcher is ambiguous"
    expect_file "$R/data/on_boot.d/0-att-bypass.sh" "activate: ambiguous trigger untouched"
}

t_activate_needs_takeover() {
    setup needtk
    legacy_box
    run activate eth8
    expect_rc 1 "activate: refuses legacy without --takeover"
    expect_out 'unit wpa_supplicant.service' "activate: lists legacy unit"
    expect_out 'trigger 0-att-bypass.sh' "activate: lists legacy trigger"
    expect_file "$R/data/on_boot.d/0-att-bypass.sh" "activate: trigger untouched without --takeover"
    expect_eq "$(state_of wpa_supplicant.service active)" active "activate: legacy still running without --takeover"
}

# The stubs log their calls in state/*.log. Those files are not device state.
# The bundle lock file in /run is not state: plan and builds create it empty.
tree_sig() { (cd "$T" && find root state -type f ! -name '*.log' ! -path root/run/att-wpa-supplicant.bundle.lock -exec sha256sum {} + | sort | sha256sum); }

t_plan() {
    setup plan-legacy
    legacy_box
    before=$(tree_sig)
    : >"$S/systemctl.log"
    run plan eth8
    expect_nogrep '\(start\|stop\|restart\|enable\|disable\|mask\|unmask\|daemon-reload\|kill\)\( \|$\)' "$S/systemctl.log" "plan: sends no systemctl command that changes state"
    expect_grep 'is-enabled' "$S/systemctl.log" "plan: the systemctl log records the queries"
    expect_rc 0 "plan: succeeds when a takeover can proceed"
    expect_out 'unit wpa_supplicant.service' "plan: lists the legacy unit"
    expect_out 'trigger 0-att-bypass.sh' "plan: lists the legacy trigger"
    expect_out 'next: att-wpa-supplicant activate eth8 --takeover' "plan: names the takeover command"
    expect_eq "$(tree_sig)" "$before" "plan: changes no file (legacy box)"
    expect_nofile "$S/apt.log" "plan: runs no apt"
    expect_out 'supplicant: wpa_supplicant v2.10-test from bundle bullseye-arm64 loads' "plan: reports the load check"

    setup plan-clean
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    before=$(tree_sig)
    run plan eth8
    expect_rc 1 "plan: blocked without a bundle"
    expect_out 'no bundle at' "plan: names the missing bundle"
    bundle_ready
    before=$(tree_sig)
    run plan eth8
    expect_rc 0 "plan: succeeds when the runtime passes the load check"
    expect_out 'next: att-wpa-supplicant activate eth8$' "plan: names the plain activate command"
    expect_eq "$(tree_sig)" "$before" "plan: changes no file"
    expect_nofile "$(INSTD eth8)/active" "plan: does not activate"

    rm -f "$R"/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64/root/usr/lib/aarch64-linux-gnu/libpcsclite.so*
    run plan eth8
    expect_rc 1 "plan: blocked by a runtime without its library"
    expect_out 'no usable library directory' "plan: says what is wrong with the runtime"
    expect_out 'blocked: the supplicant runtime failed its check' "plan: says that the runtime blocks"
    rm -rf "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64"
    bundle_ready
    mv "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64" "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64.prev"
    run plan eth8
    expect_rc 0 "plan: accepts a bundle that is only .prev"
    expect_file "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64.prev" "plan: does not rename .prev"
    rm -rf "$R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64.prev"
    mkbundle "$(DEB_WPA="$B/fake-rt-broken" mkdeb wpasupplicant 2:2.9.0-21)" "$(mkdeb libpcsclite1 1.9.1-1)"
    run plan eth8
    expect_rc 1 "plan: blocked when the runtime does not load"
    expect_out 'libdbus-1.so.3' "plan: shows the loader's line"

    setup plan-noiface
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    rmdir "$R/sys/class/net/eth8"
    run plan eth8
    expect_rc 1 "plan: blocked when the interface is not present"
    expect_out 'interface eth8 is not present' "plan: names the interface"

    setup plan-unknown
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    fake_proc 4242 libpod-abc.scope /usr/sbin/wpa_supplicant -Dwired -ieth8 -c/x.conf
    run plan eth8
    expect_rc 1 "plan: blocked by an unknown owner"
    expect_out 'unknown 4242' "plan: names the unknown process"
    if printf '%s' "$OUT" | grep -q 'next:'; then bad "plan: no next step when blocked"; else ok "plan: no next step when blocked"; fi
}

t_activate_takeover_success() {
    setup takeover
    legacy_box
    authorized
    run activate eth8 --takeover
    expect_rc 0 "takeover: succeeds when authorized"
    expect_grep '^lock free at start of att-wpa-supplicant@eth8.service$' "$S/lock.log" "activate: the load check released the bundle lock before the unit starts"
    expect_nofile "$R/data/on_boot.d/0-att-bypass.sh" "takeover: legacy trigger moved out of on_boot.d"
    expect_nofile "$R/data/on_boot.d/10-wpa_supplicant.sh" "takeover: podman trigger moved out"
    expect_file "$(INSTD eth8)/quarantine/0-att-bypass.sh" "takeover: trigger kept in quarantine"
    expect_grep '^unit wpa_supplicant.service enabled active$' "$(INSTD eth8)/takeover.state" "takeover: unit state recorded"
    expect_grep '^unit setup-att-bypass.service enabled failed$' "$(INSTD eth8)/takeover.state" "takeover: failed oneshot recorded"
    expect_eq "$(state_of wpa_supplicant.service active)" inactive "takeover: legacy unit actually stopped"
    expect_eq "$(state_of wpa_supplicant.service enabled)" disabled "takeover: legacy unit disabled"
    expect_nofile "$R/proc/900" "takeover: legacy process gone"
    expect_eq "$(state_of att-wpa-supplicant@eth8.service active)" active "takeover: our instance running"
    expect_file "$(INSTD eth8)/active" "takeover: flag set"
}

# A setup from the evie-lau guide: a templated unit plus reinstall-wpa.service.
evie_box() { # template
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    unit "$1@eth8.service" enabled active
    fake_proc 910 "$1@eth8.service" /sbin/wpa_supplicant -c/etc/wpa_supplicant/x.conf -Dwired -ieth8
    unit reinstall-wpa.service enabled inactive
    printf 'ExecStart=/bin/systemctl start %s@eth8\n' "$1" >"$S/units/reinstall-wpa.service.cat"
}

t_takeover_evie_lau() {
    for tpl in wpa_supplicant-wired wpa_supplicant; do
        setup "evie-$tpl"
        evie_box "$tpl"
        run activate eth8
        expect_rc 1 "evie($tpl): refuses without --takeover"
        expect_out "unit $tpl@eth8.service" "evie($tpl): lists the templated unit"
        expect_out 'unit reinstall-wpa.service' "evie($tpl): lists reinstall-wpa.service"
        authorized
        run activate eth8 --takeover
        expect_rc 0 "evie($tpl): takeover succeeds"
        expect_eq "$(state_of "$tpl@eth8.service" enabled)" disabled "evie($tpl): unit disabled"
        expect_eq "$(state_of reinstall-wpa.service enabled)" disabled "evie($tpl): reinstall-wpa disabled"
        expect_nofile "$R/proc/910" "evie($tpl): legacy process gone"
        expect_grep '^unit reinstall-wpa.service enabled inactive$' "$(INSTD eth8)/takeover.state" "evie($tpl): reinstall-wpa recorded"
        run deactivate eth8 --restore-legacy
        expect_rc 0 "evie($tpl): restore succeeds"
        expect_eq "$(state_of "$tpl@eth8.service" enabled)" enabled "evie($tpl): unit re-enabled"
        expect_eq "$(state_of "$tpl@eth8.service" active)" active "evie($tpl): unit running again"
        expect_eq "$(state_of reinstall-wpa.service enabled)" enabled "evie($tpl): reinstall-wpa re-enabled"
        expect_nogrep 'start --no-block reinstall-wpa.service' "$S/systemctl.log" "evie($tpl): inactive oneshot not started"
    done
    evie_refused() { # label
        authorized
        : >"$S/systemctl.log"
        run activate eth8 --takeover
        expect_rc 1 "$1: refused"
        expect_out 'ambiguous reinstall-wpa.service' "$1: says which launcher is ambiguous"
        expect_eq "$(state_of wpa_supplicant-wired@eth8.service active)" active "$1: legacy still running"
        expect_nogrep '^\(stop\|disable\)' "$S/systemctl.log" "$1: nothing stopped or disabled"
    }
    setup evie-other
    evie_box wpa_supplicant-wired
    printf 'ExecStart=/bin/systemctl start wpa_supplicant-wired@eth9\n' >"$S/units/reinstall-wpa.service.cat"
    evie_refused "evie(other iface)"
    # A comment that names eth8 does not make an eth9 launcher ours.
    setup evie-comment
    evie_box wpa_supplicant-wired
    printf '# was eth8\nExecStart=/bin/systemctl start wpa_supplicant-wired@eth9\n' >"$S/units/reinstall-wpa.service.cat"
    evie_refused "evie(comment)"
    # A drop-in moved the launcher from eth8 to eth9. Only the effective
    # command counts.
    setup evie-dropin
    evie_box wpa_supplicant-wired
    printf '/bin/systemctl start wpa_supplicant-wired@eth9\n' >"$S/units/reinstall-wpa.service.show"
    evie_refused "evie(drop-in)"
}

# reinstall-wpa.service is mid-start: its ExecStartPost enables the child
# just before the launcher stops. Takeover must leave the child disabled.
t_takeover_launcher_first() {
    setup evie-race
    evie_box wpa_supplicant-wired
    echo activating >"$S/units/reinstall-wpa.service.active"
    mkdir -p "$S/hook"
    printf 'echo enabled >"%s"\n' "$S/units/wpa_supplicant-wired@eth8.service.enabled" \
        >"$S/hook/stop-reinstall-wpa.service"
    authorized
    run activate eth8 --takeover
    expect_rc 0 "race: takeover succeeds"
    l=$(grep -n '^stop reinstall-wpa.service' "$S/systemctl.log" | head -n 1 | cut -d: -f1)
    c=$(grep -n '^stop wpa_supplicant-wired@eth8.service' "$S/systemctl.log" | head -n 1 | cut -d: -f1)
    if [ -n "$l" ] && [ -n "$c" ] && [ "$l" -lt "$c" ]; then
        ok "race: launcher stops before its child"
    else
        bad "race: launcher stops before its child (launcher=$l child=$c)"
    fi
    expect_eq "$(state_of wpa_supplicant-wired@eth8.service enabled)" disabled "race: child stays disabled"
}

check_restored() { # label
    expect_file "$R/data/on_boot.d/0-att-bypass.sh" "$1: trigger restored"
    expect_file "$R/data/on_boot.d/10-wpa_supplicant.sh" "$1: podman trigger restored"
    expect_nofile "$(INSTD eth8)/active" "$1: flag removed"
    expect_eq "$(state_of wpa_supplicant.service enabled)" enabled "$1: legacy unit re-enabled"
    expect_eq "$(state_of wpa_supplicant.service active)" active "$1: legacy unit running again"
    expect_nogrep 'start --no-block setup-att-bypass.service' "$S/systemctl.log" "$1: failed oneshot not restarted"
    case "$(state_of att-wpa-supplicant@eth8.service active)" in
        active) bad "$1: our instance not running" ;;
        *) ok "$1: our instance not running" ;;
    esac
}

t_activate_rollback_unauthorized() {
    setup rollback
    legacy_box
    unauthorized
    run activate eth8 --takeover
    expect_rc 1 "rollback: activation fails when unauthorized"
    check_restored "rollback(unauthorized)"
}

t_activate_rollback_enable_fails() {
    setup rb-enable
    legacy_box
    authorized
    fail_next enable att-wpa-supplicant@eth8.service
    run activate eth8 --takeover
    expect_rc 1 "rollback: activation fails when our unit cannot be enabled"
    check_restored "rollback(enable fails)"
}

t_activate_rollback_start_fails() {
    setup rb-start
    legacy_box
    authorized
    fail_next start att-wpa-supplicant@eth8.service
    run activate eth8 --takeover
    expect_rc 1 "rollback: activation fails when our unit cannot start"
    check_restored "rollback(start fails)"
}

t_activate_legacy_stop_fails() {
    setup rb-stop
    legacy_box
    authorized
    fail_next stop wpa_supplicant.service
    run activate eth8 --takeover
    expect_rc 1 "takeover: aborts when the legacy unit will not stop"
    expect_out 'did not stop' "takeover: says the legacy unit did not stop"
    expect_eq "$(state_of att-wpa-supplicant@eth8.service active)" none "takeover: ours never started next to legacy"
    expect_file "$R/data/on_boot.d/0-att-bypass.sh" "takeover: trigger restored after aborted stop"
}

t_activate_masked_instance() {
    setup masked
    legacy_box
    unit att-wpa-supplicant@eth8.service masked inactive
    run activate eth8 --takeover
    expect_rc 1 "activate: refuses a masked instance before touching legacy"
    expect_eq "$(state_of wpa_supplicant.service active)" active "activate: legacy untouched when ours is masked"
}

t_deactivate_refuses_restore_if_ours_runs() {
    setup deact
    legacy_box
    authorized
    "$SCRIPT" activate eth8 --takeover >/dev/null 2>&1
    fail_next stop att-wpa-supplicant@eth8.service
    run deactivate eth8 --restore-legacy
    expect_rc 1 "deactivate: fails when our unit will not stop"
    expect_nofile "$R/data/on_boot.d/0-att-bypass.sh" "deactivate: legacy not restored while ours runs"
}

t_takeover_records_disabled_running_unit() {
    setup disabled-running
    legacy_box
    unit wpa_supplicant.service disabled active
    unauthorized
    run activate eth8 --takeover
    expect_rc 1 "rollback: fails when unauthorized (disabled-but-running legacy)"
    expect_grep '^unit wpa_supplicant.service disabled active$' "$(INSTD eth8)/takeover.state.restored."* \
        "takeover: ledger keeps one line per unit when is-enabled exits non-zero"
    expect_eq "$(state_of wpa_supplicant.service active)" active "rollback: disabled-but-running legacy restarted"
}

t_restore_failure_keeps_ledger() {
    setup restore-fail
    legacy_box
    authorized
    "$SCRIPT" activate eth8 --takeover >/dev/null 2>&1
    chmod 555 "$R/data/on_boot.d"
    run deactivate eth8 --restore-legacy
    chmod 755 "$R/data/on_boot.d"
    expect_rc 1 "restore: fails when a trigger cannot be moved back"
    expect_file "$(INSTD eth8)/takeover.state" "restore: ledger kept after a failed restore"
    expect_file "$(INSTD eth8)/quarantine/0-att-bypass.sh" "restore: quarantined trigger kept"
}

t_rollback_without_legacy_stops_ours() {
    setup fresh-rollback
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    unauthorized
    run activate eth8
    expect_rc 1 "fresh: activation fails when unauthorized"
    case "$(state_of att-wpa-supplicant@eth8.service active)" in
        active) bad "fresh: our instance stopped after rollback" ;;
        *) ok "fresh: our instance stopped after rollback" ;;
    esac
    expect_nofile "$(INSTD eth8)/active" "fresh: flag removed after rollback"
}

t_stop_query_error_is_not_stopped() {
    setup query-error
    legacy_box
    authorized
    printf '' >"$S/units/wpa_supplicant.service.active"
    fail_next stop wpa_supplicant.service
    run activate eth8 --takeover
    expect_rc 1 "takeover: an unreadable unit state does not count as stopped"
}

t_validate_exact_modes() {
    setup modes
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    chmod 700 "$(INSTD eth8)/certs/PrivateKey.pem"
    run validate eth8
    expect_rc 1 "validate: rejects an executable key file (mode 700)"
}

# ---------- tests: boot, uninstall, check, units ----------

t_boot() {
    setup boot-inert
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    : >"$S/systemctl.log"
    run boot
    expect_rc 0 "boot: inert succeeds"
    expect_nogrep 'start' "$S/systemctl.log" "boot: inert starts nothing"
    expect_grep 'disable --quiet att-wpa-supplicant@eth8.service' "$S/systemctl.log" "boot: inert disables the instance"
    : >"$(INSTD eth8)/active"
    : >"$S/systemctl.log"
    run boot
    expect_grep 'start --no-block att-wpa-supplicant@eth8.service' "$S/systemctl.log" "boot: active starts instance"
    expect_eq "$(state_of att-wpa-supplicant@eth8.service active)" active "boot: the instance precheck passed"
    expect_eq "$(head -n 1 "$(CHOICE eth8)" 2>/dev/null)" cur "boot: the instance start chose the runtime"
}

t_uninstall() {
    setup uninstall
    legacy_box
    authorized
    "$SCRIPT" activate eth8 --takeover >/dev/null 2>&1
    run uninstall
    expect_rc 1 "uninstall: refuses after takeover without --restore-legacy"
    expect_file "$R/etc/systemd/system/att-wpa-supplicant@.service" "uninstall: nothing removed after refusal"
    run uninstall --restore-legacy
    expect_rc 0 "uninstall: succeeds with --restore-legacy"
    expect_file "$(BD)/root/usr/sbin/wpa_supplicant" "uninstall: keeps the bundles and their runtime"
    expect_nofile "$R/etc/systemd/system/att-wpa-supplicant@.service" "uninstall: units removed"
    expect_nofile "$R/data/on_boot.d/01-att-wpa-supplicant.sh" "uninstall: boot entry removed"
    expect_file "$(INSTD eth8)/certs/PrivateKey.pem" "uninstall: keeps /data"
    expect_file "$R/data/on_boot.d/0-att-bypass.sh" "uninstall: restores legacy setup"
    expect_eq "$(state_of wpa_supplicant.service active)" active "uninstall: legacy supplicant running again"
}

t_check() {
    setup check
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    : >"$(INSTD eth8)/active"
    authorized
    run check
    expect_rc 1 "check: fails before precheck chose the runtime"
    expect_out 'FAIL eth8: no runtime chosen: precheck did not pass since the unit started' "check: says that no runtime was chosen"
    expect_out 'Restart the unit: systemctl restart att-wpa-supplicant@eth8.service' "check: names the fix"
    systemctl start att-wpa-supplicant@eth8.service
    : >"$S/cli.log"
    printf '#!/bin/sh\ncase "$*" in\n*addr*) echo "4: eth8    inet 203.0.113.7/22 brd 203.0.113.255 scope global eth8" ;;\n*route*) echo "1.1.1.1 via 203.0.113.1 dev eth8 src 203.0.113.7 uid 0" ;;\nesac\n' >"$B/ip"
    chmod +x "$B/ip"
    run check
    expect_rc 0 "check: passes when authorized"
    expect_grep "LD_LIBRARY_PATH=$(BD)/root/usr/lib/aarch64-linux-gnu\$" "$S/cli.log" "check: wpa_cli gets the runtime LD_LIBRARY_PATH"
    expect_out 'INFO eth8: runtime at start: wpa_supplicant v2.10-test from bundle bullseye-arm64 (libpcsclite1 1.9.1-1, wpasupplicant 2:2.9.0-21)$' "check: reports the runtime version, bundle, and packages that precheck recorded"
    if printf '%s' "$OUT" | grep -q 'changed since the start'; then bad "check: no note while the bundle is unchanged"; else ok "check: no note while the bundle is unchanged"; fi
    # A new bundle after the start: check still reports what started, and
    # says that the bundle changed.
    "$SCRIPT" import-bundle "$(mktgz 2:2.10-7)" >/dev/null 2>&1
    run check
    expect_rc 0 "check: passes after an import while the supplicant runs"
    expect_out 'INFO eth8: runtime at start: wpa_supplicant v2.10-test from bundle bullseye-arm64 (libpcsclite1 1.9.1-1, wpasupplicant 2:2.9.0-21)$' "check: after an import, still reports what started"
    expect_out 'INFO eth8: bundle bullseye-arm64 changed since the start' "check: says that the bundle changed since the start"
    # The chosen tree has no wpa_cli now: check uses the other runtime's.
    rm -f "$(BD)"/root/usr/sbin/wpa_cli
    run check
    expect_rc 0 "check: uses the wpa_cli of .prev when the chosen tree has none"
    # A wpa_cli that runs but gives no status (it cannot load): the same.
    printf '#!/bin/sh\nexit 127\n' >"$(BD)"/root/usr/sbin/wpa_cli
    chmod +x "$(BD)"/root/usr/sbin/wpa_cli
    : >"$S/cli.log"
    run check
    expect_rc 0 "check: uses the wpa_cli of .prev when the chosen one gives no status"
    expect_grep "LD_LIBRARY_PATH=$(BD).prev/root/" "$S/cli.log" "check: the status came from the wpa_cli of .prev"
    expect_out 'INFO eth8: interface has an IPv4 address' "check: reports the WAN address as information"
    expect_out 'INFO eth8: IPv4 route to the internet goes out on eth8' "check: reports the route as information"
    if printf '%s' "$OUT" | grep -q '203\.0\.113'; then bad "check: never prints the WAN address"; else ok "check: never prints the WAN address"; fi
    printf '#!/bin/sh\nexit 2\n' >"$B/ip"
    run check
    expect_rc 0 "check: no address and no route do not change the exit status"
    expect_out 'no IPv4 route to the internet' "check: reports a missing route"
    expect_out 'matches private key' "check: cert/key match reported"
    if printf '%s' "$OUT" | grep -q 'AA:BB'; then bad "check: never prints identity"; else ok "check: never prints identity"; fi
    unit att-wpa-supplicant@eth8.service enabled inactive
    run check
    expect_rc 1 "check: fails when the unit is not active"
    unit att-wpa-supplicant@eth8.service enabled active
    printf 'Supplicant PAE state=HELD\nsuppPortStatus=Unauthorized\n' >"$S/wpa_status"
    run check
    expect_rc 1 "check: fails when unauthorized"
    authorized
    printf 'garbage\n' >"$(INSTD eth8)/certs/PrivateKey.pem"
    printf 'garbage\n' >"$(INSTD eth8)/certs/Client.pem"
    run check
    expect_rc 1 "check: unreadable cert and key do not count as a match"
}

mktgz_rel() { # codename version -> path of a <codename>-arm64 bundle archive
    d="$T/tgzr-$1/$1-arm64"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$(mkdeb wpasupplicant "$2")" "$(mkdeb libpcsclite1 1.9.1-1)" "$d/"
    (cd "$d" && sha256sum -- *.deb >SHA256SUMS)
    printf 'codename=%s\narch=arm64\npkg=wpasupplicant %s\n' "$1" "$2" >"$d/MANIFEST"
    tar -czf "$T/tgzr-$1.tgz" -C "$T/tgzr-$1" "$1-arm64"
    printf '%s' "$T/tgzr-$1.tgz"
}

t_import_bundle_several() {
    setup multi
    bds="$R/data/unifi-common-addons/att-wpa-supplicant/bundles"
    run import-bundle "$(mktgz_rel bullseye 2:2.9.0-21)" "$(mktgz_rel trixie 2:2.10-1)"
    expect_rc 0 "import-bundle: two archives in one call"
    expect_grep 'wpasupplicant 2:2.9.0-21' "$bds/bullseye-arm64/MANIFEST" "import-bundle: first archive imported"
    expect_grep 'wpasupplicant 2:2.10-1' "$bds/trixie-arm64/MANIFEST" "import-bundle: second archive imported"
    expect_out 'trixie-arm64 is not this gateway' "import-bundle: notes the bundle for another release"
    # A failing second archive leaves the first imported.
    rm -rf "$bds"
    printf 'not a tarball\n' >"$T/bad.tgz"
    run import-bundle "$(mktgz_rel bullseye 2:2.9.0-21)" "$T/bad.tgz" "$(mktgz_rel trixie 2:2.10-1)"
    expect_rc 1 "import-bundle: a failing second archive exits non-zero"
    expect_out "import-bundle: $T/bad.tgz failed" "import-bundle: the message names the failing file"
    run import-bundle "$(mktgz_rel bullseye 2:2.9.0-21)" "$T/missing.tgz"
    expect_rc 1 "import-bundle: a missing file is refused before any import"
    expect_out "$T/missing.tgz is not a file" "import-bundle: names the missing file"
    expect_grep 'wpasupplicant 2:2.9.0-21' "$bds/bullseye-arm64/MANIFEST" "import-bundle: the archive before the failure stays imported"
    expect_nofile "$bds/trixie-arm64" "import-bundle: stops at the first failure"
    # A rename that fails inside the swap fails the whole command, also
    # with several archives.
    rm -rf "$bds"
    printf '#!/bin/sh\ncase "$*" in *bookworm-arm64) echo "mv: stub failure" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' >"$B/mv"
    chmod +x "$B/mv"
    run import-bundle "$(mktgz_rel bullseye 2:2.9.0-21)" "$(mktgz_rel bookworm 2:2.10-12)" "$(mktgz_rel trixie 2:2.10-1)"
    rm -f "$B/mv"
    expect_rc 1 "import-bundle: a failed rename fails the command"
    expect_out 'cannot install bookworm-arm64' "import-bundle: names the failed rename"
    if printf '%s' "$OUT" | grep -q 'bookworm-arm64 installed'; then bad "import-bundle: no success message after a failed rename"; else ok "import-bundle: no success message after a failed rename"; fi
    expect_nofile "$bds/trixie-arm64" "import-bundle: stops after a failed rename"
    [ -z "$(find "$bds" -name '.import.*')" ] && ok "import-bundle: no temp dir left after a failure" || bad "import-bundle: no temp dir left after a failure"
}

t_check_bundles() {
    setup chkb
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    : >"$(INSTD eth8)/active"
    systemctl start att-wpa-supplicant@eth8.service
    # Without the bundle, its runtime (and wpa_cli) is gone too.
    rm -rf "$R/data/unifi-common-addons/att-wpa-supplicant/bundles"
    authorized
    printf '#!/bin/sh\nexit 2\n' >"$B/ip"
    chmod +x "$B/ip"
    bds="$R/data/unifi-common-addons/att-wpa-supplicant/bundles"
    run check
    expect_rc 1 "check: fails without the bundle: no wpa_cli to ask"
    expect_out "FAIL eth8: no runtime at $R/data/unifi-common-addons/att-wpa-supplicant/bundles/bullseye-arm64/root, or it cannot be read. Run import-bundle" "check: says that the runtime is gone"
    expect_out '^WARN bundles: none for this release (bullseye-arm64). Run fetch or import-bundle$' "check: warns when no bundle matches the release"
    "$SCRIPT" import-bundle "$(mktgz_rel bullseye 2:2.9.0-21)" "$(mktgz_rel trixie 2:2.10-1)" >/dev/null 2>&1
    "$SCRIPT" import-bundle "$(mktgz_rel trixie 2:2.10-2)" >/dev/null 2>&1
    expect_file "$bds/trixie-arm64.prev" "check: a .prev directory exists for the test"
    mkdir -p "$bds/.hidden-arm64"
    run check
    expect_rc 0 "check: bundles line does not change the exit status"
    expect_out '^INFO bundles: bullseye-arm64, trixie-arm64 (this release: bullseye-arm64)$' "check: lists both bundles and marks this release"
    printf '%s\n' "$OUT" >"$T/check.out"
    expect_nogrep 'prev' "$T/check.out" "check: .prev is not listed"
    expect_nogrep 'hidden' "$T/check.out" "check: dot-directories are not listed"
    expect_eq "$(grep -c 'bundles:' "$T/check.out")" 1 "check: bundles line is printed once"
    rm -rf "$bds/bullseye-arm64"
    run check
    expect_rc 1 "check: fails without the bundle for this release"
    expect_out '^WARN bundles: trixie-arm64. None for this release (bullseye-arm64)' "check: warns when only other releases are present, and lists them"
    unit att-wpa-supplicant@eth8.service enabled inactive
    run check
    expect_rc 1 "check: still fails when the unit is not active"
}

t_legacy_file() {
    setup legacy-file
    expect_file "$R/data/unifi-common-addons/att-wpa-supplicant/legacy.sh" "install: copies legacy.sh"
    # The installed copy runs through a symlink, like /usr/local/sbin.
    ln -s "$R/data/unifi-common-addons/att-wpa-supplicant/att-wpa-supplicant" "$T/link"
    OUT=$("$T/link" plan eth9 2>&1) && RC=0 || RC=$?
    expect_out 'eth9: no instance' "legacy.sh: found through a symlink to the script"
    # install through the link, as from /usr/local/sbin, reinstalls in place.
    OUT=$("$T/link" install 2>&1) && RC=0 || RC=$?
    expect_rc 0 "install: works through a symlink to the installed script"
    # Without legacy.sh, the commands that need it stop with a clear
    # message. The others work.
    mkdir "$T/alone"
    cp "$SCRIPT" "$T/alone/att-wpa-supplicant"
    OUT=$("$T/alone/att-wpa-supplicant" plan eth8 2>&1) && RC=0 || RC=$?
    expect_rc 1 "legacy.sh missing: plan exits 1"
    expect_out "missing or unreadable $T/alone/legacy.sh" "legacy.sh missing: names the file"
    OUT=$("$T/alone/att-wpa-supplicant" validate 2>&1) && RC=0 || RC=$?
    if printf '%s' "$OUT" | grep -q 'legacy.sh'; then bad "legacy.sh missing: validate does not need it"; else ok "legacy.sh missing: validate does not need it"; fi
    # deactivate --restore-legacy checks legacy.sh before it stops anything.
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    : >"$(INSTD eth8)/active"
    unit att-wpa-supplicant@eth8.service enabled active
    OUT=$("$T/alone/att-wpa-supplicant" deactivate eth8 --restore-legacy 2>&1) && RC=0 || RC=$?
    expect_rc 1 "legacy.sh missing: deactivate --restore-legacy exits 1"
    expect_eq "$(state_of att-wpa-supplicant@eth8.service active)" active "legacy.sh missing: deactivate leaves the supplicant running"
    expect_file "$(INSTD eth8)/active" "legacy.sh missing: deactivate leaves the instance activated"
}

# Under systemd, each log line reaches the journal once.
t_journal_once() {
    setup journal
    bundle_ready
    "$SCRIPT" add-instance eth8 "$T/src" >/dev/null 2>&1
    # Interactive: stderr and logger.
    : >"$S/logger.log"
    OUT=$("$SCRIPT" precheck eth8 2>&1) && RC=0 || RC=$?
    expect_eq "$(grep -c 'runtime ready' "$S/logger.log")" 1 "log: an interactive command also writes to logger"
    expect_out 'runtime ready' "log: an interactive command writes to stderr"
    # Under systemd with stderr on the journal: stderr only.
    : >"$S/logger.log"
    : >"$T/journal"
    js=$(stat -L -c '%d:%i' "$T/journal")
    JOURNAL_STREAM=$js "$SCRIPT" precheck eth8 2>>"$T/journal"
    expect_eq "$(grep -c 'runtime ready' "$T/journal")" 1 "log: under systemd, the line goes to stderr (the journal)"
    expect_eq "$(grep -c . "$S/logger.log")" 0 "log: under systemd, no logger call (each line once in the journal)"
    # stderr is the journal stream, but the write fails (/dev/full stands
    # in for a disconnected journal): logger keeps the line.
    : >"$S/logger.log"
    JOURNAL_STREAM=$(stat -L -c '%d:%i' /dev/full) "$SCRIPT" precheck eth8 2>/dev/full
    expect_eq "$(grep -c 'runtime ready' "$S/logger.log")" 1 "log: a failed write to the journal stream still goes to logger"
    # JOURNAL_STREAM set, but stderr is elsewhere (redirected): logger too.
    : >"$S/logger.log"
    : >"$T/other"
    JOURNAL_STREAM=$js "$SCRIPT" precheck eth8 2>>"$T/other"
    expect_eq "$(grep -c 'runtime ready' "$S/logger.log")" 1 "log: a stale JOURNAL_STREAM does not drop the logger line"
}

t_units_static() {
    u="$HERE/../systemd/att-wpa-supplicant@.service"
    grep -q '^ConditionPathExists=/data/unifi-common-addons/att-wpa-supplicant/instances/%i/active$' "$u" && ok "unit: activation via ConditionPathExists" || bad "unit: activation via ConditionPathExists"
    grep -q 'ExecCondition' "$u" && bad "unit: no ExecCondition" || ok "unit: no ExecCondition"
    grep -q '^RuntimeDirectory=att-wpa-supplicant/%i$' "$u" && ok "unit: RuntimeDirectory is only the control socket directory (/run is noexec on UniFi OS)" || bad "unit: RuntimeDirectory is only the control socket directory (/run is noexec on UniFi OS)"
    grep -q 'BindsTo' "$u" && bad "unit: no BindsTo" || ok "unit: no BindsTo"
}

for t in t_install_inert t_fetch t_add_instance t_validate_rejects \
    t_runtime_start t_runtime_refusals t_runtime_prev t_import_unpacks t_swap_while_running t_install_upgrade \
    t_bundle_swap_keeps_previous t_bundle_lock \
    t_activate_refuses_unknown t_activate_dormant_launchers t_activate_needs_takeover t_plan \
    t_activate_takeover_success t_takeover_evie_lau t_takeover_launcher_first t_activate_setup_dropin_other t_activate_rollback_unauthorized t_activate_rollback_enable_fails \
    t_activate_rollback_start_fails t_activate_legacy_stop_fails t_activate_masked_instance \
    t_deactivate_refuses_restore_if_ours_runs t_takeover_records_disabled_running_unit \
    t_restore_failure_keeps_ledger t_rollback_without_legacy_stops_ours \
    t_stop_query_error_is_not_stopped t_validate_exact_modes t_boot t_uninstall t_check t_import_bundle_several t_check_bundles t_legacy_file t_journal_once t_units_static; do
    $t
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
