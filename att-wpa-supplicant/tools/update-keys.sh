#!/bin/sh
# Makes keys/debian-archive.asc again: the Debian archive keys that
# "att-wpa-supplicant fetch <codename>" trusts. It takes them from the
# debian-archive-keyring package in a Debian container, and prints each
# key's fingerprint. Compare the fingerprints with
# https://ftp-master.debian.org/keys.html before you commit the file.
# Usage: tools/update-keys.sh [debian-image]   (default: debian:trixie)
# Needs Docker.
set -eu
image=${1:-debian:trixie}
here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/keys/debian-archive.asc"
mkdir -p "$here/keys"
docker run --rm "$image" sh -euc '
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends gpg >/dev/null 2>&1
    echo "keyring: debian-archive-keyring $(dpkg-query -W -f "\${Version}" debian-archive-keyring)" >&2
    for f in /etc/apt/trusted.gpg.d/debian-archive-*.asc; do
        gpg --show-keys --with-fingerprint --keyid-format long "$f" 2>/dev/null |
            sed -n "s/^ *Key fingerprint = //p; s/^uid *//p" >&2
        cat "$f"
    done
' >"$out.tmp"
mv "$out.tmp" "$out"
echo "wrote $out ($(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "$out") keys)" >&2
