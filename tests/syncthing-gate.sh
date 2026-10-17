#!/bin/bash
# Tests for the laptop-side Syncthing gate in setup.sh (step_syncthing ->
# _syncthing_server_probe verify -> _two_sided_gate). When docker on the server
# can't be queried the gate must stop ("changing nothing"), not read it as "not
# installed" and offer an install. Not installed still offers it; running is
# unchanged.
# Run: bash tests/syncthing-gate.sh   (exits non-zero on any failure)
# Stubbed ssh/docker/syncthing/systemctl: no real server, no network.
# SETUP_SH=<file> tests another copy of setup.sh (fail-first check).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/nolap"
BOLD= DIM= RED= GREEN= YELLOW= BLUE= NC=
ok()   { echo "O: $1"; }; fail() { echo "F: $1"; }; info() { echo "I: $1"; }; warn() { echo "W: $1"; }
for f in _server_probe _syncthing_server_probe _two_sided_gate step_syncthing; do
  awk -v f="^$f\\\\(\\\\)" '$0 ~ f{p=1} p{print} p&&/^}/{exit}' "$SRC"
done > "$T/fn.sh"
source "$T/fn.sh"
_is_server() { return 1; }
_syncthing_install_laptop() { echo "CALLED install-laptop" >> "$T/calls"; }
_syncthing_server_step()    { echo "CALLED server-step" >> "$T/calls"; }
_on_server()                { echo "CALLED on-server $*" >> "$T/calls"; }
_syncthing_uninstall_both() { echo "CALLED uninstall" >> "$T/calls"; }
cat > "$T/bin/ssh" <<'X'
#!/bin/bash
[ -n "$SSH_DOWN" ] && exit 255
for a in "$@"; do last=$a; done
[ "$last" = -s ] && exec bash -s
exec bash -c "$last"
X
cat > "$T/bin/docker" <<'X'
#!/bin/bash
[ -n "$DOCKER_DOWN" ] && exit 1
case "$1 $2" in
  "ps -a") [ -n "$ST_EXISTS" ] && echo syncthing ;;
  "ps --format") [ "$ST_EXISTS" = running ] && echo syncthing ;;
esac
exit 0
X
printf '#!/bin/bash\nexit 0\n' > "$T/bin/syncthing"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/systemctl"
chmod +x "$T/bin/"*
# PATH without the syncthing stub = "not installed on the laptop"
mkdir -p "$T/binlap"; cp "$T/bin/syncthing" "$T/binlap/"
BASEPATH=$PATH
export PATH="$T/bin:$BASEPATH"; rm -f "$T/bin/syncthing"
SERVER_USER=tester SERVER_IP=192.0.2.1
PASS=0; FAILN=0
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC out='$OUT' calls='$(cat $T/calls 2>/dev/null)']"; FAILN=$((FAILN+1)); fi; }
# gate <laptop-installed 0|1> <stdin>; env: DOCKER_DOWN, ST_EXISTS
gate() {
  rm -f "$T/calls"
  if [ "$1" = 1 ]; then export PATH="$T/binlap:$T/bin:$BASEPATH"; else export PATH="$T/bin:$BASEPATH"; fi
  OUT=$(step_syncthing <<<"$2" 2>&1); RC=$?
}

unset DOCKER_DOWN ST_EXISTS
DOCKER_DOWN=1 gate 1 1
check 1 "docker down + laptop installed: fails, 'Cannot query docker', no install offered, nothing called" '[ $RC = 1 ] && [[ "$OUT" == *"Cannot query docker on the server - changing nothing."* && "$OUT" != *"Install the missing side"* ]] && [ ! -e "$T/calls" ]'
DOCKER_DOWN=1 gate 0 y
check 2 "docker down + nothing on laptop: fails too, installs nothing" '[ $RC = 1 ] && [[ "$OUT" != *"Install it now"* ]] && [ ! -e "$T/calls" ]'
SSH_DOWN=1 gate 1 1
check 3 "server unreachable: still 'Cannot reach the server', rc 1" '[ $RC = 1 ] && [[ "$OUT" == *"Cannot reach the server"* ]] && [ ! -e "$T/calls" ]'
gate 1 1
check 4 "not installed on server, laptop installed: still offers to install the missing side" '[[ "$OUT" == *"Install the missing side"* ]] && grep -q "CALLED on-server" "$T/calls"'
gate 0 y
check 5 "not installed anywhere: still offers the install (y installs the laptop side)" '[[ "$OUT" == *"isn'"'"'t installed"* ]] && grep -q "CALLED install-laptop" "$T/calls"'
ST_EXISTS=running gate 1 0
check 6 "running on both: gate passes, shows the unified Laptop/Server status" '[ $RC = 0 ] && [[ "$OUT" == *"── Server ──"* && "$OUT" != *"Install the missing side"* && "$OUT" != *"Cannot"* ]]'
ST_EXISTS=stopped gate 1 0
check 7 "stopped on server + laptop installed: gate passes" '[[ "$OUT" == *"── Server ──"* && "$OUT" != *"Install the missing side"* ]]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
