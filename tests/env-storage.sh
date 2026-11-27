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
{ for f in ok fail info warn _env_get _env_quote _set_env _install_smart_playlists _storage_change _storage_change_music \
           _storage_change_files _storage_change_immich _require_data_mount _drive_verdict _existing_ancestor _dest_drive_verdict \
           _drive_mount_point; do extract_fn "$f" "$SRC"; done; grep -E '^_DRIVE_ROOTS=' "$SRC"; } > "$T/fn.sh"
source "$T/fn.sh"
_DRIVE_ROOTS="$T/mnt $T/media"   # the sandbox stands in for /mnt and /media (the production constant is only read, never changed)
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

# ── E  one .env rule: _env_get, the disk-check's envget and _set_env agree ──
extract_fn envget "$SRC" > "$T/envget.sh"
source "$T/envget.sh"
cat > "$T/agree.env" <<'X'
# a comment line
#COMMENTED=hidden
COMMENTED=real
PLAIN=/mnt/data
SPACES=/mnt/data/My Music
DQ="/a b"
SQ='/c d'
EQ=/p?a=b&c=d
INLINE=/mnt/data   # the usb drive
QINLINE="/x y" # note
PADDED = /mnt/padded
  INDENT=/in/dent
HASHVAL=/a#b
ONLYCOMMENT=
#ONLYHIDDEN=nope
LOCATION_X=/other
X
E_KEYS="COMMENTED PLAIN SPACES DQ SQ EQ INLINE QINLINE PADDED INDENT HASHVAL ONLYCOMMENT ONLYHIDDEN LOCATION LOCATION_X NOPE"
ENV_FILE=$T/agree.env
agree=1; diag=
for k in $E_KEYS; do
  a=$(_env_get "$k" "$T/agree.env"); b=$(envget "$k")
  [ "$a" = "$b" ] || { agree=0; diag+=" $k:[$a]!=[$b]"; }
done
CHECK_DIAG='$diag'
check E1 "_env_get and the disk-check's envget return the same for every key of one fixture" '[ $agree = 1 ]'
check E2 "agreed values: quotes, inline comment, padding, = in value, # inside a word" '[ "$(_env_get DQ "$T/agree.env")" = "/a b" ] && [ "$(_env_get SQ "$T/agree.env")" = "/c d" ] && [ "$(_env_get INLINE "$T/agree.env")" = /mnt/data ] && [ "$(_env_get QINLINE "$T/agree.env")" = "/x y" ] && [ "$(_env_get PADDED "$T/agree.env")" = /mnt/padded ] && [ "$(_env_get INDENT "$T/agree.env")" = /in/dent ] && [ "$(_env_get EQ "$T/agree.env")" = "/p?a=b&c=d" ] && [ "$(_env_get HASHVAL "$T/agree.env")" = "/a#b" ]'
check E3 "a commented-out key never matches (real line wins; only-commented key is empty)" '[ "$(_env_get COMMENTED "$T/agree.env")" = real ] && [ -z "$(_env_get ONLYHIDDEN "$T/agree.env")" ]'
check E4 "a key that is only the tail of another (LOCATION) matches nothing" '[ -z "$(_env_get LOCATION "$T/agree.env")" ]'

# _set_env round trip: whatever is written is read back unchanged by both readers
VALS=('/mnt/data' '/mnt/data/My Music' 'a|b&c\d' 'x=y=z' '/p #1 music' ' lead' 'trail ' '"dq' "it's" '#start' '/a#b' 'p w "q"' 'sp  ace')
rt=1; diag=
printf 'RT=old\nOTHER=keep\n' > "$T/rt.env"; ENV_FILE=$T/rt.env
for v in "${VALS[@]}"; do
  if _set_env RT "$v" "$T/rt.env"; then
    a=$(_env_get RT "$T/rt.env"); b=$(envget RT)
    [ "$a" = "$v" ] && [ "$b" = "$v" ] || { rt=0; diag+=" [$v]->[$a]/[$b]"; }
  else diag+=" setfail[$v]"; fi
done
check E5 "set_env round trip: | & \\ = spaces, ' #', quotes, leading/trailing space all read back identical by both readers" '[ $rt = 1 ] && [ "$(grep -c "^RT=" "$T/rt.env")" = 1 ] && [ "$(_env_get OTHER "$T/rt.env")" = keep ]'
printf 'RT = old\n' > "$T/rt2.env"; _set_env RT new "$T/rt2.env"
check E6 "set_env replaces the line _env_get reads (spaced 'KEY = x'), not a second copy" '[ "$(grep -c "RT" "$T/rt2.env")" = 1 ] && [ "$(_env_get RT "$T/rt2.env")" = new ]'
printf '#RT=hidden\n' > "$T/rt3.env"; _set_env RT new "$T/rt3.env"
check E7 "set_env leaves a commented-out line alone and appends the real one" '[ "$(head -1 "$T/rt3.env")" = "#RT=hidden" ] && [ "$(_env_get RT "$T/rt3.env")" = new ]'
NLV=$'a\nb'; BOTHV="x #'\""
check E8 "set_env refuses a newline and a value with both quote kinds, file untouched" '! _set_env RT "$NLV" "$T/rt3.env" >/dev/null 2>&1 && ! _set_env RT "$BOTHV" "$T/rt3.env" >/dev/null 2>&1 && [ "$(_env_get RT "$T/rt3.env")" = new ]'

# ── S  storage-path changes refuse an unmounted drive before any mkdir ─────
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
stub_findmnt ok '$FM_ROOT' /dev/sdb1 bare / /dev/nvme0n1p2    # ok = a real drive; bare = a folder on the system disk
export FM_ROOT=$T/mnt/usb
mkdir -p "$T/mnt/usb/keep" "$T/media/u/DRV/keep"; echo f > "$T/mnt/usb/keep/f"; echo f > "$T/media/u/DRV/keep/f"
resetenv() { printf 'MUSIC_LOCATION=/old/music\nFILES_LOCATION=/old/files\nUPLOAD_LOCATION=/old/up\nDB_DATA_LOCATION=/old/db\n' > "$T/repo/.env"; }; resetenv
srun() { : > "$SG_LOG"; OUT=$(FM_MODE=$1 bash -c "source $T/fn.sh; _DRIVE_ROOTS=\"$T/mnt $T/media\"; SCRIPT_DIR=$T/repo; $2" <<<"$3" 2>&1); RC=$?; }
CHECK_DIAG='rc=$RC out=${OUT:0:300}'
untouched() { [ "$(_env_get MUSIC_LOCATION "$T/repo/.env")" = /old/music ] && [ "$(_env_get FILES_LOCATION "$T/repo/.env")" = /old/files ] \
  && [ "$(_env_get UPLOAD_LOCATION "$T/repo/.env")" = /old/up ] && [ ! -s "$SG_LOG" ]; }
srun bare _storage_change_music "$T/mnt/usb/music"$'\nY'
check S1 "music: new folder on an unplugged drive -> refused before mkdir, .env and docker untouched" '[ $RC = 1 ] && [ ! -e "$T/mnt/usb/music" ] && [[ "$OUT" == *"not mounted"* ]] && untouched'
srun bare _storage_change_files "$T/mnt/usb/files"$'\nY'
check S2 "files: same refusal" '[ $RC = 1 ] && [ ! -e "$T/mnt/usb/files" ] && [[ "$OUT" == *"not mounted"* ]] && untouched'
srun bare _storage_change_immich "$T/mnt/usb/imm"$'\nY'
check S3 "immich: same refusal, before the Continue question and any mkdir" '[ $RC = 1 ] && [ ! -e "$T/mnt/usb/imm" ] && [[ "$OUT" == *"not mounted"* ]] && [[ "$OUT" != *"Continue"* ]] && untouched'
srun ok _storage_change_music "$T/mnt/usb/music"$'\nY'
check S4 "music: the same folder with the drive mounted -> created and written" '[ $RC = 0 ] && [ -d "$T/mnt/usb/music" ] && [ "$(_env_get MUSIC_LOCATION "$T/repo/.env")" = "$T/mnt/usb/music" ] && grep -q "force-recreate navidrome" "$SG_LOG"'
rm -rf "$T/mnt/usb/music"; resetenv
srun bare _storage_change_music "$T/media/u/DRV/keep/music"$'\nY'
check S5 "a /media/<user>/<drive> path is checked too (drive unplugged -> refused, nothing created)" '[ $RC = 1 ] && [ ! -e "$T/media/u/DRV/keep/music" ] && [[ "$OUT" == *"not mounted at $T/media/u/DRV"* ]] && untouched'
srun ok _storage_change_music "$T/media/u/DRV/keep/music"$'\nY'
check S6 "a /media/<user>/<drive> path with the drive mounted -> created and written" '[ $RC = 0 ] && [ -d "$T/media/u/DRV/keep/music" ]'
rm -rf "$T/media/u/DRV/keep/music"; resetenv
srun bare _storage_change_music "$T/plain/outside"$'\nY'
check S7 "a path outside the drive roots is the user's choice -> allowed whatever findmnt says" '[ $RC = 0 ] && [ -d "$T/plain/outside" ]'
srun ok _storage_change_music "$T/mnt/gone/deep/music"$'\nY'
check S8 "no drive folder at all under the root (nearest existing parent is the root itself) -> refused, nothing created" '[ $RC = 1 ] && [ ! -e "$T/mnt/gone" ]'
srun bare '_require_data_mount "'"$T/mnt/usb/keep/x"'"' ''
check S9 "refusal names the walked-up mount point of a /mnt path (the drive folder, not the file's folder)" '[[ "$OUT" == *"not mounted at $T/mnt/usb"* ]]'
check S10 "_drive_mount_point: a real mount is named as findmnt reports it" '[ "$(FM_MODE=ok _drive_mount_point "$T/mnt/usb/keep/new")" = "$T/mnt/usb" ]'

# ── D  data defaults: one table, equal to what step_deploy writes and .env.example holds ──
DKEYS="FILES_LOCATION MEDIA_LOCATION MUSIC_LOCATION UPLOAD_LOCATION DB_DATA_LOCATION"
{ for f in ok fail info warn _env_get _env_quote _set_env _data_defaults _drive_verdict _require_data_mount _install_smart_playlists step_deploy; do
    extract_fn "$f" "$SRC"; done; grep -E '^_DRIVE_ROOTS=' "$SRC"; } > "$T/fn2.sh"
mkdir -p "$T/dep"; cp "$T/fn2.sh" "$T/dep/fn.sh"; cp "$H/../.env.example" "$T/dep/.env.example"
for c in sg openssl hostname sleep docker; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
step_logrotation() { :; }
source "$T/dep/fn.sh"      # step_deploy takes SCRIPT_DIR from where it is sourced: $T/dep
OUT=$(printf '%s\n' "$T/plain/base" | step_deploy 2>&1); RC=$?
CHECK_DIAG='rc=$RC out=${OUT:0:300}'
dep_ok=1; diag=
for k in $DKEYS; do
  [ "$(_env_get "$k" "$T/dep/.env")" = "$(_data_defaults "$k" "$T/plain/base")" ] || { dep_ok=0; diag+=" $k:[$(_env_get "$k" "$T/dep/.env")]"; }
done
CHECK_DIAG='rc=$RC bad:$diag'
check D1 "step_deploy writes exactly _data_defaults KEY BASE for every data key" '[ $dep_ok = 1 ] && [ -d "$T/plain/base/immich/upload" ]'
check D2 ".env stays mode 600 after step_deploy" '[ "$(stat -c %a "$T/dep/.env")" = 600 ]'
KEYS_WRITTEN=$(extract_fn step_deploy "$SRC" | grep -oE '_set_env "[A-Z_]+"' | sed 's/_set_env "//; s/"//' | sort -u)
miss=
for k in $KEYS_WRITTEN; do grep -qE "^$k=" "$H/../.env.example" || miss+=" $k"; done
CHECK_DIAG='missing:$miss'
check D3 "every key step_deploy writes is in .env.example" '[ -n "$KEYS_WRITTEN" ] && [ -z "$miss" ]'
check D4 ".env.example has FILES_LOCATION and no stale DATA_ROOT" 'grep -q "^FILES_LOCATION=" "$H/../.env.example" && ! grep -q "DATA_ROOT" "$H/../.env.example"'
bad=
for k in $DKEYS; do [ "$(_env_get "$k" "$H/../.env.example")" = "$(_data_defaults "$k")" ] || bad+=" $k"; done
CHECK_DIAG='differs:$bad'
check D5 ".env.example value equals _data_defaults KEY for every data key" '[ -z "$bad" ]'
check D6 "no hand-written fallback paths left (/mnt/data/data, /home/\$USER/data/immich, /mnt/data/media literals)" '! grep -v "^ *#" "$SRC" | grep -qE "/mnt/data/data|/home/\\\$USER/data/immich|:-/mnt/data/media\}|def=/mnt/data"'

check_total
