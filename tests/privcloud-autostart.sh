#!/bin/bash
# Tests for privcloud's autostart rule: after `privcloud start` / `privcloud
# update` brings the stack up, every container of the stack ends at restart
# policy unless-stopped (compose's `always` must not survive, and a container
# left at `no` by an earlier stop must be re-armed), and running ones stay up.
# Also covers the `sg docker` re-exec path (docker only works after it).
# Run: bash tests/privcloud-autostart.sh   (exits non-zero on any failure)
# Everything runs in a mktemp sandbox with stubbed docker/sg/curl/id: no real
# docker, no network. PRIVCLOUD=<file> tests another copy of the script.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${PRIVCLOUD:-$H/../privcloud}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app" "$T/c"
cp "$SRC" "$T/app/privcloud"; chmod +x "$T/app/privcloud"
cp "$H/../docker-compose.yml" "$T/app/docker-compose.yml"
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nIMMICH_VERSION=release\n' "$T" "$T" > "$T/app/.env"
# docker stub. One dir per container under $C (files name/running/policy).
# `docker info` fails until PRIVCLOUD_SG_DONE=1 (i.e. until the sg re-exec).
# Knobs: FAIL_UPDATE, FAIL_PS.
cat > "$T/bin/docker" <<'X'
#!/bin/bash
echo "docker $*" >> "$DOCKER_LOG"
C=$DOCKER_STATE
[ "$1" = info ] && { [ "$PRIVCLOUD_SG_DONE" = 1 ]; exit; }
[ "$PRIVCLOUD_SG_DONE" = 1 ] || exit 1
if [ "$1" = compose ]; then
  shift
  while [ "$1" = -f ] || [ "$1" = --env-file ]; do shift 2; done
  case "$1" in
    version) exit 0 ;;
    pull) : > "$STATE_PULLED"; exit 0 ;;
    up) : > "$STATE_UP"; for d in "$C"/*/; do [ -d "$d" ] && echo true > "$d/running"; done; exit 0 ;;
    ps) [ -n "$FAIL_PS" ] && exit 1
        for d in "$C"/*/; do [ -d "$d" ] && { cat "$d/name"; echo; }; done; exit 0 ;;
  esac
  exit 0
fi
case "$1" in
  update) [ -n "$FAIL_UPDATE" ] && exit 1
          pol=${2#--restart=}; shift 2
          for n in "$@"; do d=$C/$n; [ -d "$d" ] || exit 1; echo "$pol" > "$d/policy"; done ;;
  images) [ -e "$STATE_PULLED" ] && echo new123 || echo old123 ;;
  image) echo pruned ;;
esac
exit 0
X
printf '#!/bin/bash\nshift; exec bash -c "$*"\n' > "$T/bin/sg"            # sg docker "cmd"
printf '#!/bin/bash\n[ "$1" = -nG ] && echo "users docker"; exit 0\n' > "$T/bin/id"
printf '#!/bin/bash\n[ -e "$STATE_UP" ] && echo pong; exit 0\n' > "$T/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" DOCKER_STATE=$T/c DOCKER_LOG=$T/docker.log STATE_UP=$T/up.state STATE_PULLED=$T/pulled.state
unset PRIVCLOUD_SG_DONE
PASS=0; FAILN=0
mk() { local d="$T/c/$1"; mkdir -p "$d"; printf '%s' "$1" > "$d/name"; echo "$2" > "$d/running"; echo "$3" > "$d/policy"; }
st() { echo "$(cat "$T/c/$1/running") $(cat "$T/c/$1/policy")"; }
reset() { rm -rf "$T/c" "$STATE_UP" "$STATE_PULLED"; mkdir -p "$T/c"; : > "$DOCKER_LOG"; unset FAIL_UPDATE FAIL_PS; }
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC out='$OUT']"; FAILN=$((FAILN+1)); fi; }
run() { OUT=$("$@" 2>&1 </dev/null); RC=$?; }
runy() { OUT=$(echo y | "$@" 2>&1); RC=$?; }

reset; mk web false no; mk db true always
run "$T/app/privcloud" start
check 1a "start: a stopped policy=no container ends unless-stopped" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ]'
check 1b "start: compose 'always' becomes unless-stopped, container stays running" '[ "$(st db)" = "true unless-stopped" ]'
check 1c "start ran under the sg docker re-exec (docker was unusable before it)" 'grep -q "docker update" "$DOCKER_LOG"'

reset; mk web true unless-stopped
run "$T/app/privcloud" start
check 2a "start: already unless-stopped stays as is" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ]'

reset; mk web false no; export FAIL_UPDATE=1
run "$T/app/privcloud" start
check 3a "start: policy update fails -> reported, non-zero (no silent success)" '[ $RC != 0 ] && [[ "$OUT" == *autostart* ]]'
reset; mk web false no; export FAIL_PS=1
run "$T/app/privcloud" start
check 3b "start: cannot list containers -> reported, non-zero" '[ $RC != 0 ] && [[ "$OUT" == *autostart* ]]'

reset; mk web true always; mk db false no
runy "$T/app/privcloud" update
check 4a "update: applied update re-arms every container to unless-stopped" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ] && [ "$(st db)" = "true unless-stopped" ]'

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
