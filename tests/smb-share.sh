#!/bin/bash
# Tests for the SMB file-sharing step in setup.sh (step_samba and the _smb_*
# helpers): set-up flow, manage folders/password, status, (s) section,
# phone live-wait, uninstall. Run: bash tests/smb-share.sh (non-zero on failure)
# Everything runs in a mktemp sandbox with stubbed docker/sudo/ss/firewall-cmd/
# id/openssl/tailscale/findmnt: no real containers, no sudo, no network. All
# names and ids are fake. SETUP_SH=<file> tests another copy of setup.sh.
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SETUP_SH:-$H/../setup.sh}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/c" "$T/files/docs" "$T/files/media" "$T/files/My Pics" "$T/opt" "$T/mnt/usb/data" "$T/ro"
BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; NC=
{ grep -E '^(ok|fail|info|warn)\(\)' "$SRC"
  grep -m1 '^_shq()' "$SRC"
  grep -m1 '^_ts_ipv4()' "$SRC"
  awk '/^_ts_state\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC"
  awk '/^_svc_power_body\(\)/{p=1} p{print} /^_ps_autostart\(\)/{q=1} q&&/^}/{exit}' "$SRC"
  awk '/^_env_get\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC"
  awk '/^_container_gone\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC"
  awk '/^_confirm_delete\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC"
  sed -n '/^# ── SMB file sharing/,/^# ── end SMB/p' "$SRC"; } > "$T/fn.sh"
source "$T/fn.sh"
type step_samba >/dev/null 2>&1 || echo "FAIL  setup: step_samba not found in $SRC (older setup.sh?)"
_SMB_DIR=$T/opt/samba; _SMB_SETTLE=0; _SMB_POLL=0.2; _SMB_WAIT_TRIES=3; _SMB_DRIVE_ROOTS="$T/mnt"
echo "FILES_LOCATION=$T/files" > "$T/.env"   # _smb_files_path reads .env next to fn.sh

cat > "$T/bin/sudo" <<'X'
#!/bin/bash
[ "$1" = -v ] && { [ -n "$SUDO_FAIL" ] && exit 1; exit 0; }; exec "$@"
X
cat > "$T/bin/id" <<'X'
#!/bin/bash
case "$1" in -un) echo testuser;; -u) echo 4242;; -g) echo "${FAKE_GID:-4242}";; esac
X
cat > "$T/bin/openssl" <<'X'
#!/bin/bash
[ -n "$OPENSSL_FAIL" ] && exit 1
echo "Zx9/Qw8+Er7Ty6Ui5Op4As3Df2Gh1Jk0LmNbVcXz/aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789+/abcdefghijklmnop"
X
cat > "$T/bin/tailscale" <<'X'
#!/bin/bash
[ -n "$TS_DOWN" ] && exit 1
case "$1" in
  status) echo "100.99.99.98   iphone-test   someone@   iOS   -" ;;
  *) echo 100.99.99.99 ;;
esac
X
cat > "$T/bin/ss" <<'X'
#!/bin/bash
if [ -n "$LISTEN" ] || [ -e "$DOCKER_STATE/samba/listening" ]; then echo "LISTEN 0 4096 0.0.0.0:445 0.0.0.0:*"; fi
X
cat > "$T/bin/findmnt" <<'X'
#!/bin/bash
case "$*" in *TARGET*) col=T;; *) col=S;; esac
case "${FM_MODE:-ok}" in
  ok)   [ $col = T ] && echo "$TMNT/usb" || echo /dev/sdb1 ;;
  root) [ $col = T ] && echo / || echo /dev/nvme0n1p2 ;;
  stub) [ $col = T ] && echo "$TMNT/usb" || echo systemd-1 ;;
esac
X
cat > "$T/bin/firewall-cmd" <<'X'
#!/bin/bash
[ -n "$FW_DOWN" ] && exit 252
# Zones are modelled: a query without --zone asks the default zone (FW_DEFAULT,
# public if unset). FW_PORT / FW_SVC = the zone where it is open; "1" = the default zone.
DEF=${FW_DEFAULT:-public}; Z=$DEF
for a in "$@"; do case "$a" in --zone=*) Z=${a#--zone=} ;; esac; done
for a in "$@"; do case "$a" in
  --query-port=445/tcp) [ -n "$FW_PORT" ] && [ "${FW_PORT/#1/$DEF}" = "$Z" ] && { echo yes; exit 0; }; echo no; exit 1 ;;
  --query-service=samba) [ -n "$FW_SVC" ] && [ "${FW_SVC/#1/$DEF}" = "$Z" ] && { echo yes; exit 0; }; echo no; exit 1 ;;
esac; done
X
cat > "$T/bin/docker" <<'X'
#!/bin/bash
C=$DOCKER_STATE
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' _; }
echo "docker $*" >> "$DOCKER_LOG"
cmd=$1; shift
case "$cmd" in
  info) exit 0 ;;
  image) [ -n "$NO_IMAGE" ] && [ ! -e "$C/.pulled" ] && exit 1; exit 0 ;;
  pull) [ -n "$FAIL_PULL" ] && exit 1; mkdir -p "$C"; touch "$C/.pulled"; exit 0 ;;
  run)
    [ -n "$FAIL_RUN" ] && exit 1
    name=; pol=no; mounts=
    while [ $# -gt 0 ]; do case "$1" in
      --name) name=$2; shift 2;; --restart=*) pol=${1#--restart=}; shift;;
      -v) src=${2%%:/shares/*}; dst=/shares/${2##*:/shares/}; mounts="$mounts$dst|$src"$'\n'; shift 2;; *) shift;; esac; done
    d=$C/$(key "$name"); mkdir -p "$d"; printf '%s' "$name" > "$d/name"; echo "$pol" > "$d/policy"; printf '%s' "$mounts" > "$d/mounts"
    if [ -n "$NO_LISTEN" ]; then echo false > "$d/running"; else echo true > "$d/running"; touch "$d/listening"; fi ;;
  rm)
    [ -n "$FAIL_RM" ] && exit 1
    for a in "$@"; do case "$a" in -*) ;; *) rm -rf "$C/$(key "$a")";; esac; done ;;
  ps)
    all=0; q=0
    for a in "$@"; do case "$a" in -a) all=1;; -aq) all=1; q=1;; *Status*) full=1;; esac; done
    [ "$full" = 1 ] || q=1
    for d in "$C"/*/; do [ -d "$d" ] || continue
      [ "$all" = 1 ] || [ "$(cat "$d/running")" = true ] || continue
      n=$(cat "$d/name")
      if [ "$q" = 1 ]; then echo "$n"
      elif [ "$(cat "$d/running")" = true ]; then echo "$n|Up 2 hours"; else echo "$n|Exited (0) 3 hours ago"; fi
    done ;;
  inspect)
    fmt=""; names=()
    while [ $# -gt 0 ]; do case "$1" in -f) fmt=$2; shift 2;; *) names+=("$1"); shift;; esac; done
    for n in "${names[@]}"; do d=$C/$(key "$n"); [ -d "$d" ] || exit 1
      case "$fmt" in
        *State.Running*) echo "$(cat "$d/running") $(cat "$d/policy")" ;;
        *'{{.Name}}'*)   echo "/$n $(cat "$d/policy")" ;;
        *Mounts*)        cat "$d/mounts" ;;
        *RestartPolicy*) cat "$d/policy" ;;
      esac; done ;;
  update) pol=${1#--restart=}; d=$C/$(key "$2"); [ -d "$d" ] || exit 1; echo "$pol" > "$d/policy" ;;
  start|stop|restart)
    d=$C/$(key "$1"); [ -d "$d" ] || exit 1
    if [ "$cmd" = stop ]; then echo false > "$d/running"; rm -f "$d/listening"; else echo true > "$d/running"; touch "$d/listening"; fi ;;
  exec) case "$*" in *"smbstatus -S"*) printf '\nService      pid     Machine       Connected at                     Encryption   Signing\n%s\n' "---------------------------------------------------------------------------------------------"; cat "$SMBSTATUS" 2>/dev/null ;; esac ;;
  logs) echo "fake samba log" ;;
esac
exit 0
X
chmod +x "$T/bin/"*
export TZ=UTC   # smbstatus prints UTC; fixtures below are read as UTC unless a case sets another TZ
export PATH="$T/bin:$PATH" DOCKER_STATE=$T/c DOCKER_LOG=$T/docker.log SMBSTATUS=$T/smbstatus TMNT=$T/mnt
PASS=0; FAILN=0
mk() { local d="$T/c/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; mkdir -p "$d"
  printf '%s' "$1" > "$d/name"; echo "$2" > "$d/running"; echo "$3" > "$d/policy"; : > "$d/mounts"; [ "$2" = true ] && touch "$d/listening"; }
reset() { rm -rf "$T/c" "$T/opt" "$SMBSTATUS"; mkdir -p "$T/c" "$T/opt"; : > "$DOCKER_LOG"
  unset NO_IMAGE FAIL_PULL SUDO_FAIL LISTEN FW_PORT FW_SVC FW_DEFAULT FW_DOWN FAIL_RUN FAIL_RM NO_LISTEN OPENSSL_FAIL TS_DOWN FAKE_GID FM_MODE
  _SMB_NAMES=(); _SMB_PATHS=(); }
check() { if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1)); else echo "FAIL  $1  $2  [rc=$RC]"; FAILN=$((FAILN+1)); fi; }
# run <stdin-text> <hold-seconds> cmd...   (hold keeps stdin open so read -t can time out)
run() { local in=$1 hold=$2; shift 2; OUT=$( { printf '%s' "$in"; sleep "$hold"; } | "$@" 2>&1); RC=$?; }
ENVF=$_SMB_DIR/samba.env; SHF=$_SMB_DIR/shares.conf
RUNLINE() { grep '^docker run' "$DOCKER_LOG"; }
PWOF() { sed -n 's/^ACCOUNT_testuser=//p' "$ENVF"; }
NSH() { grep -c '|' "$SHF"; }
# a finished set-up with docs + media, password FakePass0123456x
mkset() { reset; run $'1\ny'"$T/files/docs"$'\n'"$T/files/media"$'\n\nFakePass0123456x\nFakePass0123456x\n' 0 step_samba; }
SI="1"$'\ny'"$T/files/docs"$'\n\n'   # choice 1, one folder, done (callers add the password line)

# 1 set-up: checks
reset; export TS_DOWN=1; run "$SI" 0 step_samba
check 1a "no tailscale: stops, installs nothing" '[ $RC != 0 ] && [[ "$OUT" == *"Tailscale is not connected"* ]] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ]'
reset; export LISTEN=1; run "$SI" 0 step_samba
check 1b "445 in use: stops, installs nothing" '[ $RC != 0 ] && [[ "$OUT" == *"Port 445 is already in use"* ]] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ]'
reset; mk samba-poc true unless-stopped; export LISTEN=1; run "$SI" 0 step_samba
check 1c "POC container present: prints teardown command" '[[ "$OUT" == *"docker compose -p samba-poc down"* ]]'
reset; export FW_PORT=1; run "$SI" 0 step_samba
check 1d "445 open in the default zone: stops with the fix, installs nothing" '[ $RC != 0 ] && [[ "$OUT" == *"--remove-port=445/tcp"* ]] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ]'
reset; export FW_SVC=1; run "$SI" 0 step_samba
check 1e "samba service open in the default zone: stops" '[ $RC != 0 ] && [ -z "$(RUNLINE)" ]'
reset; export FW_DEFAULT=home FW_PORT=1; run "$SI" 0 step_samba
check 1d2 "445 open in a non-public default zone (home): still stops, fix names no zone" '[ $RC != 0 ] && [[ "$OUT" == *"--remove-port=445/tcp"* && "$OUT" != *"--zone="* && "$OUT" == *"default zone"* ]] && [ -z "$(RUNLINE)" ]'
reset; export FW_DEFAULT=home FW_SVC=1; run "$SI" 0 step_samba
check 1e2 "samba service open in a non-public default zone: stops with the open-LAN message" '[ $RC != 0 ] && [[ "$OUT" == *"is open to the home network"* ]] && [ -z "$(RUNLINE)" ]'
reset; export FW_DEFAULT=home FW_PORT=public; run $'1\ny' 0 step_samba
check 1e3 "445 open only in public while the default zone is home: not flagged (the LAN NIC is not in public)" '[[ "$OUT" != *"445 is open"* && "$OUT" != *"port 445 is open"* && "$OUT" == *"Folder to share"* ]]'
reset; export FW_DOWN=1; run $'1\ny' 0 step_samba
check 1f "firewalld unreadable: warns, continues to the folder prompt" '[[ "$OUT" == *"could not read the state"* && "$OUT" == *"Folder to share"* ]]'
reset; run $'1\ny' 0 step_samba
check 1g "Enter at first folder prompt cancels, nothing changed" '[ $RC = 0 ] && [[ "$OUT" == *"Cancelled. Nothing changed"* ]] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ]'
reset; run $'0\n' 0 step_samba
check 1h "not set up submenu: Set up + Back only, with explanation" '[[ "$OUT" == *"Not set up yet"* && "$OUT" == *"1) Set up"* && "$OUT" != *"Manage folders"* ]]'
reset; run $'1\ny' 0 step_samba
check 1i "set up shows 2-line explanation, ✓ checks, files-folder tip" '[[ "$OUT" == *"Tailscale only"* || "$OUT" == *"Tailscale only,"* || "$OUT" == *"over Tailscale only"* ]] && [[ "$OUT" == *"Tailscale connected (100.99.99.99)"* && "$OUT" == *"Port 445 is free"* && "$OUT" == *"Tip: your files folder is $T/files"* ]]'

# 2 set-up: folders
reset; run $'1\nyrelative/dir\n/nonexistent/zzz\n'"$T/files/docs"$'\n\n\n' 0 step_samba
check 2a "bad folders re-ask with a reason; good one then accepted" '[[ "$OUT" == *"Use a full path"* && "$OUT" == *"does not exist"* && "$OUT" == *"Sharing docs"* && $RC = 0 ]]'
reset; run $'1\ny/etc\n/\n/usr\n/proc\n/home\n/var\n/dev\n\n' 0 step_samba
check 2b "system paths refused with the reason" '[ "$(grep -c "system location" <<<"$OUT")" -ge 6 ] && [ -z "$(RUNLINE)" ]'
echo hi > "$T/afile"; reset; run $'1\ny'"$T/afile"$'\n\n' 0 step_samba
check 2c "a file (not a folder) refused" '[[ "$OUT" == *"is not a folder"* ]]'
if [ "$(id -u)" != 0 ]; then chmod 555 "$T/ro"; reset; run $'1\ny'"$T/ro"$'\n\n' 0 step_samba; chmod 755 "$T/ro"
check 2d "non-writable folder refused" '[[ "$OUT" == *"not writable"* ]]'; fi
reset; ln -s "$T/files/docs" "$T/link"; run $'1\ny'"$T/link"$'\n\n\n' 0 step_samba
check 2e "symlink resolved via realpath" 'grep -qx "docs|$T/files/docs" "$SHF"'
reset; run $'1\ny'"$T/files/docs"$'\n'"$T/files/docs"$'\n\n\n' 0 step_samba
check 2f "same folder twice: refused as already shared" '[[ "$OUT" == *"already shared"* ]] && [ "$(NSH)" = 1 ]'
reset; mkdir -p "$T/other/docs"; run $'1\ny'"$T/files/docs"$'\n'"$T/other/docs"$'\nmydocs2\n\n\n' 0 step_samba
check 2g "name clash: asks for another name" '[[ "$OUT" == *"Another name for"* ]] && grep -qx "mydocs2|$T/other/docs" "$SHF"'
reset; run $'1\ny'"$T/files/docs"$'\n'"$T/other/docs"$'\nbad name!\n\n\n\n' 0 step_samba
check 2h "invalid replacement name re-asked; blank skips folder" '[[ "$OUT" == *"use letters, digits"* ]] && [ "$(NSH)" = 1 ]'
reset; run $'1\ny'"$T/files/My Pics"$'\n\n\n' 0 step_samba
check 2i "folder name with a space becomes a valid share name" 'grep -qx "My-Pics|$T/files/My Pics" "$SHF"'

# 3 set-up: apply, password, honesty
mkset
check 3a "two folders: set-up ok, success line says 2 folders" '[ $RC = 0 ] && [[ "$OUT" == *"File sharing set up: 2 folders."* ]]'
check 3b "one -v mount per folder at /shares/<name>, host net, env-file, autostart policy" \
  '[[ "$(RUNLINE)" == *"--network host"* && "$(RUNLINE)" == *"--env-file $ENVF"* && "$(RUNLINE)" == *"--restart=unless-stopped"* && "$(RUNLINE)" == *"-v $T/files/docs:/shares/docs"* && "$(RUNLINE)" == *"-v $T/files/media:/shares/media"* && "$(RUNLINE)" == *smbd-only-latest* && "$(RUNLINE)" != *" -p "* ]]'
check 3c "one SAMBA_VOLUME_CONFIG per share, both valid-user restricted, read-write, veto" \
  '[ "$(grep -c "^SAMBA_VOLUME_CONFIG_s" "$ENVF")" = 2 ] && grep -q "^SAMBA_VOLUME_CONFIG_s0=\[docs\]; path = /shares/docs; valid users = testuser; guest ok = no; read only = no" "$ENVF" && grep -q "^SAMBA_VOLUME_CONFIG_s1=\[media\]" "$ENVF" && grep -q "veto files = /lost+found/.Trash-\*/" "$ENVF"'
check 3d "env + list files are mode 600, list has name|path" '[ "$(stat -c %a "$ENVF")" = 600 ] && [ "$(stat -c %a "$SHF")" = 600 ] && grep -qx "docs|$T/files/docs" "$SHF"'
check 3e "hosts allow tailnet only, SMB2, runtime uid" 'grep -q "hosts allow = 100.64.0.0/10 fd7a:115c:a1e0::/48 127.0.0.1 ::1;hosts deny = ALL;server min protocol = SMB2;server smb encrypt = desired" "$ENVF" && grep -q "^UID_testuser=4242$" "$ENVF" && ! grep -q GROUP_ "$ENVF"'
check 3f "typed password used; never on docker argv/log" '[ "$(PWOF)" = FakePass0123456x ] && ! grep -qF FakePass0123456x "$DOCKER_LOG"'
check 3g "connect box: server ip, user, password, iPhone + Android steps" '[[ "$OUT" == *smb://100.99.99.99* && "$OUT" == *"User:      testuser"* && "$OUT" == *FakePass0123456x* && "$OUT" == *iPhone* && "$OUT" == *Android* && "$OUT" == *"Material Files"* ]]'
reset; run $'1\ny'"$T/files/docs"$'\n\n\n' 0 step_samba
PW=$(PWOF)
check 3h "Enter = generated password: 16 alphanumeric, shown in output" '[[ "$PW" =~ ^[A-Za-z0-9]{16}$ && "$OUT" == *"$PW"* ]]'
reset; export FAKE_GID=5353; run "$SI"$'\n' 0 step_samba
check 3i "gid != uid: group + force group" 'grep -q "^GROUP_smbshare=5353$" "$ENVF" && grep -q "force group = smbshare" "$ENVF"'
reset; run $'1\ny'"$T/files/docs"$'\n\nshort1\nback\\slash1234\n-leadingdash12\n'$'\xc3\xa9ccentpass1\nGoodPass12345\nOtherPass12345\nGoodPass12345\nGoodPass12345\n' 0 step_samba
check 3j "bad typed passwords rejected with reasons (short, backslash, dash, accent); mismatch re-asks; then works" \
  '[[ "$OUT" == *"too short"* && "$OUT" == *"backslash"* && "$OUT" == *"must not start with -"* && "$OUT" == *"plain keyboard"* && "$OUT" == *"did not match"* ]] && [ "$(PWOF)" = GoodPass12345 ]'
WEIRD="sp ace\$HOME\"q'x%s;#|&"
reset; run $'1\ny'"$T/files/docs"$'\n\n'"$WEIRD"$'\n'"$WEIRD"$'\n' 0 step_samba
check 3k "password with spaces, \$, quotes, ;, #, | round-trips through the env file" '[ "$(PWOF)" = "$WEIRD" ] && ! grep -qF "$WEIRD" "$DOCKER_LOG"'
reset; run $'1\ny'"$T/files/docs"$'\n\n\n' 0 step_samba; run $'3\n' 0 step_samba
check 3l "Manage password shows the stored weird/generated password in full" '[[ "$OUT" == *"$(PWOF)"* ]]'
reset; run $'1\ny'"$T/files/docs"$'\n\n GoodPass12345\nGoodPass12345 \nGood Pass12345\nGood Pass12345\n' 0 step_samba
check 3q "space-padded typed passwords (leading, trailing) rejected with the space message and re-asked; inner space works" \
  '[ "$(grep -o "no space at the start or end" <<<"$OUT" | wc -l)" = 2 ] && [ "$(PWOF)" = "Good Pass12345" ]'
reset; export FAIL_RUN=1; run "$SI"$'\n' 0 step_samba
check 3m "docker run fails: loud failure, no success line" '[ $RC != 0 ] && [[ "$OUT" == *"NOT RUNNING"* && "$OUT" != *"File sharing set up"* ]]'
reset; export NO_LISTEN=1; run "$SI"$'\n' 0 step_samba
check 3n "container not listening: failure, no success line" '[ $RC != 0 ] && [[ "$OUT" != *"File sharing set up"* ]]'
reset; export OPENSSL_FAIL=1; run "$SI"$'\n' 0 step_samba
check 3o "password generation fails: nothing installed" '[ $RC != 0 ] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ]'
# saved setup reuse after an uninstall
mkset; run $'7\nsamba\n' 0 step_samba
run $'1\nyy' 0 step_samba
check 3p "after uninstall, Set up offers the saved folders + password and reuses them" '[[ "$OUT" == *"Saved setup found: 2 folder"* && "$OUT" == *"File sharing set up: 2 folders."* ]] && [ "$(PWOF)" = FakePass0123456x ]'

# 4 live phone wait
reset; printf 'docs         14      100.99.99.98  Fri Nov 27 09:10:11 2026 UTC     -            -\n' > "$SMBSTATUS"
run "$SI"$'\n' 3 step_samba
check 4a "phone seen: '<device> connected, opened \"<share>\"' with Tailscale name" '[[ "$OUT" == *"waiting"* && "$OUT" == *"iphone-test connected, opened \"docs\""* ]]'
reset; run "$SI"$'\n' 2 step_samba
check 4b "no phone: timeout message with common causes, setup still reported" '[[ "$OUT" == *"No phone connected"* && "$OUT" == *"Tailscale is off on the phone"* && "$OUT" == *"File sharing set up"* ]]'
reset; run "$SI"$'\n\n' 0 step_samba
check 4c "Enter skips the wait" '[[ "$OUT" == *Skipped* && "$OUT" != *"No phone connected"* ]]'

# 5 submenu + status
mkset; run $'0\n' 0 step_samba
check 5a "set-up submenu: status block + 7 items" '[[ "$OUT" == *running* && "$OUT" == *"Port 445:  listening"* && "$OUT" == *"Autostart: on"* && "$OUT" == *"docs"* && "$OUT" == *"LAN closed"* && "$OUT" == *"2) Manage folders"* && "$OUT" == *"3) Manage password"* && "$OUT" == *"7) Uninstall"* ]]'
mkset; printf 'docs         14      100.99.99.98  Fri Nov 27 09:10:11 2026 UTC     -            -\nmedia        14      100.99.99.98  Fri Nov 27 09:11:00 2026 UTC     -            -\nmedia        20      100.99.99.77  Fri Nov 27 09:12:00 2026 UTC     -            -\n' > "$SMBSTATUS"; run $'0\n' 0 step_samba
check 5b "connected devices: Tailscale name mapped, IP fallback, shares + since" '[[ "$OUT" == *"iphone-test"* && "$OUT" == *"opened: docs, media"* && "$OUT" == *"100.99.99.77"* && "$OUT" == *"since 09:10"* ]]'
mkset; run $'0\n' 0 step_samba
check 5c "nobody connected: note about idle iPhone connections" '[[ "$OUT" == *"drops idle connections"* ]]'
mkset; _smb_load; rm -rf "$T/files/media"; run $'0\n' 0 step_samba; mkdir -p "$T/files/media"
check 5d "missing folder: ✗ with reason" '[[ "$OUT" == *"✗ media"* && "$OUT" == *"folder missing"* ]]'
reset; run $'1\ny'"$T/mnt/usb/data"$'\n\n\n' 0 step_samba
run $'0\n' 0 step_samba
check 5e "drive mounted (findmnt /dev/* source): ✓" '[[ "$OUT" == *"✓ data"* ]]'
export FM_MODE=root; run $'0\n' 0 step_samba
check 5f "unmounted drive (bare dir on system disk, target /): ✗ drive not mounted" '[[ "$OUT" == *"✗ data"* && "$OUT" == *"drive not mounted"* ]]'
export FM_MODE=stub; run $'0\n' 0 step_samba
check 5g "stub/autofs mount (source not /dev/*): ✗ drive not mounted" '[[ "$OUT" == *"drive not mounted"* ]]'
unset FM_MODE
mkset; run $'5\n' 0 step_samba; run $'0\n' 0 step_samba
check 5h "Stop -> 'stopped (autostart off)' in status; policy no" '[[ "$OUT" == *"stopped (autostart off)"* && "$OUT" == *"Autostart: off"* ]] && grep -qx no "$T/c/samba/policy"'
run $'4\n' 0 step_samba
check 5i "Start -> running + unless-stopped" 'grep -qx unless-stopped "$T/c/samba/policy" && [ "$(cat "$T/c/samba/running")" = true ]'
mkset; export SUDO_FAIL=1; run $'5\n' 0 step_samba
check 5j "Stop with sudo refused: reports failure" '[ $RC != 0 ] && [[ "$OUT" == *"Stop failed"* ]]'
mkset; export FW_PORT=1; run $'0\n' 0 step_samba
check 5k "status flags 445 open on LAN with the fix" '[[ "$OUT" == *"445 open on the LAN"* && "$OUT" == *"--remove-port=445/tcp"* ]]'
mkset; export FW_DEFAULT=home FW_PORT=1; run $'0\n' 0 step_samba
check 5k2 "status flags 445 open in a non-public default zone, fix names no zone" '[[ "$OUT" == *"445 open on the LAN"* && "$OUT" == *"--remove-port=445/tcp"* && "$OUT" != *"--zone="* ]]'

# 6 manage folders
mkset; run $'2\n'"$T/files/My Pics"$'\n\n' 0 step_samba
check 6a "add a folder: container recreated with 3 mounts, password unchanged" '[ "$(NSH)" = 3 ] && grep -q "^docker rm -f samba" "$DOCKER_LOG" && [ "$(RUNLINE | wc -l)" = 2 ] && [ "$(PWOF)" = FakePass0123456x ] && [[ "$OUT" == *"Now sharing My-Pics"* && "$OUT" == *reconnect* ]]'
check 6b "list is reprinted with numbers and ✓" '[[ "$OUT" == *"1) docs -> $T/files/docs ✓"* ]]'
mkset; run $'2\n/etc\n'"$T/files/docs"$'\n\n' 0 step_samba
check 6c "system path and already-shared folder refused in manage" '[[ "$OUT" == *"system location"* && "$OUT" == *"already shared"* ]] && [ "$(NSH)" = 2 ]'
mkset; mkdir -p "$T/other2/docs"; run $'2\n'"$T/other2/docs"$'\nnewdocs\n\n' 0 step_samba
check 6d "name clash in manage asks for a name" 'grep -qx "newdocs|$T/other2/docs" "$SHF"'
mkset; run $'2\n1\ny\n\n' 0 step_samba
check 6e "remove with y: share gone, files not deleted, container recreated" '[ "$(NSH)" = 1 ] && grep -qx "media|$T/files/media" "$SHF" && [ -d "$T/files/docs" ] && [[ "$OUT" == *"Files are NOT deleted"* ]]'
mkset; run $'2\n1\nn\n\n' 0 step_samba
check 6f "remove with N keeps the share" '[ "$(NSH)" = 2 ] && [ "$(RUNLINE | wc -l)" = 1 ]'
mkset; run $'2\n1\n\n\n' 0 step_samba
check 6g "remove with blank answer keeps the share" '[ "$(NSH)" = 2 ]'
mkset; run $'2\n1\ny1\n\n' 0 step_samba
check 6h "refuses removing the last folder, points to Uninstall" '[[ "$OUT" == *"last shared folder"* && "$OUT" == *Uninstall* ]] && [ "$(NSH)" = 1 ]'
mkset; run $'2\n9\n\n' 0 step_samba
check 6i "bad number rejected" '[[ "$OUT" == *"No folder number 9"* ]] && [ "$(NSH)" = 2 ]'
mkset; export FAIL_RUN=1; run $'2\n'"$T/files/My Pics"$'\n' 0 step_samba
check 6j "recreate fails after rm: loud NOT RUNNING + how to recover, no success" '[ $RC != 0 ] && [[ "$OUT" == *"NOT RUNNING"* && "$OUT" == *"run federver -> 16 again"* && "$OUT" != *"Now sharing"* ]] && [ ! -d "$T/c/samba" ]'
unset FAIL_RUN
run $'1\nyy' 0 step_samba
check 6k 'recovery works: Set up reuses saved folders after a failed recreate' '[[ "$OUT" == *"Saved setup found: 3 folder"* && "$OUT" == *"File sharing set up: 3 folders."* ]]'
mkset; export FAIL_RM=1; run $'2\n'"$T/files/My Pics"$'\n' 0 step_samba
check 6l "old container cannot be removed: says it still runs the OLD settings" '[ $RC != 0 ] && [[ "$OUT" == *"OLD settings"* ]]'

# 7 manage password
mkset; run $'3\n\n' 0 step_samba
check 7a "Enter keeps the password, nothing recreated" '[[ "$OUT" == *"Password kept"* ]] && [ "$(RUNLINE | wc -l)" = 1 ] && [ "$(PWOF)" = FakePass0123456x ]'
check 7b "screen shows user, full password, phone steps" '[[ "$OUT" == *"User:      testuser"* && "$OUT" == *FakePass0123456x* && "$OUT" == *smb://100.99.99.99* && "$OUT" == *iPhone* ]]'
mkset; run $'3\ng\n' 0 step_samba
check 7c "g generates 16 alphanumeric, shown, applied; folders kept; re-enter notice" 'PW=$(PWOF); [[ "$PW" =~ ^[A-Za-z0-9]{16}$ && "$PW" != FakePass0123456x && "$OUT" == *"$PW"* && "$OUT" == *"re-enter"* ]] && [ "$(NSH)" = 2 ] && ! grep -qF "$PW" "$DOCKER_LOG"'
mkset; run $'3\nBrandNew-pass9\nBrandNew-pass9\n' 0 step_samba
check 7d "typed + confirmed password applied" '[ "$(PWOF)" = BrandNew-pass9 ] && [ "$(RUNLINE | wc -l)" = 2 ]'
mkset; run $'3\nBrandNew-pass9\nDifferent-pass9\n' 0 step_samba
check 7e "mismatch: nothing changed" '[[ "$OUT" == *"did not match"* ]] && [ "$(PWOF)" = FakePass0123456x ] && [ "$(RUNLINE | wc -l)" = 1 ]'
mkset; run $'3\nshort\n' 0 step_samba
check 7f "too short: nothing changed" '[[ "$OUT" == *"too short"* ]] && [ "$(PWOF)" = FakePass0123456x ]'
mkset; run $'3\nbad\\slash12345\n' 0 step_samba
check 7g "backslash rejected: nothing changed" '[[ "$OUT" == *backslash* ]] && [ "$(PWOF)" = FakePass0123456x ]'
mkset; run $'3\n GoodPass12345\n' 0 step_samba
check 7i "Manage password: leading space rejected with the space message, nothing changed" '[[ "$OUT" == *"no space at the start or end"* ]] && [ "$(PWOF)" = FakePass0123456x ]'
mkset; run $'3\nGoodPass12345 \n' 0 step_samba
check 7j "Manage password: trailing space rejected with the space message, nothing changed" '[[ "$OUT" == *"no space at the start or end"* ]] && [ "$(PWOF)" = FakePass0123456x ]'
mkset; run $'3\nGood Pass12345\nGood Pass12345 \n' 0 step_samba
check 7k "Manage password: confirm with a trailing space does not match, nothing changed" '[[ "$OUT" == *"did not match"* ]] && [ "$(PWOF)" = FakePass0123456x ]'
mkset; run $'3\nGood Pass12345\nGood Pass12345\n' 0 step_samba
check 7l "Manage password: inner space accepted and stored" '[ "$(PWOF)" = "Good Pass12345" ]'
mkset; run $'3\nBrandNew-pass9\nBrandNew-pass9\n' 0 step_samba >/dev/null; export FAIL_RUN=1
mkset; export FAIL_RUN=1; run $'3\ng\n' 0 step_samba
check 7h "recreate fails after password change: loud, no success" '[ $RC != 0 ] && [[ "$OUT" == *"NOT RUNNING"* && "$OUT" != *"Password changed"* ]]'
unset FAIL_RUN

# 8 uninstall
mkset; run $'7\n\n' 0 step_samba
check 8a "blank confirm cancels" '[ -d "$T/c/samba" ] && [[ "$OUT" == *Cancelled* ]]'
mkset; run $'7\nsamb\n' 0 step_samba
check 8b "mismatch cancels" '[ -d "$T/c/samba" ] && [[ "$OUT" == *"did not match"* ]]'
mkset; run $'7\nsamba\n' 0 step_samba
check 8c "match: container gone, /opt/samba kept" '[ $RC = 0 ] && [ ! -d "$T/c/samba" ] && [ -f "$ENVF" ] && [ -f "$SHF" ] && [[ "$OUT" == *"File sharing removed"* ]]'
mkset; export FAIL_RM=1; run $'7\nsamba\n' 0 step_samba
check 8d "rm fails: not reported as removed" '[ $RC != 0 ] && [[ "$OUT" != *"File sharing removed"* ]]'

# 9 (s) Status section: three states
reset; S=$(_smb_summary docker); R=$(_smb_summary_render "$S")
check 9a "not set up" '[ "$S" = none ] && [[ "$R" == *"not set up (federver → 16)"* ]]'
mkset; S=$(_smb_summary docker); R=$(_smb_summary_render "$S")
check 9b "running: ✓ running · N folders · K devices connected" '[ "$S" = "running|2|0|0" ] && [[ "$R" == *"✓ running · 2 folders · 0 devices connected"* ]]'
printf 'docs         14      100.99.99.98  Fri Nov 27 09:10:11 2026 UTC     -            -\n' > "$SMBSTATUS"; rm -rf "$T/files/media"
S=$(_smb_summary docker); R=$(_smb_summary_render "$S"); mkdir -p "$T/files/media"
check 9c "running with a missing folder and a device: (1 ✗ not mounted) · 1 device" '[ "$S" = "running|2|1|1" ] && [[ "$R" == *"(1 ✗ not mounted)"* && "$R" == *"1 device connected"* && "$R" != *"1 devices"* ]]'
mkset; _svc_power stop samba 2>/dev/null; S=$(_smb_summary docker); R=$(_smb_summary_render "$S")
check 9d "stopped: red ✗ stopped (autostart off)" '[ "${S%%|*}" = stopped-off ] && [[ "$R" == *"✗ stopped (autostart off)"* ]]'
check 9e "step_status wires the SMB section (remote gather + local path + render)" '[ "$(grep -c "@@SMB@@" "$SRC")" -ge 2 ] && grep -q "_smb_summary_render" "$SRC" && grep -q "declare -f _ts_ipv4 _ts_state _ps_autostart _smb_summary _smb_folder_check _smb_sessions _smb_devices _smb_devname" "$SRC" && grep -q "@@SMB_DEV_START@@" "$SRC"'

# 9f/9g: run the REAL remote Status payload (its declare -f list + heredoc body, cut out of setup.sh)
# in a clean `env -i bash -s` with the stub docker, like ts-expiry check 11: a helper missing from the
# list (or renamed) is "command not found" there, which 9e's text grep cannot see.
mkset >/dev/null
printf '%s\n' 'docs         14      100.99.99.98  Fri Nov 27 09:10:11 2026 UTC     -            -' \
               'media        15      100.99.99.98  Fri Nov 27 09:12:30 2026 UTC     -            -' > "$SMBSTATUS"
PLIST=$(grep -v '^ *#' "$SRC" | grep -o 'declare -f [^;]*_smb_summary[^;]*' | head -1)
PBODY=$(awk '/declare -f .*_smb_summary.*<<.REMOTE_STATUS./{p=1; next} /^REMOTE_STATUS$/{p=0} p' "$SRC")
PNAMES=; for n in ${PLIST#declare -f }; do declare -F "$n" >/dev/null && PNAMES="$PNAMES $n"; done
PAY="$(declare -f $PNAMES)
$PBODY"
PRES=$(env -i PATH="$T/bin:/usr/bin:/bin" TZ=UTC DOCKER_STATE="$DOCKER_STATE" DOCKER_LOG="$DOCKER_LOG" SMBSTATUS="$SMBSTATUS" TMNT="$TMNT" bash -s <<<"$PAY" 2>&1)
check 9f "remote Status payload in a clean bash -s: SMB summary + device line, no 'command not found'" \
  '[ -n "$PLIST" ] && [ -n "$PBODY" ] && [[ "$PRES" == *"@@SMB@@running|2|0|1"* && "$PRES" == *"iphone-test|docs, media|09:10"* && "$PRES" != *"not found"* ]]'
rm -f "$SMBSTATUS"
# 9g: every system-location refusal fires with its own message (the 2b count alone survives losing an entry).
# Real directories of this host, skipped when absent; /sbin /bin /lib resolve into /usr, so /usr/* is what guards them.
reset; NREF=0; MISS=""
for d in / /etc /usr /usr/bin /boot /proc /sys /dev /var /var/log /root /opt /home /mnt /run /run/user; do
  [ -d "$d" ] || continue
  NREF=$((NREF+1))
  o=$(_smb_check_path "$d" 2>&1) && o="ACCEPTED"
  [[ "$o" == *"system location"* ]] || MISS="$MISS $d"
done
check 9g "system-location blocklist refuses each of $NREF real system dirs with the 'system location' reason (missing:${MISS:- none})" '[ "$NREF" -ge 10 ] && [ -z "$MISS" ]'

# 11 real smbstatus -S output (captured on the live server) as the fixture
FIX() { printf '%s\n' \
 'resumes      328     100.99.99.98  Fri Nov 27 09:13:18 2026 UTC     AES-128-GCM  AES-128-GMAC' \
 'formal-docs  328     100.99.99.98  Fri Nov 27 09:13:17 2026 UTC     AES-128-GCM  AES-128-GMAC' > "$SMBSTATUS"; }
mkset >/dev/null; FIX
check 11a "one device with two shares = one line: name via tailscale status, both shares, earliest time" \
  '[ "$(_smb_devices docker)" = "iphone-test|resumes, formal-docs|09:13" ]'
S=$(_smb_summary docker); R=$(_smb_summary_render "$S" "$(_smb_devices docker)")
echo "---- (s) section, 1 device ----"; echo "$R"
check 11b "(s): '1 device connected' (singular) + device line under the summary" '[ "$S" = "running|2|0|1" ] && [[ "$R" == *"· 1 device connected"* && "$R" != *"1 devices"* && "$R" == *"iphone-test"*"resumes, formal-docs   since 09:13"* ]] && [ "$(wc -l <<<"$R")" = 2 ]'
printf '%s\n' 'media        401     100.99.99.77  Fri Nov 27 10:02:05 2026 UTC     AES-128-GCM  AES-128-GMAC' >> "$SMBSTATUS"
S=$(_smb_summary docker); R=$(_smb_summary_render "$S" "$(_smb_devices docker)")
echo "---- (s) section, 2 devices ----"; echo "$R"
check 11c "(s): '2 devices connected', IP fallback name for an unknown device, one line each" '[[ "$R" == *"· 2 devices connected"* && "$R" == *"100.99.99.77"*"media   since 10:02"* ]] && [ "$(wc -l <<<"$R")" = 3 ]'
rm -f "$SMBSTATUS"
S=$(_smb_summary docker); R=$(_smb_summary_render "$S" "$(_smb_devices docker)")
echo "---- (s) section, 0 devices ----"; echo "$R"
check 11d "(s): '0 devices connected', no device lines" '[[ "$R" == *"· 0 devices connected"* ]] && [ "$(wc -l <<<"$R")" = 1 ]'
FIX; run $'0\n' 0 step_samba
check 11e "submenu Connected parses the real format: name, both shares, earliest since time" '[[ "$OUT" == *"iphone-test"*"opened: resumes, formal-docs  since 09:13"* ]]'

# 12 what Set up installs, up front; image download
reset; run $'1\nn' 0 step_samba
check 12a "header lists what is installed (image from _SMB_IMAGE), before anything runs" '[[ "$OUT" == *"What Set up installs:"* && "$OUT" == *"container \"samba\""* && "$OUT" == *"image $_SMB_IMAGE, downloaded now"* && "$OUT" == *"/opt/samba"*"root only"* && "$OUT" == *"no dnf packages"* && "$OUT" == *"Start All / Stop All"* && "$OUT" == *"Continue? [Y/n]"* && "$OUT" != *"Tailscale connected"* ]]'
check 12b "n = back, nothing changed, no checks, nothing written or run" '[ $RC = 0 ] && [[ "$OUT" == *"Cancelled. Nothing changed"* ]] && [ -z "$(RUNLINE)" ] && [ ! -e "$ENVF" ] && ! grep -q "pull\|image" "$DOCKER_LOG"'
reset; export NO_IMAGE=1; run "$SI"$'\n' 0 step_samba
check 12c "image missing: 'Downloading Samba image...' then pull, before run" '[[ "$OUT" == *"Downloading Samba image..."* ]] && [ "$(grep -n "^docker pull" "$DOCKER_LOG" | cut -d: -f1)" -lt "$(grep -n "^docker run" "$DOCKER_LOG" | cut -d: -f1)" ] && [[ "$OUT" == *"File sharing set up"* ]]'
reset; run "$SI"$'\n' 0 step_samba
check 12d "image present: no download message, no pull" '[[ "$OUT" != *"Downloading"* ]] && ! grep -q "^docker pull" "$DOCKER_LOG"'
reset; export NO_IMAGE=1 FAIL_PULL=1; run "$SI"$'\n' 0 step_samba
check 12e "pull fails: own honest error, nothing run, no success" '[ $RC != 0 ] && [[ "$OUT" == *"Could not download"* && "$OUT" != *"File sharing set up"* && "$OUT" != *"NOT RUNNING"* ]] && [ -z "$(RUNLINE)" ]'
mkset >/dev/null; export NO_IMAGE=1 FAIL_PULL=1; rm -f "$T/c/.pulled"; run $'3\ng\n' 0 step_samba
check 12f "pull fails during a change: the running share is NOT removed" '[ $RC != 0 ] && [ -d "$T/c/samba" ] && ! grep -q "^docker rm" "$DOCKER_LOG"'
unset NO_IMAGE FAIL_PULL

# 13 "since": smbstatus prints UTC with a date; shown in the host's local time, earliest by epoch
reset; mkset >/dev/null
printf 'docs         14      100.99.99.98  Fri Nov 27 09:31:14 2026 UTC     -            -\n' > "$SMBSTATUS"
r=$(TZ=Europe/Berlin _smb_devices docker)
check 13a "single UTC row 09:31:14 -> 10:31 in TZ=Europe/Berlin" '[[ "$r" == *"10:31" ]]'
YD=$(date -d yesterday +%a)
printf '%s\n' "docs         14      100.99.99.98  $(date -u -d 'yesterday 23:50' '+%a %b %e %H:%M:%S %Y') UTC     -            -" \
               "media        15      100.99.99.98  $(date -u -d 'today 08:00' '+%a %b %e %H:%M:%S %Y') UTC     -            -" > "$SMBSTATUS"
r=$(_smb_devices docker)
check 13b "yesterday 23:50 + today 08:00: earliest is yesterday's, shown with the weekday" '[ "$r" = "iphone-test|docs, media|$YD 23:50" ]'
printf '%s\n' "media        15      100.99.99.98  $(date -u -d 'today 08:00' '+%a %b %e %H:%M:%S %Y') UTC     -            -" > "$SMBSTATUS"
r=$(_smb_devices docker)
check 13c "only a time from today: plain HH:MM, no weekday" '[ "$r" = "iphone-test|media|08:00" ]'
row() { printf '%s\n' "media        15      100.99.99.98  $(date -u -d "$1 08:00" '+%a %b %e %H:%M:%S %Y') UTC     -            -" > "$SMBSTATUS"; }
row '6 days ago'; r=$(_smb_devices docker)
check 13d "6 days old: still the weekday form (unique)" '[ "$r" = "iphone-test|media|$(date -d "6 days ago" +%a) 08:00" ]'
row '7 days ago'; r=$(_smb_devices docker)
check 13e "7 days old: a date, not the weekday that would equal today's" '[ "$r" = "iphone-test|media|$(date -d "7 days ago" +"%-d %b") 08:00" ]'
row '40 days ago'; r=$(_smb_devices docker)
check 13f "40 days old: a date" '[ "$r" = "iphone-test|media|$(date -d "40 days ago" +"%-d %b") 08:00" ]'
# Fixed "now" in a non-UTC zone (date wrapper, setup.sh untouched): now = 2027-01-01 00:10 Europe/Berlin
# (= 2026-12-31 23:10 UTC), so local and UTC dates differ and a year boundary sits in the 7-day window.
FAKE_NOW="2027-01-01 00:10"
date() { if [ "$1" != -d ]; then command date -d "$FAKE_NOW" "$@"; elif [[ "$2" == *ago ]]; then command date -d "$FAKE_NOW $2" "${@:3}"; else command date "$@"; fi; }
brow() { printf '%s\n' "media        15      100.99.99.98  $(command date -u -d "$1 UTC" '+%a %b %e %H:%M:%S %Y') UTC     -            -" > "$SMBSTATUS"; TZ=Europe/Berlin _smb_devices docker; }
check 13g "Berlin: Jan 1 00:05 local (Dec 31 in UTC) is today: plain HH:MM" '[ "$(brow "2026-12-31 23:05")" = "iphone-test|media|00:05" ]'
check 13h "Berlin: 1 day back across the year boundary (Dec 31 23:50 local): weekday form" '[ "$(brow "2026-12-31 22:50")" = "iphone-test|media|Thu 23:50" ]'
check 13i "Berlin: 6 days back (Dec 26 10:00 local): weekday form" '[ "$(brow "2026-12-26 09:00")" = "iphone-test|media|Sat 10:00" ]'
check 13j "Berlin: 7 days back (Dec 25 00:20 local, Dec 24 in UTC): date form, local day" '[ "$(brow "2026-12-24 23:20")" = "iphone-test|media|25 Dec 00:20" ]'
check 13k "Berlin: 8 days back (Dec 24 12:00 local): date form" '[ "$(brow "2026-12-24 11:00")" = "iphone-test|media|24 Dec 12:00" ]'
unset -f date brow; unset FAKE_NOW
rm -f "$SMBSTATUS"

# 14 saved folders are re-checked before anything is removed or run
mkusb() { reset; run $'1\ny'"$T/files/docs"$'\n'"$T/mnt/usb/data"$'\n\nFakePass0123456x\nFakePass0123456x\n' 0 step_samba; }
mkusb; export FM_MODE=root; : > "$DOCKER_LOG"; run $'3\ng\n' 0 step_samba
check 14a "unmounted saved folder + password change: refused, names folder + reason + fix, no rm/run, share untouched" \
  '[ $RC != 0 ] && [[ "$OUT" == *"data"*"drive not mounted"* && "$OUT" == *"Manage folders"* && "$OUT" != *"Password changed"* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG" && [ -d "$T/c/samba" ] && [ "$(PWOF)" = FakePass0123456x ]'
: > "$DOCKER_LOG"; run $'2\n2\ny\n' 0 step_samba
check 14b "Manage folders can still remove the broken folder (only the rest is checked)" '[ "$(NSH)" = 1 ] && grep -qx "docs|$T/files/docs" "$SHF" && [ "$(grep -c "^docker run" "$DOCKER_LOG")" = 1 ]'
mkusb; export FM_MODE=root; : > "$DOCKER_LOG"; run $'2\n1\ny\n' 0 step_samba
check 14c "removing a good folder while another is broken: refused, config unchanged" '[ $RC != 0 ] && [[ "$OUT" == *"drive not mounted"* ]] && [ "$(NSH)" = 2 ] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG"'
mkusb; run $'7\nsamba\n' 0 step_samba; export FM_MODE=root; : > "$DOCKER_LOG"; run $'1\nyy' 0 step_samba
check 14d "Reuse in Set up with an unmounted saved folder: refused with message, nothing run" '[ $RC != 0 ] && [[ "$OUT" == *"Saved setup found"* && "$OUT" == *"drive not mounted"* && "$OUT" != *"File sharing set up"* && "$OUT" != *"Manage folders"* ]] && ! grep -q "^docker run" "$DOCKER_LOG"'
# Reuse offers to drop each unavailable saved folder (y/N); the password is kept
mkusb; run $'7\nsamba\n' 0 step_samba; export FM_MODE=root; : > "$DOCKER_LOG"; run $'1\nyyy\n' 0 step_samba
check 14f "Reuse + broken folder + drop y: sets up with the remaining folder and the same password" '[ $RC = 0 ] && [[ "$OUT" == *"File sharing set up: 1 folders"* ]] && [ "$(NSH)" = 1 ] && grep -qx "docs|$T/files/docs" "$SHF" && [ "$(PWOF)" = FakePass0123456x ] && [ "$(grep -c "^docker run" "$DOCKER_LOG")" = 1 ] && [[ "$(RUNLINE)" != *"mnt/usb"* ]]'
mkusb; run $'7\nsamba\n' 0 step_samba; export FM_MODE=root; : > "$DOCKER_LOG"; cp "$ENVF" "$T/env.before"; cp "$SHF" "$T/sh.before"; run $'1\nyyn' 0 step_samba
check 14g "Reuse + broken folder + drop n: refused cleanly, saved config untouched, never points at Manage folders" '[ $RC != 0 ] && [[ "$OUT" == *"drive not mounted"* && "$OUT" == *"Nothing was changed"* && "$OUT" != *"Manage folders"* && "$OUT" != *"File sharing set up"* ]] && ! grep -q "^docker run" "$DOCKER_LOG" && cmp -s "$ENVF" "$T/env.before" && cmp -s "$SHF" "$T/sh.before"'
reset; run $'1\ny'"$T/mnt/usb/data"$'\n\nFakePass0123456x\nFakePass0123456x\n' 0 step_samba; run $'7\nsamba\n' 0 step_samba; export FM_MODE=root; : > "$DOCKER_LOG"
run $'1\nyyy'"$T/files/docs"$'\n\n\n' 0 step_samba
check 14h "Reuse, only saved folder is broken, drop y: normal folder prompt, password kept (not asked)" '[ $RC = 0 ] && [[ "$OUT" == *"No saved folder left"* && "$OUT" == *"Folder to share"* && "$OUT" != *"Password for"* && "$OUT" == *"File sharing set up: 1 folders"* ]] && [ "$(PWOF)" = FakePass0123456x ] && grep -qx "docs|$T/files/docs" "$SHF"'
# drop EVERY saved folder, then Enter (cancel) at "Folder to share": nothing is written or run
reset; mkdir -p "$T/mnt/usb/data2"
run $'1\ny'"$T/mnt/usb/data"$'\n'"$T/mnt/usb/data2"$'\n\nFakePass0123456x\nFakePass0123456x\n' 0 step_samba; run $'7\nsamba\n' 0 step_samba
export FM_MODE=root; : > "$DOCKER_LOG"; cp "$ENVF" "$T/env.before"; cp "$SHF" "$T/sh.before"
run $'1\nyyyy\n' 0 step_samba
check 14n "Reuse, drop every saved folder, Enter at 'Folder to share': cancelled, config byte-identical, no rm/run" '[ $RC = 0 ] && [[ "$OUT" == *"No saved folder left"* && "$OUT" == *"Cancelled. Nothing changed."* && "$OUT" != *"File sharing set up"* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG" && cmp -s "$ENVF" "$T/env.before" && cmp -s "$SHF" "$T/sh.before"'
rmdir "$T/mnt/usb/data2"
# a broken saved folder must not block Stop/Start/Restart/Show password/Uninstall (none may go through _smb_apply)
mkusb; export FM_MODE=root; : > "$DOCKER_LOG"; run $'5\n' 0 step_samba
check 14i "broken saved folder: Stop works, no rm/run" '[ $RC = 0 ] && [[ "$OUT" == *"Stopped."* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG" && [ "$(cat "$T/c/samba/running")" = false ]'
: > "$DOCKER_LOG"; run $'4\n' 0 step_samba
check 14j "broken saved folder: Start works, no rm/run" '[ $RC = 0 ] && [[ "$OUT" == *"Started."* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG" && [ "$(cat "$T/c/samba/running")" = true ]'
: > "$DOCKER_LOG"; run $'6\n' 0 step_samba
check 14k "broken saved folder: Restart works, no rm/run" '[ $RC = 0 ] && [[ "$OUT" == *"Restarted."* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG"'
: > "$DOCKER_LOG"; run $'3\n\n' 0 step_samba
check 14l "broken saved folder: Show password (Enter = keep) works, no rm/run" '[ $RC = 0 ] && [[ "$OUT" == *FakePass0123456x* && "$OUT" == *"Password kept"* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG"'
: > "$DOCKER_LOG"; run $'7\nsamba\n' 0 step_samba
check 14m "broken saved folder: Uninstall works (container gone, config kept), no run" '[ $RC = 0 ] && [[ "$OUT" == *"File sharing removed"* ]] && [ ! -d "$T/c/samba" ] && ! grep -q "^docker run" "$DOCKER_LOG" && [ -e "$ENVF" ]'
mkset; rm -rf "$T/files/media"; : > "$DOCKER_LOG"; run $'3\ng\n' 0 step_samba; mkdir -p "$T/files/media"
check 14e "missing saved folder: refused as 'folder missing'" '[ $RC != 0 ] && [[ "$OUT" == *"media"*"folder missing"* ]] && ! grep -q "^docker rm\|^docker run" "$DOCKER_LOG"'
unset FM_MODE

# 15 Emergency restart brings samba back too (stubs: nothing real is touched)
mkset >/dev/null
eval "$(awk '/^step_emergency\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
EM=$T/emergency.log; : > "$EM"
( sudo() { if [ "$1" = docker ]; then command docker "${@:2}"; else echo "sudo $*" >> "$EM"; fi; }
  sg() { :; }; sleep() { :; }; _svc_power() { echo "power $*" >> "$EM"; }
  step_emergency <<<"y" >/dev/null 2>&1 )
check 15a "emergency restart starts samba (only when it exists)" 'grep -qx "power start samba" "$EM"'
rm -rf "$T/c/samba"; : > "$EM"
( sudo() { if [ "$1" = docker ]; then command docker "${@:2}"; else echo "sudo $*" >> "$EM"; fi; }
  sg() { :; }; sleep() { :; }; _svc_power() { echo "power $*" >> "$EM"; }
  step_emergency <<<"y" >/dev/null 2>&1 )
check 15b "samba not installed: skipped quietly" '! grep -q samba "$EM"'

# 16 Manage while stopped: a change is saved and applied, but Stop stays Stop (stopped + restart=no);
# a running share stays running with autostart on
mkset >/dev/null; run $'5\n' 0 step_samba; OLDPW=$(PWOF)
run $'3\ng\n' 0 step_samba
check 16a "stopped + Manage password: new password saved, container stays stopped with restart=no, one-line hint" \
  '[ $RC = 0 ] && [ "$(PWOF)" != "$OLDPW" ] && [ "$(cat "$T/c/samba/running")" = false ] && grep -qx no "$T/c/samba/policy" && [[ "$OUT" == *"File sharing is stopped - Start (4) to use it."* && "$OUT" != *"Samba running on port 445"* ]] && [ ! -e "$T/c/samba/listening" ]'
mkset >/dev/null; run $'5\n' 0 step_samba
run "2"$'\n'"$T/files/My Pics"$'\n\n' 0 step_samba
check 16b "stopped + Manage folders (add): folder saved + mounted, stays stopped with restart=no" \
  '[ $RC = 0 ] && [ "$(NSH)" = 3 ] && [ "$(grep -c "^/shares/" "$T/c/samba/mounts")" = 3 ] && [ "$(cat "$T/c/samba/running")" = false ] && grep -qx no "$T/c/samba/policy" && [[ "$OUT" == *"Start (4)"* ]]'
mkset >/dev/null; run $'5\n' 0 step_samba; run $'4\n' 0 step_samba
check 16c "Stop then Start still brings it back (autostart on again)" '[ "$(cat "$T/c/samba/running")" = true ] && grep -qx unless-stopped "$T/c/samba/policy"'
mkset >/dev/null; OLDPW=$(PWOF); run $'3\ng\n' 0 step_samba
check 16d "running + Manage password: stays running, restart=unless-stopped, no stopped hint" \
  '[ $RC = 0 ] && [ "$(PWOF)" != "$OLDPW" ] && [ "$(cat "$T/c/samba/running")" = true ] && grep -qx unless-stopped "$T/c/samba/policy" && [[ "$OUT" == *"Samba running on port 445"* && "$OUT" != *"is stopped"* ]]'

# 10 main menu + public-repo hygiene
check 10a "main menu line 16 reads 'Connect phone (Files app)' with the hint" 'grep -q "16)\${NC} Connect phone (Files app) .*iPhone/Android open server folders over Tailscale" "$SRC" && grep -q "16) run_step \"\[16\] Connect phone (Files app)\" \"_on_server step_samba\"" "$SRC"'
# The pattern is built at runtime from this machine's own values (federver
# config, $USER, local FILES_LOCATION), so none of them is ever written in the
# repo. No values available = SKIP (counted as a pass with a note).
CFG=${XDG_CONFIG_HOME:-$HOME/.config}/federver/config
PAT=""
addpat() { [ -n "$1" ] && PAT="$PAT${PAT:+|}$(printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\/]/\\&/g')"; }
if [ -r "$CFG" ]; then
  for k in SERVER_USER SERVER_IP SERVER_HOST_TS; do addpat "$(sed -n "s/^$k=//p" "$CFG" | head -1 | tr -d "\"'")"; done
fi
addpat "${USER:-}"
addpat "$(_env_get FILES_LOCATION "$H/../.env" 2>/dev/null)"
if [ -n "$PAT" ] && git -C "$H/.." rev-parse >/dev/null 2>&1; then
  BAD=$(git -C "$H/.." diff main -- setup.sh tests CHANGELOG.md README.md customer-guide.md 2>/dev/null | grep '^+' | grep -E -- "$PAT")
  check 10b "no user-specific values added vs main (pattern built at runtime)" '[ -z "$BAD" ]'
else
  echo "PASS  10b  SKIP: no local config/user values available to check against"; PASS=$((PASS+1))
fi

echo ""; echo "TOTAL: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
