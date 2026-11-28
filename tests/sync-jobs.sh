#!/bin/bash
# Sync jobs of federver -> 16 (laptop): create, list, edit, schedule, delete, Status and the
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
           _cron_cmd _cron_get _cron_drop _cron_set _cron_add_sync _cron_remove_line _cron_replace_line _cron_to_english _sched_text _when_short \
           _drive_verdict _existing_ancestor _dest_drive_verdict _drive_mount_point _dest_check _require_dest_drive _mirror_guard _mirror_refuse _mirror_flush _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with \
           _mirror_scan _mirror_wipe_sized _mirror_preview _commas _mirror_delete_q _mirror_confirm _mirror_gate _src_size _confirm_delete \
           _sync_mirror_block _sync_job_mode _sync_job_field _sync_job_set_mode _sync_mode_cell _sync_result_text _sync_last_result \
           _sync_result_text _sync_change_mode _sync_execute_or_schedule _sync_show_status _sync_edit_job _sync_list_jobs \
           _sync_delete_job _sync_job_delete _sync_cron_split _sync_registry_load _sync_change_schedule _sync_install_timer _sync_remove_timer \
           _sync_rec_load _sync_rec_write _sync_valid_name _sync_default_name _sync_write_launcher _sync_job_run _sync_job_go \
           _sync_job_operands _sync_job_steps _sync_job_import_legacy _sync_prepare_dest _sync_rec_set_schedule _sync_rec_mode _sync_job_go _sync_import_all_legacy _sync_tokenize _sync_one_time_backup _env_get _server_path_presets _pick_server_path step_sync _sync_pick_schedule_unused; do
    extract_fn "$f" "$SRC"; done
  grep -E '^MIRROR_WIPE_MIN=|^_DRIVE_ROOTS=|^_SYNC_REC_KEYS=|^_SSH_OPTS=|^export RSYNC_RSH=|^_RSYNC_FLAGS=' "$SRC"; echo 'SSH_OPTS_OK=1'; } > "$T/fn.sh"
source "$T/fn.sh"
type _sync_execute_or_schedule >/dev/null 2>&1 || echo "FAIL  setup: sync functions not found in $SRC"
NEWRUN=; type _sync_job_run >/dev/null 2>&1 && NEWRUN=1   # the run exists
NEWDESIGN=; type _sync_job_import_legacy >/dev/null 2>&1 && NEWDESIGN=1   # ...and the menus use it

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
printf '#!/bin/bash\n[ "$1" = chown ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
# rsync stub for the "what does the log say for exit N" runs: argv saved, exit $RSYNC_RC
cat > "$T/rsync-stub" <<'X'
#!/bin/bash
echo "$*" >> "$RSYNC_LOG"
exit "${RSYNC_RC:-0}"
X
chmod +x "$T/bin/"* "$T/rsync-stub"
_FV_SELF=$(readlink -f "$SRC"); FEDERVER_CONFIG=$T/federver-config   # launchers run the real setup.sh under test
export T RSYNC_LOG="$T/rsync.log" SSH_LOG="$T/ssh.log"
export PATH="$T/bin:$PATH" HOME="$T/home" CRON_FILE="$T/crontab" SERVER_USER=u SERVER_IP=h SERVER_HOST_TS=
export FM_ROOT="$T/mnt/usb"
stub_findmnt ok '$FM_ROOT' /dev/sdb1  stub '$FM_ROOT' systemd-1  bare / /dev/nvme0n1p2
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
mk; mkjob dotted >/dev/null
if [ -n "$NEWDESIGN" ]; then   # a dotted name can no longer be created: make one the way an old job exists
  _cron_remove_line "sync-dotted.sh"; rm -f "$BIND/sync-dotted.sh" "$LOGD/dotted.job"
  mkdir -p "$BIND"; J_name=my.photos J_direction=upload J_mode=append J_copy_mode=contents J_src_loc=local J_dest_loc=server J_src=$T/s J_dest=$T/d J_sched_kind=cron J_sched="0 * * * *" J_created=x
  _sync_rec_write; _sync_write_launcher my.photos; _cron_add_sync my.photos "0 * * * *" "$BIND/sync-my.photos.sh"
else
  mk; mkjob my.photos >/dev/null
fi
run "" _sync_list_jobs
check 3a "List shows the dotted name" '[[ "$OUT" == *"1)"*"my.photos"*"[0 * * * *]"* ]]'
OUT=$(status)
check 3b "Status row carries the dotted name" 'grep -q "^  my.photos " <<<"$OUT"'
run "1\n6\n\n" _sync_edit_job
check 3c "Edit job opens the dotted job" '[[ "$OUT" == *"my.photos"*"cron"* ]]'
run "1\nsync-my.photos\n" _sync_delete_job
check 3d "Delete removes the dotted job" '! grep -q "sync-my.photos.sh" "$CRON_FILE" 2>/dev/null && [ ! -e "$(SCRIPT my.photos)" ]'

# ── 4  the logged result of a run: rsync exit 0 / 23 / 24 / 255 ──────────
mk; mkjob r1 >/dev/null
note() { _sync_result_text r1; }
cronrun r1 0;   N0=$(note)
check 4a "exit 0 -> ✓ ok, job exits 0" '[ "$JRC" = 0 ] && [[ "$N0" == *"✓ ok"* ]] && grep -q "Sync finished: r1 (exit 0" "$(LOGF r1)"'
cronrun r1 23;  N23=$(note)
check 4b "exit 23 -> ✗ failed (exit 23), job exits 23" '[ "$JRC" = 23 ] && [[ "$N23" == *"✗ failed (exit 23)"* ]]'
cronrun r1 255; N255=$(note)
check 4c "exit 255 -> ✗ failed (exit 255), job exits 255" '[ "$JRC" = 255 ] && [[ "$N255" == *"✗ failed (exit 255)"* ]]'
cronrun r1 24;  N24=$(note)
if [ -n "$NEWDESIGN" ]; then
  check 4d "exit 24 (files vanished) -> ✓ ok (some files vanished), job exits 0" '[ "$JRC" = 0 ] && [[ "$N24" == *"✓ ok (some files vanished)"* ]]'
else
  check 4d "exit 24 today: ✗ failed (exit 24), job exits 24 (changes with the refactor)" '[ "$JRC" = 24 ] && [[ "$N24" == *"✗ failed (exit 24)"* ]]'
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

# ── 7  the job record, the launcher and the run (design B) ───────────────
if [ -n "$NEWRUN" ]; then
rec() { # name direction mode [copy_mode]
  J_name=$1 J_direction=$2 J_mode=$3 J_copy_mode=${4:-contents} J_sched_kind=cron J_sched="0 * * * *" J_created=now
  if [ "$2" = upload ]; then J_src_loc=local J_dest_loc=server; else J_src_loc=server J_dest_loc=local; fi
  J_src=$T/s J_dest=$T/d
  _sync_rec_write
}
LOGOF() { cat "$(LOGF "$1")" 2>/dev/null; }
# a record round-trips whatever the values hold, and loading never executes them
mk
J_name=odd J_direction=upload J_mode=append J_copy_mode=folder J_src_loc=local J_dest_loc=server J_sched_kind=cron J_sched='*/5 * * * *' J_created=x
J_src="$T/s/we ird & 'q' \"d\" \$(touch $T/PWNED) \`touch $T/PWNED2\` a|b\\c=d  "; J_dest="$T/d dir/\$HOME"
_sync_rec_write; RW=$?
J_src= J_dest= J_sched=; _sync_rec_load odd; RL=$?
check 7a "record round-trip: spaces, | & \\ quotes, \$( ), backticks, = and trailing blanks come back exactly" '[ $RW = 0 ] && [ $RL = 0 ] && [ "$J_src" = "$T/s/we ird & '"'"'q'"'"' \"d\" \$(touch $T/PWNED) \`touch $T/PWNED2\` a|b\\c=d  " ] && [ "$J_dest" = "$T/d dir/\$HOME" ] && [ "$J_sched" = "*/5 * * * *" ]'
check 7b "loading a record executes nothing" '[ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ]'
check 7c "the record is private (mode 600) and a plain KEY=VALUE file" '[ "$(stat -c %a "$LOGD/odd.job")" = 600 ] && grep -q "^copy_mode=folder$" "$LOGD/odd.job" && [ "$(grep -c . "$LOGD/odd.job")" = 11 ]'
J_name=bad; J_src=$'a\nb'; run "" _sync_rec_write
check 7d "a value with a line break is refused, nothing written" '[ $RC != 0 ] && [ ! -e "$LOGD/bad.job" ] && [[ "$OUT" == *"line break"* ]]'
check 7e "a missing or incomplete record does not load" '! _sync_rec_load nope && printf "name=half\n" > "$LOGD/half.job" && ! _sync_rec_load half'

# launcher
SERVER_USER=testuser SERVER_IP=192.0.2.77 _sync_write_launcher l1; LW=$?
check 7f "launcher: two lines, runs setup.sh --run-job <name>, passes bash -n" '[ $LW = 0 ] && [ "$(wc -l < "$BIND/sync-l1.sh")" = 2 ] && [ "$(sed -n 2p "$BIND/sync-l1.sh")" = "exec $_FV_SELF --run-job l1" ] && bash -n "$BIND/sync-l1.sh" && [ -x "$BIND/sync-l1.sh" ]'
check 7g "launcher holds no address, user or function" '! grep -Eq "192.0.2.77|testuser|SERVER_|\(\) *\{" "$BIND/sync-l1.sh"'
_sync_write_launcher 'my.photos'
check 7h "a dotted name is quoted into the launcher safely" '[ "$(sed -n 2p "$BIND/sync-my.photos.sh")" = "exec $_FV_SELF --run-job my.photos" ]'

# names
check 7i "default name from a path: Photos.2024 -> photos-2024, spaces and symbols -> -" '[ "$(_sync_default_name "/x/Photos.2024")" = photos-2024 ] && [ "$(_sync_default_name "/x/My Docs/")" = my-docs ] && [ "$(_sync_default_name "/x/a&b")" = a-b ] && [ "$(_sync_default_name /)" = job ]'
check 7j "valid names: a-z 0-9 - _" '_sync_valid_name photos-2024_x >/dev/null && ! _sync_valid_name "" >/dev/null'
V=$(_sync_valid_name "my.photos"); V2=$(_sync_valid_name "a/b"); V3=$(_sync_valid_name "Up")
check 7k "invalid names: one-line reason naming the character" '[[ "$V" == "'"'"'.'"'"' is not allowed in a job name"* && "$V2" == "'"'"'/'"'"' is not"* && "$V3" == "'"'"'U'"'"' is not"* ]]'

# the run: against real rsync over the fake ssh (upload and download, append)
mk; rec up1 upload append
run "" _sync_job_run up1
check 7l "upload run: files arrive, start and finish lines, exit 0" '[ $RC = 0 ] && [ -e "$T/d/a" ] && [ -e "$T/d/sub/b" ] && [ -e "$T/d/gone" ] && [[ "$OUT" == *"Starting sync: up1"* && "$OUT" == *"Sync finished: up1 (exit 0)"* ]]'
mk; rec up2 upload append; J_dest=$T/new/deeper/dir; _sync_rec_write
run "" _sync_job_run up2
check 7m "a missing destination is created without sudo (remote mkdir -p over ssh)" '[ $RC = 0 ] && [ -e "$T/new/deeper/dir/a" ]'
mk; rec dn1 download append
run "" _sync_job_run dn1
check 7n "download run (source on the server)" '[ $RC = 0 ] && [ -e "$T/d/a" ] && [ -e "$T/d/gone" ]'
mk; rec fo1 upload append folder
run "" _sync_job_run fo1
check 7o "copy mode 'folder' lands in <dest>/<folder name>" '[ $RC = 0 ] && [ -e "$T/d/s/a" ] && [ -e "$T/d/s/sub/b" ]'
mk; mkdir -p "$T/s/sp ace"; echo q > "$T/s/sp ace/we ird.txt"; rec sp1 upload append
run "" _sync_job_run sp1
check 7p "names with spaces survive the transport (-s)" '[ $RC = 0 ] && [ -e "$T/d/sp ace/we ird.txt" ]'

# transport + no sudo
mk; rec tr1 upload append; : > "$SSH_LOG"
run "" _sync_job_run tr1
check 7q "every ssh of the run (mkdir and rsync's own) carries ConnectTimeout + keepalives" '[ "$(wc -l < "$SSH_LOG")" -ge 2 ] && ! grep -vq "ConnectTimeout=8.*ServerAliveInterval=15.*ServerAliveCountMax=4" "$SSH_LOG" && grep -q "rsync --server" "$SSH_LOG"'
cp "$T/bin/sudo" "$T/sudo-base"; printf '#!/bin/bash\necho sudo >> "$T/sudo.log"; exit 1\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"; : > "$T/sudo.log"
mk; rec ns1 upload mirror; run "" _sync_job_run ns1; mk; rec ns2 download append; J_dest=$T/nw/x; _sync_rec_write; run "" _sync_job_run ns2
check 7r "no sudo is called by an upload (mirror) or download run" '[ ! -s "$T/sudo.log" ] && [ -e "$T/nw/x/a" ]'
cp "$T/sudo-base" "$T/bin/sudo"
UNATT=$(for f in _sync_job_run _sync_job_go _sync_job_steps _sync_job_operands _sync_rec_load _pick_server_endpoint _mirror_scan _mirror_wipe_sized; do extract_fn "$f" "$T/fn.sh"; done)
check 7s "the unattended path never mentions sudo or a terminal prompt " '[ -n "$UNATT" ] && ! grep -Eq "sudo|ssh -t|read -p|read -n|/dev/tty" <<<"$UNATT"'

# exit codes (stub rsync): logged as rsync's own, 24 is success
for rc in 0 23 24 255; do
  mk; rec ec$rc upload append; mkdir -p "$T/stub"; cp "$T/rsync-stub" "$T/stub/rsync"
  OUT=$(PATH="$T/stub:$PATH" RSYNC_RC=$rc _sync_job_run ec$rc 2>&1); RC=$?
  eval "OUT$rc=\$OUT RC$rc=\$RC"
done
check 7t "rsync 0 -> '(exit 0)', job exits 0" '[ $RC0 = 0 ] && [[ "$OUT0" == *"Sync finished: ec0 (exit 0)" ]]'
check 7u "rsync 23 -> '(exit 23)', job exits 23" '[ $RC23 = 23 ] && [[ "$OUT23" == *"Sync finished: ec23 (exit 23)" ]]'
check 7v "rsync 24 -> success, noted: (exit 0, some files vanished), job exits 0" '[ $RC24 = 0 ] && [[ "$OUT24" == *"Sync finished: ec24 (exit 0, some files vanished)" ]]'
check 7w "rsync 255 -> '(exit 255)', job exits 255" '[ $RC255 = 255 ] && [[ "$OUT255" == *"Sync finished: ec255 (exit 255)" ]]'

# endpoint resolved at run time (stubbed LAN probe)
_tcp_open() { case "$1" in "$LAN") [ -n "$LAN_UP" ];; "$TS") [ -n "$TS_UP" ];; esac; }
LAN=10.0.0.5; TS=tail.example; SERVER_IP=$LAN; SERVER_HOST_TS=$TS
mk; rec ep1 upload append; cp "$T/rsync-stub" "$T/stub/rsync"
LAN_UP=1 TS_UP=1; : > "$RSYNC_LOG"; run "" env PATH="$T/stub:$PATH" bash -c 'true'; OUT=$(PATH="$T/stub:$PATH" _sync_job_run ep1 2>&1); RC=$?
check 7x "LAN answers: the job talks to the LAN address" 'grep -q "u@$LAN:" "$RSYNC_LOG"'
LAN_UP= TS_UP=1; : > "$RSYNC_LOG"; OUT=$(PATH="$T/stub:$PATH" _sync_job_run ep1 2>&1); RC=$?
check 7y "LAN down, Tailscale up: the same job talks to the Tailscale address" 'grep -q "u@$TS:" "$RSYNC_LOG" && ! grep -q "u@$LAN:" "$RSYNC_LOG" && [ $RC = 0 ]'
LAN_UP= TS_UP=; : > "$RSYNC_LOG"; OUT=$(PATH="$T/stub:$PATH" _sync_job_run ep1 2>&1); RC=$?
check 7z "both down: fails fast, rsync never started, logged as exit 255" '[ $RC = 255 ] && [ ! -s "$RSYNC_LOG" ] && [[ "$OUT" == *"Server unreachable"* && "$OUT" == *"Sync finished: ep1 (exit 255)" ]]'
SERVER_IP=h; SERVER_HOST_TS=; unset -f _tcp_open

# mirror: guard, wipe cap, nocap
mk; rec mi1 upload mirror
run "" _sync_job_run mi1
check 7aa "mirror run deletes what is gone from the source" '[ $RC = 0 ] && [ -e "$T/d/a" ] && [ ! -e "$T/d/gone" ]'
mk; rec mi2 upload mirror; rm -rf "$T/s"; mkdir "$T/s"
run "" _sync_job_run mi2
check 7ab "empty source: SKIPPED line, exit 0, nothing deleted" '[ $RC = 0 ] && [ -e "$T/d/gone" ] && [[ "$OUT" == *": SKIPPED mi2 - source empty (mirror refused, nothing deleted)"* && "$OUT" != *"Sync finished"* ]]'
mk; rec mi3 download mirror; rm -rf "$T/s"; mkdir "$T/s"
run "" _sync_job_run mi3
check 7ac "download mirror: the guard checks the server source over ssh" '[ $RC = 0 ] && [ -e "$T/d/gone" ] && [[ "$OUT" == *"SKIPPED mi3 - source empty"* ]]'
mk; rec mi4 upload mirror; for i in 1 2 3; do echo x > "$T/d/extra$i"; done; MIRROR_WIPE_MIN=3
run "" _sync_job_run mi4
check 7ad "mirror at the limit (4 files = 3 extras + gone, MIRROR_WIPE_MIN=3 -> over): wipe cap skips, logs, deletes nothing" '[ $RC = 0 ] && [ -e "$T/d/gone" ] && [ -e "$T/d/extra1" ] && [[ "$OUT" == *": SKIPPED mi4 - would delete 4 files (over the mirror limit), nothing deleted"* && "$OUT" != *"Sync finished"* ]] && [ ! -e "$T/d/a" ]'
MIRROR_WIPE_MIN=4
run "" _sync_job_run mi4
check 7ae "exactly MIRROR_WIPE_MIN deletions: not capped, deleted" '[ $RC = 0 ] && [ ! -e "$T/d/gone" ] && [ ! -e "$T/d/extra1" ] && [ -e "$T/d/a" ]'
MIRROR_WIPE_MIN=1000
mk; rec mi5 upload mirror; mkdir -p "$T/d/wholedir"; echo w > "$T/d/wholedir/f"
run "" _sync_job_run mi5
check 7af "a whole top-level folder to delete trips the cap whatever the count" '[ -e "$T/d/wholedir/f" ] && [ -e "$T/d/gone" ] && [[ "$OUT" == *"SKIPPED mi5 - would delete"*"(over the mirror limit), nothing deleted"* ]]'
run "" _sync_job_run mi5 nocap
check 7ag "nocap (the user just confirmed the preview): the same deletion runs" '[ ! -e "$T/d/wholedir" ] && [ ! -e "$T/d/gone" ] && [[ "$OUT" == *"Sync finished: mi5 (exit 0)" ]]'
mk; rec mi6 upload mirror; mkdir -p "$T/stub"; printf '#!/bin/bash\ncase "$*" in -n\ --delete*) exit 12;; esac\necho real >> "$RSYNC_LOG"; exit 0\n' > "$T/stub/rsync"; chmod +x "$T/stub/rsync"
OUT=$(PATH="$T/stub:$PATH" _sync_job_run mi6 2>&1); RC=$?
check 7ah "a dry run that fails: nothing runs, its exit code is logged" '[ $RC = 12 ] && [ ! -s "$RSYNC_LOG" ] && [[ "$OUT" == *"Could not check what a mirror would delete (rsync exit 12)"* && "$OUT" == *"Sync finished: mi6 (exit 12)" ]]'
run "" _sync_job_run ghost
check 7ai "no record: logged as a failed run (exit 2), not silence" '[ $RC = 2 ] && [[ "$OUT" == *"No usable job record for '"'"'ghost'"'"'"* && "$OUT" == *"Sync finished: ghost (exit 2)" ]]'
fi

# ── 8  creating a job through the menu code (design B) ───────────────────
if [ -n "$NEWDESIGN" ]; then
mk; SERVER_USER=testuser SERVER_IP=192.0.2.77 mkjob j8 mirror >/dev/null
check 8a "creation writes the record, the launcher and a cron line that runs the launcher" '_sync_rec_load j8 && [ "$J_mode" = mirror ] && [ "$J_direction" = upload ] && [ "$J_src" = "$T/s" ] && [ "$J_dest" = "$T/d" ] && [ "$J_sched_kind" = cron ] && [ "$J_sched" = "0 * * * *" ] && grep -q "^0 \* \* \* \* $BIND/sync-j8.sh$" "$CRON_FILE" 2>/dev/null && [ -x "$BIND/sync-j8.sh" ]'
check 8b "neither the record nor the launcher holds the server's address or user" '! grep -q "192.0.2.77\|testuser" "$BIND/sync-j8.sh" "$LOGD/j8.job" && [ "$(wc -l < "$BIND/sync-j8.sh")" = 2 ]'
check 8c "the first run after creating logs like any other run (Status reads it)" 'grep -q "Sync finished: j8 (exit 0)" "$(LOGF j8)" && [[ "$(_sync_result_text j8)" == *"✓ ok"* ]]'
check 8d "the record is private" '[ "$(stat -c %a "$LOGD/j8.job")" = 600 ]'

# names: default from the folder, typed names checked
mk; mv "$T/s" "$T/Photos.2024"; run "2\n\n" _sync_execute_or_schedule upload "$T/Photos.2024" "$T/d" contents append
check 8e "default name of 'Photos.2024' is photos-2024 and Enter takes it" '[ -e "$BIND/sync-photos-2024.sh" ] && _sync_rec_load photos-2024'
mk; run "2\nmy.photos\nMy Docs\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents append
check 8f "a typed name with a bad character is refused with the character named, then asked again" '[[ "$OUT" == *"'"'"'.'"'"' is not allowed in a job name"* ]] && [ -e "$BIND/sync-my-docs.sh" ] && [ ! -e "$BIND/sync-my.photos.sh" ]'
mk; mkjob dup >/dev/null; run "2\ndup\nother\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents append
check 8g "a name that already exists is refused (an existing job is never overwritten)" '[[ "$OUT" == *"A job named '"'"'dup'"'"' already exists"* ]] && [ -e "$BIND/sync-other.sh" ] && [ "$(grep -c "sync-dup.sh" "$CRON_FILE")" = 1 ]'
mk; run "2\nq\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents append
check 8h "q backs out: nothing written" '[ -z "$(ls -A "$BIND" "$LOGD" | grep -v :)" ] && [ ! -s "$CRON_FILE" ]'

# Run now (no schedule): runs the shared run, nothing saved
mk; run "1\n" _sync_execute_or_schedule upload "$T/s" "$T/d" contents append
check 8i "Run now copies once, saves no job" '[ -e "$T/d/a" ] && [ -e "$T/d/sub/b" ] && [[ "$OUT" == *"Sync complete."* ]] && [ -z "$(ls -A "$BIND" "$LOGD" | grep -v :)" ]'
mk; mkdir -p "$T/ro"; chmod 555 "$T/ro"; run "1\n" _sync_execute_or_schedule upload "$T/s" "$T/ro/sub" contents append; chmod 755 "$T/ro"
if [ "$(id -u)" = 0 ]; then echo "PASS  8j  SKIP: running as root"; PASS=$((PASS+1)); else
check 8j "Run now into a folder that cannot be made: the run says so (no sudo in the run), the menu says 'Sync failed.'" '[[ "$OUT" == *"Could not create the destination"* && "$OUT" == *"Sync failed."* ]]'; fi

# change schedule keeps the record in step; pause / resume
mk; mkjob s1 >/dev/null; SCHED="timer Sat"
run "" _sync_change_schedule s1 "$(grep sync-s1.sh "$CRON_FILE")" cron; unset SCHED
check 8k "Change schedule writes the new kind and spec into the record" '_sync_rec_load s1 && [ "$J_sched_kind" = timer ] && [ "$J_sched" = Sat ]'
mk; mkjob p1 >/dev/null
run "1\n2\n" _sync_edit_job
check 8l "Pause: the cron line is commented out with #PAUSED#, List shows (paused)" 'grep -q "^#PAUSED#0 \* \* \* \* .*sync-p1.sh$" "$CRON_FILE" 2>/dev/null && [[ "$OUT" == *"Paused '"'"'p1'"'"'"* ]] && [[ "$(_sync_list_jobs)" == *"(paused)"* ]]'
run "1\n2\n" _sync_edit_job
check 8m "Resume puts it back" 'grep -q "^0 \* \* \* \* .*sync-p1.sh$" "$CRON_FILE" 2>/dev/null && [[ "$OUT" == *"Resumed '"'"'p1'"'"'"* ]]'
echo "stale" > "$(LOGF p1)"
run "1\n3\n" _sync_edit_job
check 8n "Edit -> Run now runs the launcher and shows the result" '[[ "$OUT" == *"'"'"'p1'"'"' completed."* && "$OUT" == *"✓ ok"* ]] && grep -q "Sync finished: p1 (exit 0)" "$(LOGF p1)"'

# the launcher itself, away from home: the real setup.sh --run-job resolves the address at run time
mk; mkjob aw >/dev/null; mkdir -p "$T/stub"; cp "$T/rsync-stub" "$T/stub/rsync"
printf '#!/bin/bash\ncase "$*" in *"/dev/tcp/$LAN_IP/"*) [ -n "$LAN_UP" ] && exit 0 || exit 1;; *"/dev/tcp/$TS_IP/"*) [ -n "$TS_UP" ] && exit 0 || exit 1;; esac\nexit 0\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"
awrun() { : > "$RSYNC_LOG"; : > "$(LOGF aw)"; PATH="$T/stub:$PATH" SERVER_IP=10.9.9.9 SERVER_HOST_TS=100.64.0.7 LAN_IP=10.9.9.9 TS_IP=100.64.0.7 LAN_UP=$1 TS_UP=$2 bash "$BIND/sync-aw.sh" >/dev/null 2>&1; JRC=$?; }
awrun 1 1
check 8s "launcher at home: the LAN address is used" '[ $JRC = 0 ] && grep -q "u@10.9.9.9:" "$RSYNC_LOG" && ! grep -q "100.64.0.7" "$RSYNC_LOG"'
awrun "" 1
check 8t "launcher away from home: the same job, unchanged, uses the Tailscale address" '[ $JRC = 0 ] && grep -q "u@100.64.0.7:" "$RSYNC_LOG" && ! grep -q "10.9.9.9" "$RSYNC_LOG" && grep -q "Sync finished: aw (exit 0)" "$(LOGF aw)"'
awrun "" ""
check 8u "launcher with no way to the server: exit 255, nothing started, the log says why" '[ $JRC = 255 ] && [ ! -s "$RSYNC_LOG" ] && grep -q "Server unreachable" "$(LOGF aw)" && grep -q "Sync finished: aw (exit 255)" "$(LOGF aw)" && [[ "$(_sync_result_text aw)" == *"✗ failed (exit 255)"* ]]'

# the one-time copies and one-time mirror banner of step_sync summaries
step_sync_stubs() { _pick_local_path() { local_path=$T/s; }; _pick_server_path() { server_path=$T/d; }; _sync_execute_or_schedule() { echo "EXEC $*"; }; }
BAN="Mode: mirror - deletes destination files that are gone from the source"
mk; step_sync_stubs; type step_sync >/dev/null 2>&1 || eval "$(extract_fn step_sync "$SRC")"
run "1\ndelete\n" step_sync
check 8o "step_sync upload: a mirror shows the red banner in its summary and hands the job over" '[[ "$OUT" == *"$BAN"* && "$OUT" == *"EXEC upload $T/s $T/d contents mirror" ]]'
mk; step_sync_stubs; run "1\n\n" step_sync
check 8p "step_sync upload: append shows no banner" '[[ "$OUT" != *"$BAN"* && "$OUT" == *"EXEC upload $T/s $T/d contents append" ]]'
mk; step_sync_stubs; run "2\ndelete\n" step_sync
check 8q "step_sync download: a mirror shows the banner too (source/destination as picked)" '[[ "$OUT" == *"$BAN"* && "$OUT" == *"EXEC download $T/d $T/s contents mirror" ]]'
fi

# ── 9  converting old job scripts (the only code that reads one) ─────────
if [ -n "$NEWDESIGN" ]; then
# legacy NAME KIND: an old generated script. kinds: cur-append, cur-mirror-dl, old-exit, nice, two, flag, nokey,
# disagree, badpre, mirror-nodelete, ip, crlf
legacy() {
  local n=$1 kind=$2 f=$BIND/sync-$1.sh ip=${3:-h} rs
  rs="rsync \$DELFLAG -avh --progress -s '$T/s/' 'u@$ip:$T/d/'"
  local hdr="#!/bin/bash
# Sync job: $n
# Direction: upload
# Source: $T/s
# Destination: $T/d
# Created: 2026-06-01 10:00
exec >>\"$LOGD/$n.log\" 2>&1

SERVER_USER=\"u\"
SERVER_IP=\"$ip\"
"
  local blk_a="# >>> copy mode (federver 14 → 3 'Change copy mode' rewrites this block)
MODE=append
DELFLAG=
# <<< copy mode"
  local pre="ssh -t 'u@$ip' 'sudo mkdir -p $T/d && sudo chown u:u $T/d'"
  local start="echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: $n\""
  local fin="rc=\$?
echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: $n (exit \$rc)\"
exit \$rc"
  case $kind in
    cur-append) printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "$rs" "$fin" ;;
    cur-mirror-dl)
      printf '#!/bin/bash\n# Sync job: %s\n# Direction: download\n# Source: %s\n# Destination: %s\n# Created: x\nexec >>"%s/%s.log" 2>&1\n\nSERVER_USER="u"\nSERVER_IP="h"\n\n' "$n" "$T/s" "$T/d" "$LOGD" "$n"
      printf '# >>> copy mode (federver 14 → 3 rewrites this block)\nMODE=mirror\ndeclare -- _DRIVE_ROOTS="/mnt /media"\nssh () \n{ \n    command ssh -o ConnectTimeout=8 "$@"\n}\n_mirror_guard () \n{ \n    local loc=$1;\n    return 0\n}\nDELFLAG=--delete\n_mirror_guard server %s || {\n    printf "%%s: SKIPPED %%s - %%s (mirror refused, nothing deleted)\\n" "$(date)" %s "$_mirror_why"\n    exit 0\n}\n# <<< copy mode\n\n' "$T/s" "$n"
      printf '%s\nsudo mkdir -p %s\nrsync $DELFLAG -avh --progress -s %s %s\n%s\n' "$start" "$T/d" "u@h:$T/s/" "$T/d/" "$fin" ;;
    old-exit)
      printf '#!/bin/bash\n# Sync job: %s\n# Direction: upload\n# Source: %s\n# Destination: %s\nexec >>"%s/%s.log" 2>&1\nSERVER_USER="u"\nSERVER_IP="h"\n%s\nrsync -avh --progress "%s/" "u@h:%s/"\necho "[$(date '"'"'+%%Y-%%m-%%d %%H:%%M:%%S'"'"')] Sync finished: %s (exit $?)"\n' "$n" "$T/s" "$T/d" "$LOGD" "$n" "$start" "$T/s" "$T/d" "$n" ;;
    nice)     printf '%s\n%s\n\n%s\n%s\nnice %s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "${rs/\$DELFLAG /}" "$fin" ;;
    two)      printf '%s\n%s\n\n%s\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "$rs" "$rs" "$fin" ;;
    flag)     printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "${rs/-avh/-avh --exclude=x}" "$fin" ;;
    nokey)    printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$(sed '/^# Source: /d' <<<"$hdr")" "$blk_a" "$start" "$pre" "$rs" "$fin" ;;
    disagree) printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "${rs/$T\/s\//$T/other/}" "$fin" ;;
    badpre)   printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "scp /etc/hosts u@$ip:/tmp/" "$rs" "$fin" ;;
    mirror-nodelete) printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "${blk_a/MODE=append/MODE=mirror}" "$start" "$pre" "$rs" "$fin" ;;
    ip)       printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "$rs" "$fin" ;;
    crlf)     printf '%s\n%s\n\n%s\n%s\n%s\n%s\n' "$hdr" "$blk_a" "$start" "$pre" "$rs" "$fin" | sed 's/$/\r/' ;;
  esac > "$f"
  chmod 755 "$f"
  echo "0 3 * * * $f" >> "$CRON_FILE"
}
legacy_mk() { mk; mkdir -p "$BIND" "$LOGD"; : > "$CRON_FILE"; }
sum() { cksum < "$1"; }

legacy_mk; legacy a1 cur-append; cp "$BIND/sync-a1.sh" "$T/a1.orig"
OUT=$(status); LAUNCH=$(cat "$BIND/sync-a1.sh")
check 9a "current-format script: converted - record written, launcher in place, old script kept as .bak byte for byte" '_sync_rec_load a1 && [ "$J_direction" = upload ] && [ "$J_src" = "$T/s" ] && [ "$J_dest" = "$T/d" ] && [ "$J_copy_mode" = contents ] && [ "$J_mode" = append ] && [ "$J_sched_kind" = cron ] && [ "$J_sched" = "0 3 * * *" ] && cmp -s "$BIND/sync-a1.sh.bak" "$T/a1.orig" && [ "$(wc -l < "$BIND/sync-a1.sh")" = 2 ]'
check 9b "one notice line per converted job, naming the .bak" '[[ "$OUT" == *"Converted '"'"'a1'"'"' to a launcher (old script kept as $BIND/sync-a1.sh.bak)."* ]] && [ "$(grep -c Converted <<<"$OUT")" = 1 ]'
check 9c "the converted job runs through the launcher (real setup.sh --run-job)" 'bash "$BIND/sync-a1.sh" >/dev/null 2>&1; [ -e "$T/d/a" ] && grep -q "Sync finished: a1 (exit 0)" "$(LOGF a1)"'
OUT=$(status)
check 9d "a second Status converts nothing again (no new .bak, no notice)" '[[ "$OUT" != *Converted* ]] && [ ! -e "$BIND/sync-a1.sh.bak2" ] && [ "$(cat "$BIND/sync-a1.sh")" = "$LAUNCH" ]'

legacy_mk; legacy m1 cur-mirror-dl
OUT=$(status)
check 9e "current-format mirror download job (function copies inside the block): converted, mirror + download + guard source" '_sync_rec_load m1 && [ "$J_mode" = mirror ] && [ "$J_direction" = download ] && [ "$J_src" = "$T/s" ] && [ "$J_dest" = "$T/d" ] && [ "$J_src_loc" = server ] && [ -e "$BIND/sync-m1.sh.bak" ] && ! grep -q "declare\|_mirror_guard" "$BIND/sync-m1.sh"'
check 9f "its Status row shows mirror and the download direction" '[[ "$(grep -E "^  m1 " <<<"$OUT")" == *download*mirror* ]]'

legacy_mk; legacy o1 old-exit
OUT=$(status)
check 9g "an old script with the '(exit \$?)' finish line and double quotes: converted (the bug dies with the script)" '_sync_rec_load o1 && [ "$J_mode" = append ] && [ "$J_src" = "$T/s" ] && [ -e "$BIND/sync-o1.sh.bak" ]'
rm -rf "$T/s"; bash "$BIND/sync-o1.sh" >/dev/null 2>&1; JRC=$?
check 9h "...and a failing run of it now logs rsync's real exit code" '[ "$JRC" != 0 ] && grep -qP "Sync finished: o1 \(exit \K[1-9]" "$(LOGF o1)"'

legacy_mk; legacy ip1 ip 192.0.2.9
OUT=$(status)
check 9i "frozen-IP script: converted, neither the record nor the launcher keeps the address" '_sync_rec_load ip1 && ! grep -q "192.0.2.9" "$BIND/sync-ip1.sh" "$LOGD/ip1.job" && grep -q "192.0.2.9" "$BIND/sync-ip1.sh.bak"'

legacy_mk; legacy c1 crlf
OUT=$(status)
check 9j "a script with CRLF line endings converts too" '_sync_rec_load c1 && [ "$J_mode" = append ]'

legacy_mk; legacy d.1 cur-append
OUT=$(status)
check 9k "a dotted-name job converts and stays listed, editable and deletable" '_sync_rec_load d.1 && grep -qE "^  d.1 " <<<"$OUT" && [[ "$(_sync_list_jobs)" == *"d.1"* ]]'
run "1\nsync-d.1\n" _sync_delete_job
check 9l "...delete removes its launcher and record" '[ ! -e "$BIND/sync-d.1.sh" ] && [ ! -e "$LOGD/d.1.job" ] && ! grep -q "sync-d.1.sh" "$CRON_FILE" 2>/dev/null'

# refusals: left untouched, shown in Status with the reason and the path
refuse() { # kind reason-fragment
  legacy_mk; legacy r1 "$1"; local before; before=$(sum "$BIND/sync-r1.sh"); cp "$BIND/sync-r1.sh" "$T/r1.orig"
  OUT=$(status)
  RROW=$(grep -A1 -E "^  r1 " <<<"$OUT" | tr '\n' ' ')
  [ ! -e "$LOGD/r1.job" ] && [ "$(sum "$BIND/sync-r1.sh")" = "$before" ] && cmp -s "$BIND/sync-r1.sh" "$T/r1.orig" && [ ! -e "$BIND/sync-r1.sh.bak" ] && [[ "$RROW" == *"cannot convert: "*"$2"*"$BIND/sync-r1.sh"* ]]
}
check 9m "'nice rsync': refused (another command named), script untouched, reason + path in Status" 'refuse nice "another command (nice)"'
check 9n "two rsync lines: refused" 'refuse two "more than one rsync line"'
check 9o "an rsync flag the generator never wrote: refused, flag named" 'refuse flag "unknown rsync flag --exclude=x"'
check 9p "a missing header key: refused, key named" 'refuse nokey "missing header: Source"'
check 9q "header and rsync line that disagree: refused" 'refuse disagree "disagree"'
check 9r "an unknown pre-command (scp): refused" 'refuse badpre "a line this tool did not write: scp"'
check 9s "mode mirror but no --delete in the rsync line: refused" 'refuse mirror-nodelete "does not delete"'
legacy_mk; legacy r1 nice; OUT=$(status); OUT2=$(status)
check 9t "a refused job is retried (not remembered) on the next Status, still untouched" '[[ "$OUT2" == *"cannot convert"* ]] && [ ! -e "$LOGD/r1.job" ]'
run "1\n6\n" _sync_edit_job
check 9u "an unconverted job cannot have its copy mode changed (clear message, nothing touched)" '[[ "$OUT" == *"has no job record"* ]]'
legacy_mk; legacy b1 cur-append; : > "$BIND/sync-b1.sh.bak"
OUT=$(status)
check 9v "an existing .bak is never overwritten: the next free name is used" '[ -e "$BIND/sync-b1.sh.bak2" ] && [ ! -s "$BIND/sync-b1.sh.bak" ] && _sync_rec_load b1'

# the tokenizer: reads %q output, refuses anything with shell meaning, never evaluates
tok() { _sync_tokenize "$1"; TRC=$?; TOKS=$(printf '[%s]' "${_tok[@]}"); }
tok "rsync \$DELFLAG -avh 'a b' \"c d\" e\\ f"
check 9w "tokenizer: \$DELFLAG, flags, single quotes, double quotes, backslash-space" '[ $TRC = 0 ] && [ "$TOKS" = "[rsync][\$DELFLAG][-avh][a b][c d][e f]" ]'
P=$'/x/we ird & \'q\' "d" $HOME `id` a|b;c'; tok "rsync $(_shq "$P") dst"
check 9x "tokenizer: a path printf %q wrote comes back whole (or is refused, never mangled)" '[ $TRC != 0 ] || [ "$TOKS" = "[rsync][$P][dst]" ]'
tok "rsync \$(touch $T/PWN3) a b"; R1=$TRC; tok 'rsync a; rm -rf b'; R2=$TRC; tok 'rsync "a $b" c'; R3=$TRC; tok "rsync 'unclosed"; R4=$TRC
check 9y "tokenizer: \$( ), ; and \$ inside double quotes and an unclosed quote are refused" '[ $R1 != 0 ] && [ $R2 != 0 ] && [ $R3 != 0 ] && [ $R4 != 0 ] && [ ! -e "$T/PWN3" ]'
fi

# ── 11  the destination must be on a mounted drive (found live: /mnt/data was not there) ─────
# FM_MODE=bare = the drive is not mounted (findmnt resolves everything to /); ok = it is.
BARE=$T/mnt/usb
dgrun() { # name direction dest: a record whose destination is $3, run the way cron does
  mk; rec "$1" "$2" append; J_dest=$3; _sync_rec_write
  mkdir -p "$T/stub"; cp "$T/rsync-stub" "$T/stub/rsync"; : > "$RSYNC_LOG"
  OUT=$(PATH="$T/stub:$PATH" _sync_job_run "$1" 2>&1); RC=$?
}
export FM_MODE=bare; _DRIVE_ROOTS=$T/mnt
dgrun dg1 upload "$BARE/backup"
check 11a "run, upload to an unmounted drive: SKIPPED with the mount point, nothing written, exit 0 like the other skips" '[ $RC = 0 ] && [[ "$OUT" == *": SKIPPED dg1 - destination drive not mounted ($BARE), nothing written"* && "$OUT" != *"Sync finished"* ]]'
check 11b "...no rsync, no mkdir on the server" '[ ! -s "$RSYNC_LOG" ] && [ ! -e "$BARE/backup" ]'
printf '%s\n' "$OUT" > "$(LOGF dg1)"
check 11c "Status shows it as skipped with the reason" 'R=$(_sync_result_text dg1); [[ "$R" == *"⚠ skipped (destination drive not mounted ($BARE))"* ]]'
dgrun dg2 download "$BARE/pulled"
check 11d "run, download to an unmounted laptop drive: SKIPPED, nothing created, no rsync" '[ $RC = 0 ] && [[ "$OUT" == *"SKIPPED dg2 - destination drive not mounted ($BARE), nothing written"* ]] && [ ! -s "$RSYNC_LOG" ] && [ ! -e "$BARE/pulled" ]'
dgrun dg3 upload "$T/d"
check 11e "run, destination outside the drive roots (a /home path): not guarded, rsync runs" '[ $RC = 0 ] && [[ "$OUT" == *"Sync finished: dg3 (exit 0)" ]] && [ -s "$RSYNC_LOG" ]'
export FM_MODE=ok
dgrun dg4 upload "$BARE/backup"
check 11f "run, same path with the drive mounted: runs, destination made" '[ $RC = 0 ] && [[ "$OUT" == *"Sync finished: dg4 (exit 0)" ]] && [ -s "$RSYNC_LOG" ] && [ -d "$BARE/backup" ]'
mk; export FM_MODE=bare
_dest_check local "$T/mnt/none/x"; R1=$?; V1=$_dest_v
check 11g "a path under a root with no mount below it (/mnt/<x> that is not there): refused, verdict unmounted" '[ $R1 = 1 ] && [ "$V1" = unmounted ]'
SSH_DOWN=1 _dest_check server "$BARE/x"; R2=$?
check 11h "no answer from the server: refused as unreachable, never ok" '[ $R2 = 1 ] && [ "$_dest_v" = unreachable ]'

# the one-time flows: refused right after the destination is picked, before any preview
refuse() { # input-for-menu pick-script: run step_sync / _sync_one_time_backup with the stubs set
  mk; export FM_MODE=bare; : > "$RSYNC_LOG"; _ps=
  _pick_local_path()  { local_path=$T/s; }
  _pick_server_path() { if [ -z "$_ps" ]; then _ps=1; server_path=$T/s; else server_path=$BARE/up; fi; }
  _pick_copy_mode()   { copy_mode=contents; }
  run "$1" "$2"
}
WHY="$BARE/up is on $BARE, which is not mounted - plug in the drive or pick another path."
refuse "1\ndelete\n" _sync_one_time_backup; _pick_server_path() { server_path=$BARE/up; }
run "1\ndelete\n" _sync_one_time_backup
check 11i "one-time upload (16 -> 5) to an unmounted /mnt/<x>: refused before the preview, nothing created" '[ $RC = 1 ] && [[ "$OUT" == *"$WHY"* && "$OUT" != *"Proceed"* && "$OUT" != *"Nothing to delete"* ]] && [ ! -e "$BARE/up" ] && [ ! -s "$RSYNC_LOG" ]'
check 11j "...and says first that it is checking the server's drives" '[[ "$OUT" == *"Checking the server'"'"'s drives..."* ]]'
refuse "4\n" _sync_one_time_backup
check 11k "one-time server -> server (4): destination refused the same way, before the sudo prompt" '[ $RC = 1 ] && [[ "$OUT" == *"$WHY"* && "$OUT" != *"sudo"* ]] && [ ! -e "$BARE/up" ]'
mk; export FM_MODE=bare; _pick_server_path() { server_path=$BARE/up; }; run "1\n" step_sync
check 11l "Sync menu (new job / run now) upload: refused before the schedule question" '[ $RC = 1 ] && [[ "$OUT" == *"$WHY"* && "$OUT" != *"Run now"* ]] && [ ! -e "$BARE/up" ]'
mk; export FM_MODE=bare; _pick_server_path() { server_path=$T/s; }; _pick_local_path() { local_path=$BARE/dl; }
run "2\n" step_sync
check 11m "Sync menu download to an unmounted laptop drive: refused locally" '[ $RC = 1 ] && [[ "$OUT" == *"$BARE/dl is on $BARE, which is not mounted"* ]] && [ ! -e "$BARE/dl" ]'
export FM_MODE=ok

# presets of the server path picker come from the server's real state
mk; mkdir -p "$BARE/media" "$T/home/privcloud"
printf 'FILES_LOCATION=%s\nMEDIA_LOCATION=%s\nMUSIC_LOCATION=%s\n' "$BARE" "$BARE/media" "$BARE/gone" > "$T/home/privcloud/.env"
mv "$T/bin/findmnt" "$T/bin/findmnt.real"
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
case "$*" in
  *"-rn -o SOURCE,TARGET"*) printf '/dev/nvme0n1p2 /\n/dev/sdb1 %s\nsystemd-1 %s/auto\n/dev/sdc1 /boot\n' "$FM_ROOT" "$(dirname "$FM_ROOT")" ;;
  *TARGET*) echo "$FM_ROOT" ;;
  *) echo /dev/sdb1 ;;
esac
X
chmod +x "$T/bin/findmnt"
PK='source "$T/fn.sh"; _DRIVE_ROOTS=$T/mnt; _pick_server_path false; echo "rc=$? SP=$server_path"'
run "q\n" bash -c "$PK"
check 11n "picker offers the mounted drive and the .env paths that exist, labelled" '[[ "$OUT" == *"1) $BARE  (USB drive /dev/sdb1, Files)"* && "$OUT" == *"2) $BARE/media  (Media)"* ]]'
check 11o "...never a path that is not there (MUSIC_LOCATION gone, /mnt/data, ~/data), nor an autofs stub or a non-drive mount" '[[ "$OUT" != *"$BARE/gone"* && "$OUT" != *"/mnt/data"* && "$OUT" != *"/data  "* && "$OUT" != *"/auto"* && "$OUT" != *"/boot"* ]] && [[ "$OUT" != *"3)"* ]]'
check 11p "...it says it is checking the server's drives before the list" '[[ "$OUT" == *"Checking the server'"'"'s drives..."*"Server paths:"* ]]'
run "2\n" bash -c "$PK"
check 11q "choosing preset 2 gives that path" '[[ "$OUT" == *"SP=$BARE/media" ]]'
run "$BARE/typed\n" bash -c "$PK"
check 11r "a typed path still works" '[[ "$OUT" == *"SP=$BARE/typed" ]]'
run "7\n7\n7\n" bash -c "$PK"
check 11s "a number with no preset is refused, never taken as a path" '[[ "$OUT" == *"No preset 7"* && "$OUT" != *"SP=7"* ]]'
PKE='source "$T/fn.sh"; _DRIVE_ROOTS=$T/mnt; rc=0; _pick_server_path false || rc=$?; echo "rc=$rc SP=$server_path"'
run "2\n" bash -ec "$PKE"
check 11u "errexit (bash -e): the presets picker lists the drive and .env paths and a choice still works" '[[ "$OUT" == *"1) $BARE  (USB drive /dev/sdb1, Files)"* && "$OUT" == *"rc=0 SP=$BARE/media" ]]'
SSH_DOWN=1 run "q\n" bash -ec "$PKE"
check 11v "errexit (bash -e): presets with the server unreachable: the hint, then the picker goes on" '[[ "$OUT" == *"Could not read the server'"'"'s drives - type a path."* && "$OUT" == *"rc=2 "* ]]'
mv "$T/bin/findmnt.real" "$T/bin/findmnt"
SSH_DOWN=1 run "q\n" bash -c "$PK"
check 11t "server unreachable: no presets, a hint to type a path" '[[ "$OUT" == *"Could not read the server'"'"'s drives - type a path."* && "$OUT" != *"1)"* ]]'

# 12 the destination guard and the server presets under `set -e` (how `setup.sh --run <step>` runs on the server)
CHECK_DIAG="rc=\$RC out='\$OUT'"
mk; export FM_MODE=bare
errexit_here _require_dest_drive local "$T/mnt/none/x"
check 12a "errexit: unmounted local destination: refused with the message, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"not mounted - plug in the drive"* ]]'
errexit_here _require_dest_drive server "$BARE/x"
check 12b "errexit: unmounted server destination: refused with the message, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Checking the server'"'"'s drives..."* && "$OUT" == *"not mounted - plug in the drive"* ]]'
SSH_DOWN=1 errexit_here _require_dest_drive server "$BARE/x"
check 12c "errexit: server unreachable: 'Could not check', rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Could not check the drive of"* ]]'
export FM_MODE=ok
errexit_here _require_dest_drive server "$BARE/x"; r1=$RC
errexit_here _require_dest_drive local "$BARE/x"
check 12d "errexit: mounted destination, server and local: rc 0" '[ $r1 = 0 ] && [ $RC = 0 ]'
check_total
