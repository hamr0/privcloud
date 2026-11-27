#!/bin/bash
# .env, compose and storage-change guards (cleanup step 6b, piece 5b).
# Section P pins today's behaviour; later sections cover the one .env reader/writer
# (E), the never-edited compose file (C), the data defaults (D) and the storage-path
# changes (S). Run: bash tests/env-storage.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first runs).
# Everything runs in a mktemp sandbox (cwd, HOME and SCRIPT_DIR are inside it) with
# stubbed sudo/sg/findmnt: nothing is written into the repo tree, no real docker.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo" "$T/home" "$T/mnt"
cd "$T" || exit 1
export HOME=$T/home
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=
{ for f in ok fail info warn _env_get _set_env _install_smart_playlists _storage_change_music _storage_change_files \
           _storage_change_immich; do extract_fn "$f" "$SRC"; done; } > "$T/fn.sh"
source "$T/fn.sh"
SCRIPT_DIR=$T/repo

# sudo runs the command (chown is skipped: the sandbox user owns everything); sg logs the docker command.
printf '#!/bin/bash\n[ "$1" = chown ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
printf '#!/bin/bash\necho "$*" >> "$SG_LOG"\n' > "$T/bin/sg"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" SG_LOG=$T/sg.log

# ── P  pins ─────────────────────────────────────────────────────────────────
# _env_get on one fixture
printf '%s\n' '#COMMENTED=old' 'COMMENTED=new' 'PLAIN=/mnt/data' 'SPACES=/mnt/data/My Music' 'DQ="/a b"' "SQ='/c d'" \
  'EQ=a=b=c' 'PWD_KEY=p|a&s\w' 'EMPTY=' > "$T/fix.env"
g() { _env_get "$1" "$T/fix.env"; }
check P1a "env_get: plain value" '[ "$(g PLAIN)" = /mnt/data ]'
check P1b "env_get: value with spaces is kept verbatim" '[ "$(g SPACES)" = "/mnt/data/My Music" ]'
check P1c "env_get: surrounding double / single quotes are stripped" '[ "$(g DQ)" = "/a b" ] && [ "$(g SQ)" = "/c d" ]'
check P1d "env_get: value containing = keeps everything after the first =" '[ "$(g EQ)" = "a=b=c" ]'
check P1e "env_get: | & \\ are returned literally" '[ "$(g PWD_KEY)" = '"'"'p|a&s\w'"'"' ]'
check P1f "env_get: a commented-out line is skipped for the real one" '[ "$(g COMMENTED)" = new ]'
check P1g "env_get: missing key and missing file print nothing" '[ -z "$(g NOPE)" ] && [ -z "$(_env_get PLAIN "$T/none.env")" ] && [ -z "$(g EMPTY)" ]'
check P1h "env_get: a key that is only a suffix of another does not match" '[ -z "$(g LOCATION)" ]'

# the storage-change menus: prompts, writes, redeploy
printf 'MUSIC_LOCATION=/old/music\nFILES_LOCATION=/old/files\nUPLOAD_LOCATION=/old/up\nDB_DATA_LOCATION=/old/db\nX=keep\n' > "$T/repo/.env"
run() { : > "$SG_LOG"; OUT=$(printf "$2" | "$1" 2>&1); RC=$?; }
CHECK_DIAG='rc=$RC out=${OUT:0:300}'
run _storage_change_music '\n'
check P2a "music: empty path -> refused, rc 1, .env untouched" '[ $RC = 1 ] && [[ "$OUT" == *"Path is required"* ]] && [ "$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")" = /old/music ]'
run _storage_change_music "$T/plain/music\nY"
check P2b "music: new folder is offered, created, written to .env, navidrome recreated" '[ $RC = 0 ] && [ -d "$T/plain/music" ] && [ "$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/music" ] && grep -q "force-recreate navidrome" "$SG_LOG" && [[ "$OUT" == *"Created $T/plain/music"* ]]'
check P2c "music: the other .env lines are untouched" '[ "$(_env_get X "$SCRIPT_DIR/.env")" = keep ] && [ "$(_env_get FILES_LOCATION "$SCRIPT_DIR/.env")" = /old/files ]'
run _storage_change_music "$T/plain/never\nn"
check P2d "music: declining the create prompt -> nothing created, .env unchanged" '[ ! -d "$T/plain/never" ] && [ "$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/music" ] && [ ! -s "$SG_LOG" ]'
mkdir -p "$T/plain/files"
run _storage_change_files "$T/plain/files\n"
check P2e "files: existing folder -> written to .env, filebrowser recreated, no create prompt" '[ $RC = 0 ] && [ "$(_env_get FILES_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/files" ] && grep -q "force-recreate filebrowser" "$SG_LOG" && [[ "$OUT" != *"Create it"* ]]'
run _storage_change_files '\n'
check P2f "files: empty path -> refused, rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Path is required"* ]]'
run _storage_change_immich "$T/plain/imm\nY"
check P2g "immich: base path -> upload + postgres folders created, both keys written, server+database recreated" '[ $RC = 0 ] && [ -d "$T/plain/imm/upload" ] && [ -d "$T/plain/imm/postgres" ] && [ "$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/imm/upload" ] && [ "$(_env_get DB_DATA_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/imm/postgres" ] && grep -q "force-recreate immich-server database" "$SG_LOG"'
run _storage_change_immich "$T/plain/imm2\nn"
check P2h "immich: answering n to Continue -> nothing created, .env unchanged" '[ ! -d "$T/plain/imm2" ] && [ "$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")" = "$T/plain/imm/upload" ]'
check P2i "_set_env keeps .env at mode 600" 'chmod 600 "$SCRIPT_DIR/.env"; _set_env X y "$SCRIPT_DIR/.env"; [ "$(stat -c %a "$SCRIPT_DIR/.env")" = 600 ]'

check_total
