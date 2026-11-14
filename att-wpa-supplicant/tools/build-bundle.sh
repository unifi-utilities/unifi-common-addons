#!/bin/sh
# Builds a bundle for each named Debian release, for one architecture. A
# bundle holds the two packages that the addon unpacks into its runtime:
# wpasupplicant and libpcsclite1. Runs on any machine with Docker. It needs
# no emulation: the container runs on the host architecture, and APT is told
# the target architecture, so it only downloads the packages.
# Usage: tools/build-bundle.sh <codename>[,<codename>...] <arch> [outdir]
# Example: tools/build-bundle.sh bullseye,bookworm,trixie arm64
# Output: <outdir>/<codename>-<arch>.tgz for each codename, for
# "att-wpa-supplicant import-bundle". If one codename fails, the script
# builds the rest and exits non-zero at the end.
set -eu
PKGS="wpasupplicant libpcsclite1"
[ $# -ge 2 ] || { echo "usage: $0 <codename>[,<codename>...] <arch> [outdir]" >&2; exit 2; }
codename=$1
arch=$2
out=$(cd "${3:-.}" && pwd)
case "$codename" in
*,*)
    # Several codenames: build each with a fresh run of this script. $0 can
    # be a bare name found through PATH, so resolve it first.
    if ! self=$(command -v -- "$0") || ! self=$(readlink -f "$self"); then
        echo "cannot find $0" >&2
        exit 2
    fi
    old_ifs=$IFS
    IFS=,
    # shellcheck disable=SC2086 # split on commas
    set -- $codename
    IFS=$old_ifs
    for c; do
        case "$c" in *[!a-z]* | '') echo "invalid codename '$c' (use lowercase letters only)" >&2; exit 2 ;; esac
    done
    failed=''
    for c; do
        sh "$self" "$c" "$arch" "$out" || { echo "build failed for $c" >&2; failed="$failed $c"; }
    done
    [ -z "$failed" ] || { echo "failed codenames:$failed" >&2; exit 1; }
    exit 0
    ;;
esac
case "$codename" in *[!a-z]* | '') echo "invalid codename '$codename' (use lowercase letters only)" >&2; exit 2 ;; esac
case "$arch" in *[!a-z0-9]* | '') echo "invalid arch '$arch'" >&2; exit 2 ;; esac
# Releases whose security support ended move to archive.debian.org. The
# security pool on deb.debian.org then returns 404 (bullseye since
# 2026-08-31). APT still checks the archive's Release signatures.
archived=0
case "$codename" in buster | bullseye) archived=1 ;; esac
name="$codename-$arch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/$name"

docker run --rm -e "TARGET_ARCH=$arch" -e "PKGS=$PKGS" -e "ARCHIVED=$archived" -e "CODENAME=$codename" \
    -v "$work/$name:/out" "debian:$codename" sh -euc '
    if [ "$ARCHIVED" = 1 ]; then
        rm -f /etc/apt/sources.list.d/*
        printf "deb http://archive.debian.org/debian %s main\ndeb http://archive.debian.org/debian %s-updates main\ndeb http://archive.debian.org/debian-security %s-security main\n" \
            "$CODENAME" "$CODENAME" "$CODENAME" > /etc/apt/sources.list
    fi
    printf "APT::Architecture \"%s\";\nAPT::Architectures \"%s\";\n" "$TARGET_ARCH" "$TARGET_ARCH" \
        > /etc/apt/apt.conf.d/00target-arch
    apt-get update -qq
    cd /out && apt-get download -qq $PKGS
    for p in $PKGS; do
        n=0
        for f in *.deb; do [ "$(dpkg-deb -f "$f" Package)" = "$p" ] && n=$((n + 1)); done
        [ "$n" -eq 1 ] || { echo "expected one $p package, got $n" >&2; exit 1; }
    done
    for f in *.deb; do
        case "$(dpkg-deb -f "$f" Architecture)" in
            "$TARGET_ARCH"|all) ;;
            *) echo "wrong architecture: $f" >&2; exit 1 ;;
        esac
        printf "pkg=%s %s\n" "$(dpkg-deb -f "$f" Package)" "$(dpkg-deb -f "$f" Version)"
    done > /out/.pkglist
    chown -R '"$(id -u):$(id -g)"' /out
'

(cd "$work/$name" && sha256sum -- *.deb > SHA256SUMS)  # host needs only coreutils
{
    printf 'codename=%s\narch=%s\nbuilt=%s\nsource=%s\n' "$codename" "$arch" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "tools/build-bundle.sh (docker debian:$codename)"
    cat "$work/$name/.pkglist"
} > "$work/$name/MANIFEST.tmp"
rm -f "$work/$name/.pkglist"
mv "$work/$name/MANIFEST.tmp" "$work/$name/MANIFEST"
tar -czf "$out/$name.tgz" -C "$work" "$name"
echo "wrote $out/$name.tgz ($(grep -c '^pkg=' "$work/$name/MANIFEST") packages)"
