#!/bin/bash
# Tests for the opt-in mirror mode (rsync --delete) of federver -> 16 sync and
# backups: the copy-mode question, source guard, dry-run preview + y/N, the tar
# (sudo) route, scheduled jobs (stored MODE, cron guard, skip log), Status rows
# and 14 -> 3 -> Change copy mode. Run: bash tests/sync-mirror.sh (non-zero on failure)
# Functions are extracted from setup.sh and run against REAL rsync on temp dirs;
# only the pickers, the schedule menu, crontab/systemctl/findmnt and the server
# hop are stubbed (a fake `ssh` runs the remote command locally). No network, no
# sudo. SETUP_SH=<file> tests another copy of setup.sh.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.local/bin" "$T/home/.local/share/sync-jobs"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=
CR=$'\033[R]'; CY=$'\033[Y]'   # status() swaps these in for RED/YELLOW

{ for f in ok fail info warn ssh _shq; do extract_fn "$f" "$SRC"; done   # ssh may be missing in an old copy: skipped
  grep -E "^MIRROR_WIPE_MIN=|^_DRIVE_ROOTS=|^_RSYNC_FLAGS=|^_SSH_OPTS=|^export RSYNC_RSH=|^_SYNC_REC_KEYS=" "$SRC"
  for f in _drive_verdict _existing_ancestor _dest_drive_verdict _drive_mount_point _dest_check _require_dest_drive _mirror_guard _mirror_refuse _mirror_flush _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with \
           _mirror_scan _mirror_wipe_sized _mirror_preview _commas _tick _mirror_delete_q _mirror_confirm _src_size _mirror_gate _sync_mode_cell _sync_result_text _sync_last_result _sync_change_mode \
           _sync_execute_or_schedule _sync_show_status _sync_rec_write _sync_rec_load _sync_write_launcher _sync_default_name _sync_valid_name _sync_job_operands _sync_job_steps _sync_job_go _sync_job_run _sync_prepare_dest _sync_rec_set_schedule _sync_rec_mode _sync_job_import_legacy _sync_import_all_legacy _sync_tokenize _pick_server_endpoint _tcp_open _is_server _sync_edit_job _sync_list_jobs _sync_cron_split _sync_registry_load _sync_job_delete _sync_delete_job _sync_change_schedule _sync_remove_timer _confirm_delete _cron_cmd _cron_get _cron_drop _cron_set _cron_remove_line _cron_replace_line \
           _cron_to_english _sched_text _when_short _sync_one_time_backup _dirlink_target _fold_dirlink; do extract_fn "$f" "$SRC"; done; } > "$T/fn.sh"
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
stub_findmnt ok '$FM_ROOT' /dev/sdb1  stub '$FM_ROOT' systemd-1
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
printf '#!/bin/bash\n[ "$1" = chown ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
chmod +x "$T/bin/"*
export T P_SRC P_DST
mkdir -p "$T/tmpd"; export TMPDIR=$T/tmpd
_FV_SELF=$(readlink -f "$SRC")
export PATH="$T/bin:$PATH" HOME="$T/home" CRON_FILE="$T/crontab" SERVER_USER=u SERVER_IP=h
export FM_ROOT="$T/mnt/usb"
_DRIVE_ROOTS="$T/mnt"   # the sandbox stands in for /mnt; shipped into job scripts and to the "server" with declare -p

# Stubs for what needs a terminal, cron, or the server's sudo.
_pick_local_path()  { if [ -z "$_pl" ]; then _pl=1; local_path=$P_SRC; else local_path=$P_DST; fi; }
_pick_server_path() { if [ -z "$_ps" ]; then _ps=1; server_path=$P_SRC; else server_path=$P_DST; fi; }
_pick_copy_mode()   { copy_mode=contents; }
_sync_pick_schedule() { echo "cron 0 * * * *"; }
_cron_add_sync() { echo "$2 $3" >> "$CRON_FILE"; }          # job_name sched script
_server_sudo_pw_prompt() { _SRV_PW=fake; return 0; }
_server_sudo_run() { bash -c "$1"; }                         # "root on the server" = this shell

CHECK_DIAG='rc=$RC'
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
check 2d "confirm wording" '[[ "$OUT" == *"Delete these 3 files and copy? [y/N]: "* ]]'
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
run "" env PATH="$T/lsonly" "$(command -v bash)" -c 'source "$T/fn.sh"; _DRIVE_ROOTS=$T/mnt; _drive_verdict "$T/mnt/usb/data"'
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
check 5d "empty-folders-only still asks y/N, then removes them" '[[ "$OUT" == *"Delete these 2 empty folders and copy? [y/N]: "* ]] && empties_gone && [[ "$OUT" == *"Mirror complete - 2 deleted"* ]]'
mkempty; run "${ONE}delete\nn\n$Y" LOCALCMD
check 5e "empty-folders-only + n: nothing removed" 'empties_kept && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkempty; mkdir "$T/d/e3" "$T/d/e4" "$T/d/e5" "$T/d/e6" "$T/d/e7"
run "${ONE}delete\nn\n$Y" LOCALCMD
check 5f "more than 5 empty folders: 5 groups then '... and M more folders'" '[[ "$OUT" == *"⚠ 7 empty folders would be removed"* && "$OUT" == *"... and 2 more folders"* ]]'
mkempty; rm -rf "$T/d/e2"
run "${ONE}delete\nn\n$Y" LOCALCMD
check 5g "one empty folder is singular" '[[ "$OUT" == *"⚠ 1 empty folder would be removed at $T/d:"* && "$OUT" == *"Delete these 1 empty folder and copy? [y/N]: "* ]]'
mk; mkdir "$T/d/e1" "$T/d/full"; echo f > "$T/d/full/f"
run "${ONE}delete\n4\n$Y" LOCALCMD   # full/ goes whole: type the count
check 5h "files and empty folders: file count kept, '(+ N empty folder)' added; a folder holding deleted files is not counted" '[[ "$OUT" == *"⚠ 4 files (+ 1 empty folder) would be deleted at $T/d:"* && "$OUT" == *"Type 4 to delete and copy, Enter = cancel: "* ]] && extras_gone && [ ! -e "$T/d/e1" ] && [ ! -e "$T/d/full" ]'
mk; rm -rf "$T/d"; mkdir -p "$T/d/sub"; echo a > "$T/d/a"; echo b > "$T/d/sub/b"
run "${ONE}delete\n$Y" LOCALCMD
check 5i "nothing at all to delete still says so (no folders either)" '[[ "$OUT" == *"✓ Nothing to delete - destination has no extra files."* && "$OUT" != *"empty folder"* && "$OUT" != *"Delete these"* ]]'

# ── 5b  ONE confirmation per one-time mirror copy, asked after the summary box ──
# (read -p prints no prompt on a pipe, so a Proceed? read is proved by the answer it consumes.)
# Input has NO extra answer for a second question: the old flow (delete question
# + Proceed?) read EOF at Proceed? and cancelled.
box_then_q() { local a=${OUT%%"$1"*}; [[ "$OUT" == *"$1"* && ( "$a" == *"One-time local copy"* || "$a" == *"One-time download"* || "$a" == *"One-time server copy"* ) ]]; }
nq() { grep -o '\[y/N\]' <<<"$OUT" | wc -l; }
mk; run "${ONE}delete\ny\n" LOCALCMD
check 5ja "local mirror, 3 deletions, ONE y: copies and deletes" 'copied && extras_gone'
check 5jb "exactly one [y/N], no Proceed?, asked after the summary box" '[ "$(nq)" = 1 ] && [[ "$OUT" != *"Proceed?"* ]] && box_then_q "Delete these 3 files and copy? [y/N]: "'
check 5jc "the preview (summary, full list) still prints before the box" 'PRE=${OUT%%"One-time local copy"*}; [[ "$PRE" == *"3 files would be deleted"* && "$PRE" == *"Full list: "* ]]'
mk; run "${ONE}delete\n" LOCALCMD
check 5jd "Enter at the one question cancels: nothing copied or deleted" '! copied && extras_kept && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mk; mkdir -p "$T/d/full"; echo f > "$T/d/full/f"; run "${ONE}delete\n4\n" LOCALCMD
check 5jf "wipe guard: typed count is the only question, copy runs" 'box_then_q "Type 4 to delete and copy, Enter = cancel: " && [ "$(nq)" = 0 ] && [[ "$OUT" != *"Proceed?"* ]] && extras_gone && copied'
mk; mkdir -p "$T/d/full"; echo f > "$T/d/full/f"; run "${ONE}delete\ny\n" LOCALCMD
check 5jg "wipe guard + y: cancelled" '! copied && extras_kept'
mk; rm -rf "$T/d"; mkdir "$T/d"; run "${ONE}delete\ny\n" LOCALCMD
check 5jh "mirror with nothing to delete: only the Proceed? read (one answer), no deletion question" 'copied && [ "$(nq)" = 0 ] && [[ "$OUT" != *"Delete these"* ]]'
mk; run "${ONE}\ny" LOCALCMD
check 5ji "append: unchanged, one Proceed? read, no deletion question" 'copied && extras_kept && [[ "$OUT" != *"Delete these"* ]]'
mk; _pl=1; run "2\ndelete\ny\n" LOCALCMD
check 5jj "download: one question" 'copied && extras_gone && [ "$(nq)" = 1 ] && [[ "$OUT" != *"Proceed?"* ]]'
mk; run "4\ndelete\ny\n" LOCALCMD
check 5jk "server -> server: one question" 'copied && extras_gone && [ "$(nq)" = 1 ] && [[ "$OUT" != *"Proceed?"* ]]'
mk; run "4\n\ny\n" LOCALCMD
check 5jl "server -> server append: unchanged, Proceed? answered (not cancelled)" '[[ "$OUT" != *"Cancelled"* ]] && extras_kept'
mk; run "1\ny\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents mirror
check 5jm "Run now (no box): the deletion question is the only one" 'copied && extras_gone && [ "$(nq)" = 1 ] && [[ "$OUT" != *"Proceed?"* ]]'

# ── 5c  From: size of a symlinked source ──────────────────────────────────
mk; head -c 3000000 /dev/zero > "$T/s/big"; ln -s "$T/s" "$T/lnk"; P_SRC=$T/lnk
run "${ONE}\ny" LOCALCMD
check 5ka "symlink to a folder: From: shows the folder's size, not (0)" '[[ "$OUT" == *"From: $T/lnk (2.9M)"* ]]'
mk; head -c 3000000 /dev/zero > "$T/s/big"; P_SRC=$T/s/
run "${ONE}\ny" LOCALCMD
check 5kb "plain folder size unchanged" '[[ "$OUT" == *"From: $T/s/ (2.9M)"* ]]'
mk; head -c 3000000 /dev/zero > "$T/s/big"
run "" bash -c 'source "$T/fn.sh"; echo "[$(_src_size "$T/s/big")] [$(_src_size "$T/nope")]"'
check 5kc "a single file and a missing path do not break" '[ "$OUT" = "[2.9M] []" ]'

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
# A job is a record + a two-line launcher; "a cron run" here is the run itself
# (_sync_job_run, logged to the job's log the way --run-job does). The launcher
# dispatch through the real setup.sh is covered in tests/sync-jobs.sh.
JOB=$T/home/.local/bin/sync-j1.sh; LOG=$T/home/.local/share/sync-jobs/j1.log; LOGD=$T/home/.local/share/sync-jobs
jobrun() { # name -> output into its log, JRC = its exit code
  ( exec >>"$T/home/.local/share/sync-jobs/$1.log" 2>&1; _sync_job_run "$1" ); JRC=$?
}
recmode() { _sync_rec_load "$1" && echo "$J_mode"; }
mkjob() { # mode answers [direction]
  mk
  run "2\nj1\n$2" _sync_execute_or_schedule "${3:-upload}" "$T/s" "$T/d" contents "$1"
}
mkjob mirror "y\n"
check 8a "mirror job: warning, preview, Save prompt" '[[ "$OUT" == *"⚠ Every scheduled run will delete destination files that are gone from the source."* && "$OUT" == *"⚠ 3 files would be deleted at $T/d:"* && "$OUT" == *"Save this job as mirror? [y/N]: "* ]]'
check 8b "mode is stored in the job record; the launcher is two lines" '[ "$(recmode j1)" = mirror ] && [ "$(wc -l < "$JOB")" = 2 ] && bash -n "$JOB"'
check 8c "the cron line runs that script" 'grep -q "sync-j1.sh" "$CRON_FILE"'
check 8d "creating it ran the first mirror copy" 'copied && extras_gone'
echo q > "$T/d/stray"; echo n > "$T/d/sub/stray2"
jobrun j1
check 8e "cron run of a mirror job deletes extras" '[ ! -e "$T/d/stray" ] && [ ! -e "$T/d/sub/stray2" ] && copied'
mkjob mirror "n\n"
check 8f "Save = n: nothing saved, no cron line, nothing copied" '[ ! -e "$JOB" ] && [ -z "$(recmode j1)" ] && [ ! -s "$CRON_FILE" ] && ! copied && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkjob append "\n"
check 8g "append job: stored as append, no prompt" '[ "$(recmode j1)" = append ] && [[ "$OUT" != *"Save this job"* ]]'
echo q > "$T/d/stray"
jobrun j1
check 8h "cron run of an append job keeps destination extras" '[ -e "$T/d/stray" ] && [ -e "$T/d/gone" ] && copied'
mkjob mirror "y\n"
rm -rf "$T/s"; mkdir "$T/s"; echo q > "$T/d/stray"; : > "$LOG"
jobrun j1
check 8i "empty source: cron run skips - no rsync, nothing deleted" '[ "$JRC" = 0 ] && [ -e "$T/d/stray" ] && [ -e "$T/d/a" ]'
check 8j "skip is logged in the agreed form" 'grep -Eq "^[0-9-]+ [0-9:]+: SKIPPED j1 - source empty \(mirror refused, nothing deleted\)$" "$LOG"'
check 8k "skip run writes no rsync output" '! grep -q "sending incremental" "$LOG"'
rm -rf "$T/s"
jobrun j1
check 8l "missing source: cron run skips too" '[ -e "$T/d/stray" ] && [ "$(grep -c SKIPPED "$LOG")" = 2 ]'
check 8r "missing source is logged as such, not as empty/unmounted" 'tail -n 1 "$LOG" | grep -Eq ": SKIPPED j1 - source missing \(mirror refused"'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; export FM_MODE=stub
run "2\nj2\ny\n" _sync_execute_or_schedule upload "$T/mnt/usb/data" "$T/d" contents mirror
check 8m "unmounted source refused at creation" '[ ! -e "$T/home/.local/bin/sync-j2.sh" ] && extras_kept && [[ "$OUT" == *"Refused."* ]]'
mk; mkdir -p "$T/mnt/usb/data"; echo q > "$T/mnt/usb/data/f"; export FM_MODE=ok
run "2\nj2\n4\n" _sync_execute_or_schedule upload "$T/mnt/usb/data" "$T/d" contents mirror   # sub/ goes whole: type the count
echo k > "$T/d/stray"; export FM_MODE=stub
jobrun j2
check 8n "cron run after the drive vanished (stub mount) skips" '[ -e "$T/d/stray" ] && grep -q "SKIPPED j2" "$T/home/.local/share/sync-jobs/j2.log"'
check 8s "unmounted drive is logged as such" 'grep -Eq ": SKIPPED j2 - drive not mounted \(mirror refused" "$T/home/.local/share/sync-jobs/j2.log"'
mk; run "2\nj3\ny\n" _sync_execute_or_schedule download "$T/s" "$T/d" contents mirror
echo k > "$T/d/stray"; rm -rf "$T/s"; mkdir "$T/s"
jobrun j3
check 8o "download job: the guard checks the SERVER path (over ssh) and skips" '[ -e "$T/d/stray" ] && grep -q "SKIPPED j3" "$T/home/.local/share/sync-jobs/j3.log" && [ "$(_sync_rec_load j3; echo $J_direction)" = download ]'
SSH_DOWN=1 jobrun j3; unset SSH_DOWN
check 8t "unreachable server is logged as a failed check, not as an empty source" '[ -e "$T/d/stray" ] && tail -n 1 "$T/home/.local/share/sync-jobs/j3.log" | grep -Eq ": SKIPPED j3 - could not check source \(mirror refused"'
mk; run "1\ny\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents mirror
check 8p "Run now with a mirror: preview, confirm, deletes" 'extras_gone && [[ "$OUT" == *"Mirror complete - 3 deleted"* ]]'
mk; run "1\n\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents mirror
check 8q "Run now, confirm = Enter: nothing changed" 'extras_kept && ! copied'
mkempty; run "1\ny\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents mirror
check 8u "Run now with only empty folders to remove: warned, confirmed, removed" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"* && "$OUT" != *"Nothing to delete"* ]] && empties_gone'
mkempty; run "2\nj1\nn\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents mirror
check 8v "Save job (mirror) with only empty folders: warned before the Save prompt" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"*"Save this job as mirror? [y/N]: "* ]] && empties_kept'

# ── 9  Status rows ────────────────────────────────────────────────────────
status() { ( RED=$CR; YELLOW=$CY; GREEN=$'\033[G]'; NC=$'\033[N]'
  _server_sudo_pw_prompt() { return 2; }
  ssh() { case "$*" in *"systemctl cat immich-backup.timer"*) echo "*-*-* 03:00:00";; esac; return 0; }
  _sync_show_status ) 2>&1; }
mk
mkjob mirror "y\n" >/dev/null
# an old generated script (pre-mirror, no MODE= line): Status converts it to a record + launcher
cat > "$T/home/.local/bin/sync-old.sh" <<EOF
#!/bin/bash
# Sync job: old
# Direction: upload
# Source: $T/s
# Destination: $T/d
exec >>"$T/home/.local/share/sync-jobs/old.log" 2>&1
SERVER_USER="u"
SERVER_IP="h"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: old"
rsync -avh --progress -s '$T/s/' 'u@h:$T/d/'
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
check 9b "converted old job (no stored mode) shows append" '[[ "$(row old)" == *append* && "$(row old)" != *mirror* ]]'
check 9c "skipped last result shown in yellow on the mirror row" "[[ \"\$(row j1)\" == *\"\${CY}⚠ skipped (source empty)\"* ]]"
check 9d "clean last result shown on the converted row" '[[ "$(row old)" == *"✓ ok"* ]]'
check 9e "Immich backup row shows append" '[[ "$(row immich-backup)" == *append* ]]'
check 9f "table has a Copy column" '[[ "$OUT" == *"Name"*"Copy"*"Note"* ]]'
check 9g "Last runs table also reports the skip" '[[ "$OUT" == *"j1"*"skipped (source empty)"* ]]'
echo "---- sample: Sync Status rows ----"; grep -E "^  (j1|old|immich-backup) " <<<"$OUT" | sed -E 's/\x1b\[[0-9;]*m//g; s/\x1b\[[A-Z]\]//g'; echo "----------------------------------"
check 9q "Schedule column: one readable format; When column names the mechanism; no raw '*-*-*' or 'systemd'" '[[ "$(row immich-backup)" == *"daily 03:00"*timer* && "$(row old)" == *"daily 03:30"*cron* && "$OUT" != *"*-*-*"* && "$OUT" != *systemd* ]]'
check 9r "Note column holds only the result (one wording with Last runs): no job type leaks into it" '[[ "$(row old)" != *"ok timer"* && "$(row old)" == *"✓ ok"* ]] && [[ "$OUT" != *"last:"* ]]'
printf '2026-11-21 03:00:01: SKIPPED j1 - could not check source (mirror refused, nothing deleted)\n' >> "$LOG"
OUT=$(status)
check 9m "Status names the real reason of the last skip" "[[ \"\$(row j1)\" == *\"⚠ skipped (could not check source)\"* ]]"
printf '2026-11-22 03:00:01: SKIPPED j1 - source empty or drive not mounted (mirror refused, nothing deleted)\n' >> "$LOG"
OUT=$(status)
check 9n "a skip logged by an older script keeps its own wording" "[[ \"\$(row j1)\" == *\"⚠ skipped (source empty or drive not mounted)\"* ]]"
printf '2026-11-23 03:00:01: SKIPPED j1 - would delete 4 files (over the mirror limit), nothing deleted\n' >> "$LOG"
OUT=$(status)
check 9o "a wipe-cap skip is shown with its count" "[[ \"\$(row j1)\" == *\"⚠ skipped (would delete 4 files (over the mirror limit))\"* ]]"
# systemd-timer job rows too
mkdir -p "$T/home/.config/systemd/user"
printf '[Timer]\nOnCalendar=Sat\n' > "$T/home/.config/systemd/user/sync-wk.timer"
J_name=wk J_mode=mirror J_direction=upload J_src=$T/s J_dest=$T/d J_src_loc=local J_dest_loc=server J_copy_mode=contents J_sched_kind=timer J_sched=Sat J_created=x
_sync_rec_write; _sync_write_launcher wk
OUT=$(status)
check 9h "timer job row shows its mode" '[[ "$(row wk)" == *mirror* ]]'
check 9s "timer job row: the mechanism appears once (When), not again in Note; weekly time is readable" '[ "$(grep -o timer <<<"$(row wk)" | wc -l)" = 1 ] && [[ "$(row wk)" == *"weekly "* ]]'
rm -rf "$T/home/.config"
# A REAL run of a job: a failed rsync must log its own exit code and show as
# "✗ failed (exit N)"; a clean run as "✓ ok".
mkjob append "\n" >/dev/null
logexit() { grep -oP 'Sync finished: j1 \(exit \K[0-9]+' "$LOG" | tail -n 1; }
rm -rf "$T/s"
jobrun j1; LE=$(logexit)
OUT=$(status)
check 9i "real failed run (missing source) logs a non-zero exit" '[ -n "$LE" ] && [ "$LE" != 0 ]'
check 9j "Status shows ✗ failed (exit N) with that same N" '[[ "$(row j1)" == *"✗ failed (exit $LE)"* ]]'
check 9k "the job exits with the rsync code (a timer unit shows failed)" '[ "$JRC" != 0 ] && [ "$JRC" = "$LE" ]'
mkdir -p "$T/s"; echo a > "$T/s/a"
jobrun j1
OUT=$(status)
check 9l "a clean real run after it: log says exit 0, Status shows ✓ ok, job exits 0" '[ "$(logexit)" = 0 ] && [ "$JRC" = 0 ] && [[ "$(row j1)" == *"✓ ok"* ]]'

# ── 10 Edit job -> Change copy mode ──────────────────────────────────────
mkjob append "\n" >/dev/null
EDIT() { _sync_edit_job; }
run "1\n6\ndelete\ny\n" EDIT
check 10a "menu offers 'Change copy mode' as 6 and keeps 0) Back" '[[ "$OUT" == *"6)"*"Change copy mode"* && "$OUT" == *"0)"*"Back"* ]]'
check 10b "append -> mirror stores mode=mirror in the record; the launcher is untouched" '[ "$(recmode j1)" = mirror ] && [ "$(wc -l < "$JOB")" = 2 ] && bash -n "$JOB"'
check 10b2 "no function copy or frozen value anywhere: the job files hold no verdict code" '! grep -q "_drive_verdict\|_mirror_guard\|SERVER_IP" "$JOB" "$LOGD/j1.job"'
check 10c "same preview + Save prompt as at creation" '[[ "$OUT" == *"⚠ 3 files would be deleted at $T/d:"* && "$OUT" == *"Save this job as mirror? [y/N]: "* ]]'
check 10d "the changed job now deletes on its next run" 'echo q > "$T/d/stray"; jobrun j1; [ ! -e "$T/d/stray" ]'
mkjob mirror "y\n" >/dev/null
run "1\n6\n\n" EDIT
check 10f "mirror -> append (Enter) stores mode=append" '[ "$(recmode j1)" = append ] && [[ "$OUT" == *"Append only"* ]]'
check 10g "an append job keeps destination extras" 'echo q > "$T/d/stray"; jobrun j1; [ -e "$T/d/stray" ]'
mkjob append "\n" >/dev/null
rm -rf "$T/s"; mkdir "$T/s"
run "1\n6\ndelete\ny\n" EDIT
check 10h "mirror refused on an empty source: job stays append" '[ "$(recmode j1)" = append ] && [[ "$OUT" == *"Refused."* ]]'
mkjob append "\n" >/dev/null
run "1\n6\ndelete\n\n" EDIT
check 10i "Save = Enter: job unchanged" '[ "$(recmode j1)" = append ] && [[ "$OUT" == *"Cancelled - nothing changed."* ]]'
mkjob append "\n" >/dev/null; rm -rf "$T/d"; mkdir -p "$T/d/sub" "$T/d/e1" "$T/d/e2"; echo a > "$T/d/a"; echo b > "$T/d/sub/b"
run "1\n6\ndelete\nn\n" EDIT
check 10q "Change copy mode with only empty folders to remove: warned before the Save prompt" '[[ "$OUT" == *"⚠ 2 empty folders would be removed at $T/d:"*"Save this job as mirror? [y/N]: "* && "$OUT" != *"Nothing to delete"* ]]'
check 10r "Change copy mode leaves no temp file behind (no mktemp leak)" '[ -z "$(ls "$TMPDIR" 2>/dev/null)" ] && [ -z "$(ls "$T/home/.local/bin" "$LOGD" | grep -E "\.[A-Za-z0-9]{6}$")" ]'
# a download job (source on the server): editing to mirror must guard over ssh
mkjob append "\n" download >/dev/null
run "1\n6\ndelete\ny\n" EDIT
echo k > "$T/d/stray"; rm -rf "$T/s"; mkdir "$T/s"
jobrun j1
check 10k "edited download job guards the SERVER source and skips on empty" '[ "$(recmode j1)" = mirror ] && [ -e "$T/d/stray" ] && grep -q "SKIPPED j1" "$LOG"'

# ── 11  Immich backup stays append-only ───────────────────────────────────
IMM=$(for f in step_immich_backup _immich_backup_run _immich_backup_status _immich_backup_remove step_immich_backup_menu; do extract_fn "$f" "$SRC"; done)
check 11a "Immich backup functions exist and never touch the mirror question" '[ -n "$IMM" ] && ! grep -Eq "_mirror_|sync_mode" <<<"$IMM"'

# ── 12  a symlinked source folder (one-time laptop -> laptop copy) ───────────
# `rsync link dest/` copies the link itself; "The whole folder" must copy the real folder into <dest>/<link name>/.
lnk() { mk; rm -f "$T/lnk"; ln -s "$T/s" "$T/lnk"; P_SRC=$T/lnk; }
_pick_copy_mode() { copy_mode=${CM:-contents}; }
CM=folder; lnk; run "${ONE}\n$Y" LOCALCMD
check 12a "folder mode, symlinked source: real files land in <dest>/<link name>/, not a link" '[ ! -L "$T/d/lnk" ] && [ -f "$T/d/lnk/a" ] && [ -f "$T/d/lnk/sub/b" ] && [ ! -e "$T/d/s" ]'
check 12b "screen: From says it is a symlink and where to, To is the real destination, one info line" '[[ "$OUT" == *"From: $T/lnk ("*") (symlink → $T/s)"* && "$OUT" == *"To:   $T/d/lnk"* && "$OUT" == *"is a symlink to $T/s - copying the real folder into $T/d/lnk/"* ]]'
CM=contents; lnk; run "${ONE}\n$Y" LOCALCMD
check 12c "contents mode with a symlinked source is unchanged: files land directly in <dest>, no <dest>/lnk, no symlink note" '[ -f "$T/d/a" ] && [ -f "$T/d/sub/b" ] && [ ! -e "$T/d/lnk" ] && [[ "$OUT" != *symlink* ]]'
CM=folder; mk; run "${ONE}\n$Y" LOCALCMD
check 12d "folder mode, a real (not symlinked) folder: unchanged, lands in <dest>/s/ and no symlink note" '[ -f "$T/d/s/a" ] && [[ "$OUT" != *symlink* ]]'
CM=folder; lnk; mkdir -p "$T/d/lnk"; echo stale > "$T/d/lnk/stale"
run "${ONE}delete\ny\n$Y" LOCALCMD
check 12e "mirror, folder mode, symlinked source: compared against <dest>/<link name>/ - its stale file is deleted, the parent's extras are not" '[ ! -L "$T/d/lnk" ] && [ ! -e "$T/d/lnk/stale" ] && [ -f "$T/d/lnk/a" ] && extras_kept && [[ "$OUT" == *"⚠ 1 file would be deleted at $T/d/lnk:"* ]]'
CM=; unset CM

check_total
