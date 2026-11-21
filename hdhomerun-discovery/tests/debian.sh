#!/bin/sh
# Run tests/run.sh in Debian 11, 12, and 13 containers, as root. UniFi OS
# 4.x and later is built on these releases, so the script must work with
# their versions of sh, flock, sed, awk, and coreutils. Also compile
# proxy.pl with the perl of each slim image, which has perl-base only:
# every module the proxy uses must be in perl-base.
# Needs docker. Usage: tests/debian.sh      Exit 0 only when all pass.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
fail=0
for r in bullseye bookworm trixie; do
    out=$(docker run --rm -v "$HERE:/a:ro" "debian:$r-slim" sh -c '
        sh /a/tests/run.sh >/tmp/out 2>&1; rc=$?
        tail -n 1 /tmp/out
        [ "$rc" -eq 0 ] || { grep "^FAIL" /tmp/out; exit 1; }
        perl -c /a/proxy.pl 2>&1') || fail=1
    echo "$r: $(printf '%s' "$out" | tr '\n' ' ')"
done
[ "$fail" -eq 0 ]
