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
grep -m1 '^_ts_ipv4()' "$SRC" > "$T/fn.sh"
awk '/^_ts_state\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC" >> "$T/fn.sh"
awk '/^_ts_key\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC" >> "$T/fn.sh"
awk '/^_ts_running\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC" >> "$T/fn.sh"
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

# _ts_ipv4: one address, no stderr; empty -> the "not connected" caller; remote payloads define it
mkdir -p "$T/b2"
cat > "$T/b2/tailscale" <<'X'
#!/bin/bash
case "$1" in
  ip) [ "$TS_IP_MODE" = none ] && { echo "noise: not logged in" >&2; exit 1; }
      printf '100.64.0.1\n100.64.0.2\n'; echo "stderr noise" >&2 ;;
  status) printf '{\n  "BackendState": "Running",\n  "Self": {\n  "KeyExpiry": "2999-01-01T00:00:00Z"\n  }\n}\n' ;;
esac
X
chmod +x "$T/b2/tailscale"
OLDPATH=$PATH; export PATH="$T/b2:$PATH"
unset TS_IP_MODE; V=$(_ts_ipv4 2>"$T/err")
check 7 "_ts_ipv4: two lines + stderr noise -> first address only, nothing on stderr" '[ "$V" = 100.64.0.1 ] && [ ! -s "$T/err" ]'
export TS_IP_MODE=none; V=$(_ts_ipv4 2>"$T/err")
check 8 "_ts_ipv4: no address -> empty, no stderr" '[ -z "$V" ] && [ ! -s "$T/err" ]'
LINE=$(grep -m1 'ts_ip=\${ts_ip:-not connected}' "$SRC")
OUTC=$(eval "$LINE"; echo "$ts_ip"); unset TS_IP_MODE; OUTD=$(eval "$LINE"; echo "$ts_ip")
check 9 "RDP caller: no address prints 'not connected', address prints the first one" '[ -n "$LINE" ] && [ "$OUTC" = "not connected" ] && [ "$OUTD" = 100.64.0.1 ]'
LISTS=$(grep -v '^ *#' "$SRC" | grep -o 'declare -f [^;)}]*_ts_state[^;)}]*')
NL=$(wc -l <<<"$LISTS")
BADL=$(grep -vc '_ts_ipv4' <<<"$LISTS")
check 10 "every declare -f list with _ts_state (found $NL) also ships _ts_ipv4" '[ "$NL" -ge 5 ] && [ "$BADL" = 0 ]'
export PATH="$OLDPATH"
bad=0
while read -r list; do
  names=; for n in ${list#declare -f }; do declare -F "$n" >/dev/null && names="$names $n"; done
  payload="$(declare -f $names)
_ts_state; echo \"TS_IP=\$(_ts_ipv4)\""
  RES=$(env -i PATH="$T/b2:/usr/bin:/bin" bash -s <<<"$payload" 2>&1)
  [[ "$RES" == "Running 2999-01-01"*"100.64.0.1"$'\n'"TS_IP=100.64.0.1" ]] || { bad=1; echo "  payload [$list]: $RES"; }
done <<<"$LISTS"
check 11 "each remote payload runs in a clean bash -s (no 'command not found'), yields TS_IP=first" '[ $bad = 0 ]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
