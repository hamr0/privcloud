#!/bin/bash
# Tests for the generated disk-check monitor and its installer (setup.sh:
# _disk_check_script, _disk_check_existing_note, step_disk_monitor).
# Run: bash tests/disk-check.sh   (from anywhere; exits non-zero on any failure)
# Everything runs in a mktemp sandbox with stubbed findmnt/df/curl/sudo/crontab
# helpers: no sudo, no network, no real cron, no real fstab or logs.
# SETUP_SH=<file> tests another copy of setup.sh (used for mutation checks).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/log" "$T/tmpd"
export TMPDIR=$T/tmpd   # mktemp in the installer lands here so leaks are visible
# Only the generator (up to step_disk_monitor); its heredoc has col-0 '}' lines.
awk '/^_disk_check_script\(\)/{p=1} /^step_disk_monitor\(\)/{p=0} p' "$SRC" > "$T/gen.sh"
source "$T/gen.sh"
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
p="${@: -1}"; best=/
while read -r m; do case "$p" in "$m"|"$m"/*) [ ${#m} -gt ${#best} ] && best=$m;; esac; done < "$FM_MAP"
echo "$best"
X
cat > "$T/bin/df" <<'X'
#!/bin/bash
m="${@: -1}"; pct=$(awk -v m="$m" '$1==m{print $2}' "$DF_MAP"); [ -z "$pct" ] && exit 1
echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "x 1 1 1 ${pct}% $m"
X
cat > "$T/bin/curl" <<'X'
#!/bin/bash
# Emulates curl: a URL containing BADTOKEN answers HTTP 404 -> exit 22 with -f
# (--fail or a short-flag group containing f), exit 0 without it.
echo "$*" >> "$CURL_LOG"; sleep "${CURL_SLEEP:-0}"
f=0
for a in "$@"; do
  case "$a" in --fail) f=1 ;; --*) ;; -*f*) f=1 ;; esac
done
url="${@: -1}"
if [[ "$url" == *BADTOKEN* ]]; then [ "$f" = 1 ] && exit 22; exit 0; fi
exit "${CURL_RC:-0}"
X
cat > "$T/bin/docker" <<'X'
#!/bin/bash
# Stub for the Kuma DB query: DOCKER_RC (default 1 = docker down) and DOCKER_OUT (rows).
[ "${DOCKER_RC:-1}" = 0 ] || exit "${DOCKER_RC:-1}"
printf '%s' "$DOCKER_OUT"
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" CURL_LOG=$T/curl.log FM_MAP=$T/fm DF_MAP=$T/df.map
PASS=0; FAILN=0
gen() { # envfile [url] -> $T/dc.sh
  _disk_check_script "${2:-http://example.invalid/api/push/SECRETTOKEN}" "$1" | sed "s#/var/log/disk-check#$T/log/dc#g; s#FSTAB=\"/etc/fstab\"#FSTAB=\"$T/fstab\"#" > "$T/dc.sh"; }
reset() { rm -f "$T"/log/* "$CURL_LOG"; : > "$T/fm"; : > "$T/fstab"; printf '/ 40\n' > "$DF_MAP"; unset CURL_RC CURL_SLEEP; }
check() { # id desc cond(true/false)
  if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC state='$(cat $T/log/dc.last 2>/dev/null)' curl='$(cat $CURL_LOG 2>/dev/null)' out='$OUT']"; FAILN=$((FAILN+1)); fi; }
run() { OUT=$(bash "$T/dc.sh" 2>&1); RC=$?; }
mkenv() { printf '%s\n' "$@" > "$T/env"; }
D=$T/mnt/federver; mkdir -p "$D" "$T/other"

# 1a install: .env path wrong -> dry-run rc 4, nothing written/pushed
reset; gen /nonexistent/.env; OUT=$(DISKCHECK_DRYRUN=1 bash "$T/dc.sh" 2>&1); RC=$?
check 1a "install dry-run, wrong .env path -> rc4 'config not found', no writes/curl" '[ $RC = 4 ] && [[ "$OUT" == *"config not found: /nonexistent/.env"* ]] && [ ! -e $T/log/dc.last ] && [ ! -e $CURL_LOG ]'
# 1b step_disk_monitor end-to-end with wrong location: refuses, installs nothing
mkdir -p "$T/copy"
awk '/^_disk_check_script\(\)/{p=1} /^step_logrotation\(\)/{p=0} p' "$SRC" > "$T/copy/setup.sh"   # no .env beside it
cat > "$T/step.sh" <<'X'
info(){ echo "I:$*"; }; warn(){ echo "W:$*"; }; fail(){ echo "F:$*"; }; ok(){ echo "O:$*"; }
YELLOW= NC= BLUE= BOLD= DIM= GREEN= RED=
hostname(){ echo 1.2.3.4; }
sudo(){ echo "SUDO $*" >> $T/sudo.log; case "$1" in grep) command grep "${@:2}"; return;; rm) command rm "${@:2}";; install) eval "$INSTALL_HOOK"; cp "${@: -2:1}" "$T/installed.sh"; chmod "$7" "$T/installed.sh";; esac; return 0; }
_cron_get(){ echo ""; }; _cron_drop(){ :; }; _cron_set(){ echo "CRONSET $2" >> $T/sudo.log; return 0; }
X
# Run step_disk_monitor from the sandbox copy; $1 = sudo behaviour hook (optional
# shell snippet run inside the install stub, e.g. to simulate Ctrl-C), $2 = sed
# expression applied to the copy (used to inject a script bug), $3 = e for set -e.
run_step() {
  rm -f "$T/sudo.log" "$T/installed.sh"
  ( export T; export INSTALL_HOOK="$1"; source "$T/step.sh"
    sed "s#/var/log/disk-check#$T/log/dc#g; s#/usr/local/bin/disk-check.sh#$T/bin-dc.sh#g; ${2:-}" "$T/copy/setup.sh" > "$T/copy/s2.sh"
    source "$T/copy/s2.sh"
    eval "$STEP_PRE"
    [ "$3" = e ] && set -e
    step_disk_monitor <<< "${STEP_IN-http://example.invalid/api/push/TOK?status=up&msg=OK&ping=}"
    echo "STEP_RC=$?"; echo "TRAPS=[$(trap -p | grep -E 'RETURN|INT|TERM')]" ) 2>&1
}
leaked() { ls "$T"/tmpd/tmp.* 2>/dev/null | wc -l; }
rm -f "$T/copy/.env" "$T/bin-dc.sh"; reset
OUT=$(run_step); RC=$?
check 1b "installer copy with no .env beside it -> fail, nothing installed/scheduled" '[[ "$OUT" == *"NOT installed"* ]] && [ ! -e $T/sudo.log ]'
check 1b2 "refused with no disk-check installed -> says nothing installed" '[[ "$OUT" == *"No disk-check is installed - nothing installed"* && "$OUT" != *"still active"* ]]'
check 1b3 "refused run leaves no temp file and no leaked RETURN/INT/TERM trap" '[ "$(leaked)" = 0 ] && [[ "$OUT" == *"TRAPS=[]"* ]]'
touch "$T/bin-dc.sh"
OUT=$(run_step); RC=$?
check 1b4 "refused with a disk-check already installed -> still active, unchanged, may be outdated, re-run 14 -> 7" '[[ "$OUT" == *"still active and unchanged"* && "$OUT" == *"outdated"* && "$OUT" == *"14 -> 7"* && "$OUT" != *"nothing installed"* ]]'
rm -f "$T/bin-dc.sh"
# 1b5 a bug in the generated script (bash exits 2 on a syntax error) is a script
# error, not a "blind config"; refuses and installs nothing
OUT=$(run_step "" 's/^THRESHOLD=85$/THRESHOLD=85 )(/'); RC=$?
check 1b5 "syntax error in generated script (bash rc 2) -> 'Monitor script error', not 'blind', nothing installed" '[[ "$OUT" == *"Monitor script error (dry-run exit 2)"* && "$OUT" != *"would be blind"* && ! -e $T/sudo.log && "$(leaked)" = 0 ]]'
# 1c same with .env present and a good location -> installs 0700, scheduled
mkdir -p "$T/copy/data"; printf 'FILES_LOCATION=%s\n' "$T/copy/data" > "$T/copy/.env"; echo "$T/copy/data" > "$T/fm"; printf '/ 40\n%s 50\n' "$T/copy/data" > "$DF_MAP"
OUT=$(run_step); RC=$?
check 1c "good .env -> install -o root -g root -m 700, cron set, shows Watching/Config" '[[ "$OUT" == *"Watching:"* && "$OUT" == *"Config: $T/copy/.env"* ]] && grep -q "install -o root -g root -m 700" $T/sudo.log && grep -q CRONSET $T/sudo.log'
check 1c2 "good .env run leaves no temp file and no leaked trap" '[ "$(leaked)" = 0 ] && [[ "$OUT" == *"TRAPS=[]"* ]]'
check 1d "installed script has query stripped and token only in the root-0700 file" 'grep -q "PUSH_URL=http://example.invalid/api/push/TOK$" $T/installed.sh && ! grep -q "status=up" $T/installed.sh && [ "$(stat -c %a $T/installed.sh)" = 700 ]'

# 1e Ctrl-C at the sudo password prompt: simulate SIGINT arriving inside the install
OUT=$(run_step 'kill -INT $BASHPID; sleep 1'); RC=$?
check 1e "SIGINT during sudo install -> temp file removed" '[ "$(leaked)" = 0 ] && [[ "$OUT" != *"STEP_RC"* ]]'
OUT=$(run_step 'kill -TERM $BASHPID; sleep 1'); RC=$?
check 1f "SIGTERM during sudo install -> temp file removed" '[ "$(leaked)" = 0 ] && [[ "$OUT" != *"STEP_RC"* ]]'
# 1g failing sudo install under set -e (the --run path): temp file removed, step fails
OUT=$(run_step 'return 1' '' e); RC=$?
check 1g "sudo install fails under set -e (the --run path) -> reported, temp file removed" '[[ "$OUT" == *"Could not install"* && "$(leaked)" = 0 ]]'

# 1h-1q existing Push URL is reused; removal only ever explicit (setup.sh:
# _disk_check_url_from_script/_from_kuma/_remove). Good .env is still in place.
STEP_PRE='_cron_get(){ cat "$T/cron"; }; _cron_drop(){ grep -v -- "$3" <<<"$1" || true; }; _cron_set(){ printf "%s" "$2" > "$T/cron"; }'
newstep() { # stdin-lines script-url(optional) kuma-rows(optional, "" = docker down)
  rm -f "$T/bin-dc.sh"; printf '0 1 * * * other\n*/5 * * * * /usr/local/bin/disk-check.sh\n' > "$T/cron"
  [ -n "$2" ] && _disk_check_script "$2" /x > "$T/bin-dc.sh"
  if [ -n "$3" ]; then export DOCKER_RC=0 DOCKER_OUT="$3"; else export DOCKER_RC=1 DOCKER_OUT=; fi
  STEP_IN=$1; OUT=$(run_step); RC=$?; }
SCRIPTURL=http://example.invalid/api/push/SCRIPTTOKEN9999
KUMAURL=http://1.2.3.4:3001/api/push/KUMATOKEN12345678
newstep "" "$SCRIPTURL"
check 1h "URL in the installed script + Enter -> installs with it, box titled Kuma monitor settings, token masked" '[[ "$OUT" == *"…9999"* && "$OUT" == *"from the installed script"* && "$OUT" == *"Kuma monitor settings"* && "$OUT" == *"Heartbeat Interval: "* && "$OUT" != *"Set up the Kuma monitor first"* && "$OUT" != *SCRIPTTOKEN* ]] && grep -q "PUSH_URL=$SCRIPTURL$" $T/installed.sh'
# 1r-1u "Current" block (cron line + last run; $T/log/dc.last stands in for /var/log/disk-check.last)
now=$(date '+%F %H:%M'); LASTF=$T/log/dc.last
rm -f "$LASTF"; printf '%s ok\n' "$now" > "$LASTF"; newstep "" "$SCRIPTURL"
check 1r "found + cron line + fresh ok .last -> Current block: masked URL, cron line, last run ok, no stale" '[[ "$OUT" == *"Current"* && "$OUT" == *"http://example.invalid/api/push/…9999"* && "$OUT" == *"*/5 * * * * "*"disk-check.sh"* && "$OUT" == *"Last run:  $now ok"* && "$OUT" != *"(stale)"* && "$OUT" != *"not scheduled"* ]]'
CUROUT=$OUT
STEP_PRE_SAVE=$STEP_PRE
STEP_PRE='_cron_get(){ printf "0 1 * * * other\n"; }; _cron_drop(){ :; }; _cron_set(){ :; }'; newstep "" "$SCRIPTURL"
check 1s "found + no disk-check cron line -> 'not scheduled'" '[[ "$OUT" == *"Cron:      "*"not scheduled"* ]]'
STEP_PRE='_cron_get(){ return 1; }; _cron_drop(){ :; }; _cron_set(){ :; }'; newstep "" "$SCRIPTURL"
check 1s2 "crontab unreadable -> 'unknown (could not read root...)'" '[[ "$OUT" == *"unknown (could not read root"* ]]'
STEP_PRE=$STEP_PRE_SAVE
printf '%s ALERT / 91%%\n' "$now" > "$LASTF"; newstep "" "$SCRIPTURL"
check 1t "ALERT .last shown as the last run" '[[ "$OUT" == *"Last run:  $now ALERT / 91%"* ]]'
printf '2020-01-01 00:00 ok\n' > "$LASTF"; newstep "" "$SCRIPTURL"
check 1t2 "old .last -> (stale)" '[[ "$OUT" == *"2020-01-01 00:00 ok"*"(stale)"* ]]'
rm -f "$LASTF"; newstep "" "$SCRIPTURL"
check 1t3 "missing .last -> 'never'" '[[ "$OUT" == *"Last run:  never"* ]]'
check 1u "full token never in Current output" '[[ "$CUROUT" != *SCRIPTTOKEN* ]]'
newstep "" "" KUMATOKEN12345678
check 1i "URL only in Kuma + Enter -> installs with http://<ip>:3001/api/push/<token>" '[[ "$OUT" == *"…5678"* && "$OUT" == *"from Uptime Kuma"* && "$OUT" == *"Kuma monitor settings"* && "$OUT" != *"Set up the Kuma monitor first"* ]] && grep -q "PUSH_URL=$KUMAURL$" $T/installed.sh'
newstep $'p\nhttp://example.invalid/api/push/NEWTOK?status=up' "$SCRIPTURL"
check 1j "found + p + new URL -> shows the settings box once, installs the new URL" '[[ "$OUT" == *"Kuma monitor settings"* && "$OUT" != *"Set up the Kuma monitor first"* && "$(grep -c "Friendly Name" <<<"$OUT")" = 1 ]] && grep -q "PUSH_URL=http://example.invalid/api/push/NEWTOK$" $T/installed.sh'
newstep "" "" ""; cronb=$(cat $T/cron)
check 1k "nothing found + blank -> back, no changes: no sudo call, cron untouched" '[[ "$OUT" == *"Set up the Kuma monitor first"* && "$OUT" == *"No changes."* && "$OUT" == *"STEP_RC=2"* ]] && [ ! -e $T/sudo.log -o "$(grep -vc "SUDO grep" $T/sudo.log 2>/dev/null)" = 0 ] && [ "$(cat $T/cron)" = "$cronb" ] && [ ! -e $T/installed.sh ]'
newstep "q" "" ""
check 1k2 "nothing found + q -> back, no changes" '[[ "$OUT" == *"STEP_RC=2"* && ! -e $T/installed.sh ]]'
newstep $'r\n' "$SCRIPTURL"; cronb=$(cat $T/cron)
check 1l "r + blank confirm -> nothing removed" '[[ "$OUT" == *"Cancelled. Nothing removed."* ]] && [ -e $T/bin-dc.sh ] && [ "$(cat $T/cron)" = "$cronb" ]'
newstep $'r\nyes' "$SCRIPTURL"
check 1m "r + wrong confirm -> nothing removed" '[[ "$OUT" == *"did not match"* ]] && [ -e $T/bin-dc.sh ] && [ "$(cat $T/cron)" = "$cronb" ]'
newstep $'r\ndisk-check' "$SCRIPTURL"
check 1n "r + disk-check -> cron line and script gone, other cron lines kept, verified" '[[ "$OUT" == *"disk-check removed"* ]] && [ ! -e $T/bin-dc.sh ] && ! grep -q bin-dc $T/cron && grep -q other $T/cron'
newstep $'r\ndisk-check' "" KUMATOKEN12345678; rm -f "$T/bin-dc.sh"; printf '0 1 * * * other\n' > "$T/cron"
OUT=$(STEP_IN=$'r' run_step)
check 1n2 "r with nothing installed -> says so, no confirm asked" '[[ "$OUT" == *"nothing to remove"* && "$OUT" != *"to confirm"* ]]'
newstep "" "" $'AAA111\nBBB222'
check 1o "two Kuma matches -> treated as not found (setup box + paste prompt, blank = back)" '[[ "$OUT" == *"Set up the Kuma monitor first"* && "$OUT" == *"No changes."* && "$OUT" != *"Found the Push URL"* && ! -e $T/installed.sh ]]'
newstep "" "" ""
check 1p "docker failing -> not found, step does not abort and prints no error" '[[ "$OUT" == *"STEP_RC=2"* && "$OUT" != *F:* ]]'
newstep "" "$SCRIPTURL" KUMATOKEN12345678
check 1q "full token (script and Kuma) never appears in output" '[[ "$OUT" != *SCRIPTTOKEN* && "$OUT" != *KUMATOKEN12345678* ]]'
newstep "" "" KUMATOKEN12345678
check 1q2 "Kuma token not echoed either" '[[ "$OUT" != *KUMATOKEN12345678* ]]'
unset STEP_IN STEP_PRE DOCKER_RC DOCKER_OUT; rm -f "$T/bin-dc.sh" "$T/installed.sh"

reset; gen "$T/missing.env"; run
check 2a "run time .env missing -> ALERT 'config not found', push down, never ok" '[ $RC = 1 ] && grep -q "ALERT config not found: $T/missing.env" $T/log/dc.last && grep -q "status=down" $CURL_LOG && ! grep -q " ok" $T/log/dc.last'
reset; mkenv "FILES_LOCATION=$D"; chmod 000 "$T/env"; gen "$T/env"; run
if [ "$(id -u)" = 0 ]; then echo "SKIP 2b (root)"; else check 2b "run time .env unreadable -> ALERT 'config unreadable', push down" 'grep -q "ALERT config unreadable" $T/log/dc.last && grep -q "status=down" $CURL_LOG'; fi
chmod 644 "$T/env"

reset; mkenv "# nothing" "FOO=bar"; gen "$T/env"; run
check 3a "zero *_LOCATION keys -> ALERT 'no data locations in', down" 'grep -q "ALERT no data locations in $T/env" $T/log/dc.last && grep -q "status=down" $CURL_LOG'
reset; mkenv "FOO=bar"; gen "$T/env"; OUT=$(DISKCHECK_DRYRUN=1 bash $T/dc.sh 2>&1); RC=$?
check 3b "same at install dry-run -> rc 4 (refuse)" '[ $RC = 4 ]'

reset; mkenv "FILES_LOCATION=$T/nope/data"; gen "$T/env"; run
check 4a "*_LOCATION path doesn't exist (no fstab) -> ALERT '<p> missing', down" 'grep -q "ALERT $T/nope/data missing" $T/log/dc.last && grep -q "status=down" $CURL_LOG'
reset; mkenv "FILES_LOCATION=$T/nope/data"; gen "$T/env"; OUT=$(DISKCHECK_DRYRUN=1 bash $T/dc.sh 2>&1); RC=$?
check 4b "all locations nonexistent at install -> rc 4 (nothing resolves, refuse)" '[ $RC = 4 ]'
reset; mkenv "FILES_LOCATION=$D" "MUSIC_LOCATION=$T/nope/music"; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; gen "$T/env"; run
check 4c "one of two paths missing -> ALERT mentions missing one, other still watched" 'grep -q "nope/music missing" $T/log/dc.last && grep -q "status=down" $CURL_LOG'

# 5 absent drive, empty stub, no fstab line (udisks fallback)
reset; mkdir -p "$T/media/x"; mkenv "FILES_LOCATION=$T/media/x"; gen "$T/env"; run
sed -i "s#/mnt/\*|/media/\*#$T/media/*|/media/*#" $T/dc.sh; run
check 5 "empty stub on / (no fstab) under removable prefix -> 'not mounted', down" 'grep -q "ALERT $T/media/x not mounted" $T/log/dc.last'
# 6a absent drive, stub has files, fstab declares mount
reset; touch "$D/leftover"; echo "UUID=abcd $T/mnt/federver ext4 nofail,x-systemd.automount 0 0" > $T/fstab; mkenv "FILES_LOCATION=$D/photos"; mkdir -p "$D/photos"; gen "$T/env"; run
check 6a "fstab declares mount, path resolves to / and stub non-empty -> 'not mounted', down" 'grep -q "ALERT $D/photos not mounted" $T/log/dc.last && grep -q "status=down" $CURL_LOG'
# 6b same drive actually mounted
reset; echo "UUID=abcd $T/mnt/federver ext4 nofail 0 0" > $T/fstab; echo "$T/mnt/federver" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D/photos"; gen "$T/env"; run
check 6b "fstab mount present and mounted -> ok, up" '[ $RC = 0 ] && grep -q " ok" $T/log/dc.last && grep -q "status=up" $CURL_LOG'
# 6c fstab: commented line ignored, swap/none ignored, space (\040) mountpoint, no fstab line + non-empty plain dir under /mnt = deliberate -> ok
reset; touch "$D/photos/f1"; printf '#UUID=z %s ext4 0 0\nnone swap swap 0 0\n/dev/x / ext4 0 0\n' "$D" > $T/fstab; mkenv "FILES_LOCATION=$D/photos"; gen "$T/env"; sed -i "s#/mnt/\*|/media/\*#$T/mnt/*|/media/*#" $T/dc.sh; run
check 6c "commented/swap/'/' fstab lines ignored; non-empty plain dir w/o real intent -> ok" '[ $RC = 0 ] && grep -q " ok" $T/log/dc.last'
reset; mkdir -p "$T/My Music/lib"; echo "/dev/x $T/My\\040Music ext4 0 0" > $T/fstab; mkenv "FILES_LOCATION=$T/My Music/lib"; gen "$T/env"; run
check 6d "fstab field2 with \\040 (space) matches path with space, resolves to / -> not mounted" 'grep -q "My Music/lib not mounted" $T/log/dc.last'
reset; mkdir -p "$T/mntx"; echo "/dev/x $T/mnt ext4 0 0" > $T/fstab; mkenv "FILES_LOCATION=$T/mntx"; gen "$T/env"; run
check 6e "fstab /mnt must not prefix-match /mntx (component boundary)" '[ $RC = 0 ]'

# 7 over threshold
reset; echo "$D" > $T/fm; printf '/ 40\n%s 91\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; run
check 7a "mount over threshold -> ALERT '<m> 91%', down, logged" 'grep -q "ALERT $D 91%" $T/log/dc.last && grep -q "status=down" $CURL_LOG && grep -q "WARNING" $T/log/dc.log'
reset; echo "$D" > $T/fm; printf '/ 86\n%s 40\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; run
check 7b "/ over threshold alone -> ALERT" 'grep -q "ALERT / 86%" $T/log/dc.last'
reset; echo "$D" > $T/fm; printf '/ 85\n%s 85\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; run
check 7c "exactly 85% is not over -> ok" '[ $RC = 0 ]'
reset; echo "$D" > $T/fm; printf '/ 40\n' > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; run
check 7d "df can't read a watched mount -> 'usage unreadable' ALERT (never silently ok)" 'grep -q "usage unreadable" $T/log/dc.last'

# 9 Kuma push fails
reset; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; export CURL_RC=7; run
check 9a "curl fails (exit 7) -> rc 3, state ALERT 'Kuma push failed', not ok, token not leaked" '[ $RC = 3 ] && grep -q "ALERT Kuma push failed (curl exit 7)" $T/log/dc.last && ! grep -q SECRETTOKEN $T/log/dc.last $T/log/dc.log && [[ "$OUT" != *SECRETTOKEN* ]]'
reset; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; export CURL_SLEEP=20; s=$SECONDS; timeout 5 bash $T/dc.sh; RC=$?
grep -c -- "-m 15" $CURL_LOG >/dev/null; OUT=
check 9b "curl is invoked with -m 15 (bounded; stub sleeps, we kill at 5s)" 'grep -q -- " -m 15 " <(echo " $(cat $CURL_LOG) ") || grep -q -- "-m 15" $CURL_LOG'
reset; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env" "http://example.invalid/api/push/BADTOKEN"; run
check 9e "bad token (HTTP 404): curl -f makes it fail -> rc 3, .last 'Kuma push failed' (without -f curl exits 0 and this reads ok)" '[ $RC = 3 ] && grep -q "Kuma push failed" $T/log/dc.last && ! grep -q " ok" $T/log/dc.last'
reset; echo "$D" > $T/fm; printf '/ 40\n%s 95\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; export CURL_RC=22; run
check 9c "alert AND push fails -> state keeps both" 'grep -q "Kuma push failed (curl exit 22); $D 95%" $T/log/dc.last'
reset; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; run
check 9d "healthy run: curl -G urlencoded status/msg, exactly one query (no '?' in URL arg)" 'grep -q -- "-G --data-urlencode status=up --data-urlencode msg=OK http://example.invalid/api/push/SECRETTOKEN$" $CURL_LOG'
reset; echo "$D" > $T/fm; printf '/ 40\n%s 50\n' "$D" > $DF_MAP; mkenv "FILES_LOCATION=$D"; gen "$T/env"; DISKCHECK_DRYRUN=1 bash $T/dc.sh > $T/dry.out; RC=$?; OUT=$(cat $T/dry.out)
check 2c "dry-run: prints Watching/Config, rc 0, no curl, no log/state files" '[ $RC = 0 ] && [[ "$OUT" == "Watching: / (40%), $D (50%)"* ]] && [ ! -e $CURL_LOG ] && [ -z "$(ls $T/log)" ]'
echo "TOTAL pass=$PASS fail=$FAILN"
[ "$FAILN" -eq 0 ]
