#!/bin/sh
# Runs the simulation tests of ra-deprecate against its script. Needs python3
# only; nothing is sent and no state file is touched.
set -eu

ADDON_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

exec python3 "$ADDON_DIR/tests/simulate.py" "$ADDON_DIR/scripts/ra-deprecate"
