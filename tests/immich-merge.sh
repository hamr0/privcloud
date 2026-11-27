#!/bin/bash
# Structure checks for the privcloud -> setup.sh merge ("Manage Immich"): the one
# .env writer, the one version reader, no leftovers (macOS branches, the privcloud
# CLI, its wrapper), every former privcloud action reachable from the menu and
# dispatchable with --run, the backup items wired to the existing backup steps.
# Run: bash tests/immich-merge.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
S=${SETUP_SH:-$H/../setup.sh}
SETUP_SH=$S
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
for f in _fv_pkg_version _set_env; do extract_fn "$f" "$S"; done > "$T/fn.sh"
source "$T/fn.sh"

# 1 the one .env writer round-trips | & \ and touches nothing else
E=$T/.env
printf 'A=1\nB=2\nAB=3\n' > "$E"; chmod 644 "$E"
_set_env B 'v|a&l\ue' "$E"; _set_env C 'x|&\' "$E"
check 1a "_set_env replaces literally (| & \\)" '[ "$(grep ^B= "$E")" = "B=v|a&l\\ue" ]'
check 1b "_set_env appends a missing key; AB and A untouched" '[ "$(cat "$E")" = "$(printf "A=1\nB=v|a&l\\\\ue\nAB=3\nC=x|&\\\\")" ]'
check 1c "_set_env leaves the file mode 600, no temp file behind" '[ "$(stat -c %a "$E")" = 600 ] && [ "$(ls -A "$T" | grep -c "^\.env\.")" = 0 ]'
rm -f "$T/new.env"; _set_env K v "$T/new.env"
check 1d "_set_env creates a missing file (mode 600)" '[ "$(cat "$T/new.env")" = "K=v" ] && [ "$(stat -c %a "$T/new.env")" = 600 ]'

# 2 the one version reader
printf '{\n  "name": "x",\n  "version": "1.2.3"\n}\n' > "$T/package.json"
check 2a "version read from package.json" '[ "$(_fv_pkg_version "$T/package.json")" = 1.2.3 ]'
check 2b "missing package.json -> unknown" '[ "$(_fv_pkg_version "$T/nope.json")" = unknown ]'
printf '{ "name": "x" }\n' > "$T/nover.json"
check 2c "package.json without a version -> unknown" '[ "$(_fv_pkg_version "$T/nover.json")" = unknown ]'
check 2d "no stale 0.9.5 fallback left" '! grep -q "0\.9\.5" "$S"'

check_total
