#!/bin/bash
# Tests for the data-drive start guard in _unified_service_picker (federver -> 7
# Start): single start of navidrome/filebrowser and Start All must refuse when
# the data drive is not mounted, before any container is started. The picker runs
# on the laptop; the guard has to run on the server, so ssh is a stub that runs
# the "remote" command locally with a fake findmnt and a fake $HOME.
# Run: bash tests/picker-guard.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/privcloud"
GREEN=; RED=; YELLOW=; BLUE=; BOLD=; DIM=; NC=
{ grep -E '^(ok|fail|info|warn)\(\)' "$SRC"
  grep -m1 '^_shq()' "$SRC"
  awk '/^_svc_power_body\(\)/{p=1} p{print} p&&/^_svc_power_all_remote\(\)/{exit}' "$SRC"
  for f in _env_get _require_data_mount _unified_service_picker _picker_data_guard; do
    awk -v f="$f" '$0 ~ "^"f"\\(\\)"{p=1} p{print} p&&/^}/{exit}' "$SRC"; done; } > "$T/fn.sh"
source "$T/fn.sh"
type _unified_service_picker >/dev/null 2>&1 || echo "FAIL  setup: _unified_service_picker not found in $SRC"
# laptop-side stubs
_ts_state() { echo NeedsLogin; }
_ts_ip() { echo 100.64.0.1; }
_ts_start_both() { echo "TS_START" >> "$T/acts.log"; }
_syncthing_start_both() { echo "ST_START" >> "$T/acts.log"; }
systemctl() { return 1; }
printf 'MUSIC_LOCATION=/mnt/data/media\nFILES_LOCATION=/mnt/data\n' > "$T/home/privcloud/.env"
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
[ -n "$FINDMNT_SRC" ] && echo "$FINDMNT_SRC"; exit 0
X
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
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
PASS=0; FAILN=0
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC out='${OUT:0:200}']"; FAILN=$((FAILN+1)); fi; }
# pick: 3=navidrome 4=filebrowser a=All (Start list: tailscale, syncthing, navidrome, filebrowser, adguard)
go() { : > "$SSH_LOG"; : > "$T/acts.log"; OUT=$(printf '%s\n' "$1" | _unified_service_picker start 2>&1); RC=$?; }
started() { grep -qE 'docker start|compose up' "$SSH_LOG"; }

export FINDMNT_SRC=""   # data drive not mounted
go 3; check 1a "navidrome, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go 4; check 1b "filebrowser, drive unmounted: refused, nothing started" '[ $RC != 0 ] && ! started && [[ "$OUT" == *"not mounted"* ]]'
go a; check 1c "All, drive unmounted: refused, no compose up, no laptop-side start" '[ $RC != 0 ] && ! started && [ ! -s "$T/acts.log" ] && [[ "$OUT" == *"not mounted"* ]]'
export FINDMNT_SRC=/dev/sdb1
go 3; check 2a "navidrome, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go 4; check 2b "filebrowser, drive mounted: started" '[ $RC = 0 ] && grep -q "docker start" "$SSH_LOG"'
go a; check 2c "All, drive mounted: compose up runs" '[ $RC = 0 ] && grep -q "compose up" "$SSH_LOG"'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
