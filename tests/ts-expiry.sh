#!/bin/bash
# Tests for the Tailscale key-expiry day count in setup.sh (_ts_state, shown by
# _ts_key / _ts_word). Days left round UP, so "expired" only means actually
# expired: +12h reads "1 day", -1h reads expired, +45d stays 45.
# Run: bash tests/ts-expiry.sh   (exits non-zero on any failure)
# Stubbed tailscale and date (a fixed "now"): no real tailscale, no network.
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
GREEN= RED= YELLOW= DIM= NC= BOLD=
awk '/^_ts_state\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC" > "$T/fn.sh"
awk '/^_ts_key\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC" >> "$T/fn.sh"
source "$T/fn.sh"
cat > "$T/bin/tailscale" <<'X'
#!/bin/bash
case "$1" in
  status) printf '{\n  "BackendState": "Running",\n  "Self": {\n  "KeyExpiry": "%s"\n  }\n}\n' "$KEY_EXPIRY" ;;
  ip) echo 100.64.0.1 ;;
esac
X
cat > "$T/bin/date" <<'X'
#!/bin/bash
[ "$*" = "+%s" ] && { echo "$NOW"; exit; }
exec /usr/bin/date "$@"
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
PASS=0; FAILN=0
EXP=2026-06-01T12:00:00Z; EPOCH=$(/usr/bin/date -d "$EXP" +%s)
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rec='$REC' key='$KEY']"; FAILN=$((FAILN+1)); fi; }
at() { # seconds until expiry
  export KEY_EXPIRY=$EXP NOW=$(( EPOCH - $1 )); REC=$(_ts_state); KEY=$(_ts_key "$REC"); }
at 43200;      check 1 "+12h: 1 day left, not expired" '[ "$(cut -d" " -f3 <<<"$REC")" = 1 ] && [[ "$KEY" == *"1 days"* && "$KEY" != *expired* ]]'
at -3600;      check 2 "-1h: expired" '[ "$(cut -d" " -f3 <<<"$REC")" = 0 ] && [[ "$KEY" == expired* ]]'
at $((45*86400)); check 3 "+45d: 45 days, unchanged" '[ "$(cut -d" " -f3 <<<"$REC")" = 45 ] && [[ "$KEY" == "expires 2026-06-01 (45 days)" ]]'
at 0;          check 4 "exactly now: expired" '[ "$(cut -d" " -f3 <<<"$REC")" = 0 ]'
at 86400;      check 5 "+24h exactly: 1 day" '[ "$(cut -d" " -f3 <<<"$REC")" = 1 ]'
at $((29*86400+3600)); check 6 "+29d1h: rounds up to 30 days" '[ "$(cut -d" " -f3 <<<"$REC")" = 30 ]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
