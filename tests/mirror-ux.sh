#!/bin/bash
# Look-and-feel of the mirror flow in setup.sh: the colour-coded copy-mode
# question (_mirror_ask) and the preview progress line (_mirror_preview).
# Run: bash tests/mirror-ux.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
# Real colour codes here (sync-mirror.sh runs with them empty).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
{ grep -E '^(ok|fail|info|warn)\(\)' "$SRC"
  grep -E '^MIRROR_WIPE_MIN=' "$SRC"
  for f in _mirror_flush _mirror_ask _mirror_preview; do
    awk -v f="$f" '$0 ~ "^"f"\\(\\)"{p=1} p{print} p&&/^}/{exit}' "$SRC"; done; } > "$T/fn.sh"
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
_server_sudo_run() { bash -c "$1"; }   # "root on the server" = this shell
mkdir -p "$T/tmp"; export TMPDIR=$T/tmp XDG_STATE_HOME=$T/state
PASS=0; FAILN=0
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [out=$(printf '%q' "${OUT:0:300}")]"; FAILN=$((FAILN+1)); fi; }
plain() { sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }

# 1 copy-mode question colours
OUT=$(printf '\n' | _mirror_ask 2>&1)
check 1a "question line is yellow" '[[ "$OUT" == *"$(printf "${YELLOW}Deleted at source → also delete at destination?${NC}")"* ]]'
check 1b "'append only' is green" '[[ "$OUT" == *"$(printf "${GREEN}append only${NC}")"* ]]'
check 1c "'delete' and 'mirror' are red" '[[ "$OUT" == *"$(printf "${RED}delete${NC}")"* && "$OUT" == *"$(printf "${RED}mirror${NC}")"* ]]'
check 1d "text unchanged once colours are stripped" '[[ "$(plain "$OUT")" == *"Enter = no, append only · type \"delete\" = mirror: "* ]]'
ask() { sync_mode=; printf '%s\n' "$1" > "$T/in"; _mirror_ask < "$T/in" >/dev/null 2>&1; echo "$sync_mode"; }
m1=$(ask delete); m2=$(ask " delete"); m3=$(ask ""); m4=$(ask Delete)
check 1e "exact word 'delete' = mirror; padded, capitalised or empty = append" '[ "$m1" = mirror ] && [ "$m2" = append ] && [ "$m3" = append ] && [ "$m4" = append ]'

# 2 preview: explanation line, unchanged rc + parsing, no temp file left
LIST="printf 'del.|a\\ndel.|sub/b\\n'"
for loc in local sudo; do
  OUT=$(echo n | _mirror_preview $loc /s /d "$LIST" copy 2>&1); RC=$?
  check 2a-$loc "$loc: explains what is happening before the dry run" '[[ "$OUT" == *"Checking what a mirror would delete"* ]]'
  check 2b-$loc "$loc: deletion list parsed as before, answer n -> rc 1" '[ $RC = 1 ] && [[ "$(plain "$OUT")" == *"⚠ 2 files would be deleted at /d:"* && "$OUT" == *"    (top level)  1 file"* && "$OUT" == *"    sub/  1 file"* && "$OUT" == *"Cancelled"* ]]'
  OUT=$(echo y | _mirror_preview $loc /s /d "$LIST" copy 2>&1); RC=$?
  check 2c-$loc "$loc: answer y -> rc 0" '[ $RC = 0 ]'
  OUT=$(_mirror_preview $loc /s /d "echo oops; exit 23" copy 2>&1); RC=$?
  check 2d-$loc "$loc: rsync failure keeps rc 1 and the exit code in the message" '[ $RC = 1 ] && [[ "$OUT" == *"Could not preview the deletions (rsync exit 23) - nothing changed."* && "$OUT" != *"would be deleted"* ]]'
done
OUT=$(_mirror_preview local /s /d "printf ''" copy 2>&1); RC=$?
check 2f "nothing to delete: still rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Nothing to delete"* ]]'

# 3 on a terminal: elapsed-seconds ticker on the line, cleared when done
cat > "$T/tty.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
echo n | _mirror_preview local /s /d "sleep 2; printf 'del.|a\\\\n'" copy
echo "RC=\$?"
X
RAW=$(script -qec "bash $T/tty.sh" /dev/null 2>&1; true)
OUT=$RAW
check 3a "tty: ticker shows elapsed seconds" '[[ "$RAW" == *"1s"* && "$RAW" == *"Checking what a mirror would delete"* ]]'
check 3b "tty: the ticker line is cleared before the result" '[[ "$RAW" == *$'"'"'\033[K'"'"'* && "$RAW" == *"would be deleted at /d"* ]]'
check 3c "tty: temp file removed" '[ -z "$(ls -A "$T/tmp")" ]'

# 4 full list goes to a file (not a shell variable); newest 5 kept; path shown
rm -rf "$T/state"
OUT=$(echo n | _mirror_preview local /s /d "$LIST" copy 2>&1); RC=$?
LF=$(ls "$T/state/federver"/mirror-preview-*.txt 2>/dev/null | head -1)
check 4a "'Full list: <path>' is printed and the file exists" '[ -n "$LF" ] && [[ "$OUT" == *"Full list: $LF"* ]]'
check 4b "list file holds the dry-run output, mode 600, dir 700" '[ -n "$LF" ] && grep -qx "del.|sub/b" "$LF" && [ "$(stat -c %a "$LF")" = 600 ] && [ "$(stat -c %a "$T/state/federver")" = 700 ]'
for i in 1 2 3 4 5 6 7 8; do : > "$T/state/federver/mirror-preview-2020010$i-000000.txt"; done
OUT=$(echo n | _mirror_preview local /s /d "$LIST" copy 2>&1)
check 4c "only the newest 5 list files are kept" '[ "$(ls "$T/state/federver" | wc -l)" = 5 ] && [ ! -e "$T/state/federver/mirror-preview-20200101-000000.txt" ] && [ -e "$T/state/federver/mirror-preview-20200108-000000.txt" ]'
sleep 1.1  # list names are per second
OUT=$(_mirror_preview local /s /d "echo oops; exit 23" copy 2>&1)
check 4d "failed preview leaves no new list file" '[ "$(ls "$T/state/federver" | wc -l)" = 5 ]'
BIG="awk 'BEGIN{for(i=1;i<=200000;i++) print \"del.|d\" (i%7) \"/f\" i}'"
S0=$(date +%s.%N); OUT=$(echo n | _mirror_preview local /s /d "$BIG" copy 2>&1); RC=$?; S1=$(date +%s.%N)
check 4e "200k-line deletion list is counted from the file" '[ $RC = 1 ] && [[ "$(plain "$OUT")" == *"⚠ 200000 files would be deleted at /d:"* ]]'
check 4f "the preview never holds the whole output in a variable" '! declare -f _mirror_preview | grep -Eq "out=|\$\(cat"'
echo "      (200k preview took $(awk -v a="$S0" -v b="$S1" 'BEGIN{printf "%.1f", b-a}')s)"

# 5 screen summary by top-level folder; whole folders flagged
SUM="awk 'BEGIN{for(f=1;f<=7;f++){for(i=1;i<=8-f;i++) print \"del.|f\" f \"/x\" i}; print \"del.|f3/\"; print \"del.|top.txt\"; print \"del.|emp/\"}'"
OUT=$(plain "$(echo n | _mirror_preview local /s /d "$SUM" copy 2>&1)")
check 5a "top 5 folders by count, biggest first, with counts" '[[ "$OUT" == *"    f1/  7 files"*"    f2/  6 files"* && "$OUT" == *"    f5/  3 files"* ]]'
check 5b "only 5 groups shown; the rest summed" '[[ "$OUT" == *"... and 4 more folders"* && "$OUT" != *"    f6/"* ]]'
check 5c "whole-folder deletion is marked, others are not" '[[ "$OUT" == *"    f3/  5 files  ← whole folder deleted"* && "$OUT" != *"f1/  7 files  ←"* ]]'
check 5d "total line unchanged and the file names are not dumped" '[[ "$OUT" == *"⚠ 29 files (+ 1 empty folder) would be deleted at /d:"* && "$OUT" != *"x1"* ]]'
OUT=$(plain "$(echo n | _mirror_preview local /s /d "printf 'del.|a\\ndel.|b\\n'" copy 2>&1)")
check 5e "files directly at the top level are grouped as (top level)" '[[ "$OUT" == *"    (top level)  2 files"* ]]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
