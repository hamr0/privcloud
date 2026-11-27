#!/bin/bash
# Tests for the Immich upload step (step_immich_upload) and the Google Photos fix
# step (step_immich_fix_gp) in setup.sh: Immich must be running, three bad API
# keys give up, the key is never on the docker argv (only inherited by name),
# albums vs flat, cancel uploads nothing, fix-gp validates its path and calls
# scripts/google-takeout-fix.sh.
# Run: bash tests/immich-upload.sh   (non-zero on any failure)
# Stubbed docker/curl in a mktemp sandbox: no real docker, no network.
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app/scripts" "$T/photos/trip"
touch "$T/photos/trip/a.jpg" "$T/photos/b.mp4"
{
  printf '#!/bin/bash\nGREEN= RED= YELLOW= BOLD= DIM= NC=\nDRY_RUN=0\n_FV_SELF=%q\n' "$T/app/setup.sh"
  for f in ok fail info warn _immich_up _immich_docker_group step_immich_upload step_immich_fix_gp; do extract_fn "$f" "$SRC"; done
  printf '[ "$1" = --run ] && { "$2"; exit $?; }\n'
} > "$T/app/run.sh"
printf '#!/bin/bash\necho "fixgp $*" >> "$FIX_LOG"\n' > "$T/app/scripts/google-takeout-fix.sh"
cat > "$T/bin/docker" <<'X'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  image) exit 0 ;;                                   # image inspect: already pulled
  run) case "$*" in
         *--version*) echo "9.9.9" ;;
         *) echo "ARGV: $*" >> "$RUN_LOG"; echo "ENVKEY: $IMMICH_API_KEY" >> "$RUN_LOG" ;;
       esac ;;
esac
exit 0
X
cat > "$T/bin/curl" <<'X'
#!/bin/bash
case "$*" in
  *server/ping*) [ -e "$UP" ] && echo pong; exit 0 ;;
  *users/me*) grep -q 'x-api-key: goodkey' ; exit ;;   # key arrives on stdin (-H @-)
esac
exit 0
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" UP=$T/up RUN_LOG=$T/run.log FIX_LOG=$T/fix.log
CHECK_DIAG="rc=\$RC out='\$OUT' log='\$(cat \$RUN_LOG 2>/dev/null)'"
go() { local input="$1"; shift; : > "$RUN_LOG"; OUT=$(printf '%b' "$input" | bash "$T/app/run.sh" --run "$@" 2>&1); RC=$?; }

rm -f "$UP"
go 'goodkey\n' step_immich_upload
check 1a "Immich not running -> refuses, rc 1, nothing run" '[ $RC = 1 ] && [[ "$OUT" == *"not running"* ]] && [ ! -s "$RUN_LOG" ]'

: > "$UP"
go '\n\n\n' step_immich_upload
check 2a "three empty API keys -> gives up, rc 1, no upload" '[ $RC = 1 ] && [ ! -s "$RUN_LOG" ] && [[ "$OUT" != *"API key valid"* ]]'
go 'bad\nbad\nbad\n' step_immich_upload
check 2b "three wrong API keys -> gives up, rc 1, no upload" '[ $RC = 1 ] && [[ "$OUT" == *"Giving up"* ]] && [ ! -s "$RUN_LOG" ]'
go 'bad\ngoodkey\n/no/such/dir\n' step_immich_upload
check 2c "key on the second try is accepted; a bad folder stops with rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"API key valid"* ]] && [[ "$OUT" == *"Not a valid directory"* ]] && [ ! -s "$RUN_LOG" ]'

go "goodkey\n$T/photos\n1\ny\n" step_immich_upload
check 3a "albums: --album and the read-only /import mount, rc 0" '[ $RC = 0 ] && grep -q "ARGV:.* upload --recursive --album /import" "$RUN_LOG" && grep -q -- "-v $T/photos:/import:ro" "$RUN_LOG"'
check 3b "the API key is not on the docker argv, only in the environment" '! grep "^ARGV:" "$RUN_LOG" | grep -q goodkey && grep -qx "ENVKEY: goodkey" "$RUN_LOG" && grep "^ARGV:" "$RUN_LOG" | grep -q -- "-e IMMICH_API_KEY "'
check 3c "the count shown counts media files (2)" '[[ "$OUT" == *"upload 2 media files"* ]]'
go "goodkey\n$T/photos\n2\n\n" step_immich_upload
check 4a "flat (and Enter = continue): no --album" '[ $RC = 0 ] && grep -q "upload --recursive  */import" "$RUN_LOG" && ! grep -q -- "--album" "$RUN_LOG"'
go "goodkey\n$T/photos\n1\nn\n" step_immich_upload
check 5a "answering n cancels: nothing uploaded, rc 0" '[ $RC = 0 ] && [ ! -s "$RUN_LOG" ] && [[ "$OUT" == *"Cancelled"* ]]'

: > "$FIX_LOG"
go '\n' step_immich_fix_gp
check 6a "fix-gp: no path -> rc 1, script not called" '[ $RC = 1 ] && [ ! -s "$FIX_LOG" ]'
go '/no/such/zip\n' step_immich_fix_gp
check 6b "fix-gp: missing path -> rc 1, script not called" '[ $RC = 1 ] && [[ "$OUT" == *"Not found"* ]] && [ ! -s "$FIX_LOG" ]'
go "$T/photos\n" step_immich_fix_gp
check 6c "fix-gp: valid path -> scripts/google-takeout-fix.sh gets it" '[ $RC = 0 ] && grep -qx "fixgp $T/photos" "$FIX_LOG"'

check_total
