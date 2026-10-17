#!/bin/bash
# Tests for container power control and the Status marker in setup.sh:
# _svc_power_body / _svc_power / _svc_power_all / _svc_power_remote /
# _svc_power_all_remote / _ps_autostart. The rule: autostart follows the last
# action (stop -> restart=no, start/restart -> unless-stopped), verified by
# reading state + policy back.
# Run: bash tests/svc-power.sh   (from anywhere; exits non-zero on any failure)
# Everything runs in a mktemp sandbox with stubbed docker/sudo/ssh: no real
# containers, no sudo, no network. SETUP_SH=<file> tests another copy of
# setup.sh (used for the fail-first check against an older version).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/c"
# _shq plus the power/status helpers (stop after _ps_autostart's closing brace).
{ grep -m1 '^_shq()' "$SRC"
  awk '/^_svc_power_body\(\)/{p=1} p{print} /^_ps_autostart\(\)/{q=1} q&&/^}/{exit}' "$SRC"; } > "$T/fn.sh"
source "$T/fn.sh"
type _svc_power_body >/dev/null 2>&1 || { echo "FAIL  setup: _svc_power_body not found in $SRC (older setup.sh?)"; }
cat > "$T/bin/sudo" <<'X'
#!/bin/bash
[ -n "$SUDO_FAIL" ] && exit 1; [ "$1" = -v ] && exit 0; exec "$@"
X
# docker stub: one dir per container under $C (key = sanitized name), files
# name/running/policy. Failure knobs: DOCKER_DOWN, FAIL_UPDATE, FAIL_ACTION,
# LIE_ACTION (action returns 0 but changes nothing).
cat > "$T/bin/docker" <<'X'
#!/bin/bash
C=$DOCKER_STATE
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' _; }
echo "docker $*" >> "$DOCKER_LOG"
[ -n "$DOCKER_DOWN" ] && exit 1
cmd=$1; shift
case "$cmd" in
  info) exit 0 ;;
  ps)
    all=0; q=0
    for a in "$@"; do case "$a" in -a) all=1;; -aq) all=1; q=1;; *Status*) full=1;; esac; done
    [ "$full" = 1 ] || q=1   # --format '{{.Names}}' prints names only
    for d in "$C"/*/; do [ -d "$d" ] || continue
      [ "$all" = 1 ] || [ "$(cat "$d/running")" = true ] || continue
      n=$(cat "$d/name")
      if [ "$q" = 1 ]; then echo "$n"
      else
        if [ "$(cat "$d/running")" = true ]; then echo "$n|Up 2 hours"; else echo "$n|Exited (0) 3 hours ago"; fi
      fi
    done ;;
  inspect)
    fmt=""; names=()
    while [ $# -gt 0 ]; do case "$1" in -f) fmt=$2; shift 2;; *) names+=("$1"); shift;; esac; done
    for n in "${names[@]}"; do
      d=$C/$(key "$n"); [ -d "$d" ] || exit 1
      case "$fmt" in
        *State.Running*) echo "$(cat "$d/running") $(cat "$d/policy")" ;;
        *'{{.Name}}'*)   echo "/$n $(cat "$d/policy")" ;;
      esac
    done ;;
  update)
    [ -n "$FAIL_UPDATE" ] && exit 1
    pol=${1#--restart=}; d=$C/$(key "$2"); [ -d "$d" ] || exit 1; echo "$pol" > "$d/policy" ;;
  start|stop|restart)
    [ -n "$FAIL_ACTION" ] && exit 1
    d=$C/$(key "$1"); [ -d "$d" ] || exit 1
    [ -n "$LIE_ACTION" ] && exit 0
    if [ "$cmd" = stop ]; then echo false > "$d/running"; else echo true > "$d/running"; fi ;;
esac
exit 0
X
# ssh stub: drops options/-t/target, runs the command string through bash -c
# (what the remote login shell does).
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
echo "ssh $*" >> "$SSH_LOG"
[ -n "$SSH_DOWN" ] && { echo "ssh: connect timed out" >&2; exit 255; }
for a in "$@"; do last=$a; done
exec bash -c "$last"
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" DOCKER_STATE=$T/c DOCKER_LOG=$T/docker.log SSH_LOG=$T/ssh.log
SERVER_USER=tester SERVER_IP=192.0.2.1
PASS=0; FAILN=0
mk() { # name running policy
  local d="$T/c/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; mkdir -p "$d"
  printf '%s' "$1" > "$d/name"; echo "$2" > "$d/running"; echo "$3" > "$d/policy"; }
st() { local d="$T/c/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; echo "$(cat "$d/running") $(cat "$d/policy")"; }
reset() { rm -rf "$T/c"; mkdir -p "$T/c"; : > "$DOCKER_LOG"; : > "$SSH_LOG"; unset SUDO_FAIL DOCKER_DOWN FAIL_UPDATE FAIL_ACTION LIE_ACTION SSH_DOWN; }
check() { # id desc cond
  if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC err='$ERR' state='$(st "${CN:-x}" 2>&1)']"; FAILN=$((FAILN+1)); fi; }
run() { ERR=$("$@" 2>&1 >/dev/null); RC=$?; }

# 1 basic transitions, local
CN=adguard
reset; mk adguard false no;               run _svc_power start adguard
check 1a "start: running + unless-stopped"       '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ]'
reset; mk adguard true unless-stopped;    run _svc_power stop adguard
check 1b "stop: stopped + restart=no"            '[ $RC = 0 ] && [ "$(st adguard)" = "false no" ]'
reset; mk adguard true no;                run _svc_power restart adguard
check 1c "restart: running + unless-stopped"     '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ]'
reset; mk adguard true always;            run _svc_power stop adguard
check 1d "stop overrides a compose 'always' policy"  '[ $RC = 0 ] && [ "$(st adguard)" = "false no" ]'

# 2 the incident: Stop, then Restart, then "reboot" must leave autostart on
reset; mk adguard true unless-stopped
_svc_power stop adguard 2>/dev/null; _svc_power restart adguard 2>/dev/null; RC=$?
check 2a "stop then restart: back to unless-stopped (AdGuard case)" '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ]'
reset; mk adguard false no
_svc_power restart adguard 2>/dev/null; RC=$?
check 2b "restart of a stopped container starts it and re-enables autostart" '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ]'

# 3 failures report fail, never success
reset; mk adguard false no; export FAIL_UPDATE=1; run _svc_power start adguard
check 3a "update fails: rc 4, says so, container not started" '[ $RC = 4 ] && [[ "$ERR" == *"restart policy"* ]] && [ "$(st adguard)" = "false no" ]'
reset; mk adguard false no; export FAIL_ACTION=1; run _svc_power start adguard
check 3b "update ok, start fails: rc 5"          '[ $RC = 5 ] && [[ "$ERR" == *"start failed"* ]]'
reset; mk adguard true no; export FAIL_ACTION=1; run _svc_power restart adguard
check 3c "restart fails: rc 5"                   '[ $RC = 5 ]'
reset; mk adguard true unless-stopped; export LIE_ACTION=1; run _svc_power stop adguard
check 3d "stop that did not stop: read-back catches it (rc 6)" '[ $RC = 6 ] && [[ "$ERR" == *"expected"* ]]'
reset; mk adguard false no; export DOCKER_DOWN=1; run _svc_power start adguard
check 3e "docker down: rc 2, clear message"      '[ $RC = 2 ] && [[ "$ERR" == *"not reachable"* ]]'
reset; mk adguard false no; export SUDO_FAIL=1; run _svc_power start adguard
check 3f "sudo refused: rc 7, says sudo (not 'not reachable'), nothing updated" '[ $RC = 7 ] && [[ "$ERR" == *sudo* ]] && [[ "$ERR" != *"not reachable"* ]] && ! grep -q "docker update" "$DOCKER_LOG"'

# 4 missing container
CN=ghost; reset; run _svc_power start ghost
check 4a "missing container: rc 3, names it, nothing updated" '[ $RC = 3 ] && [[ "$ERR" == *"no such container: ghost"* ]] && ! grep -q "docker update" "$DOCKER_LOG"'

# 5 odd names are one argument and never execute
ODD='my app;touch '"$T"'/pwned $(touch '"$T"'/pwned2) "q" '"'"'s'"'"
CN=$ODD; reset; mk "$ODD" false no; run _svc_power start "$ODD"
check 5a "local: odd name works, no injection"   '[ $RC = 0 ] && [ "$(st "$ODD")" = "true unless-stopped" ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'
reset; mk "$ODD" true unless-stopped; run _svc_power_remote stop "$ODD"
check 5b "remote: odd name survives the ssh parse" '[ $RC = 0 ] && [ "$(st "$ODD")" = "false no" ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'

# 6 remote path (ssh -t stub)
CN=syncthing
reset; mk syncthing true no;  run _svc_power_remote restart syncthing
check 6a "remote restart restores unless-stopped" '[ $RC = 0 ] && [ "$(st syncthing)" = "true unless-stopped" ] && grep -q -- "tester@192.0.2.1" "$SSH_LOG" && grep -q -- " -t " <<<" $(cat "$SSH_LOG") "'
reset; mk syncthing true unless-stopped; export SSH_DOWN=1; run _svc_power_remote stop syncthing
check 6b "ssh hop fails: non-zero, container untouched" '[ $RC != 0 ] && [ "$(st syncthing)" = "true unless-stopped" ]'
reset; mk syncthing false no; export FAIL_ACTION=1; run _svc_power_remote start syncthing
check 6c "remote: start failure propagates through ssh" '[ $RC = 5 ]'
reset; run _svc_power_remote start syncthing
check 6d "remote: missing container propagates rc 3" '[ $RC = 3 ]'

# 7 bulk
reset; mk immich_server true always; mk adguard true unless-stopped; mk syncthing true unless-stopped
run _svc_power_all stop
check 7a "stop all: every container stopped + restart=no (incl. adguard/syncthing)" '[ $RC = 0 ] && [ "$(st immich_server)" = "false no" ] && [ "$(st adguard)" = "false no" ] && [ "$(st syncthing)" = "false no" ]'
run _svc_power_all start
check 7b "start all: every container (incl. stopped) running + unless-stopped" '[ $RC = 0 ] && [ "$(st immich_server)" = "true unless-stopped" ] && [ "$(st adguard)" = "true unless-stopped" ] && [ "$(st syncthing)" = "true unless-stopped" ]'
reset; mk a true unless-stopped; mk dead false unless-stopped
run _svc_power_all stop
check 7g "stop all: a container that exited on its own under unless-stopped ends at 'false no'" '[ $RC = 0 ] && [ "$(st a)" = "false no" ] && [ "$(st dead)" = "false no" ]'
reset; mk a true no; mk b true always; mk c false no
run _svc_power_all_remote restart
check 7c "restart all (remote): running ones restored, a deliberately stopped one left alone" '[ $RC = 0 ] && [ "$(st a)" = "true unless-stopped" ] && [ "$(st b)" = "true unless-stopped" ] && [ "$(st c)" = "false no" ]'
reset; mk a true no; mk b true no; export FAIL_ACTION=1; run _svc_power_all restart
check 7d "bulk: failures make the whole run fail" '[ $RC = 1 ] && [[ "$ERR" == *"restart failed"* ]]'
reset; export DOCKER_DOWN=1; run _svc_power_all stop
check 7e "bulk with docker down: fail, not 'nothing to do'" '[ $RC = 2 ]'
reset; run _svc_power_all stop
check 7f "bulk with nothing running: ok" '[ $RC = 0 ]'
reset; mk a true no; export SUDO_FAIL=1; run _svc_power_all stop
check 7h "bulk, sudo refused: rc 7, says sudo (not 'not reachable'), nothing updated" '[ $RC = 7 ] && [[ "$ERR" == *sudo* ]] && [[ "$ERR" != *"not reachable"* ]] && ! grep -q "docker update" "$DOCKER_LOG"'

# 8 Status marker
reset; mk adguard false no; mk navidrome false unless-stopped; mk immich_server true always; mk fresh false no
printf 'created\n' >/dev/null
OUT=$(_ps_autostart docker)
echo "---- sample Status data (name|status) ----"; echo "$OUT"; echo "------------------------------------------"
check 8a "stopped + policy no -> 'stopped (autostart off)'" 'grep -qx "adguard|stopped (autostart off)" <<<"$OUT"'
check 8b "stopped + unless-stopped keeps docker status"       'grep -qx "navidrome|Exited (0) 3 hours ago" <<<"$OUT"'
check 8c "running is untouched even with policy always"       'grep -qx "immich_server|Up 2 hours" <<<"$OUT"'
reset; OUT=$(_ps_autostart docker); RC=$?
check 8d "no containers: empty output, rc 0" '[ -z "$OUT" ] && [ $RC = 0 ]'
reset; export DOCKER_DOWN=1; OUT=$(_ps_autostart docker); RC=$?
check 8e "docker down: non-zero (renderer shows nothing, not a lie)" '[ $RC != 0 ]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
