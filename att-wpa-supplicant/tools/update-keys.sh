#!/bin/sh
# Makes keys/debian-<codename>.asc again: one key file per release for
# "att-wpa-supplicant fetch <codename>". It takes the keys from the
# debian-archive-keyring package in a Debian container, and prints each
# file's fingerprints. Compare them with
# https://ftp-master.debian.org/keys.html before you commit the files.
# Usage: tools/update-keys.sh [debian-image]   (default: debian:trixie)
# Needs Docker.
set -eu
image=${1:-debian:trixie}
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$here/keys"
out=''
trap '[ -z "$out" ] || rm -f -- "$out.tmp"' EXIT
trap 'exit 1' INT TERM HUP
for c in bullseye bookworm trixie; do
    out="$here/keys/debian-$c.asc"
    echo "keys/debian-$c.asc:" >&2
    docker run --rm "$image" sh -euc '
        c=$1
        apt-get update -qq >/dev/null
        apt-get install -y -qq --no-install-recommends gpg >/dev/null 2>&1
        echo "keyring: debian-archive-keyring $(dpkg-query -W -f "\${Version}" debian-archive-keyring)" >&2
        set -- /etc/apt/trusted.gpg.d/debian-archive-"$c"-*.asc
        [ "$#" -eq 3 ] || { echo "expected three keys for $c" >&2; exit 1; }
        for f; do
            gpg --show-keys --with-fingerprint --keyid-format long "$f" >&2
            cat "$f"
        done
    ' sh "$c" >"$out.tmp"
    mv "$out.tmp" "$out"
    echo "wrote $out ($(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "$out") keys)" >&2
done
