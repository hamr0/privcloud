#!/bin/bash
# Tests for the one-time Immich backup (step_immich_backup_once) in setup.sh,
# moved as-is from `privcloud backup` -> 1: scope choice, destination check,
# append vs mirror (--delete), online pg_dumpall (a failed dump must not look ok),
# cold copy only with the stack down, .env copied 0600, cancel/back copy nothing.
# Run: bash tests/immich-backup-once.sh   (non-zero on any failure)
# Stubbed sudo/rsync/docker/du/df in a mktemp sandbox: no real copy, no docker.
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app" "$T/up" "$T/db" "$T/drive"
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nDB_PASSWORD=secret\n' "$T" "$T" > "$T/app/.env"
{
  printf '#!/bin/bash\nGREEN= RED= YELLOW= BOLD= DIM= NC=\nDRY_RUN=0\n_FV_SELF=%q\n' "$T/app/setup.sh"
  for f in ok fail info warn _env_get _immich_compose _immich_docker_group step_immich_backup_once; do extract_fn "$f" "$SRC"; done
  printf '_IMMICH_ENV=%q\n_IMMICH_COMPOSE=%q\n' "$T/app/.env" "$T/app/docker-compose.yml"
  printf '[ "$1" = --run ] && { "$2"; exit $?; }\n'
} > "$T/app/run.sh"
printf '#!/bin/bash\n[ "$1" = -v ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
cat > "$T/bin/rsync" <<'X'
#!/bin/bash
echo "rsync $*" >> "$RS_LOG"
dst=${@: -1}; mkdir -p "$dst"; echo data > "$dst/f"
X
printf '#!/bin/bash\necho "12M	${@: -1}"\n' > "$T/bin/du"
printf '#!/bin/bash\necho Filesystem; echo "x 1 2 100G"\n' > "$T/bin/df"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/chown"
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
export PATH="$T/bin:$PATH" RS_LOG=$T/rs.log PG_UP=$T/pg.up COMPOSE_UP=$T/compose.up
CHECK_DIAG="rc=\$RC out='\$OUT'"
go() { local input="$1"; : > "$RS_LOG"; rm -rf "$T/drive/privcloud-backup"; OUT=$(printf '%b' "$input" | bash "$T/app/run.sh" --run step_immich_backup_once 2>&1); RC=$?; }
B=$T/drive/privcloud-backup
mode() { stat -c %a "$1"; }

: > "$PG_UP"; rm -f "$COMPOSE_UP"; unset FAIL_DUMP
go "\n$T/drive\n\n\n"
check 1a "both, append, stack up: rc 0, photos rsynced to <dest>/privcloud-backup/photos/, no --delete" '[ $RC = 0 ] && grep -q "rsync -a  *--info=progress2 $T/up/ $B/photos/" "$RS_LOG" && ! grep -q -- --delete "$RS_LOG"'
check 1b "online dump written, gzip, mode 600" 'f=$(ls $B/immich-db-*.sql.gz 2>/dev/null | head -1); [ -n "$f" ] && [ "$(mode "$f")" = 600 ] && [ "$(zcat "$f")" = SQLDUMP ]'
check 1c ".env copied into the backup, mode 600" '[ "$(mode "$B/.env")" = 600 ] && cmp -s "$T/app/.env" "$B/.env"'
check 1d "the restore hint points at the federver menu (no ./privcloud)" '[[ "$OUT" == *"federver -> i -> Start"* ]] && [[ "$OUT" != *"./privcloud"* ]]'

go "\n$T/drive\n\n2\n"
check 2a "mirror mode: rsync gets --delete, and says so" '[ $RC = 0 ] && grep -q -- "rsync -a --delete" "$RS_LOG" && [[ "$OUT" == *"Mirror mode"* ]]'

go "2\n$T/drive\n\n\n"
check 3a "photos only: photos copied, no database dump" '[ $RC = 0 ] && [ -d "$B/photos" ] && ! ls $B/immich-db-* >/dev/null 2>&1'
go "3\n$T/drive\n\n"
check 3b "database only: dump written, no photos rsync" '[ $RC = 0 ] && ls $B/immich-db-*.sql.gz >/dev/null 2>&1 && ! grep -q "photos" "$RS_LOG"'

export FAIL_DUMP=1
go "3\n$T/drive\n\n"
check 4a "a failed pg_dumpall is a failure: rc 1, no dump file left behind" '[ $RC = 1 ] && [[ "$OUT" == *"dump failed"* ]] && ! ls $B/immich-db-* >/dev/null 2>&1'
unset FAIL_DUMP

rm -f "$PG_UP"
go "3\n$T/drive\n\n"
check 5a "stack down: the data dir is cold-copied to <dest>/privcloud-backup/postgres/" '[ $RC = 0 ] && grep -q "rsync -a .*$T/db/ $B/postgres/" "$RS_LOG" && [[ "$OUT" == *"Immich is stopped"* ]]'
: > "$COMPOSE_UP"
go "3\n$T/drive\n\n"
check 5b "postgres not up but a container still running: refuses the cold copy, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"cannot safely cold-copy"* ]] && ! grep -q "postgres/" "$RS_LOG"'
rm -f "$COMPOSE_UP"; : > "$PG_UP"

go "\n$T/nodir\n"
check 6a "destination that is not a directory: rc 1, nothing copied" '[ $RC = 1 ] && [[ "$OUT" == *"Not a valid directory"* ]] && [ ! -s "$RS_LOG" ]'
go "\n$T/drive\nn\n"
check 6b "answering n cancels: rc 0, nothing copied" '[ $RC = 0 ] && [[ "$OUT" == *"Cancelled"* ]] && [ ! -s "$RS_LOG" ]'
go "0\n"
check 6c "0 = Back: rc 2 (the caller treats it as a clean back), nothing copied" '[ $RC = 2 ] && [ ! -s "$RS_LOG" ]'
go "9\n"
check 6d "invalid scope: rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Invalid choice"* ]]'
rm -f "$T/app/.env"
go "\n"
check 7a "no .env (not installed): rc 1 with the install hint" '[ $RC = 1 ] && [[ "$OUT" == *"federver -> i -> Install"* ]]'

check_total
