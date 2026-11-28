#!/bin/bash
# Tests for the data-drive start guard in _unified_service_picker (federver -> 7
# Start): single start of navidrome/filebrowser and Start All must refuse when
# the data drive is not mounted, before any container is started. The picker runs
# on the laptop; the guard has to run on the server, so ssh is a stub that runs
# the "remote" command locally with a fake findmnt and a fake $HOME.
# Run: bash tests/picker-guard.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/privcloud"
GREEN=; RED=; YELLOW=; BLUE=; BOLD=; DIM=; NC=
for f in ok fail info warn _shq _svc_power_body _svc_docker_fn _svc_power_all_body _svc_power _svc_power_all _svc_power_remote \
         _svc_power_all_remote _compose _compose_up_quiet _env_get _data_defaults _drive_verdict _existing_ancestor _dest_drive_verdict _drive_mount_point _require_data_mount _unified_service_picker _picker_data_guard; do
  extract_fn "$f" "$SRC"; done > "$T/fn.sh"
grep -E '^_DRIVE_ROOTS=' "$SRC" >> "$T/fn.sh"
source "$T/fn.sh"
type _unified_service_picker >/dev/null 2>&1 || echo "FAIL  setup: _unified_service_picker not found in $SRC"
# laptop-side stubs
# Tailscale is federver -> 8 only: any call to it from the picker is a bug, so every entry point logs
_ts_state() { echo "TS_STATE" >> "$T/acts.log"; }
_ts_start_both() { echo "TS_START" >> "$T/acts.log"; }
_ts_stop_both() { echo "TS_STOP" >> "$T/acts.log"; }
_ts_restart_both() { echo "TS_RESTART" >> "$T/acts.log"; }
_syncthing_stop_both() { echo "ST_STOP" >> "$T/acts.log"; }
stub_cmd tailscale 'echo "tailscale $*" >> "$ACTS"; exit 0'
export ACTS=$T/acts.log
_syncthing_start_both() { echo "ST_START" >> "$T/acts.log"; }
systemctl() { return 1; }
stub_findmnt <<'X'
[ -n "$FINDMNT_SRC" ] && echo "$FINDMNT_SRC"; exit 0
X
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
# The data drive's mount point lives in the sandbox ($T/mnt/data, under the drive root the
# guard is shipped with): setdata files | missing makes it a folder with files, or removes it.
_DRIVE_ROOTS="$T/mnt"
setdata() { rm -rf "$T/mnt/data"; [ "$1" = missing ] || { mkdir -p "$T/mnt/data"; echo f > "$T/mnt/data/f"; }; }
printf 'MUSIC_LOCATION=%s/mnt/data/media\nFILES_LOCATION=%s/mnt/data\n' "$T" "$T" > "$T/home/privcloud/.env"
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
for a in "$@"; do last=$a; done
case "$last" in
  *"_ps_autostart docker"*) printf '%b' "${PS_OUT:-navidrome|Exited (0) 1 hour ago\\nfilebrowser|Exited (0) 1 hour ago\\n}"; exit 0 ;;
  *"_require_data_mount"*) HOME=$FAKE_HOME exec bash -c "$last" ;;
  *"_compose_up_quiet"*) echo "$last" >> "$SSH_LOG"; HOME=$FAKE_HOME exec bash -c "$last" ;;
esac
echo "$last" >> "$SSH_LOG"
exit 0
X
stub_cmd docker 'case "$1" in info) exit 0 ;; compose) echo "Container navidrome Started"; exit ${COMPOSE_RC:-0} ;; esac'   # never the real docker
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" SSH_LOG=$T/ssh.log FAKE_HOME=$T/home
SERVER_USER=tester SERVER_IP=192.0.2.1
CHECK_DIAG='rc=$RC out='"'"'${OUT:0:200}'"'"
# pick: 2=navidrome 3=filebrowser a=All (Start list: syncthing, navidrome, filebrowser, adguard - Tailscale is federver -> 8 only)
go() { : > "$SSH_LOG"; : > "$T/acts.log"; OUT=$(printf '%s\n' "$1" | _unified_service_picker start 2>&1); RC=$?; }
started() { grep -qE 'docker start|compose up' "$SSH_LOG"; }

setdata files; export FINDMNT_SRC=""   # data drive not mounted
go 2; check 1a "navidrome, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go 3; check 1b "filebrowser, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go a; check 1c "All, drive unmounted: refused, no compose up, no laptop-side start" '[ $RC != 0 ] && ! started && [ ! -s "$T/acts.log" ] && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=systemd-1   # autofs placeholder, not a device
go 2; check 1d "navidrome, autofs stub on the drive: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=/dev/sdb1; setdata missing   # mount point gone
go 3; check 1e "filebrowser, mount point missing: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=/dev/sdb1; setdata files
go 2; check 2a "navidrome, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go 3; check 2b "filebrowser, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go a; check 2c "All, drive mounted: compose up runs" '[ $RC = 0 ] && grep -q "compose up" "$SSH_LOG"'


# 3 All = one question. Stop All, Syncthing installed nowhere, Tailscale up: skips listed BEFORE the single
# confirmation, one 'y' is enough, no Tailscale or Syncthing prompt, no tailscale command, one line per container.
export PS_OUT='navidrome|Up 2 hours\nfilebrowser|Up 2 hours\n'
# stdin 'a','y' then a sentinel line: whatever the picker did not read is echoed back as REST=, so a second read shows
stopgo() { : > "$SSH_LOG"; : > "$T/acts.log"; OUT=$(printf 'a\ny\nSENTINEL\n' | { _unified_service_picker stop; echo "RC=$? REST=$(cat | tr -d '\n')"; } 2>&1); RC=${OUT##*RC=}; RC=${RC%% *}; }
stopgo
echo "---- sample: Stop All screen ----"; echo "$OUT"; echo "---------------------------------"
check 3a "Stop All: exactly one confirmation, answered by a single 'y' (the sentinel line is never read)" '[ $RC = 0 ] && [[ "$OUT" == *"REST=SENTINEL"* ]] && [ "$(grep -c "\[y/N\]" <<<"$OUT")" = 1 ] && [[ "$OUT" != *Disconnect* && "$OUT" != *"Stop Syncthing"* && "$OUT" != *Cancelled* ]]'
check 3b "Stop All: Syncthing skips are printed before the question" 'awk "/Syncthing \(laptop\): not installed - skipped/{a=NR} /Syncthing \(server\): not installed - skipped/{b=NR} /\[y\/N\]/{c=NR} END{exit !(a&&b&&a<c&&b<c)}" <<<"$OUT"'
check 3c "Stop All: no tailscale command, no _ts_* call; the containers are stopped over one ssh" '! grep -q "TS\|tailscale" "$T/acts.log" && [ "$(grep -c "docker stop\|docker update" "$SSH_LOG")" -ge 1 ] && [[ "$OUT" == *"Tailscale: not touched"* && "$OUT" == *"2 server containers (navidrome, filebrowser)"* ]]'
: > "$SSH_LOG"; OUT=$(printf 'a\nn\n' | _unified_service_picker stop 2>&1)
check 3d "Stop All answered n: Cancelled, nothing sent to the server" '[[ "$OUT" == *Cancelled* ]] && ! grep -q "docker stop" "$SSH_LOG"'
export FINDMNT_SRC=/dev/sdb1; setdata files
: > "$T/acts.log"; OUT=$(printf 'a\n' | _unified_service_picker restart 2>&1)
check 3e "Restart All: no question at all, no tailscale" '[[ "$OUT" != *"[y/N]"* ]] && ! grep -q "TS\|tailscale" "$T/acts.log"'
check 3f "the picker lists no Tailscale row and points at federver -> 8" '! grep -qE "^ +[0-9]+\) +Tailscale" <<<"$OUT" && ! grep -q "ts_laptop\|ts_server" <(extract_fn _unified_service_picker "$SRC") && [[ "$OUT" == *"Tailscale: federver -> 8"* ]]'

# 4 Start All runs compose up quietly: its raw "Container X Started" lines stay off the screen, but show on failure
export FINDMNT_SRC=/dev/sdb1; setdata files; export PS_OUT='navidrome|Exited (0) 1 hour ago\n'
go a
check 4a "Start All: compose up ran, its raw 'Container ... Started' lines are not on screen" '[ $RC = 0 ] && grep -q "_compose_up_quiet" "$SSH_LOG" && [[ "$OUT" != *"Container navidrome"* ]]'
export COMPOSE_RC=1; go a
check 4b "Start All: compose up failing shows its output and a fail line, and the run fails" '[ $RC != 0 ] && [[ "$OUT" == *"Container navidrome Started"* && "$OUT" == *"docker compose up failed"* ]]'
unset COMPOSE_RC
check_total
