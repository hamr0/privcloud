#!/bin/bash
# Tests for the Immich config step (step_immich_config) and the one .env writer
# (_set_env) in setup.sh.
# On an existing .env only UPLOAD_LOCATION and DB_DATA_LOCATION change (plus the
# DB password when it is empty/the placeholder); every other line stays
# byte-identical. A missing .env is created the first-time way, mode 600.
# Run: bash tests/immich-config.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
GREEN= RED= YELLOW= BOLD= DIM= NC=
for f in ok fail info warn _env_get _env_quote _set_env step_immich_config; do extract_fn "$f" "$SRC"; done > "$T/fn.sh"
source "$T/fn.sh"
type _set_env >/dev/null 2>&1 && type step_immich_config >/dev/null 2>&1 || echo "FAIL  setup: _set_env/step_immich_config not found in $SRC (unfixed copy?)"
ENV_FILE=$T/.env; _IMMICH_ENV=$ENV_FILE
CHECK_DIAG='rc=$RC'
mode() { stat -c %a "$1"; }
cfg() { RC=0; ( set -e; printf '%s\n' "$1" | step_immich_config ) >"$T/out" 2>&1 || RC=$?; }
others() { grep -vE '^(UPLOAD_LOCATION|DB_DATA_LOCATION)=' "$1"; }

# 1 existing .env: media/music/files keys survive, only the two asked keys change
ODD='/tmp/x|y&z\w'
cat > "$ENV_FILE" <<X
# Immich
UPLOAD_LOCATION=/old/upload
DB_DATA_LOCATION=/old/postgres
IMMICH_VERSION=v3
DB_PASSWORD=real|pass&word\\1
MEDIA_LOCATION=/mnt/data/media
MUSIC_LOCATION=/mnt/data/media/My Music|&\\
FILES_LOCATION=/mnt/data/files
DATA_ROOT=/mnt/data
X
chmod 644 "$ENV_FILE"; cp "$ENV_FILE" "$T/before"
NEW="$T/new|loc&x\\y"
cfg "$NEW"
check 1a "config rc 0" '[ $RC = 0 ]'
check 1b "UPLOAD_LOCATION updated literally (| & \\ intact)" '[ "$(grep ^UPLOAD_LOCATION= "$ENV_FILE")" = "UPLOAD_LOCATION=$NEW" ]'
check 1c "DB_DATA_LOCATION follows" '[ "$(grep ^DB_DATA_LOCATION= "$ENV_FILE")" = "DB_DATA_LOCATION=$T/postgres" ]'
check 1d "every other line byte-identical (MEDIA/MUSIC/FILES/password/version kept)" 'cmp -s <(others "$T/before") <(others "$ENV_FILE")'
check 1e "mode tightened to 600" '[ "$(mode "$ENV_FILE")" = 600 ]'
check 1f "no temp file left behind" '[ "$(ls -A "$T" | grep -c "^\.env\.")" = 0 ]'

# 2 _set_env on its own
printf 'A=1\nB=2\n' > "$ENV_FILE"
_set_env B 'v|a&l\ue' "$ENV_FILE"; _set_env C 3 "$ENV_FILE"
check 2a "_set_env replaces literally" '[ "$(grep ^B= "$ENV_FILE")" = "B=v|a&l\\ue" ]'
check 2b "_set_env appends a missing key, leaves A" '[ "$(cat "$ENV_FILE")" = "$(printf "A=1\nB=v|a&l\\\\ue\nC=3")" ]'
printf 'AB=1\nA=2\n' > "$ENV_FILE"; _set_env A 9 "$ENV_FILE"
check 2c "_set_env matches the whole key (AB untouched)" '[ "$(cat "$ENV_FILE")" = "$(printf "AB=1\nA=9")" ]'

# 3 placeholder password is still regenerated on an existing .env
printf 'UPLOAD_LOCATION=/o\nDB_DATA_LOCATION=/p\nDB_PASSWORD=changeme_use_a_real_password\nFILES_LOCATION=/f\n' > "$ENV_FILE"
cfg "$T/ph"
check 3a "placeholder password replaced, FILES kept" '! grep -q changeme "$ENV_FILE" && grep -qE "^DB_PASSWORD=privcloud_" "$ENV_FILE" && grep -qx "FILES_LOCATION=/f" "$ENV_FILE"'

# 4 first-time: no .env -> created with the six keys, mode 600
rm -f "$ENV_FILE"; cfg "$T/first"
check 4a "fresh .env has the six keys" '[ $RC = 0 ] && [ "$(cut -d= -f1 "$ENV_FILE" | tr "\n" " ")" = "UPLOAD_LOCATION DB_DATA_LOCATION IMMICH_VERSION DB_PASSWORD DB_USERNAME DB_DATABASE_NAME " ]'
check 4b "fresh .env mode 600, upload dir made" '[ "$(mode "$ENV_FILE")" = 600 ] && [ -d "$T/first" ]'

check_total
