#!/bin/bash
# Tests for the ONE Immich backup (setup.sh: step_immich_backup / the generated
# immich-backup.sh / _immich_backup_status / _remove / _configured_backup_dir).
# The real functions run in a mktemp sandbox: system paths are rewritten onto it
# (rw), sudo/systemctl/crontab/docker are stubs, rsync is the real one behind an
# argument logger, so the layout, excludes and append-only claims are checked on
# real trees. No root, no docker, no network.
# Run: bash tests/immich-backup.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
R=$T/root; BIN=$R/usr/local/bin/immich-backup.sh; CONF=$R/etc/immich-backup.conf
UNITS=$R/units; LOG=$R/log/immich-backup.log; CRON_FILE=$R/crontab
DEST=$T/drive/bk
mkdir -p "$T/bin" "$T/app" "$T/up" "$T/db" "$R/usr/local/bin" "$R/etc" "$UNITS" "$R/log" "$T/drive"
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"

# system paths -> sandbox, applied to every extracted function (old and new code alike)
rw() { sed -e "s|/usr/local/bin/immich-backup.sh|$BIN|g" -e "s|/var/log/immich-backup.log|$LOG|g" \
           -e "s|/etc/systemd/system/|$UNITS/|g" -e "s|/etc/immich-backup.conf|$CONF|g"; }
fns() { local f; for f in "$@"; do extract_fn "$f" "$SRC" | rw; done; }
FNS="ok fail info warn _env_get _drive_verdict _cron_cmd _cron_get _cron_drop _cron_set _immich_backup_script _immich_backup_conf _immich_backup_outdated _immich_cron_lines _configured_backup_dir _pick_backup_default step_immich_backup _immich_backup_run _immich_backup_status _immich_backup_remove _immich_docker_group _immich_compose step_immich_backup_once _mirror_guard _mirror_refuse _mirror_flush _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with _mirror_scan _mirror_wipe_sized _mirror_preview _mirror_delete_q _mirror_confirm _mirror_gate _shq"
mkrun() {  # rebuild run.sh from the CURRENT $SRC (functions that do not exist yet are skipped)
  {
    printf '#!/bin/bash\nGREEN= RED= YELLOW= BOLD= DIM= NC= BLUE=\nDRY_RUN=0\nMIRROR_WIPE_MIN=1000\n_FV_SELF=%q\n' "$T/app/setup.sh"
    printf '_DRIVE_ROOTS=%q\n_IMMICH_BACKUP_BIN=%q\n_IMMICH_BACKUP_CONF=%q\n_IMMICH_BACKUP_LOG=%q\n_IMMICH_UNIT_DIR=%q\n' "$T/mnt" "$BIN" "$CONF" "$LOG" "$UNITS"
    printf '_IMMICH_ENV=%q\n_IMMICH_COMPOSE=%q\n_cron_to_english() { echo "$1"; }\n' "$T/app/.env" "$T/app/docker-compose.yml"
    sed -n '/^_IMMICH_CRON_PAT=/p;/^_IMMICH_EXCLUDES=/p' "$SRC"
    fns $FNS
    printf '[ "$1" = --run ] && { "$2"; exit $?; }\n'
  } > "$T/app/run.sh"
}
mkrun

# ── stubs ──────────────────────────────────────────────────────────────────
cat > "$T/bin/sudo" <<'X'
#!/bin/bash
echo "sudo $*" >> "$T/sudo.log"
[ -n "$SUDO_FAIL" ] && { echo "sudo: a password is required" >&2; exit 1; }
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -v) exit 0 ;; *) break ;; esac; done
exec "$@"
X
cat > "$T/bin/install" <<'X'
#!/bin/bash
args=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
X
cat > "$T/bin/crontab" <<'X'
#!/bin/bash
[ -n "$CRON_FAIL" ] && { echo "crontab: cannot read" >&2; exit 1; }
case "$1" in
  -l) [ -e "$CRON_FILE" ] || { echo "no crontab for root" >&2; exit 1; }; cat "$CRON_FILE" ;;
  -r) rm -f "$CRON_FILE" ;;
  -)  cat > "$CRON_FILE" ;;
esac
X
cat > "$T/bin/systemctl" <<'X'
#!/bin/bash
case "$*" in
  *"show immich-backup.timer"*) [ -e "$UNITS/immich-backup.timer" ] && echo loaded || echo not-found ;;
  "cat immich-backup.timer") cat "$UNITS/immich-backup.timer" 2>/dev/null ;;
  "list-timers"*) echo "Sat 2026-11-28 03:00:00 UTC 5h left - - immich-backup.timer immich-backup.service" ;;
  "is-enabled"*) echo enabled ;;
  "start "*) echo "$*" >> "$T/systemctl.log" ;;
esac
exit 0
X
cat > "$T/bin/rsync" <<'X'
#!/bin/bash
echo "rsync $*" >> "$RS_LOG"
exec /usr/bin/rsync "$@"
X
cat > "$T/bin/docker" <<'X'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  ps) [ -e "$PG_UP" ] && echo immich_postgres ;;
  exec) [ -n "$FAIL_DUMP" ] && { echo "pg_dumpall: error" >&2; exit 1; }; echo "SQLDUMP" ;;
  compose) case "$*" in *" ps "*) [ -e "$COMPOSE_UP" ] && echo abc123 ;; esac ;;
esac
exit 0
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" T UNITS CRON_FILE RS_LOG=$T/rs.log PG_UP=$T/pg.up COMPOSE_UP=$T/compose.up
: > "$PG_UP"

CHECK_DIAG="rc=\$RC out='\$OUT'"
go() { local input="$1"; shift; OUT=$(printf '%b' "$input" | bash "$T/app/run.sh" --run "$@" 2>&1); RC=$?; }
mode() { stat -c %a "$1"; }
mkup() {  # a small library: originals, regenerable dirs, and a nested folder that merely SHARES a name
  rm -rf "$T/up"; mkdir -p "$T/up/library/u1" "$T/up/library/thumbs" "$T/up/thumbs/x" "$T/up/encoded-video/y" "$T/up/backups"
  echo orig > "$T/up/library/u1/a.jpg"; echo keep > "$T/up/library/thumbs/keep.jpg"
  echo t > "$T/up/thumbs/x/t.webp"; echo v > "$T/up/encoded-video/y/v.mp4"; echo d > "$T/up/backups/immich-db-backup.sql.gz"
}
fresh() { rm -rf "$DEST" "$CONF" "$BIN" "$CRON_FILE" "$UNITS"/* "$LOG"; : > "$RS_LOG"; mkup; }
setup_sched() {  # $1 = cadence input (default daily). Runs the real Set up.
  go "$DEST\ny\n${1:-1}\nn\n" step_immich_backup
}
runbk() {  # run the installed script like systemd does; its output goes to the log
  : > "$LOG"; : > "$RS_LOG"; bash "$BIN" "$@" >"$T/bk.out" 2>&1; RC=$?; LOGTXT=$(cat "$LOG"); OUT=$(cat "$T/bk.out")
}

# ── 1  the scheduled script as installed by Set up ─────────────────────────
fresh; setup_sched
check 1a "Set up installs an executable immich-backup.sh and the timer" '[ $RC = 0 ] && [ -x "$BIN" ] && [ -e "$UNITS/immich-backup.timer" ] && grep -q "OnCalendar=\*-\*-\* 03:00:00" "$UNITS/immich-backup.timer"'
runbk
check 1b "run: photos land in <dest>/immich/photos, the dump in <dest>/immich/db/immich-db-*.sql.gz" '[ $RC = 0 ] && [ -f "$DEST/immich/photos/library/u1/a.jpg" ] && [ "$(zcat "$DEST"/immich/db/immich-db-*.sql.gz)" = SQLDUMP ]'
check 1c "anchored excludes: /thumbs /encoded-video /backups skipped, a nested folder with the same name is kept" '[ ! -e "$DEST/immich/photos/thumbs" ] && [ ! -e "$DEST/immich/photos/encoded-video" ] && [ ! -e "$DEST/immich/photos/backups" ] && [ -f "$DEST/immich/photos/library/thumbs/keep.jpg" ]'
check 1d "log lines Status parses: DB dump ok, Photos synced, final \"Backup complete → <dest>\"" '[[ "$LOGTXT" == *"DB dump ok"* && "$LOGTXT" == *"Photos synced"* ]] && tail -n 1 "$LOG" | grep -q "Backup complete → $DEST\$"'
echo stray > "$DEST/immich/photos/stray"; rm "$T/up/library/u1/a.jpg"; runbk
check 1e "append-only: no --delete in the rsync call, a stray file and a deleted-at-source file survive" '! grep -q -- --delete "$RS_LOG" && [ -e "$DEST/immich/photos/stray" ] && [ -f "$DEST/immich/photos/library/u1/a.jpg" ]'
mkup
touch -d '10 days ago' "$DEST/immich/db/immich-db-old.sql.gz"; touch "$DEST/immich/db/immich-db-new.sql.gz"
runbk
check 1f "daily retention (7 days): a 10-day-old dump is pruned, a fresh one stays" '[ ! -e "$DEST/immich/db/immich-db-old.sql.gz" ] && [ -e "$DEST/immich/db/immich-db-new.sql.gz" ]'
fresh; setup_sched "2\n1"
mkdir -p "$DEST/immich/db"; touch -d '10 days ago' "$DEST/immich/db/immich-db-old.sql.gz"
runbk
check 1g "weekly retention (21 days): the same 10-day-old dump stays" '[ -e "$DEST/immich/db/immich-db-old.sql.gz" ] && grep -q "OnCalendar=Sun" "$UNITS/immich-backup.timer"'
fresh; setup_sched; rm -rf "$T/up"; runbk
check 1h "missing UPLOAD_LOCATION: rc 1, the log says photos skipped and Backup FAILED (exit 1)" '[ $RC = 1 ] && [[ "$LOGTXT" == *"UPLOAD_LOCATION missing"* ]] && tail -n 1 "$LOG" | grep -q "Backup FAILED (exit 1)"'
mkup

# ── 2  destination read-back and the default offered at Set up ─────────────
fresh
check 2a "no schedule installed: _configured_backup_dir is empty" '[ -z "$(bash "$T/app/run.sh" --run _configured_backup_dir)" ]'
setup_sched
check 2b "after Set up: _configured_backup_dir returns the destination" '[ "$(bash "$T/app/run.sh" --run _configured_backup_dir)" = "$DEST" ]'
go "\ny\n1\nn\n" step_immich_backup
check 2c "Set up again, Enter at the destination: keeps the configured one" '[ $RC = 0 ] && [ "$(bash "$T/app/run.sh" --run _configured_backup_dir)" = "$DEST" ]'

# ── 3  Status and Remove, timer and legacy cron ────────────────────────────
fresh; setup_sched
runbk
go "" _immich_backup_status
check 3a "Status (timer): one row with the schedule from the unit, next run in the Note" '[[ "$OUT" == *"immich-backup"*"*-*-* 03:00:00"*"systemd"*"next: Sat 2026-11-28"* ]]'
check 3b "Status: Last runs shows the run as ok" '[[ "$OUT" == *"Last runs"* && "$OUT" == *"✓ ok"* ]]'
printf 'Sat Nov 28 03:00:01 UTC 2026: Backup FAILED (exit 1) — systemd will retry\n' >> "$LOG"
go "" _immich_backup_status
check 3c "Status: a FAILED line shows as failed" '[[ "$OUT" == *"✗ failed"* ]]'
go "n\n" _immich_backup_remove
check 3d "Remove, answer n: kept, rc 2, timer and script still there" '[ $RC = 2 ] && [ -e "$UNITS/immich-backup.timer" ] && [ -e "$BIN" ]'
go "y\n" _immich_backup_remove
check 3e "Remove, y: timer, service, script gone; backup files stay" '[ $RC = 0 ] && [ ! -e "$UNITS/immich-backup.timer" ] && [ ! -e "$BIN" ] && [ -f "$DEST/immich/photos/library/thumbs/keep.jpg" ] && [[ "$OUT" == *"removed"* ]]'
go "" _immich_backup_remove
check 3f "Remove with nothing installed: says so, rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"No scheduled Immich backup to remove"* ]]'

fresh; printf '%s\n' '# nightly' '30 2 * * * docker exec immich_postgres pg_dumpall -U postgres | gzip > /x/immich-db-$(date +\%F).sql.gz' '0 5 * * * /usr/local/bin/other.sh' > "$CRON_FILE"
go "" _immich_backup_status
check 3g "Status, no timer + a legacy cron line (immich-db): shown as legacy cron, not 'none'" '[[ "$OUT" == *"(legacy cron)"* && "$OUT" != *"not configured"* ]]'
go "y\n" _immich_backup_remove
check 3h "Remove clears the legacy immich-db cron line and keeps the other lines" '[ $RC = 0 ] && ! grep -q immich-db "$CRON_FILE" && grep -q other.sh "$CRON_FILE" && grep -q "^# nightly" "$CRON_FILE"'
fresh; : > "$CRON_FILE"
go "" _immich_backup_status
check 3i "Status, nothing scheduled and an empty crontab: 'not configured'" '[[ "$OUT" == *"not configured"* ]]'
fresh; printf '%s\n' '15 4 * * * /usr/local/bin/immich-backup.sh' '0 5 * * * /usr/local/bin/other.sh' > "$CRON_FILE"
setup_sched
check 3j "Set up removes a legacy cron line that runs immich-backup.sh and installs the timer" '[ -e "$UNITS/immich-backup.timer" ] && ! grep -q immich-backup "$CRON_FILE" && grep -q other.sh "$CRON_FILE"'

# ── 4  one legacy-cron pattern, one reader (D20) ───────────────────────────
LEG='30 2 * * * docker exec immich_postgres pg_dumpall -U postgres | gzip > /x/immich-db-$(date +\%F).sql.gz'
fresh; printf '%s\n' "$LEG" '0 5 * * * /usr/local/bin/other.sh' > "$CRON_FILE"
setup_sched
check 4a "Set up removes a legacy cron line that only runs an immich-db dump (it used to be left: both ran)" '[ -e "$UNITS/immich-backup.timer" ] && ! grep -q immich-db "$CRON_FILE" && grep -q other.sh "$CRON_FILE"'
fresh; : > "$T/sudo.log"; go "" _immich_backup_status
check 4b "Status reads root's crontab without a sudo password prompt (sudo -n crontab)" 'grep -q "^sudo -n crontab -l" "$T/sudo.log"'
fresh; : > "$T/sudo.log"; go "$DEST\ny\n1\nn\n" step_immich_backup
check 4c "Set up reads it through the same reader (sudo crontab, may prompt)" 'grep -q "^sudo crontab -l" "$T/sudo.log" && ! grep -q "^sudo -n crontab" "$T/sudo.log"'
fresh; go "" _immich_backup_status
check 4d "Status, root has no crontab at all: 'not configured' (was misread as unreadable)" '[[ "$OUT" == *"not configured"* && "$OUT" != *"unreadable"* ]]'
fresh; CRON_FAIL=1 go "" _immich_backup_status
check 4e "Status, crontab read fails: shown as unknown, never 'none'" '[[ "$OUT" == *"unknown"* && "$OUT" == *"unreadable"* && "$OUT" != *"not configured"* ]]'
fresh; setup_sched; CRON_FAIL=1 go "y\n" _immich_backup_remove
check 4f "Remove, crontab read fails: nothing removed, says so, rc 1" '[ $RC = 1 ] && [ -e "$BIN" ] && [ -e "$UNITS/immich-backup.timer" ] && [[ "$OUT" == *"Could not read root"* ]]'
fresh; CRON_FAIL=1 go "" _immich_backup_remove
check 4g "Remove with nothing else installed and an unreadable crontab: not 'nothing to remove'" '[ $RC = 1 ] && [[ "$OUT" != *"No scheduled Immich backup"* ]]'
fresh; CRON_FAIL=1 setup_sched
check 4h "Set up, crontab read fails: refuses before touching anything" '[ $RC = 1 ] && [ ! -e "$BIN" ] && [ ! -e "$UNITS/immich-backup.timer" ] && [[ "$OUT" == *"Could not read root"* ]]'
fresh; printf '%s\n' "$LEG" > "$CRON_FILE"; go "y\n" _immich_backup_remove
check 4i "Remove: legacy-cron-only schedule is detected, removed and verified" '[ $RC = 0 ] && [ ! -s "$CRON_FILE" ]'

check_total
