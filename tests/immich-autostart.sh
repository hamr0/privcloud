#!/bin/bash
# Tests for the Immich autostart rule in setup.sh: after step_immich_start /
# step_immich_update brings the stack up, every container of the stack ends at
# restart policy unless-stopped (compose's `always` must not survive, and a
# container left at `no` by an earlier stop must be re-armed), and running ones
# stay up. The policy goes through _svc_power (set, start, read back).
# Also covers the `sg docker` re-run path (docker only works after it).
# Run: bash tests/immich-autostart.sh   (exits non-zero on any failure)
# Everything runs in a mktemp sandbox with stubbed docker/sudo/sg/curl/id: no real
# docker, no network. SETUP_SH=<file> tests another copy of setup.sh.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/app" "$T/c"
cp "$H/../docker-compose.yml" "$T/app/docker-compose.yml"
printf 'UPLOAD_LOCATION=%s/up\nDB_DATA_LOCATION=%s/db\nIMMICH_VERSION=release\n' "$T" "$T" > "$T/app/.env"
# The step functions come straight from setup.sh; run.sh is the --run entry.
{
  printf '#!/bin/bash\nGREEN= RED= YELLOW= BOLD= DIM= NC=\nDRY_RUN=0\n_FV_SELF=%q\n' "$T/app/run.sh"
  for f in ok fail info warn _env_get _shq _svc_sudo_guard _svc_power_body _svc_power _immich_compose _immich_up \
           _immich_urls _immich_needs_selinux _immich_fix_permissions _immich_docker_group \
           _immich_ensure_docker _immich_keep_autostart _immich_need_env step_immich_start step_immich_update; do
    extract_fn "$f" "$SRC"
  done
  printf '_IMMICH_ENV=%q\n_IMMICH_COMPOSE=%q\n' "$T/app/.env" "$T/app/docker-compose.yml"
  printf '[ "$1" = --run ] && { "$2"; exit $?; }\n'
} > "$T/app/run.sh"
chmod +x "$T/app/run.sh"
# docker stub. One dir per container under $C (files name/running/policy).
# `docker info` fails until _IMMICH_SG_DONE=1 (i.e. until the sg re-run).
# Knobs: FAIL_UPDATE, FAIL_PS, NOOP_UPDATE (update says ok but changes nothing).
cat > "$T/bin/docker" <<'X'
#!/bin/bash
echo "docker $*" >> "$DOCKER_LOG"
C=$DOCKER_STATE
[ "$1" = info ] && { [ "$_IMMICH_SG_DONE" = 1 ]; exit; }
[ "$_IMMICH_SG_DONE" = 1 ] || exit 1
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
  update) [ -n "$FAIL_UPDATE" ] && exit 1; [ -n "$NOOP_UPDATE" ] && exit 0
          pol=${2#--restart=}; shift 2
          for n in "$@"; do d=$C/$n; [ -d "$d" ] || exit 1; echo "$pol" > "$d/policy"; done ;;
  inspect) shift
           if [ "$1" = -f ]; then d=$C/$3; [ -d "$d" ] || exit 1; echo "$(cat "$d/running") $(cat "$d/policy")"
           else [ -d "$C/$1" ] || exit 1; fi ;;
  start) [ -d "$C/$2" ] || exit 1; echo true > "$C/$2/running" ;;
  images) [ -e "$STATE_PULLED" ] && echo new123 || echo old123 ;;
  image) echo pruned ;;
esac
exit 0
X
printf '#!/bin/bash\nshift; exec bash -c "$*"\n' > "$T/bin/sg"            # sg docker "cmd"
printf '#!/bin/bash\n[ "$1" = -v ] && exit 0\nexec "$@"\n' > "$T/bin/sudo"
printf '#!/bin/bash\n[ "$1" = -nG ] && echo "users docker"; exit 0\n' > "$T/bin/id"
printf '#!/bin/bash\n[ -e "$STATE_UP" ] && echo pong; exit 0\n' > "$T/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" DOCKER_STATE=$T/c DOCKER_LOG=$T/docker.log STATE_UP=$T/up.state STATE_PULLED=$T/pulled.state
unset _IMMICH_SG_DONE
mk() { local d="$T/c/$1"; mkdir -p "$d"; printf '%s' "$1" > "$d/name"; echo "$2" > "$d/running"; echo "$3" > "$d/policy"; }
st() { echo "$(cat "$T/c/$1/running") $(cat "$T/c/$1/policy")"; }
reset() { rm -rf "$T/c" "$STATE_UP" "$STATE_PULLED"; mkdir -p "$T/c"; : > "$DOCKER_LOG"; unset FAIL_UPDATE FAIL_PS NOOP_UPDATE; }
CHECK_DIAG="rc=\$RC out='\$OUT'"
run() { OUT=$("$@" 2>&1 </dev/null); RC=$?; }
runy() { OUT=$(echo y | "$@" 2>&1); RC=$?; }
RUN="$T/app/run.sh --run"

reset; mk web false no; mk db true always
run $RUN step_immich_start
check 1a "start: a stopped policy=no container ends unless-stopped" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ]'
check 1b "start: compose 'always' becomes unless-stopped, container stays running" '[ "$(st db)" = "true unless-stopped" ]'
check 1c "start ran under the sg docker re-run (docker was unusable before it)" 'grep -q "docker update" "$DOCKER_LOG"'

reset; mk web true unless-stopped
run $RUN step_immich_start
check 2a "start: already unless-stopped stays as is" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ]'

reset; mk web false no; export FAIL_UPDATE=1
run $RUN step_immich_start
check 3a "start: policy update fails -> warned (visible), start still reaches Waiting for Immich, rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Could not set autostart"* ]] && [[ "$OUT" == *"Waiting for Immich"* ]]'
reset; mk web false no; export FAIL_PS=1
run $RUN step_immich_start
check 3b "start: cannot list containers -> warned, continues, rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Could not set autostart"* ]] && [[ "$OUT" == *"Waiting for Immich"* ]]'
reset; mk web true always; export FAIL_UPDATE=1
runy $RUN step_immich_update
check 3c "update: policy update fails -> warned, still prints Update applied + prunes, rc 0" '[ $RC = 0 ] && [[ "$OUT" == *"Could not set autostart"* ]] && [[ "$OUT" == *"Update applied"* ]] && grep -q "docker image prune" "$DOCKER_LOG"'
reset; mk web false no
run $RUN step_immich_start
check 3d "start success path: no warning printed" '[ $RC = 0 ] && [[ "$OUT" != *"Could not set autostart"* ]]'

reset; mk web true always; mk db false no
runy $RUN step_immich_update
check 4a "update: applied update re-arms every container to unless-stopped" '[ $RC = 0 ] && [ "$(st web)" = "true unless-stopped" ] && [ "$(st db)" = "true unless-stopped" ] && [[ "$OUT" != *"Could not set autostart"* ]]'

# the read-back: a policy update that "succeeds" but does not stick is a warning, not a silent pass
reset; mk web false no; export NOOP_UPDATE=1
run $RUN step_immich_start
check 5a "start: a policy that did not stick is caught by the read-back (warned, rc 0)" '[ $RC = 0 ] && [[ "$OUT" == *"Could not set autostart"* ]] && [ "$(st web)" = "true no" ]'

# C: the tracked compose file is never edited, whatever SELinux says (it carries :Z, which docker ignores when SELinux is off)
printf '#!/bin/bash\necho "${GE_MODE:-Permissive}"\n' > "$T/bin/getenforce"; chmod +x "$T/bin/getenforce"
cp "$H/../docker-compose.yml" "$T/compose.orig"
for mode in Enforcing Permissive Disabled; do
  cp "$T/compose.orig" "$T/app/docker-compose.yml"; reset; mk web false no; export GE_MODE=$mode
  run $RUN step_immich_start
  check "6-$mode" "start with SELinux $mode: docker-compose.yml is byte-identical afterwards" '[ $RC = 0 ] && cmp -s "$T/app/docker-compose.yml" "$T/compose.orig" && [ ! -e "$T/app/docker-compose.yml.bak" ]'
done
cp "$T/compose.orig" "$T/app/docker-compose.yml"; reset; mk web true always; export GE_MODE=Permissive
runy $RUN step_immich_update
check 6u "update with SELinux off: docker-compose.yml is byte-identical afterwards" '[ $RC = 0 ] && cmp -s "$T/app/docker-compose.yml" "$T/compose.orig"'
check 6z "the committed compose file carries :Z on both Immich bind mounts" '[ "$(grep -c ":Z$" "$H/../docker-compose.yml")" = 2 ]'

check_total
