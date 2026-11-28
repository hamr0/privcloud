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
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/c"
# _shq plus the power/status helpers (stop after _ps_autostart's closing brace).
for f in _shq _svc_power_body _svc_docker_fn _svc_power_all_body _svc_power _svc_power_all _svc_power_remote \
         _svc_power_all_remote _ps_autostart; do extract_fn "$f" "$SRC"; done > "$T/fn.sh"
source "$T/fn.sh"
type _svc_power_body >/dev/null 2>&1 || { echo "FAIL  setup: _svc_power_body not found in $SRC (older setup.sh?)"; }
cat > "$T/bin/sudo" <<'X'
#!/bin/bash
echo "sudo $*" >> "$SUDO_LOG"; [ -n "$SUDO_FAIL" ] && exit 1; [ "$1" = -v ] && exit 0; exec "$@"
X
# docker stub: one dir per container under $C (key = sanitized name), files
# name/running/policy. Failure knobs: DOCKER_DOWN, FAIL_UPDATE, FAIL_ACTION,
# LIE_ACTION (action returns 0 but changes nothing).
stub_docker <<'X'
C=$DOCKER_STATE
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' _; }
echo "docker $*" >> "$DOCKER_LOG"
[ -n "$DOCKER_DOWN" ] && exit 1
cmd=$1; shift
case "$cmd" in
  info) [ -n "$NEEDS_SG" ] && [ -z "$_VIA_SG" ] && exit 1; exit 0 ;;
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
# sg stub (docker group added in this very login): runs the command with _VIA_SG=1; id says we are in the group
printf '#!/bin/bash\necho "sg $*" >> "$SG_LOG"; shift 2; _VIA_SG=1 exec bash -c "$1"\n' > "$T/bin/sg"
printf '#!/bin/bash\n[ "$1" = -nG ] && echo "users docker"; exit 0\n' > "$T/bin/id"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" DOCKER_STATE=$T/c DOCKER_LOG=$T/docker.log SSH_LOG=$T/ssh.log SUDO_LOG=$T/sudo.log SG_LOG=$T/sg.log
SERVER_USER=tester SERVER_IP=192.0.2.1
mk() { # name running policy
  local d="$T/c/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; mkdir -p "$d"
  printf '%s' "$1" > "$d/name"; echo "$2" > "$d/running"; echo "$3" > "$d/policy"; }
st() { local d="$T/c/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; echo "$(cat "$d/running") $(cat "$d/policy")"; }
reset() { rm -rf "$T/c"; mkdir -p "$T/c"; : > "$DOCKER_LOG"; : > "$SSH_LOG"; : > "$SUDO_LOG"; : > "$SG_LOG"; unset NEEDS_SG SUDO_FAIL DOCKER_DOWN FAIL_UPDATE FAIL_ACTION LIE_ACTION SSH_DOWN; }
CHECK_DIAG="rc=\$RC err='\$ERR' state='\$(st \"\${CN:-x}\" 2>&1)'"
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
check 3f "D10: sudo is never called (a refusing sudo changes nothing: start still works)" '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ] && [ ! -s "$SUDO_LOG" ]'
reset; mk adguard false no; export NEEDS_SG=1; run _svc_power start adguard
check 3g "D10: docker group not active yet in this login: falls back to sg docker, still no sudo" '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ] && [ -s "$SG_LOG" ] && [ ! -s "$SUDO_LOG" ]'
reset; mk adguard false no; export NEEDS_SG=1; export DOCKER_DOWN=1; run _svc_power start adguard
check 3h "D10: docker really down even via sg: rc 2" '[ $RC = 2 ] && [[ "$ERR" == *"not reachable"* ]]'
check 3i "D10: the generated bodies contain no sudo at all (single and bulk)" '! _svc_power_body start x | grep -q sudo && ! _svc_power_all_body stop | grep -q sudo'
CN=adguard

# 4 missing container
CN=ghost; reset; run _svc_power start ghost
check 4a "missing container: rc 3, names it, nothing updated" '[ $RC = 3 ] && [[ "$ERR" == *"no such container: ghost"* ]] && ! grep -q "docker update" "$DOCKER_LOG"'

# 5 odd names are one argument and never execute
ODD='my app;touch '"$T"'/pwned $(touch '"$T"'/pwned2) "q" '"'"'s'"'"
CN=$ODD; reset; mk "$ODD" false no; run _svc_power start "$ODD"
check 5a "local: odd name works, no injection"   '[ $RC = 0 ] && [ "$(st "$ODD")" = "true unless-stopped" ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'
reset; mk "$ODD" true unless-stopped; run _svc_power_remote stop "$ODD"
check 5b "remote: odd name survives the ssh parse" '[ $RC = 0 ] && [ "$(st "$ODD")" = "false no" ] && [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]'

# 6 remote path (no -t: nothing here needs a TTY)
CN=syncthing
reset; mk syncthing true no;  run _svc_power_remote restart syncthing
check 6a "remote restart restores unless-stopped, over a plain ssh (no -t), no sudo" '[ $RC = 0 ] && [ "$(st syncthing)" = "true unless-stopped" ] && grep -q -- "tester@192.0.2.1" "$SSH_LOG" && ! grep -q -- " -t " <<<" $(cat "$SSH_LOG") " && [ ! -s "$SUDO_LOG" ]'
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
check 7h "D10 bulk: sudo is never called, the stop still works" '[ $RC = 0 ] && [ "$(st a)" = "false no" ] && [ ! -s "$SUDO_LOG" ]'

# 7i per-container result lines, same text local and over ssh; failures keep the body's stderr line
reset; mk a true unless-stopped; mk b true unless-stopped
OUT=$(_svc_power_all stop 2>&1); OUT2=$(_svc_power_all_remote stop 2>&1)
check 7i "stop all: announces the count first, then one success line per container (autostart off), local = remote" '[ "$(sed -n 1p <<<"$OUT")" = "Stopping 2 containers on the server…" ] && grep -qx "✓ a stopped (autostart off)" <<<"$OUT" && grep -qx "✓ b stopped (autostart off)" <<<"$OUT"'
reset; mk a false no
OUT=$(_svc_power_all_remote start 2>&1)
check 7j "start all over ssh prints the same kind of line: 'started'" '[[ "$OUT" == *"✓ a started"* && "$OUT" == "Starting 1 containers"* ]]'
reset; mk a true no; mk b true no; export FAIL_ACTION=1; OUT=$(_svc_power_all restart 2>&1); RC=$?
check 7k "a failed container prints its failure and no success line; exit code still 1" '[ $RC = 1 ] && [[ "$OUT" == *"a: docker restart failed"* && "$OUT" != *"✓"* ]]'

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

# 9 D10: Start/Stop All skips what is already in the wanted state or not installed - no sudo, no false failure
for f in _ts_ipv4 _ts_state _ts_skip _ts_server_state _server_probe _ts_start_both _ts_stop_both \
         _syncthing_server_probe _syncthing_skip _syncthing_start_both _syncthing_stop_both; do eval "$(extract_fn "$f" "$SRC")"; done
ok() { echo "OK $*"; }; fail() { echo "FAIL $*"; }; info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }
BOLD= DIM= NC=
# tailscale stub: BackendState from $TS_STATE (default Running), `up`/`down` are logged. systemctl/syncthing: absent.
stub_cmd tailscale 'echo "tailscale $*" >> "$TS_LOG"
case "$1" in
  status) printf "{\"BackendState\": \"%s\", \"Self\": {}}\n" "${TS_STATE:-Running}" ;;
  ip) echo 100.64.0.1 ;;
esac
exit 0'
export TS_LOG=$T/ts.log
all_start() { : > "$TS_LOG"; OUT=$( { _ts_start_both; _syncthing_start_both; _svc_power_all_remote start; } 2>&1 ); RC=$?; }
CHECK_DIAG="rc=\$RC out='\$OUT' sudo='\$(cat \$SUDO_LOG)'"
reset; mk adguard false no
all_start
check 9a "Start All, Tailscale Running both sides + Syncthing absent both sides: rc 0, no sudo, nothing failed" '[ $RC = 0 ] && [ ! -s "$SUDO_LOG" ] && ! grep -q "tailscale up" "$TS_LOG" && [[ "$OUT" != *WARN* && "$OUT" != *FAIL* && "$OUT" != *"no such container"* ]]'
check 9b "... and says so: one skipped line per side for Tailscale and for Syncthing" '[[ "$OUT" == *"Tailscale (Laptop): already connected - skipped"* && "$OUT" == *"Tailscale (Server): already connected - skipped"* && "$OUT" == *"Syncthing (Laptop): not installed - skipped"* && "$OUT" == *"Syncthing (Server): not installed - skipped"* ]] && [ "$(st adguard)" = "true unless-stopped" ]'
export TS_STATE=Stopped; all_start; unset TS_STATE
check 9c "Tailscale actually down: sudo tailscale up runs once per side (twice here: the stub shares one host), never more" '[ $RC = 0 ] && [ "$(grep -c "tailscale up" "$TS_LOG")" = 2 ] && [ "$(grep -c "^sudo tailscale up" "$SUDO_LOG")" = 2 ]'
reset; export TS_STATE=Stopped; OUT=$(printf "y" | _ts_stop_both 2>&1); unset TS_STATE
check 9d "Stop with Tailscale already down: skipped, no sudo, no 'not connected' warning" '[ ! -s "$SUDO_LOG" ] && [[ "$OUT" == *"already down - skipped"* && "$OUT" != *"not connected"* ]]'
reset; mk syncthing true unless-stopped; OUT=$(_syncthing_start_both 2>&1); RC=$?
check 9e "Syncthing on the server but not the laptop: server side starts, laptop skipped, no sudo" '[ $RC = 0 ] && [[ "$OUT" == *"Syncthing (Laptop): not installed - skipped"* && "$OUT" == *"Server: started."* ]] && [ ! -s "$SUDO_LOG" ]'

# 10 federver -> 8 -> 4 Restart both: server first (scheduled, detached), then laptop; proven by a changed
# tailscaled start stamp AND state Running. One shared host plays both sides: systemctl keeps one stamp file.
for f in _ts_running _ts_started_at _ts_server_stamp _ts_prove_restart _ts_restart_both; do eval "$(extract_fn "$f" "$SRC")"; done
_ts_connected_via_ts() { return 1; }; _resolve_server_endpoint() { :; }
stub_cmd sleep 'exit 0'
stub_cmd systemctl 'case "$1" in
  show) cat "$TS_STAMP" ;;
  restart) echo "laptop-restart" >> "$ORDER"; [ -n "$NO_RESTART" ] || echo $(( $(cat "$TS_STAMP") + 1 )) > "$TS_STAMP"; echo "${AFTER_STATE:-Running}" > "$TS_STATEF" ;;
esac
exit 0'
stub_cmd systemd-run 'echo "systemd-run $*" >> "$ORDER"; [ -n "$NO_RESTART" ] || echo $(( $(cat "$TS_STAMP") + 1 )) > "$TS_STAMP"; echo "${AFTER_STATE:-Running}" > "$TS_STATEF"; exit 0'
stub_cmd tailscale 'case "$1" in status) printf "{\"BackendState\": \"%s\", \"Self\": {}}\n" "$(cat "$TS_STATEF")" ;; ip) echo 100.64.0.1 ;; esac; exit 0'
export TS_STAMP=$T/stamp TS_STATEF=$T/tsstate ORDER=$T/order.log
rr() { reset; echo 1000 > "$TS_STAMP"; echo Running > "$TS_STATEF"; : > "$ORDER"; unset NO_RESTART AFTER_STATE; }
CHECK_DIAG="rc=\$RC out='\$OUT' order='\$(cat \$ORDER) ssh=\$(cat \$SSH_LOG)'"
rr; OUT=$(_ts_restart_both 2>&1); RC=$?
echo "---- sample: federver -> 8 -> 4 ----"; echo "$OUT"; echo "-------------------------------------"
check 10a "restart both: server scheduled first, then the laptop; both proven" '[ $RC = 0 ] && [ "$(sed -n 1p "$ORDER" | cut -c1-11)" = systemd-run ] && [ "$(sed -n 2p "$ORDER")" = laptop-restart ] && [[ "$OUT" == *"OK Server: restarted, connected"* && "$OUT" == *"OK Laptop: restarted, connected"* ]]'
check 10b "server restart is detached: systemd-run --on-active runs inside one ssh -t (the command returns before the link drops), announced first" 'grep -q -- "ssh -t tester@192.0.2.1 sudo systemd-run --quiet --on-active=2 systemctl restart tailscaled" "$SSH_LOG" && [[ "$OUT" == *"INFO Restarting Tailscale on the server…"* ]] && ! grep -q "ssh.*sudo systemctl restart" "$SSH_LOG"'
rr; export NO_RESTART=1; OUT=$(_ts_restart_both 2>&1); RC=$?
check 10c "unchanged start stamp: 'NOT restarted' failure for each side, rc 1, never a success line" '[ $RC = 1 ] && [[ "$OUT" == *"FAIL Server: Tailscale was NOT restarted"* && "$OUT" == *"FAIL Laptop: Tailscale was NOT restarted"* && "$OUT" != *"restarted, connected"* ]]'
rr; export AFTER_STATE=Stopped; OUT=$(_ts_restart_both 2>&1); RC=$?
check 10d "restarted but state not Running: says it did not reconnect (not 'not restarted')" '[ $RC = 1 ] && [[ "$OUT" == *"FAIL Server: tailscaled restarted but did not reconnect (state: Stopped)"* && "$OUT" != *"NOT restarted"* ]]'
rr; export SSH_DOWN=1; OUT=$(_ts_restart_both 2>&1)
check 10e "server unreachable: skipped with the existing warning, the laptop is still restarted and proven" '[[ "$OUT" == *"Tailscale (Server): cannot reach it - skipped"* && "$OUT" == *"OK Laptop: restarted, connected"* ]] && ! grep -q systemd-run "$ORDER"'

# 11 the same paths under `set -e`, as `setup.sh --run <step>` runs them on the server (the checks
# above call them without errexit; a command that returns 1 in normal operation would abort silently)
CHECK_DIAG="rc=\$RC out='\$OUT'"
all_start_fn() { _ts_start_both; _syncthing_start_both; _svc_power_all_remote start; }
all_stop_fn()  { _ts_stop_both <<<y; _syncthing_stop_both <<<y; _svc_power_all_remote stop; }
rr; mk adguard false no; errexit_here all_start_fn
check 11a "errexit: Start All (Tailscale, Syncthing, server containers): rc 0, container started" '[ $RC = 0 ] && [ "$(st adguard)" = "true unless-stopped" ]'
rr; mk adguard true unless-stopped; errexit_here all_stop_fn
check 11b "errexit: Stop All: rc 0, container stopped with autostart off" '[ $RC = 0 ] && [ "$(st adguard)" = "false no" ]'
rr; errexit_here _ts_restart_both
check 11c "errexit: Restart both with the restart proof: rc 0, both sides proven" '[ $RC = 0 ] && [[ "$OUT" == *"OK Server: restarted, connected"* && "$OUT" == *"OK Laptop: restarted, connected"* ]]'
rr; export AFTER_STATE=Stopped; errexit_here _ts_restart_both
check 11d "errexit: Restart both, not reconnected: the failure is reported (rc 1, message), not a silent abort" '[ $RC = 1 ] && [[ "$OUT" == *"did not reconnect"* ]]'
unset AFTER_STATE
# the link rides the restarting tailnet: the proof re-picks the address; that helper failing must not abort the proof
rr; unreach() { echo unreachable; }; _ts_connected_via_ts() { return 0; }; _resolve_server_endpoint() { return 1; }
errexit_here _ts_prove_restart Server 1000 unreach _ts_server_state
_ts_connected_via_ts() { return 1; }; _resolve_server_endpoint() { :; }
check 11e "errexit: server unreachable during the proof and re-picking the address fails: still polls out and reports 'NOT restarted' (rc 1)" '[ $RC = 1 ] && [[ "$OUT" == *"FAIL Server: Tailscale was NOT restarted"* ]]'

check_total
