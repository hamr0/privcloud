#!/bin/bash
# Drive-mount verdict (cleanup step 3, piece 1): every place that asks "is this
# path really on a mounted drive?" must answer the same for the same path.
# Section P pins what each member does today on the shared findmnt-stub cases
# (ok / missing / empty / bare folder / autofs stub / findmnt absent); later
# sections cover _drive_verdict and the callers that map it.
# Run: bash tests/drive-mount.sh   (non-zero on any failure)
# SETUP_SH=<file> tests another copy of setup.sh (fail-first runs).
# No sudo, no network, no real mounts: findmnt/df/mountpoint/lsblk/sleep/ls are
# stubs, the folders are in a mktemp sandbox.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$H/lib.sh"
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=
for f in ok fail info warn _env_get _mirror_guard _smb_folder_check _smb_folder_reason _require_data_mount _storage_status _pick_backup_default; do
  extract_fn "$f" "$SRC"; done > "$T/fn.sh"
extract_fn _drive_verdict "$SRC" >> "$T/fn.sh"; grep -E '^_DRIVE_ROOTS=' "$SRC" >> "$T/fn.sh"
sed -i "s#/run/media/\*/\* /media/\*/\* /mnt/\*#$T/mnt/*#" "$T/fn.sh"   # candidate glob -> sandbox
source "$T/fn.sh"
_storage_check_fstab_options() { :; }

# findmnt answers by $FM_MODE: ok = the drive's own device; stub = autofs
# placeholder (SOURCE systemd-1); bare = a plain folder on the system disk
# (-T resolves to / ; an exact-target lookup finds nothing); none = nothing.
stub_findmnt <<'X'
case "$*" in *TARGET*) col=T;; *) col=S;; esac
case "$*" in *" -T "*) tflag=1;; esac
case "${FM_MODE:-ok}" in
  ok)   [ $col = T ] && echo "$FM_ROOT" || echo /dev/sdb1 ;;
  stub) [ $col = T ] && echo "$FM_ROOT" || echo systemd-1 ;;
  bare) [ -n "$tflag" ] && { [ $col = T ] && echo / || echo /dev/nvme0n1p2; } ;;
  none) : ;;
esac
exit 0
X
printf '#!/bin/bash\necho "$*" >> "$SLEEP_LOG"\n' > "$T/bin/sleep"
printf '#!/bin/bash\n:\n' > "$T/bin/lsblk"
cat > "$T/bin/df" <<'X'
#!/bin/bash
p="${@: -1}"
case "$p" in "$SRC_DIR"*) echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/nvme0n1p2 100 1 100 1% /" ;;
  *) echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/sdb1 9000 1 5000 1% /x" ;; esac
X
# ls answers for the fake data-drive mount point /mnt/data (which cannot exist in a sandbox):
# LS_DATA = files | empty | missing; everything else is the real ls.
REAL_LS=$(command -v ls)
cat > "$T/bin/ls" <<X
#!/bin/bash
case "\$*" in *"/mnt/data"*)
  case "\${LS_DATA:-files}" in files) echo lost+found; exit 0 ;; empty) exit 0 ;; missing) exit 2 ;; esac ;; esac
exec $REAL_LS "\$@"
X
chmod +x "$T/bin/"*
# A PATH with the usual tools but no findmnt (stubs where the suite has one).
mkdir -p "$T/lsonly"; for c in ls sleep lsblk df; do ln -sf "$T/bin/$c" "$T/lsonly/$c"; done
for c in cut awk grep sed tr head tail cat date wc; do ln -sf "$(command -v $c)" "$T/lsonly/$c"; done
export SLEEP_LOG=$T/sleeps
export PATH="$T/bin:$PATH" FM_ROOT="$T/mnt/usb" SRC_DIR="$T/src"
mkdir -p "$T/mnt/usb/data" "$T/mnt/usb/empty" "$T/src"; echo f > "$T/mnt/usb/data/f"
D=$T/mnt/usb/data; E=$T/mnt/usb/empty; M=$T/mnt/usb/nope
CHECK_DIAG='got=$GOT'
_DRIVE_ROOTS="$T/mnt /mnt"   # the sandbox stands in for /mnt; the real /mnt is for the fake data-drive mount point (production value: R)

# ── P  pins: today's answers, per member and per case ───────────────────────
# mirror (_mirror_guard -> its reason text; it asks _drive_verdict)
mg() { ( export FM_MODE=$1; _mirror_guard local "$2" && echo ok || echo "$_mirror_why" ); }
mnofm() { env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; _mirror_guard local $1 && echo ok || echo \"\$_mirror_why\""; }
GOT=$(mg ok "$D");   check P1a "mirror: real mount, files -> allowed" '[ "$GOT" = ok ]'
GOT=$(mg ok "$M");   check P1b "mirror: missing path -> source missing" '[ "$GOT" = "source missing" ]'
GOT=$(mg ok "$E");   check P1c "mirror: empty dir -> source empty" '[ "$GOT" = "source empty" ]'
GOT=$(mg bare "$D"); check P1d "mirror: bare folder on the system disk -> drive not mounted" '[ "$GOT" = "drive not mounted" ]'
GOT=$(mg stub "$D"); check P1e "mirror: autofs stub (SOURCE systemd-1) -> drive not mounted" '[ "$GOT" = "drive not mounted" ]'
GOT=$(mnofm "$D");   check P1f "mirror: findmnt absent -> refused (could not check source)" '[ "$GOT" = "could not check source" ]'
GOT=$(mg bare "$E"); check P1g "mirror: empty bare folder (an unplugged drive's leftover) -> refused" '[ "$GOT" != ok ]'

# SMB (_smb_folder_check maps the verdict to ok / missing / unmounted / unknown)
sv() { FM_MODE=$1 _smb_folder_check "$2"; }
GOT=$(sv ok "$D");   check P2a "smb: real mount -> ok" '[ "$GOT" = ok ]'
GOT=$(sv ok "$M");   check P2b "smb: missing -> missing" '[ "$GOT" = missing ]'
GOT=$(sv ok "$E");   check P2c "smb: empty dir on a real mount -> ok (an empty share is fine)" '[ "$GOT" = ok ]'
GOT=$(sv bare "$D"); check P2d "smb: bare folder -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(sv stub "$D"); check P2e "smb: autofs stub -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; _smb_folder_check $D")
check P2f "smb: findmnt absent -> unknown (fails closed: not ok; was 'unmounted' before the merge)" '[ "$GOT" = unknown ]'
GOT=$(sv ok "$T/media/gone"); check P2g "smb: absent folder under /media -> missing" '[ "$GOT" = missing ]'
mkdir -p "$T/media/u/USB"; echo f > "$T/media/u/USB/f"
GOT=$(_DRIVE_ROOTS="$T/mnt $T/media" sv bare "$T/media/u/USB"); check P2h "smb: a /media-style root is now mount-checked: bare folder, drive unplugged -> unmounted (was ok before the merge)" '[ "$GOT" = unmounted ]'
check P2i "smb: refusal wording for each check result" '[ "$(_smb_folder_reason unmounted)" = "drive not mounted" ] && [ "$(_smb_folder_reason missing)" = "folder missing" ] && [ -z "$(_smb_folder_reason ok)" ] && [[ "$(_smb_folder_reason unknown)" == *"cannot check"* ]]'

# start guard (_require_data_mount: /mnt/* only; exact mount point, no existence check)
rq() { FM_MODE=$1 FM_ROOT=/mnt/data LS_DATA=${2:-files} _require_data_mount "${3:-/mnt/data/media}" >/dev/null 2>&1; echo $?; }
GOT=$(rq ok);        check P3a "start guard: real mount -> allowed (rc 0)" '[ "$GOT" = 0 ]'
GOT=$(rq stub);      check P3b "start guard: autofs stub -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq none);      check P3c "start guard: nothing mounted -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq bare);      check P3d "start guard: bare folder -> refused" '[ "$GOT" = 1 ]'
GOT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _require_data_mount /mnt/data >/dev/null 2>&1; echo \$?")
check P3e "start guard: findmnt absent -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq none files /home/x/data); check P3f "start guard: a path outside /mnt is not guarded -> allowed" '[ "$GOT" = 0 ]'
GOT=$(rq ok missing); check P3h "start guard: real mount but the mount point cannot be listed (gone) -> refused (new: the verdict also checks the folder exists)" '[ "$GOT" = 1 ]'
GOT=$(rq ok empty);   check P3i "start guard: freshly formatted (empty) drive on a real mount -> allowed" '[ "$GOT" = 0 ]'
OUT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; BOLD=; NC=; fail() { echo \"\$*\"; }; info() { :; }; _require_data_mount /mnt/data"); check P3j "start guard: findmnt absent says it cannot check (not a wrong 'not mounted')" '[[ "$OUT" == *"Cannot check"*"findmnt is missing"* && "$OUT" != *"not mounted"* ]]'
OUT=$(FM_MODE=stub _require_data_mount /mnt/data 2>&1); check P3g "start guard: refusal names the mount point and says not mounted" '[[ "$OUT" == *"not mounted at /mnt/data"* ]]'

# Storage -> Status block (_storage_status warns for each /mnt/* data path not on a real device)
mkdir -p "$T/sd"; SCRIPT_DIR=$T/sd
printf 'FILES_LOCATION=/mnt/data\nMUSIC_LOCATION=/mnt/data/media\nUPLOAD_LOCATION=/mnt/data/immich\nDB_DATA_LOCATION=/home/x/db\n' > "$T/sd/.env"
st() { FM_MODE=$1 FM_ROOT=/mnt/data LS_DATA=${2:-files} _storage_status 2>&1; }
OUT=$(st ok);   check P4a "status: real mount -> no warning" '[[ "$OUT" != *"NOT mounted"* ]]'
OUT=$(st stub); check P4b "status: autofs stub -> warns once for /mnt/data" '[[ "$OUT" == *"/mnt/data is NOT mounted"* ]] && [ "$(grep -c "NOT mounted" <<<"$OUT")" = 1 ]'
OUT=$(st none); check P4c "status: nothing mounted -> warns" '[[ "$OUT" == *"/mnt/data is NOT mounted"* ]]'
OUT=$(st bare); check P4d "status: bare folder -> warns" '[[ "$OUT" == *"/mnt/data is NOT mounted"* ]]'
OUT=$(env PATH="$T/lsonly" FM_MODE=ok "$(command -v bash)" -c "source $T/fn.sh; BOLD=; NC=; DIM=; RED=; YELLOW=; _storage_check_fstab_options() { :; }; SCRIPT_DIR=$T/sd; _storage_status" 2>&1)
check P4e "status: findmnt absent -> a plain 'cannot check' warning (no false NOT mounted claim)" '[[ "$OUT" == *"Cannot check whether /mnt/data is mounted"* && "$OUT" != *"NOT mounted"* ]]'

OUT=$(st ok empty);   check P4f "status: empty drive on a real mount -> no warning" '[[ "$OUT" != *"NOT mounted"* && "$OUT" != *"Cannot check"* ]]'
OUT=$(st ok missing); check P4g "status: mount point cannot be listed -> NOT mounted" '[[ "$OUT" == *"/mnt/data is NOT mounted"* ]]'

# backup default (_pick_backup_default: candidate must be a dir the verdict calls ok or empty)
bd() { FM_MODE=$1 _pick_backup_default "$SRC_DIR"; }
GOT=$(bd ok);   check P5a "backup default: real mount offered" '[ "$GOT" = "$T/mnt/usb" ]'
GOT=$(bd bare); check P5b "backup default: bare folder not offered" '[ -z "$GOT" ]'
GOT=$(bd stub); check P5c "backup default: autofs stub not offered (mountpoint -q used to be fooled by it)" '[ -z "$GOT" ]'
rmdir "$T/mnt/usb/empty"; rm -rf "$T/mnt/usb/data"; GOT=$(bd ok); check P5d "backup default: a freshly formatted (empty) real drive is offered" '[ "$GOT" = "$T/mnt/usb" ]'
GOT=$(env PATH="$T/lsonly" SRC_DIR=$SRC_DIR "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; _pick_backup_default $SRC_DIR")
check P5e "backup default: findmnt absent -> nothing offered (cannot verify, fail closed)" '[ -z "$GOT" ]'
mkdir -p "$T/mnt/usb/data" "$T/mnt/usb/empty"; echo f > "$T/mnt/usb/data/f"   # restore the fixtures

# ── A  acceptance: one verdict for one fixture, whoever asks ───────────────
# Mirror, SMB, the start guard, Storage Status and the backup default each get the
# same fixture (drive state x folder state) and must accept or refuse as the one
# verdict says. The first four ask about /mnt/data (faked by the ls stub: LS_DATA);
# the backup default lists the sandbox drive $T/mnt/usb in the same state.
cat > "$T/acc.sh" <<X
source $T/fn.sh
_DRIVE_ROOTS="$T/mnt /mnt"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; NC=; SCRIPT_DIR=$T/sd
_storage_check_fstab_options() { :; }
printf 'FILES_LOCATION=/mnt/data\nMUSIC_LOCATION=/home/x/m\nUPLOAD_LOCATION=/home/x/u\nDB_DATA_LOCATION=/home/x/db\n' > $T/sd/.env
v=\$(_drive_verdict /mnt/data)
m=refuse; _mirror_guard local /mnt/data && m=accept
c=\$(_smb_folder_check /mnt/data); sm=refuse; [ "\$c" = ok ] && sm=accept
g=accept; _require_data_mount /mnt/data/media >/dev/null 2>&1 || g=refuse
o=\$(_storage_status 2>&1); st=accept; case "\$o" in *"NOT mounted"*|*"Cannot check"*) st=refuse;; esac
b=\$(_pick_backup_default $SRC_DIR); bd=refuse; [ -n "\$b" ] && bd=accept
echo "verdict=\$v mirror=\$m smb=\$sm start=\$g status=\$st backup=\$bd"
X
fixture() { # fm-mode ls-state -> the summary line (findmnt-less when mode is "nofm")
  rm -rf "$T/mnt/usb"
  case "$2" in files) mkdir -p "$T/mnt/usb"; echo f > "$T/mnt/usb/f" ;; empty) mkdir -p "$T/mnt/usb" ;; esac
  if [ "$1" = nofm ]; then LS_DATA=$2 env PATH="$T/lsonly" "$(command -v bash)" "$T/acc.sh" 2>&1 | tail -1
  else LS_DATA=$2 FM_MODE=$1 FM_ROOT=/mnt/data bash "$T/acc.sh" 2>&1 | tail -1; fi
}
GOT=$(fixture ok files);   check A1 "real mount, files: ok -> everyone accepts" '[ "$GOT" = "verdict=ok mirror=accept smb=accept start=accept status=accept backup=accept" ]'
GOT=$(fixture ok empty);   check A2 "real mount, empty folder: empty -> only the mirror refuses (it would wipe the destination)" '[ "$GOT" = "verdict=empty mirror=refuse smb=accept start=accept status=accept backup=accept" ]'
GOT=$(fixture ok missing); check A3 "folder gone: missing -> everyone refuses" '[ "$GOT" = "verdict=missing mirror=refuse smb=refuse start=refuse status=refuse backup=refuse" ]'
GOT=$(fixture bare files); check A4 "bare folder on the system disk: unmounted -> everyone refuses" '[ "$GOT" = "verdict=unmounted mirror=refuse smb=refuse start=refuse status=refuse backup=refuse" ]'
GOT=$(fixture stub files); check A5 "autofs stub (SOURCE systemd-1): unmounted -> everyone refuses" '[ "$GOT" = "verdict=unmounted mirror=refuse smb=refuse start=refuse status=refuse backup=refuse" ]'
GOT=$(fixture nofm files); check A6 "no findmnt: unknown -> everyone refuses or only warns (fails closed)" '[ "$GOT" = "verdict=unknown mirror=refuse smb=refuse start=refuse status=refuse backup=refuse" ]'
mkdir -p "$T/mnt/usb/data" "$T/mnt/usb/empty"; echo f > "$T/mnt/usb/data/f"   # restore the fixtures

# ── V  _drive_verdict: one answer per case ──────────────────────────────────
vv() { : > "$SLEEP_LOG"; FM_MODE=$1 _drive_verdict "$2"; }
nsleep() { wc -l < "$SLEEP_LOG"; }
GOT=$(vv ok "$D");   check V1a "verdict: real mount, files -> ok" '[ "$GOT" = ok ]'
GOT=$(vv ok "$M");   check V1b "verdict: missing path -> missing" '[ "$GOT" = missing ]'
GOT=$(vv ok "$E");   check V1c "verdict: real mount, empty dir -> empty" '[ "$GOT" = empty ]'
GOT=$(vv bare "$D"); check V1d "verdict: bare folder on the system disk (target /) -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(vv stub "$D"); check V1e "verdict: autofs stub (SOURCE systemd-1) -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(vv none "$D"); check V1f "verdict: findmnt finds no mount -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(vv bare "$E"); check V1g "verdict: empty bare folder (what an unplugged drive leaves) -> unmounted, not empty" '[ "$GOT" = unmounted ]'
GOT=$(env PATH="$T/lsonly" SLEEP_LOG=$SLEEP_LOG "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; _drive_verdict $D")
check V1h "verdict: findmnt absent on a drive path -> unknown" '[ "$GOT" = unknown ]'
GOT=$(vv ok "$T/media/u/USB"); check V2a "verdict: path outside the roots, files -> ok (not drive-backed: no mount question)" '[ "$GOT" = ok ]'
mkdir -p "$T/plain-empty"
GOT=$(vv bare "$T/plain-empty"); check V2b "verdict: path outside the roots, empty -> empty, whatever findmnt says" '[ "$GOT" = empty ]'
GOT=$(vv ok "$T/plain-none");    check V2c "verdict: path outside the roots, absent -> missing" '[ "$GOT" = missing ]'
GOT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; _drive_verdict $T/media/u/USB")
check V2d "verdict: outside the roots never needs findmnt" '[ "$GOT" = ok ]'
GOT=$(_DRIVE_ROOTS="$T/media $T/mnt" vv bare "$T/media/u/USB"); check V2e "verdict: every listed root counts (a /media-style root is checked, so a bare folder there is unmounted)" '[ "$GOT" = unmounted ]'

# retries: a healthy drive never waits; a drive path that is not ok is retried
vv ok "$D" >/dev/null; check V3a "retry: healthy drive -> no sleep" '[ "$(nsleep)" = 0 ]'
GOT=$(vv bare "$D"; nsleep); check V3b "retry: unmounted drive -> 3 looks, 2 sleeps of 1 s" '[ "$(tail -1 <<<"$GOT")" = 2 ] && [ "$(sort -u "$SLEEP_LOG")" = 1 ]'
GOT=$(vv ok "$M"; nsleep); check V3c "retry: missing drive path -> retried too (2 sleeps)" '[ "$(tail -1 <<<"$GOT")" = 2 ]'
GOT=$(vv ok "$T/plain-none"; nsleep); check V3d "retry: not drive-backed and missing -> no retry" '[ "$(tail -1 <<<"$GOT")" = 0 ]'
GOT=$(env PATH="$T/lsonly" SLEEP_LOG=$SLEEP_LOG "$(command -v bash)" -c "source $T/fn.sh; _DRIVE_ROOTS=$T/mnt; : > $SLEEP_LOG; _drive_verdict $D >/dev/null; wc -l < $SLEEP_LOG")
check V3e "retry: unknown (no findmnt) answers at once, no sleep" '[ "$GOT" = 0 ]'
# a slow spin-up: unmounted on the first look, mounted by the second
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
n=$(cat "$FM_COUNT" 2>/dev/null || echo 0)
case "$*" in *TARGET*) col=T; echo $((n+1)) > "$FM_COUNT" ;; *) col=S ;; esac
if [ "$n" -lt 1 ]; then [ $col = T ] && echo / || echo /dev/nvme0n1p2; else [ $col = T ] && echo "$FM_ROOT" || echo /dev/sdb1; fi
X
chmod +x "$T/bin/findmnt"; export FM_COUNT=$T/fmcount; rm -f "$FM_COUNT"; : > "$SLEEP_LOG"
GOT=$(_drive_verdict "$D"); check V3f "retry: drive that comes up on the second look -> ok (one sleep)" '[ "$GOT" = ok ] && [ "$(nsleep)" = 1 ]'
# the poke: the path is listed (wakes an idle automount) before findmnt answers
rm -f "$T/bin/findmnt"; stub_findmnt ok '$FM_ROOT' /dev/sdb1
cat > "$T/bin/ls" <<X
#!/bin/bash
echo "\$*" >> "\$LS_LOG"
case "\$*" in *"/mnt/data"*)
  case "\${LS_DATA:-files}" in files) echo lost+found; exit 0 ;; empty) exit 0 ;; missing) exit 2 ;; esac ;; esac
exec $REAL_LS "\$@"
X
chmod +x "$T/bin/ls"; export LS_LOG=$T/lslog; : > "$LS_LOG"
GOT=$(vv ok "$D"); check V4a "poke: the path is listed with ls -A" 'grep -q -- "-A -- $D" "$LS_LOG"'

# unreadable-but-present folder (live: a root/service-owned dir, ls -> Permission denied) is present, not missing
if [[ $EUID == 0 ]]; then echo "SKIP  V5  unreadable-folder checks: running as root, chmod 000 would not block reading"
else
  mkdir -p "$T/plain-locked" "$T/mnt/usb/locked"; chmod 000 "$T/plain-locked" "$T/mnt/usb/locked"
  GOT=$(vv ok "$T/plain-locked"); check V5a "verdict: unreadable folder outside the roots -> ok (exists; not missing)" '[ "$GOT" = ok ]'
  GOT=$(vv ok "$T/mnt/usb/locked"; nsleep); check V5b "verdict: unreadable folder on a real mount -> ok, no retry sleep" '[ "$(head -1 <<<"$GOT")" = ok ] && [ "$(tail -1 <<<"$GOT")" = 0 ]'
  S=$(date +%s%N); vv ok "$T/mnt/usb/locked" >/dev/null; check V5c "verdict: ... and answers in under 1 s" '[ $(( ($(date +%s%N) - S) / 1000000 )) -lt 1000 ]'
  GOT=$(vv bare "$T/mnt/usb/locked"); check V5d "verdict: unreadable folder on an unmounted bare folder -> unmounted" '[ "$GOT" = unmounted ]'
  chmod 755 "$T/plain-locked" "$T/mnt/usb/locked"
fi

# R  the constant
check R1 "roots list is one plain constant: /mnt /media /run/media" '[ "$(grep -cE "^_DRIVE_ROOTS=\"/mnt /media /run/media\"" "$SRC")" = 1 ]'
roots_under_env() { printf '%s\necho "$_DRIVE_ROOTS"\n' "$(grep -E '^_DRIVE_ROOTS=' "$SRC")" | env _DRIVE_ROOTS=/evil bash; }
check R2 "the environment cannot change the production roots (assignment, no :- default)" '[ "$(roots_under_env)" = "/mnt /media /run/media" ]'
check R3 "no per-feature roots list or env override left (_MIRROR_DRIVE_ROOTS, _SMB_DRIVE_ROOTS)" '[ "$(grep -cE "_MIRROR_DRIVE_ROOTS|_SMB_DRIVE_ROOTS" "$SRC")" = 0 ]'
src_tests() { grep -cE '"\$s" != /dev/\*|case "\$s" in /dev/\*' "$SRC"; }
check R4 "the SOURCE /dev/* test lives in _drive_verdict and the standalone disk-check only; no mountpoint -q left" '[ "$(src_tests)" = 2 ] && [ "$(grep -v "^ *#" "$SRC" | grep -c "mountpoint -q")" = 0 ]'

check_total
