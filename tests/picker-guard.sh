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
for f in ok fail info warn _shq _svc_power_body _svc_sudo_guard _svc_power_all_body _svc_power _svc_power_all _svc_power_remote \
         _svc_power_all_remote _env_get _data_defaults _drive_verdict _existing_ancestor _dest_drive_verdict _drive_mount_point _require_data_mount _unified_service_picker _picker_data_guard; do
  extract_fn "$f" "$SRC"; done > "$T/fn.sh"
grep -E '^_DRIVE_ROOTS=' "$SRC" >> "$T/fn.sh"
source "$T/fn.sh"
type _unified_service_picker >/dev/null 2>&1 || echo "FAIL  setup: _unified_service_picker not found in $SRC"
# laptop-side stubs
_ts_state() { echo NeedsLogin; }
_ts_ip() { echo 100.64.0.1; }
_ts_start_both() { echo "TS_START" >> "$T/acts.log"; }
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
  *"_ps_autostart docker"*) printf 'navidrome|Exited (0) 1 hour ago\nfilebrowser|Exited (0) 1 hour ago\n'; exit 0 ;;
  *"_ts_state"*) echo Running; exit 0 ;;
  *"_require_data_mount"*) HOME=$FAKE_HOME exec bash -c "$last" ;;
esac
echo "$last" >> "$SSH_LOG"
exit 0
X
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" SSH_LOG=$T/ssh.log FAKE_HOME=$T/home
SERVER_USER=tester SERVER_IP=192.0.2.1
CHECK_DIAG='rc=$RC out='"'"'${OUT:0:200}'"'"
# pick: 3=navidrome 4=filebrowser a=All (Start list: tailscale, syncthing, navidrome, filebrowser, adguard)
go() { : > "$SSH_LOG"; : > "$T/acts.log"; OUT=$(printf '%s\n' "$1" | _unified_service_picker start 2>&1); RC=$?; }
started() { grep -qE 'docker start|compose up' "$SSH_LOG"; }

setdata files; export FINDMNT_SRC=""   # data drive not mounted
go 3; check 1a "navidrome, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go 4; check 1b "filebrowser, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go a; check 1c "All, drive unmounted: refused, no compose up, no laptop-side start" '[ $RC != 0 ] && ! started && [ ! -s "$T/acts.log" ] && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=systemd-1   # autofs placeholder, not a device
go 3; check 1d "navidrome, autofs stub on the drive: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=/dev/sdb1; setdata missing   # mount point gone
go 4; check 1e "filebrowser, mount point missing: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=/dev/sdb1; setdata files
go 3; check 2a "navidrome, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go 4; check 2b "filebrowser, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go a; check 2c "All, drive mounted: compose up runs" '[ $RC = 0 ] && grep -q "compose up" "$SSH_LOG"'

check_total
