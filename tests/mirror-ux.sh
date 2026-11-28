#!/bin/bash
# Look-and-feel of the mirror flow in setup.sh: the colour-coded copy-mode
# question (_mirror_ask) and the preview progress line (_mirror_preview).
# Run: bash tests/mirror-ux.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
# Real colour codes here (sync-mirror.sh runs with them empty).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
{ grep -E '^MIRROR_WIPE_MIN=' "$SRC"
  for f in ok fail info warn _mirror_flush _mirror_ask _mirror_scan _mirror_wipe_sized _mirror_preview _commas _mirror_delete_q; do extract_fn "$f" "$SRC"; done; } > "$T/fn.sh"
# mp = what a one-time copy does: the preview, then (after the box) the one question.
cat >> "$T/fn.sh" <<'X'
mp() { _mirror_preview "$@"; local r=$?
  if [[ $r == 0 && "$5" == copy ]] && (( _mirror_n > 0 )); then _mirror_delete_q copy; r=$?; fi
  return $r; }
X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
_server_sudo_run() { bash -c "$1"; }   # "root on the server" = this shell
mkdir -p "$T/tmp"; export TMPDIR=$T/tmp XDG_STATE_HOME=$T/state
CHECK_DIAG='out=$(printf "%q" "${OUT:0:300}")'
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
  OUT=$(echo n | mp $loc /s /d "$LIST" copy 2>&1); RC=$?
  check 2a-$loc "$loc: explains what is happening before the dry run" '[[ "$OUT" == *"Checking what a mirror would delete"* ]]'
  check 2b-$loc "$loc: deletion list parsed as before, answer n -> rc 1" '[ $RC = 1 ] && [[ "$(plain "$OUT")" == *"⚠ 2 files would be deleted at /d:"* && "$OUT" == *"    (top level)  1 file"* && "$OUT" == *"    sub/  1 file"* && "$OUT" == *"Cancelled"* ]]'
  OUT=$(echo y | mp $loc /s /d "$LIST" copy 2>&1); RC=$?
  check 2c-$loc "$loc: answer y -> rc 0" '[ $RC = 0 ]'
  OUT=$(mp $loc /s /d "echo oops; exit 23" copy 2>&1); RC=$?
  check 2d-$loc "$loc: rsync failure keeps rc 1 and the exit code in the message" '[ $RC = 1 ] && [[ "$OUT" == *"Could not preview the deletions (rsync exit 23) - nothing changed."* && "$OUT" != *"would be deleted"* ]]'
done
OUT=$(mp local /s /d "printf ''" copy 2>&1); RC=$?
check 2f "nothing to delete: still rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Nothing to delete"* ]]'

# the preview of a one-time copy asks nothing; the caller asks once, after its summary box
OUT=$(echo n | _mirror_preview local /s /d "$LIST" copy 2>&1); RC=$?
check 2g "copy preview: rc 0 and no question (the caller asks later)" '[ $RC = 0 ] && [[ "$OUT" != *"[y/N]"* && "$OUT" != *"Cancelled"* ]]'

# 3 on a terminal: elapsed-seconds ticker on the line, cleared when done
cat > "$T/tty.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"
echo n | mp local /s /d "sleep 2; printf 'del.|a\\\\n'" copy
echo "RC=\$?"
X
RAW=$(script -qec "bash $T/tty.sh" /dev/null 2>&1; true)
OUT=$RAW
check 3a "tty: ticker shows elapsed seconds" '[[ "$RAW" == *"1s"* && "$RAW" == *"Checking what a mirror would delete"* ]]'
check 3b "tty: the ticker line is cleared before the result" '[[ "$RAW" == *$'"'"'\033[K'"'"'* && "$RAW" == *"would be deleted at /d"* ]]'
check 3c "tty: temp file removed" '[ -z "$(ls -A "$T/tmp")" ]'

# 4 full list goes to a file (not a shell variable); newest 5 kept; path shown
rm -rf "$T/state"
OUT=$(echo n | mp local /s /d "$LIST" copy 2>&1); RC=$?
LF=$(ls "$T/state/federver"/mirror-preview-*.txt 2>/dev/null | head -1)
check 4a "'Full list: <path>' is printed and the file exists" '[ -n "$LF" ] && [[ "$OUT" == *"Full list: $LF"* ]]'
check 4b "list file holds the dry-run output, mode 600, dir 700" '[ -n "$LF" ] && grep -qx "del.|sub/b" "$LF" && [ "$(stat -c %a "$LF")" = 600 ] && [ "$(stat -c %a "$T/state/federver")" = 700 ]'
for i in 1 2 3 4 5 6 7 8; do : > "$T/state/federver/mirror-preview-2020010$i-000000.txt"; done
OUT=$(echo n | mp local /s /d "$LIST" copy 2>&1)
check 4c "only the newest 5 list files are kept" '[ "$(ls "$T/state/federver" | wc -l)" = 5 ] && [ ! -e "$T/state/federver/mirror-preview-20200101-000000.txt" ] && [ -e "$T/state/federver/mirror-preview-20200108-000000.txt" ]'
sleep 1.1  # list names are per second
OUT=$(mp local /s /d "echo oops; exit 23" copy 2>&1)
check 4d "failed preview leaves no new list file" '[ "$(ls "$T/state/federver" | wc -l)" = 5 ]'
BIG="awk 'BEGIN{for(i=1;i<=200000;i++) print \"del.|d\" (i%7) \"/f\" i}'"
S0=$(date +%s.%N); OUT=$(echo n | mp local /s /d "$BIG" copy 2>&1); RC=$?; S1=$(date +%s.%N)
check 4e "200k-line deletion list is counted from the file" '[ $RC = 1 ] && [[ "$(plain "$OUT")" == *"⚠ 200000 files would be deleted at /d:"* ]]'
check 4f "the preview never holds the whole output in a variable" '! declare -f _mirror_preview | grep -Eq "out=|\$\(cat"'
echo "      (200k preview took $(awk -v a="$S0" -v b="$S1" 'BEGIN{printf "%.1f", b-a}')s)"

# 5 screen summary by top-level folder; whole folders flagged
SUM="awk 'BEGIN{for(f=1;f<=7;f++){for(i=1;i<=8-f;i++) print \"del.|f\" f \"/x\" i}; print \"del.|f3/\"; print \"del.|top.txt\"; print \"del.|emp/\"}'"
OUT=$(plain "$(echo n | mp local /s /d "$SUM" copy 2>&1)")
check 5a "top 5 folders by count, biggest first, with counts" '[[ "$OUT" == *"    f1/  7 files"*"    f2/  6 files"* && "$OUT" == *"    f5/  3 files"* ]]'
check 5b "only 5 groups shown; the rest summed" '[[ "$OUT" == *"... and 4 more folders"* && "$OUT" != *"    f6/"* ]]'
check 5c "whole-folder deletion is marked, others are not" '[[ "$OUT" == *"    f3/  5 files  ← whole folder deleted"* && "$OUT" != *"f1/  7 files  ←"* ]]'
check 5d "total line unchanged and the file names are not dumped" '[[ "$OUT" == *"⚠ 29 files (+ 1 empty folder) would be deleted at /d:"* && "$OUT" != *"x1"* ]]'
OUT=$(plain "$(echo n | mp local /s /d "printf 'del.|a\\ndel.|b\\n'" copy 2>&1)")
check 5e "files directly at the top level are grouped as (top level)" '[[ "$OUT" == *"    (top level)  2 files"* ]]'

# 6 wipe guard: whole top-level folder or > MIRROR_WIPE_MIN files = type the exact count
gen() { echo "awk 'BEGIN{for(i=1;i<=$1;i++) print \"del.|f\" i}'"; }   # n top-level files
chk() { OUT=$(printf '%s\n' "$1" | mp local /s /d "$2" "${3:-copy}" 2>&1); RC=$?; OUT=$(plain "$OUT"); }
chk "" "$(gen 1500)"
check 6a "1500 files: typed-count prompt, no y/N" '[ $RC = 1 ] && [[ "$OUT" == *"Type 1500 to delete and copy, Enter = cancel: "* && "$OUT" != *"[y/N]"* ]]'
check 6b "prompt is red" '[[ "$(printf "%s\n" 1500 | mp local /s /d "$(gen 1500)" copy 2>&1)" == *"$(printf "${RED}Type 1500 to delete and copy")"* ]]'
chk 1500 "$(gen 1500)"; check 6c "exact count accepted -> rc 0" '[ $RC = 0 ]'
for ans in y yes 1499 1501 ""; do chk "$ans" "$(gen 1500)"
  check 6d "answer [$ans] cancels" '[ $RC = 1 ] && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'; done
chk y "$(gen 1000)"; check 6e "exactly $MIRROR_WIPE_MIN files: still the plain y/N" '[ $RC = 0 ] && [[ "$OUT" != *"Type "* ]]'
chk 1001 "$(gen 1001)"; check 6f "one over the limit: typed count" '[ $RC = 0 ] && [[ "$OUT" == *"Type 1001 to delete and copy"* ]]'
WH="printf 'del.|keep/a\\ndel.|gone/x\\ndel.|gone/y\\ndel.|gone/\\n'"
chk 3 "$WH"; check 6g "3 files but a whole folder goes: typed count 3 accepted" '[ $RC = 0 ] && [[ "$OUT" == *"gone/  2 files  ← whole folder deleted"* && "$OUT" == *"Type 3 to delete and copy"* ]]'
chk y "$WH"; check 6h "whole folder + y -> cancelled" '[ $RC = 1 ]'
chk 1500 "$(gen 1500)" save; check 6i "save mode: typed count to save the job" '[ $RC = 0 ] && [[ "$OUT" == *"Type 1500 to save this job as mirror, Enter = cancel: "* ]]'
chk y "$(gen 1500)" save; check 6j "save mode + y -> cancelled" '[ $RC = 1 ]'
chk y "printf 'del.|a\\n'" save; check 6k "small save: y/N as before" '[ $RC = 0 ] && [[ "$OUT" == *"Save this job as mirror? [y/N]: "* ]]'
chk y "printf 'del.|e1/\\\\ndel.|a\\\\n'"; check 6m "an empty top-level folder alone is not a wipe: y/N" '[ $RC = 0 ] && [[ "$OUT" != *"Type "* ]]'
check 6l "the limit is one named constant" '[ "$MIRROR_WIPE_MIN" = 1000 ] && [ "$(grep -c "1000" <<<"$(declare -f _mirror_preview)")" = 0 ]'

# 7 keys typed ahead are dropped on a terminal, pipes are left alone
cat > "$T/ahead.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
export XDG_STATE_HOME="$T/state"
sleep 1                       # the keys below are already buffered when we ask
if [ "\$1" = ask ]; then _mirror_ask >/dev/null; echo "MODE=\$sync_mode"
else mp local /s /d "printf 'del.|a\\\\n'" copy >/dev/null; echo "RC=\$?"; fi
X
RAW=$({ printf 'delete\n'; sleep 3; } | timeout 10 script -qec "bash $T/ahead.sh ask" /dev/null 2>&1; true)
check 7a "tty: 'delete' typed ahead does not answer the copy-mode question" '[[ "$RAW" == *"MODE=append"* ]]'
RAW=$({ printf 'y\n'; sleep 3; } | timeout 10 script -qec "bash $T/ahead.sh prev" /dev/null 2>&1; true)
check 7b "tty: 'y' typed ahead does not answer the y/N" '[[ "$RAW" == *"RC=1"* ]]'
check 7c "pipe on stdin still answers (not flushed)" 'OUT=$(printf "y\n" | mp local /s /d "$LIST" copy 2>&1); [ $? = 0 ]'

# 8 Ctrl-C during the preview: dry run killed, no list file, nothing asked, rc 1, trap restored
cat > "$T/intr.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
export XDG_STATE_HOME="$T/state"
trap 'echo OLDTRAP' INT
mp local /s /d "echo 'del.|a'; sleep 31.7" copy
echo "RC=\$?"
trap -p INT
X
rm -rf "$T/state"
RAW=$({ sleep 2; printf '\003'; sleep 2; } | timeout 15 script -qec "bash $T/intr.sh" /dev/null 2>&1; true)
check 8a "Ctrl-C: 'Cancelled - nothing changed.' and rc 1" '[[ "$RAW" == *"Cancelled - nothing changed."* && "$RAW" == *"RC=1"* && "$RAW" != *"[y/N]"* ]]'
check 8b "Ctrl-C: the dry run is killed and no list file is left" '! pgrep -f "sleep 31.7" >/dev/null && [ -z "$(ls "$T/state/federver"/*.txt 2>/dev/null)" ]'
check 8c "Ctrl-C: the caller's own INT trap is restored" '[[ "$RAW" == *"trap -- '"'"'echo OLDTRAP'"'"' SIGINT"* ]]'

# 9 live counts on the progress line (terminal only), read from the list file as it grows
cat > "$T/live.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
export XDG_STATE_HOME="$T/state"
echo n | mp local /s /d "sleep 0.3; for r in 1 2 3 4; do for i in 1 2 3; do echo del.\\|d\\\$r\\\$i; echo send\\|c\\\$r\\\$i; done; sleep 1; done" copy
X
RAW=$(timeout 20 script -qec "bash $T/live.sh" /dev/null 2>&1; true)
check 9a "tty: progress line shows 'N to delete' and 'M to copy so far'" '[[ "$RAW" =~ [0-9]s\ ·\ [0-9,]+\ to\ delete\ ·\ [0-9,]+\ to\ copy\ so\ far ]]'
check 9b "tty: the counts grow while the dry run is still going" '[ "$(grep -o "[0-9,]* to delete ·" <<<"$RAW" | sort -u | wc -l)" -ge 2 ]'
cat > "$T/live2.sh" <<X
source "$T/fn.sh"
_mirror_guard() { return 0; }
_mirror_refuse() { :; }
export XDG_STATE_HOME="$T/state"
echo n | mp local /s /d "sleep 2.5; echo 'del.|a'" copy
X
RAW2=$(timeout 20 script -qec "bash $T/live2.sh" /dev/null 2>&1; true)
check 9c "tty: seconds only until rsync prints its first line" '[[ "$RAW2" == *"... 1s"$'"'"'\r'"'"'* && "$RAW2" == *"... 2s"$'"'"'\r'"'"'* ]]'
OUT=$(echo n | mp local /s /d "$LIST" copy 2>&1)
check 9d "no terminal: no ticker, no live counts" '[[ "$OUT" != *" to copy so far"* ]]'
cat > "$T/tick.sh" <<X
awk 'BEGIN{for(i=1;i<=200000;i++){print "del.|d" (i%7) "/f" i; print "send|s" i}}' > "$T/big.txt"
S=\$(date +%s%N)
awk '/^del\\.\\|/ { d++; next } /^(send|recv)\\|/ { c++ } END { print d + 0, c + 0 }' "$T/big.txt"
echo "TICK_MS=\$(( (\$(date +%s%N) - S) / 1000000 ))"
X
bash "$T/tick.sh" | sed 's/^/      (400k-line tick: /; s/$/)/' | tail -1

check_total
