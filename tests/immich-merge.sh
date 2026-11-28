#!/bin/bash
# Structure checks for the privcloud -> setup.sh merge ("Manage Immich"): the one
# .env writer, the one version reader, no leftovers (macOS branches, the privcloud
# CLI, its wrapper), every former privcloud action reachable from the menu and
# dispatchable with --run, the backup items wired to the existing backup steps.
# Run: bash tests/immich-merge.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
S=${SETUP_SH:-$H/../setup.sh}
SETUP_SH=$S
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
for f in _fv_pkg_version _env_quote _set_env ok fail info warn step_immich _remove_stale_privcloud_cmd; do extract_fn "$f" "$S"; done > "$T/fn.sh"
GREEN= RED= YELLOW= BOLD= DIM= NC=
source "$T/fn.sh"
ROOT=$(dirname "$S")

# 1 the one .env writer round-trips | & \ and touches nothing else
E=$T/.env
printf 'A=1\nB=2\nAB=3\n' > "$E"; chmod 644 "$E"
_set_env B 'v|a&l\ue' "$E"; _set_env C 'x|&\' "$E"
check 1a "_set_env replaces literally (| & \\)" '[ "$(grep ^B= "$E")" = "B=v|a&l\\ue" ]'
check 1b "_set_env appends a missing key; AB and A untouched" '[ "$(cat "$E")" = "$(printf "A=1\nB=v|a&l\\\\ue\nAB=3\nC=x|&\\\\")" ]'
check 1c "_set_env leaves the file mode 600, no temp file behind" '[ "$(stat -c %a "$E")" = 600 ] && [ "$(ls -A "$T" | grep -c "^\.env\.")" = 0 ]'
rm -f "$T/new.env"; _set_env K v "$T/new.env"
check 1d "_set_env creates a missing file (mode 600)" '[ "$(cat "$T/new.env")" = "K=v" ] && [ "$(stat -c %a "$T/new.env")" = 600 ]'

# 2 the one version reader
printf '{\n  "name": "x",\n  "version": "1.2.3"\n}\n' > "$T/package.json"
check 2a "version read from package.json" '[ "$(_fv_pkg_version "$T/package.json")" = 1.2.3 ]'
check 2b "missing package.json -> unknown" '[ "$(_fv_pkg_version "$T/nope.json")" = unknown ]'
printf '{ "name": "x" }\n' > "$T/nover.json"
check 2c "package.json without a version -> unknown" '[ "$(_fv_pkg_version "$T/nover.json")" = unknown ]'
check 2d "no stale 0.9.5 fallback left" '! grep -q "0\.9\.5" "$S"'

# 3 Manage Immich (federver -> 9): every former privcloud action is a menu item
# that hops to the right step; Back and junk return 2 (clean back, no DONE banner)
_on_server() { echo "$1" > "$T/called"; }
pick() { rm -f "$T/called"; MENU=$(printf '%s\n' "$1" | step_immich 2>&1); RC=$?; CALLED=$(cat "$T/called" 2>/dev/null); }
ACTIONS="1:step_immich_status:Status 2:step_immich_update:Update 3:step_immich_install:Install 4:step_immich_config:Config 5:step_immich_upload:Upload 6:step_immich_fix_gp:Fix_Google 7:step_immich_backup_once:Back_up_now 8:step_immich_backup:Set_up 9:_immich_backup_status:Status 10:_immich_backup_run:Run_now 11:_immich_backup_remove:Remove"
for a in $ACTIONS; do
  n=${a%%:*}; rest=${a#*:}; fn=${rest%%:*}; label=${rest#*:}; label=${label//_/ }
  pick "$n"
  check "3-$n" "menu $n -> $fn (label '$label' listed)" '[ "$CALLED" = "$fn" ] && [[ "$MENU" == *"$label"* ]]'
done
# D7: federver -> 7 is the only start/stop path; Immich's menu has none and its functions are gone
check 3e "no Start/Stop item in the Immich menu, and a hint points at federver -> 7" 'pick 1; ! sed -E "s/\x1b\[[0-9;]*m//g" <<<"$MENU" | grep -qE "^ +[0-9]+\) +(Start|Stop)" && [[ "$MENU" == *"federver → 7"* ]]'
check 3f "step_immich_start / step_immich_stop no longer exist; nothing calls them" '! grep -qE "step_immich_(start|stop)" "$S"'
check 3g "the submenu is numbered 1..11 contiguously, arrows are ←, arrow column aligned" 'seq=$(sed -E "s/\x1b\[[0-9;]*m//g" <<<"$MENU" | grep -oE "^ +[0-9]+\)" | tr -dc "0-9\n" | paste -sd, -); [ "$seq" = "1,2,3,4,5,6,7,8,9,10,11,0" ] && [[ "$MENU" != *"<-"* ]] && [ "$(sed -E "s/\x1b\[[0-9;]*m//g" <<<"$MENU" | grep "←" | grep -v "Start / Stop" | awk "{print index(\$0,\"←\")}" | sort -u | wc -l)" = 1 ]'
check 3h "section subheaders Immich, Photos, Backup - One-time, Backup - Scheduled appear in that order, each before its items" 'pick 1; sed -E "s/\x1b\[[0-9;]*m//g" <<<"$MENU" | grep -E "^ +(──|[0-9]+\))" | sed -E "s/^ +(── .* ──|[0-9]+\)).*/\1/" | paste -sd"|" - | grep -qF "── Immich ──|1)|2)|3)|4)|── Photos ──|5)|6)|── Backup - One-time ──|7)|── Backup - Scheduled ──|8)|9)|10)|11)|0)"'
pick 0;  check 3a "0 = Back: rc 2, nothing run" '[ $RC = 2 ] && [ -z "$CALLED" ]'
pick x;  check 3b "junk: rc 2, nothing run" '[ $RC = 2 ] && [ -z "$CALLED" ] && [[ "$MENU" == *"Invalid choice"* ]]'
check 3c "the backup items point straight at the existing scheduled-backup functions (no 'bash setup.sh --run' hop)" 'grep -q "_on_server step_immich_backup ;;" "$S" && grep -q "_on_server _immich_backup_status ;;" "$S" && grep -q "_on_server _immich_backup_run ;;" "$S" && grep -q "_on_server _immich_backup_remove ;;" "$S" && ! grep -q "setup.sh --run" <(extract_fn step_immich "$S")'
check 3d "main menu entry is 'Manage Immich' (9)" 'grep -q "run_step \"\[9\] Manage Immich\" step_immich" "$S" && grep -q "9)\${NC}  Manage Immich" "$S"'

# 4 each Immich action is a real `--run` step: run the real script (a copy, in a
# sandbox with stubbed docker/curl/sudo) and see it is dispatched, not "not defined"
SB=$T/sb; mkdir -p "$SB/bin" "$SB/home" "$SB/copy"
cp "$S" "$SB/copy/setup.sh"; cp "$ROOT/package.json" "$ROOT/docker-compose.yml" "$SB/copy/" 2>/dev/null
mkdir -p "$SB/copy/scripts"; printf '#!/bin/bash\nexit 0\n' > "$SB/copy/scripts/google-takeout-fix.sh"
for c in docker curl sudo systemctl rsync git; do printf '#!/bin/bash\nexit 0\n' > "$SB/bin/$c"; done
chmod +x "$SB/bin/"*
for fn in step_immich_status step_immich_update step_immich_install step_immich_config step_immich_upload step_immich_fix_gp step_immich_backup_once; do
  OUT=$(cd "$SB/copy" && HOME=$SB/home PATH="$SB/bin:$PATH" timeout 30 bash ./setup.sh --run "$fn" </dev/null 2>&1)
  check "4-$fn" "--run $fn dispatches (defined, runs its own code)" '[[ "$OUT" != *"is not defined"* ]] && [[ "$OUT" != *"pulling latest"* ]]'
done
check 4s "one compose helper: no inline 'sg docker -c \"docker compose ...\"' left, _immich_compose is gone" '! grep -nE "sg docker -c [\"'"'"']docker compose" "$S" && ! grep -q "_immich_compose" "$S" && grep -q "^_compose() {" "$S"'
# the stale-checkout retry names the checkout's real branch, not "main"
printf '#!/bin/bash\n[ "$1" = rev-parse ] && echo feature-x\nexit 0\n' > "$SB/bin/git"
OUT=$(cd "$SB/copy" && HOME=$SB/home PATH="$SB/bin:$PATH" timeout 30 bash ./setup.sh --run no_such_step </dev/null 2>&1)
check 4r "--run retry message names the real branch (feature-x), not main" '[[ "$OUT" == *"pulling latest of feature-x"* && "$OUT" != *"from main"* ]]'
for fn in step_immich_backup _immich_backup_status _immich_backup_run _immich_backup_remove; do
  check "4-$fn" "$fn (the existing scheduled-backup step) is defined for --run" 'extract_fn "$fn" "$S" >/dev/null'
done

# 5 nothing of the old tool is left
check 5a "the privcloud script and its standalone installer are gone" '[ ! -e "$ROOT/privcloud" ] && [ ! -e "$ROOT/scripts/install.sh" ]'
check 5b "no Darwin / get_os / brew-install-Docker branch in setup.sh" '! grep -q "Darwin" "$S" && ! grep -q "get_os" "$S" && ! grep -q "brew install --cask" "$S" && ! grep -q "open -a Docker" "$S"'
check 5c "no privcloud CLI verbs or ./privcloud in setup.sh" '! grep -qE "privcloud (install|start|stop|status|config|update|upload|fix-gp|backup)\b|\./privcloud|\"\$SCRIPT_DIR/privcloud\"" "$S"'
LEFT=$(grep -n privcloud "$S" | grep -vE '^[0-9]+:[[:space:]]*#' | sed -E 's#~/privcloud|cd privcloud|github\.com/[^/]+/privcloud|privcloud/|\.privcloud|privcloud_|privcloud-backup|privcloud\.git|\$HOME/privcloud/|/usr/local/bin/privcloud|the old .privcloud. command|Clone privcloud|the privcloud folder##g' | grep privcloud)
CHECK_DIAG='left=$LEFT'
check 5d "'privcloud' in setup.sh only as a path, repo name or comment" '[ -z "$LEFT" ]'
check 5e "the installer no longer writes a privcloud wrapper" '! grep -q "tee /usr/local/bin/privcloud" "$S" && ! grep -q "exec .*/privcloud " "$S"'

# 6 a stale /usr/local/bin/privcloud from an older install is removed with one line
STALE=$T/stale-privcloud; _STALE_PRIVCLOUD_CMD=$STALE
sudo() { echo "SUDO-RUNS"; "$@"; }
echo old > "$STALE"; OUT=$(_remove_stale_privcloud_cmd 2>&1)
check 6a "stale wrapper removed; the one-time/needs-sudo line comes BEFORE sudo runs, then one short success line" '[ ! -e "$STALE" ] && [ "$(wc -l <<<"$OUT")" = 3 ] && [[ "$(sed -n 1p <<<"$OUT")" == *"one-time, needs sudo"* && "$(sed -n 2p <<<"$OUT")" == SUDO-RUNS && "$OUT" == *"federver -> 9"* ]]'
ln -s "$T/does-not-exist" "$STALE"; OUT=$(_remove_stale_privcloud_cmd 2>&1)
check 6b "a dangling symlink (the old standalone install) is removed too" '[ ! -L "$STALE" ] && [[ "$OUT" == *"Removed"* ]]'
OUT=$(_remove_stale_privcloud_cmd 2>&1)
check 6c "nothing there: silent, no sudo asked" '[ -z "$OUT" ]'
unset -f sudo
check 6d "the installer (step 1), Immich Install and Immich Update all clean up the stale command" 'extract_fn step_ssh "$S" | grep -q "^    _remove_stale_privcloud_cmd" && extract_fn step_immich_install "$S" | grep -q "^    _remove_stale_privcloud_cmd" && extract_fn step_immich_update "$S" | grep -q "^    _remove_stale_privcloud_cmd"'

CHECK_DIAG=
# 7 Manage Immich Status (federver -> 9 -> 1) is about Immich's four compose services only
for f in step_immich_status _compose; do extract_fn "$f" "$S"; done > "$T/st.sh"
source "$T/st.sh"
eval "$(grep -m1 '^_IMMICH_SERVICES=' "$S")"
_immich_docker_group() { :; }; _env_get() { :; }; _immich_up() { return 1; }
_IMMICH_ENV=$T/x.env; _IMMICH_COMPOSE=$T/x.yml
mkdir -p "$T/bin"; DLOG=$T/docker.log
stub_cmd docker 'echo "docker $*" >> "$DLOG"
case "$*" in
  *"compose version"*|*"--version"*) echo "Docker version 1" ;;
  *" ps --format"*) [ -n "$NO_CTR" ] || printf "NAME STATUS\nimmich_server Up 1 hour (healthy)\n" ;;
  *" ps -aq "*) echo abc123 ;;
  *" logs "*) echo "fatal: boom" ;;
esac
exit 0'
export PATH="$T/bin:$PATH" DLOG
: > "$DLOG"; OUT=$(step_immich_status 2>&1)
check 7a "status lists only the four Immich services and reads only their logs (no other container named)" '[ "$(grep -c " ps --format" "$DLOG")" = 1 ] && grep " ps --format" "$DLOG" | grep -q "immich-server immich-machine-learning redis database" && [ "$(grep -c " logs " "$DLOG")" = 4 ] && ! grep -qE "docker (ps|logs) |immich_postgres" "$DLOG" && [[ "$OUT" == *"-- redis --"* ]]'
: > "$DLOG"; OUT=$(NO_CTR=1 step_immich_status 2>&1)
check 7b "no Immich containers: the message says Immich, not the whole stack" '[[ "$OUT" == *"No Immich containers running."* ]]'


# 8 Install (federver -> 9 -> 3): summary, then ONE [Y/n] before anything is changed or pulled
for f in step_immich_install _confirm_yn; do extract_fn "$f" "$S"; done > "$T/inst.sh"
source "$T/inst.sh"
_remove_stale_privcloud_cmd() { :; }; _immich_ensure_docker() { :; }; _immich_needs_selinux() { return 1; }
_immich_fix_permissions() { echo FIXPERM >> "$T/inst.log"; }
_compose() { echo "compose $*" >> "$T/inst.log"; }
printf 'UPLOAD_LOCATION=/x\n' > "$T/x.env"
: > "$T/inst.log"; OUT=$(printf 'n\n' | step_immich_install 2>&1); RC=$?
check 8a "Install: summary lists the config path and the four services; n = nothing pulled, no permission fix, rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Install summary"* && "$OUT" == *"Config:  $T/x.env"* && "$OUT" == *"immich-server immich-machine-learning redis database"* && "$OUT" == *"Cancelled - nothing pulled"* ]] && [ ! -s "$T/inst.log" ]'
: > "$T/inst.log"; OUT=$(printf '\n' | step_immich_install 2>&1); RC=$?
check 8b "Install: Enter = pull the four services, announced first ('Pulling 4 images')" '[ $RC = 0 ] && grep -qx "compose pull immich-server immich-machine-learning redis database" "$T/inst.log" && [[ "$OUT" == *"Pulling 4 images"* ]]'
check_total
