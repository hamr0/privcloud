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
for f in ok fail info warn _env_get _mirror_check_here _smb_folder_check _smb_folder_reason _require_data_mount _storage_status _pick_backup_default; do
  extract_fn "$f" "$SRC"; done > "$T/fn.sh"
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
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sleep"
printf '#!/bin/bash\n:\n' > "$T/bin/lsblk"
# mountpoint(1) as `mountpoint -q` sees it: an autofs stub counts as a mountpoint.
printf '#!/bin/bash\n[ "${FM_MODE:-ok}" = ok ] || [ "${FM_MODE:-ok}" = stub ]\n' > "$T/bin/mountpoint"
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
for c in cut awk grep sed tr head tail cat date; do ln -sf "$(command -v $c)" "$T/lsonly/$c"; done
export PATH="$T/bin:$PATH" FM_ROOT="$T/mnt/usb" SRC_DIR="$T/src"
mkdir -p "$T/mnt/usb/data" "$T/mnt/usb/empty" "$T/src"; echo f > "$T/mnt/usb/data/f"
D=$T/mnt/usb/data; E=$T/mnt/usb/empty; M=$T/mnt/usb/nope
CHECK_DIAG='got=$GOT'

# ── P  pins: today's answers, per member and per case ───────────────────────
# mirror (_mirror_check_here; test-only roots override still read from the env today)
export _MIRROR_DRIVE_ROOTS="$T/mnt"
mv_() { FM_MODE=$1 _mirror_check_here "$2"; }
mnofm() { env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _MIRROR_DRIVE_ROOTS=$T/mnt _mirror_check_here $1"; }
GOT=$(mv_ ok "$D");   check P1a "mirror: real mount, files -> ok" '[ "$GOT" = ok ]'
GOT=$(mv_ ok "$M");   check P1b "mirror: missing path -> missing" '[ "$GOT" = missing ]'
GOT=$(mv_ ok "$E");   check P1c "mirror: empty dir -> empty" '[ "$GOT" = empty ]'
GOT=$(mv_ bare "$D"); check P1d "mirror: bare folder on the system disk -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(mv_ stub "$D"); check P1e "mirror: autofs stub (SOURCE systemd-1) -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(mnofm "$D");    check P1f "mirror: findmnt absent -> unknown" '[ "$GOT" = unknown ]'
GOT=$(mv_ bare "$E"); check P1g "mirror: empty bare folder -> empty (empty is decided before the mount)" '[ "$GOT" = empty ]'
unset _MIRROR_DRIVE_ROOTS

# SMB (_smb_folder_check; roots variable set by the suite)
_SMB_DRIVE_ROOTS="$T/mnt"
sv() { FM_MODE=$1 _smb_folder_check "$2"; }
GOT=$(sv ok "$D");   check P2a "smb: real mount -> ok" '[ "$GOT" = ok ]'
GOT=$(sv ok "$M");   check P2b "smb: missing -> missing" '[ "$GOT" = missing ]'
GOT=$(sv ok "$E");   check P2c "smb: empty dir on a real mount -> ok (an empty share is fine)" '[ "$GOT" = ok ]'
GOT=$(sv bare "$D"); check P2d "smb: bare folder -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(sv stub "$D"); check P2e "smb: autofs stub -> unmounted" '[ "$GOT" = unmounted ]'
GOT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _SMB_DRIVE_ROOTS=$T/mnt _smb_folder_check $D")
check P2f "smb: findmnt absent -> unmounted (no 'unknown' verdict in this copy)" '[ "$GOT" = unmounted ]'
GOT=$(_SMB_DRIVE_ROOTS="/mnt /run/media" sv bare "/media/u/USB"); check P2g "smb: absent folder under /media -> missing" '[ "$GOT" = missing ]'
mkdir -p "$T/media/u/USB"; echo f > "$T/media/u/USB/f"
GOT=$(_SMB_DRIVE_ROOTS="/mnt /run/media" sv bare "$T/media/u/USB"); check P2h "smb: folder under a root that is not in its list reads ok even when bare (the D8 drift)" '[ "$GOT" = ok ]'

# start guard (_require_data_mount: /mnt/* only; exact mount point, no existence check)
rq() { FM_MODE=$1 FM_ROOT=/mnt/data LS_DATA=${2:-files} _require_data_mount "${3:-/mnt/data/media}" >/dev/null 2>&1; echo $?; }
GOT=$(rq ok);        check P3a "start guard: real mount -> allowed (rc 0)" '[ "$GOT" = 0 ]'
GOT=$(rq stub);      check P3b "start guard: autofs stub -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq none);      check P3c "start guard: nothing mounted -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq bare);      check P3d "start guard: bare folder -> refused" '[ "$GOT" = 1 ]'
GOT=$(env PATH="$T/lsonly" "$(command -v bash)" -c "source $T/fn.sh; _require_data_mount /mnt/data >/dev/null 2>&1; echo \$?")
check P3e "start guard: findmnt absent -> refused" '[ "$GOT" = 1 ]'
GOT=$(rq none files /home/x/data); check P3f "start guard: a path outside /mnt is not guarded -> allowed" '[ "$GOT" = 0 ]'
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
check P4e "status: findmnt absent -> warns (source none)" '[[ "$OUT" == *"/mnt/data is NOT mounted"* ]]'

# backup default (_pick_backup_default: candidate must be a dir and `mountpoint -q`)
bd() { FM_MODE=$1 _pick_backup_default "$SRC_DIR"; }
GOT=$(bd ok);   check P5a "backup default: real mount offered" '[ "$GOT" = "$T/mnt/usb/privcloud-backup" ]'
GOT=$(bd bare); check P5b "backup default: bare folder (not a mountpoint) not offered" '[ -z "$GOT" ]'
GOT=$(bd stub); check P5c "backup default: autofs stub IS offered today (mountpoint -q is fooled; the drift)" '[ -n "$GOT" ]'

check_total
