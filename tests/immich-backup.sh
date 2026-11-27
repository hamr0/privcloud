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
FNS="ok fail info warn _env_get _drive_verdict _backup_dest_verdict _cron_cmd _cron_get _cron_drop _cron_set _immich_backup_script _immich_backup_conf _immich_backup_outdated _immich_cron_lines _configured_backup_dir _pick_backup_default step_immich_backup _immich_backup_run _immich_backup_status _immich_backup_remove _immich_docker_group _immich_compose step_immich_backup_once _mirror_guard _mirror_refuse _mirror_flush _mirror_ask _mirror_banner _mirror_dry_cmd _rsync_with _mirror_scan _mirror_wipe_sized _mirror_preview _mirror_delete_q _mirror_confirm _mirror_gate _shq"
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

# ── 5  one generated script, values read at run time (D3, D7) ──────────────
for odd in 'a|b' 'a&b' 'a\b' 'a b' 'a|&\ b$c'; do
  fresh; D="$T/drive/$odd"; mkdir -p "$D"
  go "${D//\\/\\\\}\ny\n1\nn\n" step_immich_backup; runbk   # go() runs printf %b: double the backslash
  check "5a" "destination '$odd' round-trips: configured dir, conf, and the run lands there" '[ "$(bash "$T/app/run.sh" --run _configured_backup_dir)" = "$D" ] && [ -f "$D/immich/photos/library/u1/a.jpg" ] && ls "$D"/immich/db/immich-db-*.sql.gz >/dev/null 2>&1 && ! grep -q "__BACKUP_DIR__" "$BIN"'
done
fresh; setup_sched
check 5b "conf: 644 (paths only, Status reads it without sudo), script 755" '[ "$(mode "$CONF")" = 644 ] && [ "$(mode "$BIN")" = 755 ] && grep -q "^REPO_DIR=$T/app\$" "$CONF" && grep -q "^BACKUP_DIR=$DEST\$" "$CONF" && grep -q "^RETENTION_DAYS=7\$" "$CONF"'
mkdir -p "$T/up2/library"; echo moved > "$T/up2/library/m.jpg"
printf 'UPLOAD_LOCATION=%s/up2\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"
BEFORE=$(cksum < "$BIN"); runbk
check 5c ".env UPLOAD_LOCATION changed: the next run uses it, script not regenerated" '[ $RC = 0 ] && [ -f "$DEST/immich/photos/library/m.jpg" ] && [ "$(cksum < "$BIN")" = "$BEFORE" ]'
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"
echo "# tampered" >> "$BIN"; go "\ny\n1\nn\n" step_immich_backup
check 5d "every Set up regenerates the script (a hand-edit does not survive)" '! grep -q tampered "$BIN" && bash -c "source $T/app/run.sh; _immich_backup_script $CONF $LOG" | cmp -s - "$BIN"'
check 5e "the installed script has no sed placeholders and parses" '! grep -q "__[A-Z_]*__" "$BIN" && bash -n "$BIN"'
rm -f "$BIN" "$CONF"
printf '%s\ny\n1\nn\n' "$DEST" | bash -c "source $T/app/run.sh; _immich_backup_script() { echo 'if then'; }; step_immich_backup" >"$T/o.txt" 2>&1; RC=$?; OUT=$(cat "$T/o.txt")
check 5f "a generated script that does not parse is never installed" '[ $RC = 1 ] && [ ! -e "$BIN" ] && [ ! -e "$CONF" ] && [[ "$OUT" == *"syntax error"* ]]'
fresh; setup_sched; FAIL_DUMP=1 runbk
check 5g "DB dump fails (pg_dumpall exit 1 behind gzip): rc non-zero, logged FAILED, no dump file left" '[ $RC != 0 ] && [[ "$LOGTXT" == *"DB dump FAILED"* ]] && tail -n 1 "$LOG" | grep -q "Backup FAILED" && ! ls "$DEST"/immich/db/immich-db-* >/dev/null 2>&1 && [ -f "$DEST/immich/photos/library/u1/a.jpg" ]'
runbk
check 5h "dumps are owner-only (600)" '[ "$(mode "$(ls "$DEST"/immich/db/immich-db-*.sql.gz | head -1)")" = 600 ]'
rm -f "$CONF"; runbk
check 5i "config missing at run time: rc 1, logged, nothing copied" '[ $RC = 1 ] && [[ "$LOGTXT" == *"config "*" missing - run Set up again"* ]] && tail -n 1 "$LOG" | grep -q "Backup FAILED (exit 1)"'
setup_sched
runbk --mirror; r1=$RC; runbk --scope photos; r2=$RC; runbk --once; r3=$RC
check 5j "scheduled runs never take mirror/once/scope flags: usage error 64" '[ $r1 = 64 ] && [ $r2 = 64 ] && [ $r3 = 64 ]'

# ── 6  outdated installs (script from before the conf file) ────────────────
fresh; mkdir -p "$(dirname "$BIN")"
printf '#!/bin/bash\nBACKUP_DIR="%s"\nUPLOAD_LOCATION="%s/up"\nRETENTION_DAYS=7\n' "$DEST" "$T" > "$BIN"; chmod +x "$BIN"
printf '[Timer]\nOnCalendar=*-*-* 03:00:00\n' > "$UNITS/immich-backup.timer"
go "" _immich_backup_status
check 6a "Status: an installed script with no conf is flagged 'outdated - run Set up again'" '[[ "$OUT" == *"outdated - run Set up again"* ]]'
check 6b "its destination is still found (baked in the old script), so Set up keeps offering it" '[ "$(bash "$T/app/run.sh" --run _configured_backup_dir)" = "$DEST" ]'
check 6c "Status does not rewrite root files: script and conf untouched" '[ ! -e "$CONF" ] && ! grep -q "Format: 2" "$BIN"'
go "\ny\n1\nn\n" step_immich_backup
check 6d "Set up again (Enter keeps the destination) upgrades it" '[ -r "$CONF" ] && grep -q "^# Format: 2" "$BIN" && [ "$(bash "$T/app/run.sh" --run _configured_backup_dir)" = "$DEST" ]'
go "" _immich_backup_status
check 6e "after the upgrade Status is clean" '[[ "$OUT" != *outdated* ]]'
rm -f "$CONF"; go "" _immich_backup_status
check 6f "a new-format script whose conf is gone is outdated too" '[[ "$OUT" == *"outdated - run Set up again"* ]]'

# ── 7  the one-time backup runs the same script (D14) ──────────────────────
# step_immich_backup_once asks, then calls immich-backup.sh --once. Input order:
# scope, destination, Start?, copy mode (Enter = append, "delete" = mirror) [, deletion question].
export XDG_STATE_HOME=$T/state
ONE=$T/drive/one
rs_args() { grep -c -- "$1" "$RS_LOG"; }
one_fresh() { fresh; rm -rf "$ONE" "$T/sudo.log"; mkdir -p "$ONE" "$T/db"; echo 16 > "$T/db/PG_VERSION"; : > "$PG_UP"; rm -f "$COMPOSE_UP"; mkup; }
tree() { (cd "$1" && find . -mindepth 1 | sort); }

one_fresh; go "\n$ONE\n\n\n" step_immich_backup_once
check 7a "both, append, schedule not set up: rc 0; photos in <dest>/immich/photos, no --delete" '[ $RC = 0 ] && [ -f "$ONE/immich/photos/library/u1/a.jpg" ] && ! grep -q -- --delete "$RS_LOG" && [ ! -e "$ONE/privcloud-backup" ]'
check 7b "online dump <dest>/immich/db/immich-db-*.sql.gz, gzip, mode 600" 'f=$(ls "$ONE"/immich/db/immich-db-*.sql.gz 2>/dev/null | head -1); [ -n "$f" ] && [ "$(mode "$f")" = 600 ] && [ "$(zcat "$f")" = SQLDUMP ]'
check 7c ".env copied beside the backup, mode 600" '[ "$(mode "$ONE/immich/.env")" = 600 ] && cmp -s "$T/app/.env" "$ONE/immich/.env"'
check 7d "restore hint points at the federver menu (no ./privcloud)" '[[ "$OUT" == *"federver -> i -> Start"* && "$OUT" != *"./privcloud"* ]]'
check 7e "no installed script: the generated one ran from a temp file (sudo bash <tmp> --once ...) and left nothing behind" 'grep -q "^sudo bash /.* --once --dest $ONE --scope both\$" "$T/sudo.log" && [ ! -e "$BIN" ] && t=$(sed -n "s/^sudo bash \(\/[^ ]*\) --once.*/\1/p" "$T/sudo.log" | head -1) && [ -n "$t" ] && [ ! -e "$t" ]'
check 7f "excludes apply to the one-time copy too (no thumbs/encoded-video/backups; same-named subfolder kept)" '[ ! -e "$ONE/immich/photos/thumbs" ] && [ ! -e "$ONE/immich/photos/encoded-video" ] && [ ! -e "$ONE/immich/photos/backups" ] && [ -f "$ONE/immich/photos/library/thumbs/keep.jpg" ]'

one_fresh; setup_sched; go "\n$ONE\n\n\n" step_immich_backup_once
check 7g "schedule installed and current: the installed script is called with the flags" '[ $RC = 0 ] && grep -q "^sudo $BIN --once --dest $ONE --scope both\$" "$T/sudo.log"'
one_fresh; mkdir -p "$(dirname "$BIN")"; printf '#!/bin/bash\nBACKUP_DIR="x"\n' > "$BIN"; chmod +x "$BIN"
go "\n$ONE\n\n\n" step_immich_backup_once
check 7h "outdated installed script (no --once): the generator runs from a temp file instead" '[ $RC = 0 ] && grep -q "^sudo bash /.* --once" "$T/sudo.log" && [ -f "$ONE/immich/photos/library/u1/a.jpg" ]'
one_fresh; setup_sched; mkdir -p "$ONE/privcloud-backup/photos"; echo old > "$ONE/privcloud-backup/photos/o"
go "\n$ONE\n\n\n" step_immich_backup_once
check 7i "an old <dest>/privcloud-backup/ layout: one info line, left alone, nothing written into it" '[[ "$OUT" == *"old one-time layout"* && "$OUT" == *"delete the old folder by hand"* ]] && [ "$(ls "$ONE/privcloud-backup/photos")" = o ] && [ -f "$ONE/immich/photos/library/u1/a.jpg" ]'
one_fresh; setup_sched; go "\n\n\n\n" step_immich_backup_once
check 7j "schedule installed: Enter at the destination uses its destination (one copy of the library, not two)" '[ $RC = 0 ] && [ -f "$DEST/immich/photos/library/u1/a.jpg" ] && [ ! -e "$ONE/immich" ]'

# one tree, both modes
one_fresh; setup_sched; runbk; go "\n$ONE\n\n\n" step_immich_backup_once
check 7k "scheduled and one-time produce the same tree (photos + one dump) and the same dump content" '[ "$(tree "$DEST/immich/photos")" = "$(tree "$ONE/immich/photos")" ] && [ -n "$(tree "$ONE/immich/photos")" ] && [ "$(ls "$DEST"/immich/db | wc -l)" = 1 ] && [ "$(ls "$ONE"/immich/db | wc -l)" = 1 ] && [ "$(zcat "$DEST"/immich/db/*.gz)" = "$(zcat "$ONE"/immich/db/*.gz)" ]'

one_fresh; go "2\n$ONE\n\n\n" step_immich_backup_once
check 7l "photos only: photos copied, no database dump" '[ $RC = 0 ] && [ -d "$ONE/immich/photos" ] && ! ls "$ONE"/immich/db/immich-db-* >/dev/null 2>&1'
one_fresh; go "3\n$ONE\n\n" step_immich_backup_once
check 7m "database only: dump written, no photos rsync" '[ $RC = 0 ] && ls "$ONE"/immich/db/immich-db-*.sql.gz >/dev/null 2>&1 && [ ! -s "$RS_LOG" ] && [ ! -e "$ONE/immich/photos" ]'
one_fresh; FAIL_DUMP=1 go "3\n$ONE\n\n" step_immich_backup_once
check 7n "a failed pg_dumpall is a failure: rc 1, no dump file left behind" '[ $RC = 1 ] && [[ "$OUT" == *"DB dump FAILED"* && "$OUT" == *"Backup failed"* ]] && ! ls "$ONE"/immich/db/immich-db-* >/dev/null 2>&1'
one_fresh; rm -f "$PG_UP"; go "3\n$ONE\n\n" step_immich_backup_once
check 7o "stack down: the data dir is cold-copied to <dest>/immich/db/postgres/" '[ $RC = 0 ] && [ -f "$ONE/immich/db/postgres/PG_VERSION" ] && [[ "$OUT" == *"Immich is stopped"* ]]'
one_fresh; rm -f "$PG_UP"; : > "$COMPOSE_UP"; go "3\n$ONE\n\n" step_immich_backup_once
check 7p "postgres not up but a container still running: refuses the cold copy, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"cannot safely cold-copy"* ]] && [ ! -e "$ONE/immich/db/postgres" ]'
rm -f "$COMPOSE_UP"; : > "$PG_UP"
one_fresh; go "\n$T/nodir\n" step_immich_backup_once
check 7q "destination that is not a directory: rc 1, nothing copied" '[ $RC = 1 ] && [[ "$OUT" == *"Not a valid directory"* ]] && [ ! -s "$RS_LOG" ]'
go "\n$ONE\nn\n" step_immich_backup_once
check 7r "answering n cancels: rc 0, nothing copied" '[ $RC = 0 ] && [[ "$OUT" == *"Cancelled"* ]] && [ ! -s "$RS_LOG" ] && [ ! -e "$ONE/immich" ]'
go "0\n" step_immich_backup_once
check 7s "0 = Back: rc 2, nothing copied" '[ $RC = 2 ] && [ ! -s "$RS_LOG" ]'
go "9\n" step_immich_backup_once
check 7t "invalid scope: rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Invalid choice"* ]]'
mv "$T/app/.env" "$T/app/.env.bak"; go "\n" step_immich_backup_once
check 7u "no .env (not installed): rc 1 with the install hint" '[ $RC = 1 ] && [[ "$OUT" == *"federver -> i -> Install"* ]]'
mv "$T/app/.env.bak" "$T/app/.env"

# one-time mirror: same guard, preview and typed confirmation as sync
one_fresh; mkdir -p "$ONE/immich/photos"; echo stray > "$ONE/immich/photos/stray"
go "\n$ONE\n\ndelete\ny\n" step_immich_backup_once
check 7v "mirror: guard, preview of the deletion, y: rsync --delete runs, the stray file at the destination is gone" '[ $RC = 0 ] && [[ "$OUT" == *"1 file would be deleted at $ONE/immich/photos"* && "$OUT" == *"Mode: mirror"* && "$OUT" == *"Delete these 1 file and copy? [y/N]"* ]] && grep -q -- "--delete" "$RS_LOG" && [ ! -e "$ONE/immich/photos/stray" ] && [ -f "$ONE/immich/photos/library/u1/a.jpg" ]'
one_fresh; mkdir -p "$ONE/immich/photos"; echo stray > "$ONE/immich/photos/stray"
go "\n$ONE\n\ndelete\n\n" step_immich_backup_once
check 7w "mirror, Enter at the deletion question: cancelled, rc 2, nothing deleted or copied" '[ $RC = 2 ] && [ -e "$ONE/immich/photos/stray" ] && [ ! -e "$ONE/immich/photos/library" ] && [[ "$OUT" == *"Cancelled - nothing changed"* ]]'
one_fresh; mkdir -p "$ONE/immich/photos"; echo stray > "$ONE/immich/photos/stray"
go "\n$ONE\n\nno thanks\n" step_immich_backup_once
check 7x "anything but the word delete = append: nothing deleted" '[ $RC = 0 ] && [ -e "$ONE/immich/photos/stray" ] && ! grep -q -- --delete "$RS_LOG" && [[ "$OUT" == *"Append only"* ]]'
one_fresh; rm -rf "$T/up"; mkdir -p "$T/up"; mkdir -p "$ONE/immich/photos"; echo precious > "$ONE/immich/photos/stray"
go "\n$ONE\n\ndelete\ny\n" step_immich_backup_once
check 7y "mirror with an EMPTY source: refused up front, rc 2, destination untouched" '[ $RC = 2 ] && [[ "$OUT" == *"Refused"* ]] && [ "$(cat "$ONE/immich/photos/stray")" = precious ]'
one_fresh; rm -rf "$T/up"; mkdir -p "$ONE/immich/photos"; echo precious > "$ONE/immich/photos/stray"
go "\n$ONE\n\ndelete\ny\n" step_immich_backup_once
check 7z "mirror with a MISSING source: refused, destination untouched" '[ $RC = 2 ] && [[ "$OUT" == *"Refused"* ]] && [ "$(cat "$ONE/immich/photos/stray")" = precious ]'
# a source on a drive that is not mounted (bare folder on the system disk)
stub_findmnt ok "$T/mnt/usb" /dev/sdb1 bare / /dev/sda2
one_fresh; mkdir -p "$T/mnt/usb/photos/library"; echo m > "$T/mnt/usb/photos/library/m.jpg"
printf 'UPLOAD_LOCATION=%s/mnt/usb/photos\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"
mkdir -p "$ONE/immich/photos"; echo precious > "$ONE/immich/photos/stray"
FM_MODE=bare go "\n$ONE\n\ndelete\ny\n" step_immich_backup_once
check 7aa "mirror with the source drive NOT mounted: refused (interactive), destination untouched" '[ $RC = 2 ] && [[ "$OUT" == *"Refused"* ]] && [ "$(cat "$ONE/immich/photos/stray")" = precious ]'
FM_MODE=ok go "\n$ONE\n\ndelete\ny\n" step_immich_backup_once
check 7ab "same source on a mounted drive: the mirror goes ahead" '[ $RC = 0 ] && [ ! -e "$ONE/immich/photos/stray" ] && [ -f "$ONE/immich/photos/library/m.jpg" ]'
# the script refuses on its own (defence in depth) when called directly
setup_sched; echo precious > "$ONE/immich/photos/stray"
FM_MODE=bare bash "$BIN" --once --dest "$ONE" --mirror >"$T/o.txt" 2>&1; RC=$?; OUT=$(cat "$T/o.txt")
check 7ac "script-level: --mirror with an unmounted source drive -> rc 3, nothing copied or deleted" '[ $RC = 3 ] && [[ "$OUT" == *"Mirror refused: source $T/mnt/usb/photos is unmounted"* ]] && [ "$(cat "$ONE/immich/photos/stray")" = precious ]'
FM_MODE=ok bash "$BIN" --once --dest "$ONE" --mirror >"$T/o.txt" 2>&1; RC=$?
check 7ad "script-level: the same call on a mounted drive mirrors (stray removed)" '[ $RC = 0 ] && [ ! -e "$ONE/immich/photos/stray" ]'
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"
one_fresh; setup_sched; mkdir -p "$ONE/immich/photos"; echo precious > "$ONE/immich/photos/stray"; rm -rf "$T/up"; mkdir "$T/up"
bash "$BIN" --once --dest "$ONE" --mirror >"$T/o.txt" 2>&1; RC=$?; OUT=$(cat "$T/o.txt")
check 7ae "script-level: --mirror with an empty source -> rc 3, destination untouched" '[ $RC = 3 ] && [[ "$OUT" == *"Mirror refused"* && "$OUT" == *"is empty"* ]] && [ "$(cat "$ONE/immich/photos/stray")" = precious ]'
mkup
bash "$BIN" --once --scope photos >/dev/null 2>&1; r1=$?
bash "$BIN" --once --dest "$ONE" --scope nonsense >/dev/null 2>&1; r2=$?
bash "$BIN" --once --dest "$T/nodir" >/dev/null 2>&1; r3=$?
bash "$BIN" --dest "$ONE" >/dev/null 2>&1; r4=$?
check 7af "script-level: --once without --dest, a bad scope, a missing destination, --dest without --once all fail (64/64/1/64)" '[ $r1 = 64 ] && [ $r2 = 64 ] && [ $r3 = 1 ] && [ $r4 = 64 ]'
one_fresh; setup_sched; runbk; echo stray > "$DEST/immich/photos/stray"; runbk
check 7ag "scheduled path: the rsync call of a scheduled run never contains --delete, the stray at the destination stays" '! grep -q -- --delete "$RS_LOG" && [ -e "$DEST/immich/photos/stray" ]'

# ── 8  the destination must be on a mounted drive (6c) ─────────────────────
# _DRIVE_ROOTS is $T/mnt in this sandbox. findmnt stub: ok = a /dev mount at $T/mnt/usb,
# bare = only /, stub = an autofs mount (source is not a /dev device).
stub_findmnt ok "$T/mnt/usb" /dev/sdb1 bare / /dev/sda2 stub "$T/mnt/usb" systemd-1
rm -rf "$T/mnt"; mkdir -p "$T/mnt/usb/old" "$T/mnt/bare/sub"; echo x > "$T/mnt/usb/old/f"
sched_to() {  # a scheduled script (the real generator) whose configured destination is $1
  fresh; printf 'REPO_DIR=%s\nBACKUP_DIR=%s\nRETENTION_DAYS=7\n' "$T/app" "$1" > "$CONF"
  bash -c "source $T/app/run.sh; _immich_backup_script $CONF $LOG" > "$BIN"; chmod +x "$BIN"
}
sched_to "$T/mnt/usb/old"; FM_MODE=ok runbk
check 8a "destination on a /dev mount: runs, files written" '[ $RC = 0 ] && [ -f "$T/mnt/usb/old/immich/photos/library/u1/a.jpg" ]'
sched_to "$T/mnt/bare/sub"; FM_MODE=bare runbk
check 8b "destination under /mnt on a bare system-disk folder: refused, non-zero, nothing created, log line" '[ $RC != 0 ] && [[ "$LOGTXT" == *"Backup SKIPPED - destination $T/mnt/bare/sub is not on a mounted drive (unmounted), nothing written"* ]] && [ ! -e "$T/mnt/bare/sub/immich" ] && [ ! -s "$RS_LOG" ] && tail -n 1 "$LOG" | grep -q "Backup FAILED"'
sched_to "$T/mnt/usb/new/deeper"; FM_MODE=ok runbk
check 8c "destination not yet existing under a mounted drive: runs (nearest existing ancestor is checked)" '[ $RC = 0 ] && [ -f "$T/mnt/usb/new/deeper/immich/photos/library/u1/a.jpg" ]'
sched_to "$T/mnt/gone/bk"; FM_MODE=bare runbk
check 8d "destination not yet existing under an unmounted root: refused, the missing folders are not created" '[ $RC != 0 ] && [[ "$LOGTXT" == *"Backup SKIPPED"* ]] && [ ! -e "$T/mnt/gone" ]'
sched_to "$T/mnt/usb/old"; rm -rf "$T/mnt/usb/old/immich"; FM_MODE=stub runbk
check 8e "autofs stub mount: refused, non-zero, nothing written" '[ $RC != 0 ] && [[ "$LOGTXT" == *"Backup SKIPPED"* ]] && [ ! -e "$T/mnt/usb/old/immich" ]'
sched_to "$DEST"; FM_MODE=bare runbk
check 8f "destination outside the drive roots: runs as before" '[ $RC = 0 ] && [ -f "$DEST/immich/photos/library/u1/a.jpg" ]'
fresh; FM_MODE=bare go "\n$T/mnt/bare/sub\n\n\n" step_immich_backup_once
check 8g "one-time: the same refusal before Start is asked; nothing copied, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Backup SKIPPED - destination $T/mnt/bare/sub is not on a mounted drive (unmounted)"* ]] && [[ "$OUT" != *"Start backup"* ]] && [ ! -s "$RS_LOG" ] && [ ! -e "$T/mnt/bare/sub/immich" ]'
sched_to "$T/mnt/bare/sub"; FM_MODE=bare runbk; go "" _immich_backup_status
check 8h "Status shows the refusal reason from the log, run listed as failed" '[[ "$OUT" == *"Last run: Backup SKIPPED - destination $T/mnt/bare/sub is not on a mounted drive (unmounted)"* && "$OUT" == *"✗ failed"* ]]'
sched_to "$T/mnt/usb/old"; FM_MODE=ok runbk; go "" _immich_backup_status
check 8i "Status after a good run: no refusal line" '[[ "$OUT" != *"Last run: Backup SKIPPED"* ]]'

check_total
