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
  for f in ok fail info warn _immich_up _immich_docker_group _immich_key_code _immich_key_ok _immich_key_fail _ask_path _confirm_yn step_immich_upload step_immich_fix_gp; do extract_fn "$f" "$SRC"; done
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
  *users/me*) k=$(cat)                              # key arrives on stdin (-H @-)
              case "$k" in *goodkey*) c=200 ;; *noperm*) c=403 ;; *down*) c=000 ;; *) c=401 ;; esac
              case "$*" in *%{http_code}*) printf '%s' "$c" ;; esac; [ "$c" = 200 ]; exit ;;
esac
exit 0
X
chmod +x "$T/bin/"*
export XDG_CONFIG_HOME=$T/cfg
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
mkdir -p "$T/zips"; head -c 2048 /dev/zero > "$T/zips/takeout-001.zip"
go "$T/zips\ny\n" step_immich_fix_gp
check 6c "fix-gp: zips found, summary, y -> scripts/google-takeout-fix.sh gets the path" '[ $RC = 0 ] && grep -qx "fixgp $T/zips" "$FIX_LOG" && [[ "$OUT" == *"Zips:    1 (2.0K)"* && "$OUT" == *"Output:  $T/zips/extracted"* && "$OUT" == *"Free:"* ]]'
: > "$FIX_LOG"; go "$T/zips\nn\n" step_immich_fix_gp
check 6d "fix-gp: n at the summary -> nothing run, nothing created" '[ $RC = 0 ] && [ ! -s "$FIX_LOG" ] && [ ! -e "$T/zips/extracted" ] && [[ "$OUT" == *Cancelled* ]]'
go "q\n" step_immich_fix_gp
check 6e "fix-gp: q = back (rc 2), script not called" '[ $RC = 2 ] && [ ! -s "$FIX_LOG" ]'
go "$T/photos\ny\n" step_immich_fix_gp
check 6f "fix-gp: a folder without zips is refused before any question" '[ $RC = 1 ] && [[ "$OUT" == *"No zip files found"* ]] && [ ! -s "$FIX_LOG" ]'
stub_cmd df 'echo Avail; echo 1024'
go "$T/zips\ny\n" step_immich_fix_gp
check 6g "fix-gp: free space below the zip total -> clear refusal, script not called" '[ $RC = 1 ] && [[ "$OUT" == *"Not enough free space"* ]] && [ ! -s "$FIX_LOG" ]'
rm -f "$T/bin/df"

# 7 API key remembered (decision 14): file 600 in a 700 dir, never on argv, saved valid key = no typing
KEYF=$XDG_CONFIG_HOME/federver/immich-api-key; rm -rf "$XDG_CONFIG_HOME"
go "goodkey\n$T/photos\n2\ny\n" step_immich_upload
check 7a "a valid typed key is saved: mode 600 file, 700 dir, content = key" '[ "$(cat "$KEYF")" = goodkey ] && [ "$(stat -c %a "$KEYF")" = 600 ] && [ "$(stat -c %a "$(dirname "$KEYF")")" = 700 ]'
check 7b "the key never shows in the output or on the docker argv" '[[ "$OUT" != *goodkey* ]] && ! grep "^ARGV:" "$RUN_LOG" | grep -q goodkey'
go "\n$T/photos\n2\ny\n" step_immich_upload
check 7c "saved valid key: 'saved (Enter keeps it...)', Enter alone is enough, upload runs" '[ $RC = 0 ] && [[ "$OUT" == *"API key: saved (Enter keeps it, or paste a new one)"* ]] && grep -qx "ENVKEY: goodkey" "$RUN_LOG"'
echo staleKey > "$KEYF"
go "goodkey\n$T/photos\n2\ny\n" step_immich_upload
check 7d "saved key rejected: says so, asks, saves the new valid one" '[[ "$OUT" == *"saved API key was rejected"* ]] && [ "$(cat "$KEYF")" = goodkey ]'
go "q\n" step_immich_upload
check 7e "q at the key prompt = back (rc 2), nothing uploaded" '[ $RC = 2 ] && [ ! -s "$RUN_LOG" ]'
go "\nq\n" step_immich_upload
check 7f "q at the photos path = back (rc 2), nothing uploaded" '[ $RC = 2 ] && [ ! -s "$RUN_LOG" ]'
check 7g "album prompt says Enter = Flat; path prompt says q = back (read -p is silent off a tty: source checked)" 'extract_fn step_immich_upload "$SRC" | grep -q "(Enter = Flat)" && extract_fn _ask_path "$SRC" | grep -q "q = back"'


# 8 the key check: length echo (never the key) and one message per HTTP status; only a 2xx key is saved
rm -rf "$XDG_CONFIG_HOME"
go "bad\nnoperm\ndown\n" step_immich_upload
check 8a "401 / 403 / no answer: three different messages, nothing saved, gives up" '[ $RC = 1 ] && [[ "$OUT" == *"This key is not on this Immich server (deleted, mistyped or from another server) - create one: Account Settings → API Keys → New API Key, with All permissions (the secret is shown only once)"* && "$OUT" == *"This key lacks permissions - create one with \"All\" permissions (upload needs asset.upload)"* && "$OUT" == *"Could not check the key (HTTP 000)"* && ! -e "$KEYF" ]]'
go "goodkey\n/no/such/dir\n" step_immich_upload
check 8b "after Enter: masked 'Key received: ****dkey (7 characters)' (last 4 only), never the key itself" '[[ "$OUT" == *"Key received: ****dkey (7 characters)"* && "$OUT" != *goodkey* ]]'

# 9 the same paths under `set -e` (how `setup.sh --run step_immich_upload` runs on the server)
goe() { local input="$1"; shift; : > "$RUN_LOG"; run_errexit "$@" < <(printf '%b' "$input"); }
rm -rf "$XDG_CONFIG_HOME"
goe "bad\nnoperm\ndown\n" step_immich_upload
check 9a "errexit: 401 / 403 / no answer: all three messages shown, then 'Giving up', rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"not on this Immich server"* && "$OUT" == *"lacks permissions"* && "$OUT" == *"Could not check the key (HTTP 000)"* && "$OUT" == *"Giving up"* ]]'
goe "goodkey\n$T/photos\n2\ny\n" step_immich_upload
check 9b "errexit: valid key typed, upload runs: rc 0, key saved" '[ $RC = 0 ] && grep -qx "ENVKEY: goodkey" "$RUN_LOG" && [ "$(cat "$KEYF")" = goodkey ]'
goe "\n$T/photos\n2\ny\n" step_immich_upload
check 9c "errexit: saved key kept with Enter: rc 0, upload runs" '[ $RC = 0 ] && [[ "$OUT" == *"API key: saved"* ]] && grep -qx "ENVKEY: goodkey" "$RUN_LOG"'
echo staleKey > "$KEYF"
goe "goodkey\n$T/photos\n2\ny\n" step_immich_upload
check 9d "errexit: saved key rejected, new one asked: rc 0, new key saved" '[ $RC = 0 ] && [[ "$OUT" == *"saved API key was rejected"* ]] && [ "$(cat "$KEYF")" = goodkey ]'
goe "\n$T/photos\n1\nn\n" step_immich_upload
check 9e "errexit: Cancel at the final question: rc 0, nothing uploaded" '[ $RC = 0 ] && [ ! -s "$RUN_LOG" ]'
check_total
