#!/bin/bash
# Sync jobs of federver -> 14 (laptop): create, list, edit, schedule, delete, Status and the
# run of a job. Pins the current behaviour of the paths the sync-job refactor touches
# (change schedule, delete, dotted names, the logged result of a run) so each step
# stays proven, then covers what the refactor adds. Functions are extracted from
# setup.sh and run in a sandbox: stub crontab / systemctl / rsync / ssh, no network, no
# sudo. Run: bash tests/sync-jobs.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first runs).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.local/bin" "$T/home/.local/share/sync-jobs" "$T/en"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=

# Every function the sync-job code may be made of (a name missing from this copy is skipped).
{ for f in ok fail info warn ssh _shq _tcp_open _is_server _pick_server_endpoint _resolve_server_endpoint \
           _cron_cmd _cron_get _cron_drop _cron_set _cron_add_sync _cron_remove_line _cron_replace_line _cron_to_english \
           _drive_verdict _mirror_guard _mirror_refuse _mirror_flush _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with \
           _mirror_scan _mirror_wipe_sized _mirror_preview _mirror_delete_q _mirror_confirm _mirror_gate _src_size _confirm_delete \
           _sync_mirror_block _sync_job_mode _sync_job_field _sync_job_set_mode _sync_mode_cell _sync_result_text _sync_last_result \
           _sync_result_text _sync_change_mode _sync_execute_or_schedule _sync_show_status _sync_edit_job _sync_list_jobs \
           _sync_delete_job _sync_job_delete _sync_cron_split _sync_registry_load _sync_change_schedule _sync_install_timer _sync_remove_timer \
           _sync_rec_load _sync_rec_write _sync_valid_name _sync_default_name _sync_write_launcher _sync_job_run _sync_job_go \
           _sync_job_cmd _sync_job_import_legacy _sync_import_all_legacy _sync_tokenize _sync_setup_path _sync_run_logged _sync_one_time_backup; do
    extract_fn "$f" "$SRC"; done
  grep -E '^MIRROR_WIPE_MIN=|^_DRIVE_ROOTS=|^_SSH_OPTS=|^export RSYNC_RSH=|^_RSYNC_FLAGS=' "$SRC"; echo 'SSH_OPTS_OK=1'; } > "$T/fn.sh"
source "$T/fn.sh"
type _sync_execute_or_schedule >/dev/null 2>&1 || echo "FAIL  setup: sync functions not found in $SRC"
NEWDESIGN=; type _sync_job_run >/dev/null 2>&1 && NEWDESIGN=1

# fake ssh: drop the options and host, run the remote command locally (also the rsync transport)
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
echo "$*" >> "$SSH_LOG"
while [ $# -gt 0 ]; do case "$1" in -o|-l|-p|-i) shift 2;; -*) shift;; *) break;; esac; done
shift
[ -n "$SSH_DOWN" ] && exit 255
[ $# -gt 0 ] || exit 0
exec bash -c "$*"
X
# crontab stub: -l / - / -r on a file
cat > "$T/bin/crontab" <<'X'
#!/bin/bash
case "$1" in
  -l) [ -f "$CRON_FILE" ] || { echo "no crontab for x" >&2; exit 1; }; cat "$CRON_FILE" ;;
  -)  cat > "$CRON_FILE" ;;
  -r) rm -f "$CRON_FILE" ;;
esac
exit 0
X
# systemctl --user: enable/disable by a marker file per unit
cat > "$T/bin/systemctl" <<'X'
#!/bin/bash
case "$*" in
  *is-enabled*) u=${@: -1}; [ -e "$T/en/$u" ] && echo enabled || { echo disabled; exit 1; } ;;
  *"enable --now"*) : > "$T/en/${@: -1}" ;;
  *"disable --now"*) rm -f "$T/en/${@: -1}" ;;
esac
exit 0
X
printf '#!/bin/bash\nexit 0\n' > "$T/bin/loginctl"
# rsync stub for the "what does the log say for exit N" runs: argv saved, exit $RSYNC_RC
cat > "$T/rsync-stub" <<'X'
#!/bin/bash
echo "$*" >> "$RSYNC_LOG"
exit "${RSYNC_RC:-0}"
X
chmod +x "$T/bin/"* "$T/rsync-stub"
export T RSYNC_LOG="$T/rsync.log" SSH_LOG="$T/ssh.log"
export PATH="$T/bin:$PATH" HOME="$T/home" CRON_FILE="$T/crontab" SERVER_USER=u SERVER_IP=h SERVER_HOST_TS=
export FM_ROOT="$T/mnt/usb"
stub_findmnt ok '$FM_ROOT' /dev/sdb1  stub '$FM_ROOT' systemd-1
export FM_MODE=ok
_DRIVE_ROOTS="$T/mnt"
_sync_pick_schedule() { echo "${SCHED:-cron 0 * * * *}"; }
_server_sudo_pw_prompt() { return 2; }

CHECK_DIAG='rc=$RC'
run() { local in=$1; shift; OUT=$(printf '%b' "$in" | "$@" 2>&1); RC=$?; }
LOGD=$T/home/.local/share/sync-jobs; BIND=$T/home/.local/bin
mk() {
  rm -rf "$T/s" "$T/d" "$T/mnt" "$T/crontab" "$T/en/"* "$BIND/"* "$LOGD/"* "$T/home/.config" "$RSYNC_LOG" "$SSH_LOG"
  mkdir -p "$T/s/sub" "$T/d/sub" "$T/mnt/usb"
  echo a > "$T/s/a"; echo b > "$T/s/sub/b"; echo x > "$T/d/gone"
}
# mkjob NAME MODE [DIRECTION]: a job created through the menu code (append or an
# already-confirmed mirror), real rsync over the fake ssh. The creation call changed
# shape with the sync-job refactor; this is the only place that knows both.
mkjob() {
  local name=$1 mode=${2:-append} dir=${3:-upload} ans=""
  [ "$mode" = mirror ] && ans="y\n"
  if [ -n "$NEWDESIGN" ]; then
    run "2\n$name\n$ans" _sync_execute_or_schedule "$dir" "$T/s" "$T/d" contents "$mode"
  elif [ "$dir" = upload ]; then
    run "2\n$name\n$ans" _sync_execute_or_schedule upload "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" "$mode" local
  else
    run "2\n$name\n$ans" _sync_execute_or_schedule download "$T/s" "$T/d" "rsync -avh --progress -s $(_shq "$T/s/") $(_shq "$T/d/")" "" "$mode" server
  fi
}
SCRIPT() { echo "$BIND/sync-$1.sh"; }
LOGF() { echo "$LOGD/$1.log"; }
# run a job the way cron does; with the stub rsync in front of PATH it exits $RSYNC_RC
cronrun() { # name rc
  mkdir -p "$T/stub"; cp "$T/rsync-stub" "$T/stub/rsync"
  ( export PATH="$T/stub:$PATH" RSYNC_RC=$2; bash "$(SCRIPT "$1")" ) >/dev/null 2>&1; JRC=$?
}
status() { ( _server_sudo_pw_prompt() { return 2; }
  ssh() { return 0; }
  _sync_show_status ) 2>&1; }

# ── 1  change schedule (pinned) ───────────────────────────────────────────
mk; mkjob a1 >/dev/null
check 1a "creation puts a cron line that runs the job script" 'grep -q "^0 \* \* \* \* .*sync-a1.sh$" "$CRON_FILE" 2>/dev/null'
echo "5 5 * * * $(SCRIPT other).sh" >> "$CRON_FILE"
SCHED="cron 30 3 * * *"
run "" _sync_change_schedule a1 "$(grep 'sync-a1.sh' "$CRON_FILE")" cron
check 1b "cron -> cron: the schedule is rewritten, the script path kept, other lines untouched" 'grep -q "^30 3 \* \* \* .*sync-a1.sh$" "$CRON_FILE" 2>/dev/null && [ "$(grep -c "sync-a1.sh" "$CRON_FILE")" = 1 ] && grep -q "^5 5 \* \* \* " "$CRON_FILE" 2>/dev/null'
check 1c "cron -> cron says what the job runs at now" '[[ "$OUT" == *"Schedule updated for '"'"'a1'"'"'"*"daily at 3am"* || "$OUT" == *"Schedule updated for '"'"'a1'"'"'"*"30 3 * * *"* ]]'
L=$(grep 'sync-a1.sh' "$CRON_FILE"); _cron_replace_line "$L" "#PAUSED#$L"
SCHED="cron 0 4 * * *"
run "" _sync_change_schedule a1 "$(grep 'sync-a1.sh' "$CRON_FILE")" cron
check 1d "a paused cron job stays paused after a schedule change" 'grep -q "^#PAUSED#0 4 \* \* \* .*sync-a1.sh$" "$CRON_FILE" 2>/dev/null'
SCHED="timer Sat"
run "" _sync_change_schedule a1 "$(grep 'sync-a1.sh' "$CRON_FILE")" cron
check 1e "cron -> timer: cron line gone, timer + service written" '! grep -q "sync-a1.sh" "$CRON_FILE" 2>/dev/null && grep -q "^OnCalendar=Sat" "$T/home/.config/systemd/user/sync-a1.timer" && grep -q "^ExecStart=.*sync-a1.sh$" "$T/home/.config/systemd/user/sync-a1.service"'
SCHED="cron 15 * * * *"
run "" _sync_change_schedule a1 Sat timer
check 1f "timer -> cron: timer unit files gone, cron line back" '[ ! -e "$T/home/.config/systemd/user/sync-a1.timer" ] && grep -q "^15 \* \* \* \* .*sync-a1.sh$" "$CRON_FILE" 2>/dev/null'
SCHED="timer Sun"
run "" _sync_change_schedule a1 "$(grep 'sync-a1.sh' "$CRON_FILE")" cron
SCHED="timer weekly"
run "" _sync_change_schedule a1 Sun timer
check 1g "timer -> timer: only the OnCalendar changes" 'grep -q "^OnCalendar=weekly" "$T/home/.config/systemd/user/sync-a1.timer"'
unset SCHED

# ── 2  delete (pinned): menu Delete and Edit -> Delete ───────────────────
mk; mkjob d1 >/dev/null; mkjob d2 >/dev/null; echo log > "$(LOGF d1)"; echo log > "$(LOGF d2)"
run "1\nsync-d1\n" _sync_delete_job
check 2a "Delete a job: cron line, script and log of that job are gone" '! grep -q "sync-d1.sh" "$CRON_FILE" 2>/dev/null && [ ! -e "$(SCRIPT d1)" ] && [ ! -e "$(LOGF d1)" ] && [[ "$OUT" == *"Deleted"*"d1"* ]]'
check 2b "the other job is untouched" 'grep -q "sync-d2.sh" "$CRON_FILE" 2>/dev/null && [ -e "$(SCRIPT d2)" ] && [ -e "$(LOGF d2)" ]'
mk; mkjob d1 >/dev/null
run "1\n\n" _sync_delete_job
check 2c "blank confirmation cancels: nothing removed" 'grep -q "sync-d1.sh" "$CRON_FILE" 2>/dev/null && [ -e "$(SCRIPT d1)" ] && [[ "$OUT" == *"Nothing deleted"* ]]'
run "1\nwrong\n" _sync_delete_job
check 2d "wrong confirmation cancels" 'grep -q "sync-d1.sh" "$CRON_FILE" 2>/dev/null && [ -e "$(SCRIPT d1)" ]'
mk; mkjob d1 >/dev/null; echo log > "$(LOGF d1)"
run "1\n5\nsync-d1\n" _sync_edit_job
check 2e "Edit job -> Delete does the same removal" '! grep -q "sync-d1.sh" "$CRON_FILE" 2>/dev/null && [ ! -e "$(SCRIPT d1)" ] && [ ! -e "$(LOGF d1)" ] && [[ "$OUT" == *"Deleted"*"d1"* ]]'
mk; SCHED="timer Sat"; mkjob d3 >/dev/null; unset SCHED
run "1\nsync-d3\n" _sync_delete_job
check 2f "a timer job: timer + service units, script and log are removed" '[ ! -e "$T/home/.config/systemd/user/sync-d3.timer" ] && [ ! -e "$T/home/.config/systemd/user/sync-d3.service" ] && [ ! -e "$(SCRIPT d3)" ]'
run "" _sync_delete_job
check 2g "no jobs: says so" '[[ "$OUT" == *"No sync jobs to delete."* ]]'

# ── 3  dotted job names are listed and manageable (was: empty name) ──────
mk; mkjob my.photos >/dev/null
run "" _sync_list_jobs
check 3a "List shows the dotted name" '[[ "$OUT" == *"1)"*"my.photos"*"[0 * * * *]"* ]]'
OUT=$(status)
check 3b "Status row carries the dotted name" 'grep -q "^  my.photos " <<<"$OUT"'
run "1\n6\n\n" _sync_edit_job
check 3c "Edit job opens the dotted job" '[[ "$OUT" == *"my.photos"*"cron"* ]]'
run "1\nsync-my.photos\n" _sync_delete_job
check 3d "Delete removes the dotted job" '! grep -q "sync-my.photos.sh" "$CRON_FILE" && [ ! -e "$(SCRIPT my.photos)" ]'

# ── 4  the logged result of a run: rsync exit 0 / 23 / 24 / 255 ──────────
mk; mkjob r1 >/dev/null
note() { _sync_result_text r1; }
cronrun r1 0;   N0=$(note)
check 4a "exit 0 -> last: ok, job exits 0" '[ "$JRC" = 0 ] && [[ "$N0" == *"last: ok"* ]] && grep -q "Sync finished: r1 (exit 0" "$(LOGF r1)"'
cronrun r1 23;  N23=$(note)
check 4b "exit 23 -> last: failed (exit 23), job exits 23" '[ "$JRC" = 23 ] && [[ "$N23" == *"last: failed (exit 23)"* ]]'
cronrun r1 255; N255=$(note)
check 4c "exit 255 -> last: failed (exit 255), job exits 255" '[ "$JRC" = 255 ] && [[ "$N255" == *"last: failed (exit 255)"* ]]'
cronrun r1 24;  N24=$(note)
if [ -n "$NEWDESIGN" ]; then
  check 4d "exit 24 (files vanished) -> last: ok (some files vanished), job exits 0" '[ "$JRC" = 0 ] && [[ "$N24" == *"last: ok (some files vanished)"* ]]'
else
  check 4d "exit 24 today: last: failed (exit 24), job exits 24 (changes with the refactor)" '[ "$JRC" = 24 ] && [[ "$N24" == *"last: failed (exit 24)"* ]]'
fi

# ── 5  one ssh option set for rsync, and the endpoint pick ───────────────
check 5a "ssh() and RSYNC_RSH share one option set (ConnectTimeout + keepalives)" '[[ "$_SSH_OPTS" == *ConnectTimeout=8*ServerAliveInterval=15*ServerAliveCountMax=4* && "$RSYNC_RSH" == "ssh $_SSH_OPTS" ]]'
_tcp_open() { case "$1" in "$LAN") [ -n "$LAN_UP" ];; "$TS") [ -n "$TS_UP" ];; esac; }
_is_server() { return 1; }
LAN=10.0.0.5; TS=tail.example; SERVER_IP=$LAN; SERVER_HOST_TS=$TS
LAN_UP=1 TS_UP=1; EP=$(_pick_server_endpoint); R=$?
check 5b "endpoint: LAN answers -> the LAN address" '[ "$EP" = "$LAN" ] && [ $R = 0 ]'
LAN_UP= TS_UP=1; EP=$(_pick_server_endpoint); R=$?
check 5c "endpoint: LAN down, Tailscale up -> the Tailscale address" '[ "$EP" = "$TS" ] && [ $R = 0 ]'
LAN_UP= TS_UP=; EP=$(_pick_server_endpoint); R=$?
check 5d "endpoint: both down -> rc 1 (and the LAN address)" '[ "$EP" = "$LAN" ] && [ $R = 1 ]'
SERVER_HOST_TS=; LAN_UP=; EP=$(_pick_server_endpoint); R=$?
check 5e "endpoint: no Tailscale name configured -> the LAN address, no probe needed" '[ "$EP" = "$LAN" ] && [ $R = 0 ]'
SERVER_HOST_TS=$TS; LAN_UP=; TS_UP=1
LAN=$LAN TS=$TS run "" bash -c 'source "$T/fn.sh"; _tcp_open() { [ "$1" = "$TS" ]; }; _is_server() { return 1; }; SERVER_IP=$LAN SERVER_HOST_TS=$TS; _resolve_server_endpoint; echo "IP=$SERVER_IP"'
check 5f "menu: away from home it says so and switches SERVER_IP to Tailscale" '[[ "$OUT" == *"LAN address ($LAN) unreachable — using Tailscale ($TS)."* && "$OUT" == *"IP=$TS" ]]'
LAN=$LAN TS=$TS run "" bash -c 'source "$T/fn.sh"; _tcp_open() { return 1; }; _is_server() { return 1; }; SERVER_IP=$LAN SERVER_HOST_TS=$TS; _resolve_server_endpoint; echo "rc=$? IP=$SERVER_IP"'
check 5g "menu: neither answers -> the two warnings, SERVER_IP kept, rc 0" '[[ "$OUT" == *"Neither $LAN nor $TS answered on port 22."* && "$OUT" == *"make sure Tailscale is up"* && "$OUT" == *"rc=0 IP=$LAN" ]]'
unset -f _tcp_open _is_server; SERVER_IP=h; SERVER_HOST_TS=

# one-time download over the fake ssh: rsync's own ssh gets the options and -s
_pick_local_path()  { local_path=$T/d; }
_pick_server_path() { server_path=$T/s; }
_pick_copy_mode()   { copy_mode=contents; }
mk; : > "$SSH_LOG"
run "2\n\ny" _sync_one_time_backup
TR=$(grep 'rsync --server' "$SSH_LOG")
check 5h "one-time download: rsync's ssh carries ConnectTimeout + keepalives" '[ -n "$TR" ] && [[ "$TR" == *ConnectTimeout=8*ServerAliveInterval=15* ]] && [ -e "$T/d/a" ]'
check 5i "one-time download: rsync runs with -s (protect-args)" '[[ "$TR" == *"rsync --server -s"* || "$TR" == *"--server"*" -s"* ]]'
mk; : > "$SSH_LOG"
run "2\ndelete\ny\ny" _sync_one_time_backup
TR=$(grep 'rsync --server' "$SSH_LOG")
check 5j "mirror preview (dry run) and the copy both use those ssh options" '[ "$(grep -c "rsync --server" "$SSH_LOG")" -ge 2 ] && ! grep "rsync --server" "$SSH_LOG" | grep -vq ConnectTimeout=8 && [ ! -e "$T/d/gone" ]'

# ── 6  the deletion count shared by the preview and the unattended cap ────
scan() { printf '%s\n' "$@" > "$T/list"; _mirror_scan "$T/list"; }
scan "del.|a" "del.|sub/b" "del.|e/"
check 6a "scan counts files and empty folders (not folders that hold deleted files)" '[ "$_mirror_nf" = 2 ] && [ "$_mirror_nd" = 1 ] && [ "$_mirror_nwhole" = 0 ] && ! _mirror_wipe_sized'
scan "del.|d/x" "del.|d/y" "del.|d/"
check 6b "a whole top-level folder is wipe-sized" '[ "$_mirror_nwhole" = 1 ] && _mirror_wipe_sized'
MIRROR_WIPE_MIN=3
scan "del.|a" "del.|b" "del.|c" "del.|d"
check 6c "more than MIRROR_WIPE_MIN files is wipe-sized" '_mirror_wipe_sized'
scan "del.|a" "del.|b" "del.|c"
check 6d "exactly MIRROR_WIPE_MIN files is not" '! _mirror_wipe_sized'
scan
check 6e "an empty list counts nothing" '[ "$_mirror_nf" = 0 ] && [ "$_mirror_nd" = 0 ] && ! _mirror_wipe_sized'
MIRROR_WIPE_MIN=1000

check_total
