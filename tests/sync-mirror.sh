#!/bin/bash
# Tests for the opt-in mirror mode (rsync --delete) of federver -> 14 sync and
# backups: the copy-mode question, source guard, dry-run preview + y/N, the tar
# (sudo) route, scheduled jobs (stored MODE, cron guard, skip log), Status rows
# and 14 -> 3 -> Change copy mode. Run: bash tests/sync-mirror.sh (non-zero on failure)
# Functions are extracted from setup.sh and run against REAL rsync on temp dirs;
# only the pickers, the schedule menu, crontab/systemctl/findmnt and the server
# hop are stubbed (a fake `ssh` runs the remote command locally). No network, no
# sudo. SETUP_SH=<file> tests another copy of setup.sh.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.local/bin" "$T/home/.local/share/sync-jobs"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=
CR=$'\033[R]'; CY=$'\033[Y]'   # status() swaps these in for RED/YELLOW

fn() { awk -v n="$1" '
  p==0 && index($0, n "() {")==1 { p=1; print; if ($0 ~ /\}[ \t]*$/ && $0 !~ /\{[ \t]*$/ && $0 !~ /^[^#]*\{[ \t]*#/) exit; next }
  p { print } p && /^}/ { exit }' "$SRC"; }
{ grep -E '^(ok|fail|info|warn)\(\)' "$SRC"
  grep -m1 '^ssh()' "$SRC" >/dev/null && awk '/^ssh\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$SRC"
  grep -m1 '^_shq()' "$SRC"
  grep -E '^MIRROR_WIPE_MIN=' "$SRC"
  for f in _mirror_check_here _mirror_guard _mirror_refuse _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with \
           _mirror_preview _mirror_gate _sync_mirror_block _sync_job_mode _sync_job_field _sync_job_set_mode \
           _sync_mode_cell _sync_last_note _sync_last_result _sync_change_mode \
           _sync_execute_or_schedule _sync_show_status _sync_edit_job _sync_list_jobs \
           _cron_to_english _sync_one_time_backup; do fn "$f"; done; } > "$T/fn.sh"
source "$T/fn.sh"
type _sync_one_time_backup >/dev/null 2>&1 || echo "FAIL  setup: mirror functions not found in $SRC (older setup.sh?)"

# fake ssh: drop the options and host, run the remote command locally
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o|-l|-p|-i) shift 2;; -*) shift;; *) break;; esac; done
shift
[ -n "$SSH_DOWN" ] && exit 255
[ $# -gt 0 ] || exit 0
exec bash -c "$*"
X
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
case "$*" in *TARGET*) col=T;; *) col=S;; esac
case "${FM_MODE:-ok}" in
  ok)   [ $col = T ] && echo "$FM_ROOT" || echo /dev/sdb1 ;;
  stub) [ $col = T ] && echo "$FM_ROOT" || echo systemd-1 ;;
esac
X
cat > "$T/bin/crontab" <<'X'
#!/bin/bash
[ "$1" = -l ] && { cat "$CRON_FILE" 2>/dev/null; exit 0; }
exit 0
X
cat > "$T/bin/systemctl" <<'X'
#!/bin/bash
case "$*" in *is-enabled*) echo enabled ;; esac
exit 0
X
chmod +x "$T/bin/"*
export T P_SRC P_DST
export PATH="$T/bin:$PATH" HOME="$T/home" CRON_FILE="$T/crontab" SERVER_USER=u SERVER_IP=h
export _MIRROR_DRIVE_ROOTS="$T/mnt" FM_ROOT="$T/mnt/usb"

# Stubs for what needs a terminal, cron, or the server's sudo.
_pick_local_path()  { if [ -z "$_pl" ]; then _pl=1; local_path=$P_SRC; else local_path=$P_DST; fi; }
_pick_server_path() { if [ -z "$_ps" ]; then _ps=1; server_path=$P_SRC; else server_path=$P_DST; fi; }
_pick_copy_mode()   { copy_mode=contents; }
_sync_pick_schedule() { echo "cron 0 * * * *"; }
_cron_add_sync() { echo "$2 $3" >> "$CRON_FILE"; }          # job_name sched script
_server_sudo_pw_prompt() { _SRV_PW=fake; return 0; }
_server_sudo_run() { bash -c "$1"; }                         # "root on the server" = this shell

PASS=0; FAILN=0
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC]"; FAILN=$((FAILN+1)); fi; }
# run <stdin-text> cmd...  (runs in a subshell: filesystem + output are what we assert on)
run() { local in=$1; shift; OUT=$(printf '%b' "$in" | "$@" 2>&1); RC=$?; }
# fresh source (a, sub/b) and a destination holding extras (gone, sub/old, "we ird")
mk() {
  rm -rf "$T/s" "$T/d" "$T/mnt" "$T/crontab" "$T/home/.local/bin/"* "$T/home/.local/share/sync-jobs/"*
  mkdir -p "$T/s/sub" "$T/d/sub" "$T/mnt/usb"
  echo a > "$T/s/a"; echo b > "$T/s/sub/b"
  echo a > "$T/d/a"; echo x > "$T/d/sub/old"; echo y > "$T/d/gone"; echo z > "$T/d/we ird"
  P_SRC=$T/s; P_DST=$T/d; _pl=; _ps=; export FM_MODE=ok
}
extras_kept() { [ -e "$T/d/gone" ] && [ -e "$T/d/sub/old" ] && [ -e "$T/d/we ird" ]; }
extras_gone() { [ ! -e "$T/d/gone" ] && [ ! -e "$T/d/sub/old" ] && [ ! -e "$T/d/we ird" ]; }
copied()      { [ -e "$T/d/sub/b" ]; }
ONE="3\n"        # one-time local copy: laptop -> laptop
Y="y"            # Proceed? reads one character
LOCALCMD() { _sync_one_time_backup; }

# ── 1  Enter -> append ────────────────────────────────────────────────────
mk; run "${ONE}\n$Y" LOCALCMD
check 1a "Enter = append: copies, keeps destination extras" 'copied && extras_kept'
check 1b "append prints the reassurance line" '[[ "$OUT" == *"Append only - nothing at the destination will be deleted."* ]]'
check 1c "append never offers the preview or delete confirm" '[[ "$OUT" != *"would be deleted"* && "$OUT" != *"Delete these"* ]]'
check 1d "the question is asked with the agreed wording" '[[ "$OUT" == *"Deleted at source → also delete at destination?"* && "$OUT" == *"Enter = no, append only · type \"delete\" = mirror: "* ]]'
mk; run "${ONE}yes\n$Y" LOCALCMD
check 1e "anything but the exact word is append (\"yes\")" 'copied && extras_kept'
mk; run "${ONE}Delete\n$Y" LOCALCMD
check 1f "only lowercase \"delete\" selects mirror (\"Delete\" is append)" 'copied && extras_kept'
mk; run "${ONE} delete\n$Y" LOCALCMD
check 1g "padded answer (\" delete\") is not the exact word: append" 'copied && extras_kept'
mk; run "${ONE}delete \n$Y" LOCALCMD
check 1h "padded answer (\"delete \") is not the exact word: append" 'copied && extras_kept'

# ── 2  delete + y -> mirror ───────────────────────────────────────────────
mk; run "${ONE}delete\ny\n$Y" LOCALCMD
check 2a "delete + y: extras removed, source files copied" 'copied && extras_gone'
check 2b "preview header names the count and destination" '[[ "$OUT" == *"⚠ 3 files would be deleted at $T/d:"* ]]'
check 2c "preview shows the folder summary before asking" 'PRE=${OUT%%Delete these*}; [[ "$PRE" == *"(top level)  2 files"* && "$PRE" == *"sub/  1 file"* && "$PRE" == *"Full list: "* ]]'
check 2d "confirm wording" '[[ "$OUT" == *"Delete these 3 files at the destination? [y/N]: "* ]]'
check 2e "success line counts the deletions" '[[ "$OUT" == *"✓ Mirror complete - 3 deleted, destination matches source."* ]]'
mk; for i in 1 2 3 4 5 6 7; do echo x > "$T/d/extra$i"; done
run "${ONE}delete\ny\n$Y" LOCALCMD
check 2f "10 deletions: one (top level) group, counted not listed" '[[ "$OUT" == *"⚠ 10 files would be deleted"* && "$OUT" == *"(top level)  9 files"* ]]'

mk; run "" bash -c 'source "$T/fn.sh"; c=$(_mirror_dry_cmd "rsync -az $(_shq "$P_SRC/") $(_shq "$P_DST/")"); bash -c "$c"'
check 2g "dry-run command works for an rsync line without the standard flag prefix" '[ "$RC" = 0 ] && [[ "$OUT" == *"del.|gone"* ]] && extras_kept'

# ── 3  delete + Enter -> nothing changed ──────────────────────────────────
mk; run "${ONE}delete\n\n$Y" LOCALCMD
check 3a "delete + Enter: nothing copied, nothing deleted" '! copied && extras_kept'
check 3b "prints Cancelled - nothing changed." '[[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mk; run "${ONE}delete\nn\n$Y" LOCALCMD
check 3c "delete + n: nothing copied, nothing deleted" '! copied && extras_kept'

# ── 4  guard: empty / missing / unmounted source ──────────────────────────
mk; rm -rf "$T/s"; mkdir "$T/s"
run "${ONE}delete\ny\n$Y" LOCALCMD
check 4a "empty source refused, destination untouched" 'extras_kept && [ -e "$T/d/a" ]'
check 4b "refusal text" '[[ "$OUT" == *"✗ Source $T/s is empty or its drive isn'"'"'t mounted - a mirror would delete everything at the destination. Refused."* ]]'
check 4c "refusal hints at the drive / append only" '[[ "$OUT" == *"press Enter"*"append only"* ]]'
check 4d "refusal comes before any preview" '[[ "$OUT" != *"would be deleted"* ]]'
mk; rm -rf "$T/s"
run "${ONE}delete\ny\n$Y" LOCALCMD
check 4e "missing source refused, destination untouched" 'extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; P_SRC=$T/mnt/usb/data; export FM_MODE=stub
run "${ONE}delete\ny\n$Y" LOCALCMD
check 4f "non-empty source on a stub/autofs mountpoint (source systemd-1) refused" 'extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; P_SRC=$T/mnt/usb/data; export FM_MODE=ok
run "${ONE}delete\n4\n$Y" LOCALCMD   # sub/ goes whole: type the count
check 4g "same path on a real /dev mount is accepted" '[ -e "$T/d/f" ] && [ ! -e "$T/d/gone" ]'
mk; run "" bash -c 'source "$T/fn.sh"; _mirror_guard server "$P_SRC/nope"'
check 4h "server-side guard (over ssh) refuses a missing path" '[ "$RC" != 0 ]'
mk; run "" bash -c 'source "$T/fn.sh"; _mirror_guard server "$P_SRC"'
check 4i "server-side guard accepts a populated path" '[ "$RC" = 0 ]'
mk; run "" bash -c 'source "$T/fn.sh"; ssh() { return 255; }; _mirror_guard server "$P_SRC"'
check 4j "unreachable server = guard fails closed" '[ "$RC" != 0 ]'
mk; mkdir -p "$T/mnt/usb/data" "$T/lsonly"; echo q > "$T/mnt/usb/data/f"; ln -sf "$(command -v ls)" "$T/lsonly/ls"
run "" env PATH="$T/lsonly" "$(command -v bash)" -c 'source "$T/fn.sh"; _mirror_check_here "$T/mnt/usb/data"'
check 4k "no findmnt on a drive path: verdict is unknown (not unmounted), still refused" '[ "$OUT" = unknown ]'

# ── 5  zero deletions ─────────────────────────────────────────────────────
mk; rm -rf "$T/d"; mkdir "$T/d"
run "${ONE}delete\n$Y" LOCALCMD
check 5a "0 deletions: message, no confirm, copies" '[[ "$OUT" == *"✓ Nothing to delete - destination has no extra files."* && "$OUT" != *"Delete these"* ]] && copied'
check 5b "ends with the mirror success line (0 deleted)" '[[ "$OUT" == *"Mirror complete - 0 deleted"* ]]'
# destination = the source plus extra empty folders only (no extra files)
mkempty() { mk; rm -rf "$T/d"; mkdir -p "$T/d/sub" "$T/d/e1" "$T/d/e2"; echo a > "$T/d/a"; echo b > "$T/d/sub/b"; }
empties_kept() { [ -d "$T/d/e1" ] && [ -d "$T/d/e2" ]; }
empties_gone() { [ ! -e "$T/d/e1" ] && [ ! -e "$T/d/e2" ] && [ -e "$T/d/sub/b" ]; }
mkempty; run "${ONE}delete\ny\n$Y" LOCALCMD
check 5c "only empty folders to remove: warned, not 'Nothing to delete'" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"* && "$OUT" == *"e1/"* && "$OUT" != *"Nothing to delete"* ]]'
check 5d "empty-folders-only still asks y/N, then removes them" '[[ "$OUT" == *"Delete these 2 empty folders at the destination? [y/N]: "* ]] && empties_gone && [[ "$OUT" == *"Mirror complete - 2 deleted"* ]]'
mkempty; run "${ONE}delete\nn\n$Y" LOCALCMD
check 5e "empty-folders-only + n: nothing removed" 'empties_kept && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkempty; mkdir "$T/d/e3" "$T/d/e4" "$T/d/e5" "$T/d/e6" "$T/d/e7"
run "${ONE}delete\nn\n$Y" LOCALCMD
check 5f "more than 5 empty folders: 5 groups then '... and M more folders'" '[[ "$OUT" == *"⚠ 7 empty folders would be removed"* && "$OUT" == *"... and 2 more folders"* ]]'
mkempty; rm -rf "$T/d/e2"
run "${ONE}delete\nn\n$Y" LOCALCMD
check 5g "one empty folder is singular" '[[ "$OUT" == *"⚠ 1 empty folder would be removed at $T/d:"* && "$OUT" == *"Delete these 1 empty folder at the destination? [y/N]: "* ]]'
mk; mkdir "$T/d/e1" "$T/d/full"; echo f > "$T/d/full/f"
run "${ONE}delete\n4\n$Y" LOCALCMD   # full/ goes whole: type the count
check 5h "files and empty folders: file count kept, '(+ N empty folder)' added; a folder holding deleted files is not counted" '[[ "$OUT" == *"⚠ 4 files (+ 1 empty folder) would be deleted at $T/d:"* && "$OUT" == *"Type 4 to delete, Enter = cancel: "* ]] && extras_gone && [ ! -e "$T/d/e1" ] && [ ! -e "$T/d/full" ]'
mk; rm -rf "$T/d"; mkdir -p "$T/d/sub"; echo a > "$T/d/a"; echo b > "$T/d/sub/b"
run "${ONE}delete\n$Y" LOCALCMD
check 5i "nothing at all to delete still says so (no folders either)" '[[ "$OUT" == *"✓ Nothing to delete - destination has no extra files."* && "$OUT" != *"empty folder"* && "$OUT" != *"Delete these"* ]]'

# ── 6  tar (sudo) route: no prompt, info line ─────────────────────────────
if [ "$(id -u)" != 0 ]; then
  mk; mkdir -p "$T/s/locked"; echo l > "$T/s/locked/f"; chmod 000 "$T/s/locked"
  _pl=1; run "2\nn" _sync_one_time_backup
  chmod 755 "$T/s/locked"
  check 6a "root-owned source: dim info line, append only" '[[ "$OUT" == *"ℹ Needs sudo (tar copy) — append only; mirror isn'"'"'t possible for this copy."* ]]'
  check 6b "no mode question on the tar route" '[[ "$OUT" != *"Deleted at source"* && "$OUT" != *"type \"delete\""* ]]'
  mk; _pl=1; run "2\n\nn" _sync_one_time_backup
  check 6c "readable source on the rsync route still asks" '[[ "$OUT" == *"Deleted at source"* && "$OUT" != *"Needs sudo"* ]]'
else
  echo "PASS  6x  SKIP: running as root (cannot make an unreadable source)"; PASS=$((PASS+3))
fi

# ── 7  download (rsync over ssh) and server -> server (sudo run) ──────────
mk; _pl=1; run "2\ndelete\ny\n$Y" LOCALCMD
check 7a "download: mirror deletes at the laptop destination" 'copied && extras_gone'
mk; _pl=1; rm -rf "$T/s"; mkdir "$T/s"
run "2\ndelete\ny\n$Y" LOCALCMD
check 7b "download: empty server source refused (guard ran over ssh)" 'extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; run "4\ndelete\ny\n$Y" LOCALCMD
check 7c "server -> server: guard + preview + copy through the sudo run" 'copied && extras_gone && [[ "$OUT" == *"Mirror complete - 3 deleted"* ]]'
mk; rm -rf "$T/s"; mkdir "$T/s"
run "4\ndelete\ny\n$Y" LOCALCMD
check 7d "server -> server: empty source refused" 'extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; run "4\n\n$Y" LOCALCMD
check 7e "server -> server append: no sudo-run copy, nothing deleted" '[[ "$OUT" == *"Append only"* ]] && extras_kept'
BAN="Mode: mirror - deletes destination files that are gone from the source"
mk; run "${ONE}delete\ny\n$Y" LOCALCMD
check 7f "mirror banner on the one-time local copy summary" '[[ "$OUT" == *"$BAN"* ]]'
mk; _pl=1; run "2\ndelete\ny\n$Y" LOCALCMD
check 7g "mirror banner on the one-time download summary" '[[ "$OUT" == *"$BAN"* ]]'
mk; run "4\ndelete\ny\n$Y" LOCALCMD
check 7h "mirror banner on the one-time server -> server summary" '[[ "$OUT" == *"$BAN"* ]]'
mk; run "${ONE}\n$Y" LOCALCMD
check 7i "no mirror banner on an append copy" '[[ "$OUT" != *"$BAN"* ]]'

# ── 8  scheduled jobs ─────────────────────────────────────────────────────
JOB=$T/home/.local/bin/sync-j1.sh; LOG=$T/home/.local/share/sync-jobs/j1.log
mkjob() { # mode answers
  mk; local cmd="rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")"
  run "2\nj1\n$2" _sync_execute_or_schedule upload "$T/s" "$T/d" "$cmd" "" "$1" local
}
mkjob mirror "y\n"
check 8a "mirror job: warning, preview, Save prompt" '[[ "$OUT" == *"⚠ Every scheduled run will delete destination files that are gone from the source."* && "$OUT" == *"⚠ 3 files would be deleted at $T/d:"* && "$OUT" == *"Save this job as mirror? [y/N]: "* ]]'
check 8b "mode is stored in the job script" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = mirror ] && grep -q "^_mirror_guard local" "$JOB"'
check 8c "the cron line runs that script" 'grep -q "sync-j1.sh" "$CRON_FILE"'
check 8d "creating it ran the first mirror copy" 'copied && extras_gone'
echo q > "$T/d/stray"; echo n > "$T/d/sub/stray2"
bash "$(awk '{print $NF}' "$CRON_FILE")" >/dev/null 2>&1
check 8e "cron run of a mirror job deletes extras" '[ ! -e "$T/d/stray" ] && [ ! -e "$T/d/sub/stray2" ] && copied'
mkjob mirror "n\n"
check 8f "Save = n: nothing saved, no cron line, nothing copied" '[ ! -e "$JOB" ] && [ ! -s "$CRON_FILE" ] && ! copied && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkjob append "\n"
check 8g "append job: stored as append, no prompt" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = append ] && [[ "$OUT" != *"Save this job"* ]]'
echo q > "$T/d/stray"
bash "$JOB" >/dev/null 2>&1
check 8h "cron run of an append job keeps destination extras" '[ -e "$T/d/stray" ] && [ -e "$T/d/gone" ] && copied'
mkjob mirror "y\n"
rm -rf "$T/s"; mkdir "$T/s"; echo q > "$T/d/stray"
bash "$JOB" >/dev/null 2>&1; JRC=$?
check 8i "empty source: cron run skips - no rsync, nothing deleted" '[ "$JRC" = 0 ] && [ -e "$T/d/stray" ] && [ -e "$T/d/a" ]'
check 8j "skip is logged in the agreed form" 'grep -Eq "^[0-9-]+ [0-9:]+: SKIPPED j1 - source empty \(mirror refused, nothing deleted\)$" "$LOG"'
check 8k "skip run writes no rsync output" '! grep -q "sending incremental" "$LOG"'
rm -rf "$T/s"
bash "$JOB" >/dev/null 2>&1
check 8l "missing source: cron run skips too" '[ -e "$T/d/stray" ] && [ "$(grep -c SKIPPED "$LOG")" = 2 ]'
check 8r "missing source is logged as such, not as empty/unmounted" 'tail -n 1 "$LOG" | grep -Eq ": SKIPPED j1 - source missing \(mirror refused"'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; export FM_MODE=stub
cmd="rsync -avh --progress -s $(_shq "$T/mnt/usb/data/") $(_shq "$T/d/")"
run "2\nj2\ny\n" _sync_execute_or_schedule upload "$T/mnt/usb/data" "$T/d" "$cmd" "" mirror local
check 8m "unmounted source refused at creation" '[ ! -e "$T/home/.local/bin/sync-j2.sh" ] && extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; export FM_MODE=ok
run "2\nj2\n4\n" _sync_execute_or_schedule upload "$T/mnt/usb/data" "$T/d" "$cmd" "" mirror local   # sub/ goes whole: type the count
echo k > "$T/d/stray"; export FM_MODE=stub
bash "$T/home/.local/bin/sync-j2.sh" >/dev/null 2>&1
check 8n "cron run after the drive vanished (stub mount) skips" '[ -e "$T/d/stray" ] && grep -q "SKIPPED j2" "$T/home/.local/share/sync-jobs/j2.log"'
check 8s "unmounted drive is logged as such" 'grep -Eq ": SKIPPED j2 - drive not mounted \(mirror refused" "$T/home/.local/share/sync-jobs/j2.log"'
mk; run "2\nj3\ny\n" _sync_execute_or_schedule download "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$SERVER_USER@$SERVER_IP:$T/s/") $(_shq "$T/d/")" "" mirror server
echo k > "$T/d/stray"; rm -rf "$T/s"; mkdir "$T/s"
bash "$T/home/.local/bin/sync-j3.sh" >/dev/null 2>&1
check 8o "download job: the guard checks the SERVER path (over ssh) and skips" '[ -e "$T/d/stray" ] && grep -q "SKIPPED j3" "$T/home/.local/share/sync-jobs/j3.log" && [ "$(sed -n "s/^# Direction: //p" "$T/home/.local/bin/sync-j3.sh")" = download ]'
SSH_DOWN=1 bash "$T/home/.local/bin/sync-j3.sh" >/dev/null 2>&1; unset SSH_DOWN
check 8t "unreachable server is logged as a failed check, not as an empty source" '[ -e "$T/d/stray" ] && tail -n 1 "$T/home/.local/share/sync-jobs/j3.log" | grep -Eq ": SKIPPED j3 - could not check source \(mirror refused"'
mk; run "1\ny\n" _sync_execute_or_schedule upload "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" mirror local
check 8p "Run now with a mirror: preview, confirm, deletes" 'extras_gone && [[ "$OUT" == *"Mirror complete - 3 deleted"* ]]'
mk; run "1\n\n" _sync_execute_or_schedule upload "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" mirror local
check 8q "Run now, confirm = Enter: nothing changed" 'extras_kept && ! copied'
mkempty; run "1\ny\n" _sync_execute_or_schedule upload "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" mirror local
check 8u "Run now with only empty folders to remove: warned, confirmed, removed" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"* && "$OUT" != *"Nothing to delete"* ]] && empties_gone'
mkempty; run "2\nj1\nn\n" _sync_execute_or_schedule upload "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" mirror local
check 8v "Save job (mirror) with only empty folders: warned before the Save prompt" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"*"Save this job as mirror? [y/N]: "* ]] && empties_kept'

# ── 9  Status rows ────────────────────────────────────────────────────────
status() { ( RED=$CR; YELLOW=$CY; GREEN=$'\033[G]'; NC=$'\033[N]'
  _server_sudo_pw_prompt() { return 2; }
  ssh() { case "$*" in *"systemctl cat immich-backup.timer"*) echo "*-*-* 03:00:00";; esac; return 0; }
  _sync_show_status ) 2>&1; }
mk
mkjob mirror "y\n" >/dev/null
# legacy job: a pre-mirror script (no MODE= line, plain rsync line)
cat > "$T/home/.local/bin/sync-old.sh" <<EOF
#!/bin/bash
# Sync job: old
# Direction: upload
# Source: $T/s
# Destination: $T/d
exec >>"$T/home/.local/share/sync-jobs/old.log" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: old"
rsync -avh --progress -s '$T/s/' '$T/d/'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: old (exit \$?)"
EOF
chmod +x "$T/home/.local/bin/sync-old.sh"
echo "30 3 * * * $T/home/.local/bin/sync-old.sh" >> "$CRON_FILE"
# make j1 (mirror) have a skipped last result, old a clean one
printf '2026-11-20 03:00:01: SKIPPED j1 - source empty (mirror refused, nothing deleted)\n' >> "$LOG"
printf '[2026-11-20 03:00:05] Sync finished: old (exit 0)\n' >> "$T/home/.local/share/sync-jobs/old.log"
OUT=$(status); RC=0
row() { grep -E "^  $1 " <<<"$OUT" | head -n 1; }
check 9a "mirror job row shows 'mirror' in the destructive colour" "[[ \"\$(row j1)\" == *\"\${CR}mirror\"* ]]"
check 9b "legacy job (no stored mode) shows append" '[[ "$(row old)" == *append* && "$(row old)" != *mirror* ]]'
check 9c "skipped last result shown in yellow on the mirror row" "[[ \"\$(row j1)\" == *\"\${CY}last: skipped (source empty)\"* ]]"
check 9d "clean last result shown on the legacy row" '[[ "$(row old)" == *"last: ok"* ]]'
check 9e "Immich backup row shows append" '[[ "$(row immich-backup)" == *append* ]]'
check 9f "table has a Copy column" '[[ "$OUT" == *"Name"*"Copy"*"Note"* ]]'
check 9g "Last runs table also reports the skip" '[[ "$OUT" == *"j1"*"skipped (source empty)"* ]]'
printf '2026-11-21 03:00:01: SKIPPED j1 - could not check source (mirror refused, nothing deleted)\n' >> "$LOG"
OUT=$(status)
check 9m "Status names the real reason of the last skip" "[[ \"\$(row j1)\" == *\"last: skipped (could not check source)\"* ]]"
printf '2026-11-22 03:00:01: SKIPPED j1 - source empty or drive not mounted (mirror refused, nothing deleted)\n' >> "$LOG"
OUT=$(status)
check 9n "a skip logged by an older script keeps its own wording" "[[ \"\$(row j1)\" == *\"last: skipped (source empty or drive not mounted)\"* ]]"
# systemd-timer job rows too
mkdir -p "$T/home/.config/systemd/user"
printf '[Timer]\nOnCalendar=Sat\n' > "$T/home/.config/systemd/user/sync-wk.timer"
cp "$JOB" "$T/home/.local/bin/sync-wk.sh"
OUT=$(status)
check 9h "timer job row shows its mode" '[[ "$(row wk)" == *mirror* ]]'
rm -rf "$T/home/.config"
# A REAL generated job script, run for real: a failed rsync must log its own
# exit code and show as "last: failed (exit N)"; a clean run as "last: ok".
mk; mkjob append "\n" >/dev/null
logexit() { grep -oP 'Sync finished: j1 \(exit \K[0-9]+' "$LOG" | tail -n 1; }
rm -rf "$T/s"
bash "$JOB" >/dev/null 2>&1; JRC=$?; LE=$(logexit)
OUT=$(status)
check 9i "real failed run (missing source) logs a non-zero exit" '[ -n "$LE" ] && [ "$LE" != 0 ]'
check 9j "Status shows last: failed (exit N) with that same N" '[[ "$(row j1)" == *"last: failed (exit $LE)"* ]]'
check 9k "the job script exits with the rsync code (a timer unit shows failed)" '[ "$JRC" != 0 ] && [ "$JRC" = "$LE" ]'
mkdir -p "$T/s"; echo a > "$T/s/a"
bash "$JOB" >/dev/null 2>&1; JRC=$?
OUT=$(status)
check 9l "a clean real run after it: log says exit 0, Status shows last: ok, script exits 0" '[ "$(logexit)" = 0 ] && [ "$JRC" = 0 ] && [[ "$(row j1)" == *"last: ok"* ]]'

# ── 10 Edit job -> Change copy mode ──────────────────────────────────────
mk
mkjob append "\n" >/dev/null
EDIT() { _sync_edit_job; }
run "1\n6\ndelete\ny\n" EDIT
check 10a "menu offers 'Change copy mode' as 6 and keeps 0) Back" '[[ "$OUT" == *"6)"*"Change copy mode"* && "$OUT" == *"0)"*"Back"* ]]'
check 10b "append -> mirror stores MODE=mirror with the guard" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = mirror ] && grep -q "^_mirror_guard local" "$JOB" && bash -n "$JOB"'
check 10c "same preview + Save prompt as at creation" '[[ "$OUT" == *"⚠ 3 files would be deleted at $T/d:"* && "$OUT" == *"Save this job as mirror? [y/N]: "* ]]'
check 10d "the rewritten job now deletes on its cron run" 'echo q > "$T/d/stray"; bash "$JOB" >/dev/null 2>&1; [ ! -e "$T/d/stray" ]'
mk; mkjob mirror "y\n" >/dev/null
run "1\n6\n\n" EDIT
check 10f "mirror -> append (Enter) stores MODE=append" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = append ] && ! grep -q "_mirror_guard" "$JOB" && [[ "$OUT" == *"Append only"* ]]'
check 10g "append rewrite keeps the rsync line runnable and non-deleting" 'echo q > "$T/d/stray"; bash "$JOB" >/dev/null 2>&1; [ -e "$T/d/stray" ]'
mk; mkjob append "\n" >/dev/null
rm -rf "$T/s"; mkdir "$T/s"
run "1\n6\ndelete\ny\n" EDIT
check 10h "mirror refused on an empty source: job stays append" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = append ] && [[ "$OUT" == *"Refused."* ]]'
mk; mkjob append "\n" >/dev/null
run "1\n6\ndelete\n\n" EDIT
check 10i "Save = Enter: job unchanged" '[ "$(sed -n "s/^MODE=//p" "$JOB")" = append ] && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkjob append "\n" >/dev/null; rm -rf "$T/d"; mkdir -p "$T/d/sub" "$T/d/e1" "$T/d/e2"; echo a > "$T/d/a"; echo b > "$T/d/sub/b"
run "1\n6\ndelete\nn\n" EDIT
check 10q "Change copy mode with only empty folders to remove: warned before the Save prompt" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"*"Save this job as mirror? [y/N]: "* && "$OUT" != *"Nothing to delete"* ]]'
# a pre-mirror (legacy) script is upgraded in place
mk
cat > "$T/home/.local/bin/sync-old.sh" <<EOF
#!/bin/bash
# Sync job: old
# Direction: upload
# Source: $T/s
# Destination: $T/d
exec >>"$T/home/.local/share/sync-jobs/old.log" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: old"
rsync -avh --progress -s '$T/s/' '$T/d/'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: old (exit \$?)"
EOF
chmod +x "$T/home/.local/bin/sync-old.sh"; echo "30 3 * * * $T/home/.local/bin/sync-old.sh" > "$CRON_FILE"
run "1\n6\ndelete\ny\n" EDIT
check 10j "legacy script (no MODE=) upgraded to mirror and still runs" '[ "$(sed -n "s/^MODE=//p" "$T/home/.local/bin/sync-old.sh")" = mirror ] && bash -n "$T/home/.local/bin/sync-old.sh" && bash "$T/home/.local/bin/sync-old.sh" >/dev/null 2>&1 && extras_gone && copied'
# a legacy script's finish line logged date's exit (always 0): set_mode upgrades it
mk
OLD=$T/home/.local/bin/sync-old.sh; OLOG=$T/home/.local/share/sync-jobs/old.log
cat > "$OLD" <<EOF
#!/bin/bash
# Sync job: old
# Direction: upload
# Source: $T/s
# Destination: $T/d
exec >>"$OLOG" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: old"
rsync -avh --progress -s '$T/s/' '$T/d/'
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: old (exit \$?)"
EOF
chmod 750 "$OLD"
_sync_job_set_mode "$OLD" append; SRC1=$?
cp "$OLD" "$T/old.after1"
rm -rf "$T/s"; bash "$OLD" >/dev/null 2>&1; ORC=$?
OLE=$(grep -oP 'Sync finished: old \(exit \K[0-9]+' "$OLOG" | tail -n 1)
check 10l "legacy finish line upgraded: failed rsync logs its real non-zero exit and the script exits with it" '[ "$SRC1" = 0 ] && [ -n "$OLE" ] && [ "$OLE" != 0 ] && [ "$ORC" = "$OLE" ] && bash -n "$OLD"'
check 10m "Status shows last: failed (exit N) for the upgraded legacy job" '[[ "$(_sync_last_note old)" == *"last: failed (exit $OLE)"* ]]'
check 10n "script mode kept (750)" '[ "$(stat -c %a "$OLD")" = 750 ]'
_sync_job_set_mode "$OLD" append
check 10o "a second set_mode changes nothing (idempotent, no duplicate rc/exit lines)" 'cmp -s "$OLD" "$T/old.after1" && [ "$(grep -c "^rc=" "$OLD")" = 1 ] && [ "$(grep -c "^exit \$rc" "$OLD")" = 1 ]'
mk; mkjob append "\n" >/dev/null; cp "$JOB" "$T/new.before"
_sync_job_set_mode "$JOB" append
check 10p "a script already in the current form is not touched" 'cmp -s "$JOB" "$T/new.before"'

# a download job (source on the server): editing to mirror must guard over ssh
mk; JOB3=$T/home/.local/bin/sync-dl.sh
run "2\ndl\n" _sync_execute_or_schedule download "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$SERVER_USER@$SERVER_IP:$T/s/") $(_shq "$T/d/")" "" append server
run "1\n6\ndelete\ny\n" EDIT
echo k > "$T/d/stray"; rm -rf "$T/s"; mkdir "$T/s"
bash "$JOB3" >/dev/null 2>&1
check 10k "edited download job guards the SERVER source and skips on empty" '[ "$(sed -n "s/^MODE=//p" "$JOB3")" = mirror ] && grep -q "^_mirror_guard server" "$JOB3" && [ -e "$T/d/stray" ] && grep -q "SKIPPED dl" "$T/home/.local/share/sync-jobs/dl.log"'

# ── 11  Immich backup stays append-only ───────────────────────────────────
IMM=$(for f in step_immich_backup _immich_backup_run _immich_backup_status _immich_backup_remove step_immich_backup_menu; do fn "$f"; done)
check 11a "Immich backup functions exist and never touch the mirror question" '[ -n "$IMM" ] && ! grep -Eq "_mirror_|sync_mode" <<<"$IMM"'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
