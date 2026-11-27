#!/bin/bash
# Federver — Fedora XFCE server setup & management menu
# Single source of truth for the version is package.json (next to this script);
# read it at runtime so the banner never drifts. readlink -f resolves through
# symlinks — the installed `federver` is a symlink into the repo, so we must
# find package.json next to the REAL script, not next to /usr/local/bin.
_fv_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
# `|| true`: a missing/unreadable package.json falls through to the literal below
# rather than aborting (defensive — set -e is enabled later in this file).
FEDERVER_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$(dirname "$_fv_self")/package.json" 2>/dev/null || true)"
FEDERVER_VERSION="${FEDERVER_VERSION:-0.9.5}"
_FV_SELF=$_fv_self   # absolute path of this script: written into sync-job launchers
unset _fv_self
#
# HOW TO USE:
#   Always run from your LAPTOP. Server commands auto-route via SSH.
#
#   1. On the server (with monitor + keyboard) — the ONLY server step:
#      git clone https://github.com/hamr0/privcloud.git
#      cd privcloud && ./setup.sh
#      Pick option 1 — enables SSH. Then unplug the monitor.
#
#   2. From your laptop (everything else):
#      cd ~/privcloud && ./setup.sh
#      Pick option 2 first (SSH key auth), then any step in any order.
#      Server-side steps SSH in automatically. Laptop-side steps run locally.
#
#   After step 5 (Docker), log out and SSH back in before continuing.
#
#   You can re-run any step safely — they're idempotent.
#
#   Dry run (test the flow without executing anything):
#      ./setup.sh --dry-run
#   Prints what each step *would* run (sudo/sg/curl/rsync/tailscale up/down)
#   without actually changing system state. Read-only queries (hostname,
#   tailscale ip, docker ps) still execute so display logic works. From the
#   laptop, --dry-run propagates across the SSH hop to the server.

set -e

# Server connection details. Never hardcoded here — this is a public repo.
# Resolution order: environment variables → local config file → interactive
# prompt (then persisted). The config file lives outside the repo so nothing
# identifying can ever be committed.
FEDERVER_CONFIG="${FEDERVER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/federver/config}"
# shellcheck source=/dev/null
[[ -f "$FEDERVER_CONFIG" ]] && source "$FEDERVER_CONFIG"
SERVER_USER="${SERVER_USER:-}"
SERVER_IP="${SERVER_IP:-}"
# Optional Tailscale name/IP for the server. SERVER_IP is usually a LAN address
# that only answers at home; this is the address that answers from anywhere on
# the tailnet. When set, the laptop falls back to it automatically when the LAN
# address is unreachable (i.e. when roaming). Lives in the config file, not here.
SERVER_HOST_TS="${SERVER_HOST_TS:-}"

# ── Colors ───────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${DIM}$1${NC}"; }
warn() { echo -e "  ${YELLOW}!!${NC} $1"; }

# ── Safe crontab editing ─────────────────────────────
# Never rewrite a crontab with `(crontab -l | grep -v x; echo y) | crontab -`:
# the reader and the writer run concurrently, and `crontab -` can truncate the
# file before `crontab -l` has read it (root's crontab ended up empty). Always:
# read into a variable (_cron_get), build the new text, write it with ONE
# command (_cron_set), which re-reads and verifies. $1 is "root" (sudo crontab)
# or "user" (the laptop user's crontab).
_cron_cmd() { if [[ "$1" == root ]]; then sudo crontab "${@:2}"; else crontab "${@:2}"; fi; }

# Print the current crontab. "No crontab yet" and "no crontab binary" are an
# empty crontab (exit 0); any other failure (sudo denied, sudo missing, ...) returns 1.
_cron_get() {
    local out err rc=0 ef
    ef=$(mktemp) || return 1
    out=$(_cron_cmd "$1" -l 2>"$ef") || rc=$?   # stdout = the crontab; stderr kept apart
    err=$(<"$ef"); rm -f "$ef"
    if (( rc != 0 )); then
        [[ "$err" == *"no crontab for"* ]] && return 0
        # No crontab binary at all: nothing scheduled. Match the message precisely
        # ("[sudo: ]crontab: command not found"); "sudo: command not found" (no sudo,
        # rc 127) must stay an error. Matching beats probing `command -v crontab`
        # under sudo, which would be a second sudo call and a possible extra prompt.
        [[ "$err" == *"crontab: command not found"* ]] && return 0
        return 1
    fi
    printf '%s' "$out"
}

# Print $1 (a crontab) without the lines matching grep flags $2 / pattern $3.
_cron_drop() {
    [[ -n "$1" ]] || return 0
    printf '%s\n' "$1" | grep -v"$2" -- "$3" || true
}

# Write $2 as the whole crontab for $1, then re-read and require an exact match.
_cron_set() {
    local who="$1" new="$2" back
    if [[ -z "$new" ]]; then
        # Empty = remove the crontab (`crontab -r`, documented); never pipe an
        # empty file into `crontab -`. -r errors when none exists - already empty.
        local rerr
        rerr=$(_cron_cmd "$who" -r 2>&1) || [[ "$rerr" == *"no crontab for"* ]] || return 1
    else
        printf '%s\n' "$new" | _cron_cmd "$who" - || return 1
    fi
    back=$(_cron_get "$who") || return 1
    [[ "$back" == "$new" ]]
}

# Laptop sync-job crontab edits (user crontab), each verified.
_cron_add_sync() {  # job_name sched_spec script_path
    local cur kept
    cur=$(_cron_get user) || { fail "Could not read your crontab - '$1' NOT scheduled."; return 1; }
    kept=$(_cron_drop "$cur" "" "sync-$1.sh")
    _cron_set user "${kept:+$kept$'\n'}$2 $3" || { fail "Could not write your crontab - '$1' NOT scheduled."; return 1; }
}
_cron_remove_line() {  # line (fixed-string substring match, like grep -vF)
    local cur
    cur=$(_cron_get user) || { fail "Could not read your crontab - cron line not removed."; return 1; }
    _cron_set user "$(_cron_drop "$cur" F "$1")" || { fail "Could not write your crontab - cron line may still be present."; return 1; }
}
_cron_replace_line() {  # old_line new_line (exact whole-line match)
    local cur l new="" first=1 hit=0
    cur=$(_cron_get user) || { fail "Could not read your crontab - nothing changed."; return 1; }
    while IFS= read -r l; do
        if [[ "$l" == "$1" ]]; then l="$2"; hit=1; fi
        if (( first )); then new="$l"; first=0; else new+=$'\n'"$l"; fi
    done <<<"$cur"
    (( hit )) || { fail "Job line not found in crontab - nothing changed."; return 1; }
    _cron_set user "$new" || { fail "Could not write your crontab - change not applied."; return 1; }
}

# ── Dry-run mode ─────────────────────────────────────
# Invoked as `./setup.sh --dry-run`. Shims the main state-changing entry
# points (sudo, sg, curl, ssh, tailscale up/down) with echo-only stubs, so
# you can walk the menu and see which commands would run without actually
# executing them. Read-only queries (hostname, awk, docker ps, tailscale ip)
# still work, so display logic is exercised normally.
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

if [[ "$DRY_RUN" == "1" ]]; then
    _dry() { echo -e "    ${YELLOW}[dry-run]${NC} ${DIM}$*${NC}" >&2; return 0; }
    sudo()  { _dry "sudo $*"; }
    sg()    { _dry "sg $*"; }
    curl()  { _dry "curl $*"; }
    rsync() { _dry "rsync $*"; }
    # tailscale: leave read-only queries (`ip`, `status`) alone, stub state changes.
    tailscale() {
        case "${1:-}" in
            ip|status) command tailscale "$@" 2>/dev/null || echo "" ;;
            *)         _dry "tailscale $*" ;;
        esac
    }
fi

# ── SSH connection hardening ─────────────────────────
# Every laptop→server SSH in this script goes through this wrapper. Without it,
# a wrong/unreachable address (e.g. a LAN IP while roaming) makes ssh block on
# the kernel's default connect timeout — a minute-plus "hang" with no feedback.
# ConnectTimeout fails fast instead; the keepalives drop a frozen roaming link
# within ~1min rather than freezing the menu. `command ssh` avoids recursion.
# The same options reach rsync's own ssh through RSYNC_RSH (rsync spawns the real
# binary, not this function), so every rsync here - one-time copies, previews, jobs -
# fails fast the same way. _RSYNC_FLAGS is the one flag set of every laptop rsync
# (-s: the remote shell must not re-split a path with spaces).
_SSH_OPTS="-o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
export RSYNC_RSH="ssh $_SSH_OPTS"
_RSYNC_FLAGS="-avh --progress -s"
ssh() {
    command ssh $_SSH_OPTS "$@"
}

# True if a TCP connection to host:port completes within 2s. Used to pick a
# reachable server address before opening the menu. /dev/tcp is a bash builtin.
_tcp_open() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# Shell-quote a value so it survives exactly one remote shell parse over ssh.
# Stops a path containing spaces, quotes, or metacharacters from breaking (or
# injecting into) a remote command. Use for ANY user/config path embedded in an
# ssh "..." string that is executed directly (one parse). Not sufficient for
# strings later re-parsed by `bash -c` or written to scheduled scripts.
_shq() { printf '%q' "$1"; }

# ── Container power: autostart follows the last action ──────────────────────
# ONE source of truth for starting, stopping and restarting a container, used
# by every menu path (server-local, laptop-over-ssh, bulk, standalone):
#   stop    -> docker update --restart=no,             then docker stop
#   start   -> docker update --restart=unless-stopped, then docker start
#   restart -> docker update --restart=unless-stopped, then docker restart
# A restart means "I want it running", so it must clear a restart=no left by an
# earlier Stop (the incident: Stop, then Restart, then a reboot left it down).
# Afterwards the state AND the policy are read back; any mismatch is a failure,
# never a false "complete". Failures print one line to stderr and exit non-zero:
#   2 docker unreachable, 3 no such container, 4 policy update failed,
#   5 docker action failed, 6 read-back mismatch, 7 sudo refused.
# _svc_power_body prints the shell text; the runners below execute it locally
# (a fresh bash, so its exits never kill the menu) or over ssh -t (sudo needs a
# TTY). c is set from an already-quoted word, so odd names survive one parse.
_svc_power_body() { # action quoted-container-word
    local p v run
    case "$1" in
        start)   p=unless-stopped; v=start;   run=true  ;;
        stop)    p=no;             v=stop;    run=false ;;
        restart) p=unless-stopped; v=restart; run=true  ;;
        *) return 1 ;;
    esac
    printf '%s\n' "c=$2" \
        "$(_svc_sudo_guard)" \
        "sudo docker info >/dev/null 2>&1 || { echo \"docker is not reachable\" >&2; exit 2; }" \
        "sudo docker inspect \"\$c\" >/dev/null 2>&1 || { echo \"no such container: \$c\" >&2; exit 3; }" \
        "sudo docker update --restart=$p \"\$c\" >/dev/null || { echo \"\$c: could not set restart policy $p\" >&2; exit 4; }" \
        "sudo docker $v \"\$c\" >/dev/null || { echo \"\$c: docker $v failed\" >&2; exit 5; }" \
        "s=\$(sudo docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' \"\$c\" 2>/dev/null)" \
        "[ \"\$s\" = \"$run $p\" ] || { echo \"\$c: expected '$run $p', found '\$s'\" >&2; exit 6; }"
}
# The sudo-refused guard both bodies start with (exit 7), one text for both.
_svc_sudo_guard() { echo "sudo -v 2>/dev/null || { echo \"sudo failed (wrong password or not allowed) - nothing changed\" >&2; exit 7; }"; }
# Same rule for every container on the host: start and stop = all (incl. exited
# ones, so a stopped-on-its-own unless-stopped container gets restart=no and
# stays down after a daemon start); restart = the running ones only. Standalone ones (adguard, syncthing) are
# ordinary containers here, so they are covered with no special case.
_svc_power_all_body() { # action
    local list="docker ps -a --format '{{.Names}}'"
    [[ "$1" == restart ]] && list="docker ps --format '{{.Names}}'"
    printf '%s\n' \
        "$(_svc_sudo_guard)" \
        "sudo docker info >/dev/null 2>&1 || { echo \"docker is not reachable\" >&2; exit 2; }" \
        "rc=0; for n in \$(sudo $list); do (" \
        "$(_svc_power_body "$1" '"$n"')" \
        ") || rc=1; done; exit \$rc"
}
_svc_power()            { # action container   (on the server itself)
    if [[ "${DRY_RUN:-0}" == 1 ]]; then echo "    [dry-run] container $1 $2" >&2; return 0; fi
    bash -c "$(_svc_power_body "$1" "$(_shq "$2")")"
}
_svc_power_all()        { # action             (on the server itself)
    if [[ "${DRY_RUN:-0}" == 1 ]]; then echo "    [dry-run] all containers $1" >&2; return 0; fi
    bash -c "$(_svc_power_all_body "$1")"
}
_svc_power_remote()     { ssh -t "$SERVER_USER@$SERVER_IP" "$(_svc_power_body "$1" "$(_shq "$2")")"; }  # action container
_svc_power_all_remote() { ssh -t "$SERVER_USER@$SERVER_IP" "$(_svc_power_all_body "$1")"; }              # action

# Print "name|status" like `docker ps -a --format '{{.Names}}|{{.Status}}'`, but
# a stopped container whose restart policy is "no" reads "stopped (autostart
# off)", so a deliberate stop is visible before a reboot. Pass the docker
# command words: _ps_autostart docker | _ps_autostart sudo docker.
_ps_autostart() {
    local ps pol n s
    ps=$("$@" ps -a --format '{{.Names}}|{{.Status}}') || return $?
    [[ -z "$ps" ]] && return 0
    pol=$("$@" inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $("$@" ps -aq) 2>/dev/null)
    while IFS='|' read -r n s; do
        [[ -z "$n" ]] && continue
        if [[ "$s" == Exited* || "$s" == Created* ]] && grep -qxF "/$n no" <<<"$pol"; then
            s="stopped (autostart off)"
        fi
        printf '%s|%s\n' "$n" "$s"
    done <<<"$ps"
}

# Run a read-only shell snippet on the server (non-TTY, no sudo) and print its
# stdout. Prints "unreachable" if the ssh itself fails, so callers can tell
# "not installed" (empty output) from "couldn't ask".
_server_probe() {
    local out
    out=$(ssh "$SERVER_USER@$SERVER_IP" "$1" 2>/dev/null) || { echo "unreachable"; return; }
    echo "$out"
}

# Prompt once for the server's sudo password and check it. sudo's cached
# credential does not cross ssh sessions, so root reads from a non-TTY session
# need the password supplied each time over ssh's encrypted stdin (the same
# `sudo -S -p ''` pattern the privileged Download uses). On success the
# password is left in _SRV_PW for the caller's printf-builtin pipe (never argv,
# never echoed) and the caller MUST `unset _SRV_PW`. Returns 0 ok; 1 wrong
# password; 2 server unreachable. Caller reports - nothing is read on failure.
_server_sudo_pw_prompt() {
    local rc
    _SRV_PW=""
    read -rsp "  federver sudo password: " _SRV_PW; echo
    printf '%s\n' "$_SRV_PW" | ssh "$SERVER_USER@$SERVER_IP" "sudo -S -p '' true" > /dev/null 2>&1 && return 0
    rc=$?
    unset _SRV_PW
    (( rc == 255 )) && return 2
    return 1
}

# Run a script as root on the server in ONE non-TTY ssh session, using the
# password _SRV_PW (from _server_sudo_pw_prompt) and never trusting sudo to
# consume it. Stdin carries the password line then the script text. The
# remote shell reads the password into a variable (never argv, never echoed)
# and the script into another, then pipes ONLY the password to `sudo -S`: a
# NOPASSWD rule or cached ticket (sudo never reads) just leaves the password unused. The script runs
# via `bash -c` (HOME kept as the login user's). Caveat: when sudo does not
# read, bash -c inherits the pipe still holding the password line, so the
# script must NEVER read stdin (no cat, read, docker exec -i, ...). $1 = script text.
_server_sudo_run() {
    printf '%s\n%s\n' "$_SRV_PW" "$1" | ssh "$SERVER_USER@$SERVER_IP" \
        'IFS= read -r pw; s=$(cat); printf "%s\n" "$pw" | sudo -S -p "" env HOME="$HOME" bash -c "$s"' 2>/dev/null
}

# Gate for a two-sided service's laptop menu (Syncthing, Tailscale).
#   $1 label   $2 laptop state ("" = not installed)   $3 server state ("" = not installed)
#   $4 fn that installs the laptop side   $5 fn that installs the server side
#   $6 fn "<side>" that uninstalls one side ("laptop" | "server"), typed confirm + verify
# Returns 10 when both sides are installed (caller continues to its full menu).
# Anything else is the final result for the caller to return: 2 = user backed
# out / nothing changed (run_step skips the DONE banner), 1 = failure.
# Opening the menu never installs anything by itself.
_two_sided_gate() {
    local label="$1" lap="$2" srv="$3" inst_lap="$4" inst_srv="$5" uninst="$6" reply
    if [[ "$srv" == "unreachable" ]]; then
        fail "Cannot reach the server at $SERVER_IP - changing nothing."
        return 1
    fi
    [[ -n "$lap" && -n "$srv" ]] && return 10

    if [[ -z "$lap" && -z "$srv" ]]; then
        warn "$label isn't installed."
        read -rp "  Install it now? [y/N] " reply || reply=""
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Not installing."
            return 2
        fi
        "$inst_lap" || return 1
        echo -e "  ${BOLD}── Server side ──${NC}"
        _on_server "$inst_srv" || return $?
        return 0
    fi

    # Partial: exactly one side present.
    echo -e "  Laptop: ${lap:-${YELLOW}not installed${NC}}"
    echo -e "  Server: ${srv:-${YELLOW}not installed${NC}}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Install the missing side"
    echo -e "  ${BOLD}2)${NC} ${RED}Uninstall the remaining side${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -rp "  Choose: " reply || reply=0
    case "$reply" in
        1)
            # `|| return $?`: under set -e a bare failing call would abort the script.
            if [[ -z "$lap" ]]; then
                "$inst_lap" || return $?
                return 0
            fi
            echo -e "  ${BOLD}── Server side ──${NC}"
            _on_server "$inst_srv" || return $?
            return 0
            ;;
        2)
            if [[ -n "$lap" ]]; then "$uninst" laptop || return $?
            else "$uninst" server || return $?; fi
            return 0
            ;;
        *) return 2 ;;
    esac
}

# Run a step with clear screen and success/fail banner.
# Convention: a step that returns 2 means "user picked Back before doing
# anything" — skip the banner and the Press-Enter prompt so it feels like
# a clean return to the main menu instead of "DONE" for a no-op.
run_step() {
    local step_name="$1"
    local step_func="$2"
    clear
    echo -e "${BOLD}${BLUE}=== $step_name ===${NC}"
    echo ""
    local rc=0
    $step_func || rc=$?
    if (( rc == 2 )); then
        return
    fi
    if (( rc == 0 )); then
        echo ""
        echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${GREEN}✓ $step_name — DONE${NC}"
        echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo ""
        echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${RED}✗ $step_name — FAILED${NC}"
        echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    echo ""
    read -p "  Press Enter to continue..." -r
}

# ── Location-aware routing ─────────────────────────
_is_server() { [[ "$(hostname)" == "federver" ]]; }

# Ensure SERVER_USER/SERVER_IP are known before any laptop→server SSH. Prompts
# once and persists to FEDERVER_CONFIG (outside the repo). No-op on the server
# itself, which runs steps locally and never needs these.
_require_server_config() {
    _is_server && return 0
    [[ -n "$SERVER_USER" && -n "$SERVER_IP" ]] && return 0
    echo ""
    info "First run: where does your server live? (saved to ${FEDERVER_CONFIG})"
    local no_input="No input. Set SERVER_USER/SERVER_IP env vars or edit ${FEDERVER_CONFIG}."
    while [[ -z "$SERVER_USER" ]]; do
        read -rp "  Server username: " SERVER_USER || { echo ""; fail "$no_input"; return 1; }
    done
    while [[ -z "$SERVER_IP" ]]; do
        read -rp "  Server IP or hostname: " SERVER_IP || { echo ""; fail "$no_input"; return 1; }
    done
    # Optional: a Tailscale name/IP that works when away from home. If the
    # address above is a LAN IP, set this so the menu keeps working while
    # roaming; press Enter to skip.
    [[ -z "$SERVER_HOST_TS" ]] && \
        read -rp "  Tailscale name/IP for access away from home (optional): " SERVER_HOST_TS
    mkdir -p "$(dirname "$FEDERVER_CONFIG")"
    ( umask 077
      cat > "$FEDERVER_CONFIG" <<EOF
SERVER_USER="$SERVER_USER"
SERVER_IP="$SERVER_IP"
SERVER_HOST_TS="$SERVER_HOST_TS"
EOF
    ) && ok "Saved server config to $FEDERVER_CONFIG"
}

_on_server() {
    local step="$1"
    if _is_server; then
        "$step"
    else
        info "Connecting to server..."
        echo ""
        local dry=""
        [[ "$DRY_RUN" == "1" ]] && dry="--dry-run "
        ssh -t "$SERVER_USER@$SERVER_IP" "cd ~/privcloud && GIT_TERMINAL_PROMPT=0 git pull --ff-only -q 2>/dev/null; ./setup.sh ${dry}--run $step"
    fi
}

_on_laptop() {
    local step="$1"
    if _is_server; then
        warn "Runs from laptop. Exit SSH, then: ${BOLD}federver${NC}"
        return 0
    else
        "$step"
    fi
}

# Pick a reachable address for the server before the menu opens. SERVER_IP is
# typically a LAN address that only answers at home; SERVER_HOST_TS (optional,
# from the config file) is the Tailscale address that answers from anywhere.
# Probe the LAN address first — if it answers we keep it (fast path at home);
# otherwise switch to the Tailscale fallback so being away from home fails over
# instead of hanging. No-op on the server itself, and a no-op (beyond the ssh
# wrapper's fast-fail) when no fallback is configured.
_pick_server_endpoint() {   # prints the address to use; rc 1 = neither answered (prints SERVER_IP)
    local ep=$SERVER_IP rc=0
    if ! _is_server && [[ -n "$SERVER_HOST_TS" && "$SERVER_HOST_TS" != "$SERVER_IP" ]] && ! _tcp_open "$SERVER_IP" 22; then
        if _tcp_open "$SERVER_HOST_TS" 22; then ep=$SERVER_HOST_TS; else rc=1; fi
    fi
    printf '%s' "$ep"
    return $rc
}
_resolve_server_endpoint() {
    _is_server && return 0
    local ep rc=0
    ep=$(_pick_server_endpoint) || rc=$?
    if (( rc != 0 )); then
        warn "Neither $SERVER_IP nor $SERVER_HOST_TS answered on port 22."
        warn "If you're away from home, make sure Tailscale is up on this machine."
    elif [[ "$ep" != "$SERVER_IP" ]]; then
        info "LAN address ($SERVER_IP) unreachable — using Tailscale ($ep)."
        SERVER_IP=$ep
    fi
    return 0
}

step_emergency() {
    warn "Emergency restart — this will restart ALL containers and restore DNS."
    echo ""
    info "Actions:"
    info "  1. Re-enable systemd-resolved stub (restores local DNS if AdGuard is broken)"
    info "  2. Start all Docker containers (compose stack + AdGuard + Syncthing + Samba)"
    info "  3. Restart systemd-resolved"
    echo ""
    read -p "  Continue? [Y/n] " -n 1 -r
    echo ""
    [[ "$REPLY" =~ ^[Nn]$ ]] && { info "Cancelled."; return 0; }

    # Step 1: Ensure systemd-resolved stub is available as fallback DNS
    # (AdGuard disables it; if AdGuard is down, nothing resolves)
    info "Restoring systemd-resolved stub listener as DNS fallback..."
    sudo rm -f /etc/systemd/resolved.conf.d/disable-stub.conf
    sudo systemctl restart systemd-resolved > /dev/null 2>&1
    ok "systemd-resolved restored (port 53 available as fallback)."

    # Step 2: Start all containers
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$SCRIPT_DIR"
    info "Starting compose stack..."
    sg docker -c "docker compose up -d" 2>&1 | grep -v "^$" || true
    info "Starting standalone containers..."
    # Per-container rule (autostart follows the action). A standalone one that
    # was never installed is skipped quietly; a real failure is reported.
    for c in adguard syncthing samba; do
        sudo docker inspect "$c" > /dev/null 2>&1 || continue
        _svc_power start "$c" || warn "Could not start $c."
    done

    # Step 3: Once AdGuard is back, re-disable the stub so AdGuard can bind 53
    sleep 2
    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^adguard$'; then
        info "AdGuard is back — re-disabling systemd-resolved stub..."
        sudo mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf > /dev/null
        sudo systemctl restart systemd-resolved > /dev/null 2>&1
        ok "AdGuard has port 53 back."
    else
        warn "AdGuard didn't start. systemd-resolved stub stays active as DNS fallback."
        warn "Check: sudo docker logs adguard"
    fi

    echo ""
    ok "Emergency restart complete."
    info "Check: docker ps -a"
}

_show_menu_header() {
    clear
    local where_color where_label
    if _is_server; then
        where_color="$YELLOW"; where_label="server"
    else
        where_color="$GREEN"; where_label="laptop"
    fi
    echo ""
    echo -e "  ${BOLD}federver${NC} ${DIM}v${FEDERVER_VERSION}${NC} — Fedora XFCE Server Manager · ${where_color}${where_label}${NC}"
    echo -e "  ${DIM}One box. Every service. No cloud overlords.${NC}"
    echo -e "  ${BLUE}─────────────────────────────────────────────────${NC}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "  ${YELLOW}DRY RUN${NC} ${DIM}— no commands will be executed${NC}"
    fi
}

show_menu() {
    if _is_server; then
        _show_server_menu
    else
        _show_laptop_menu
    fi
}

_show_server_menu() {
    _show_menu_header
    echo -e "  ${DIM}For the full menu, run ${BOLD}${YELLOW}\"federver\"${NC} ${DIM}from your laptop.${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC}  Enable SSH + auto-login + hostname  ${YELLOW}← bootstrap (needs monitor)${NC}"
    echo -e "  ${BOLD}s)${NC}  Status"
    echo -e "  ${BOLD}p)${NC}  Power (shutdown / restart)"
    echo -e "  ${BOLD}e)${NC}  ${RED}Emergency: restart all services${NC}      ${DIM}← fixes DNS/container outages${NC}"
    echo -e "  ${BOLD}0)${NC}  Exit"
    echo ""
}

_show_laptop_menu() {
    _show_menu_header
    echo ""
    echo -e "  ${YELLOW}-- Initial setup (run once, in order) --${NC}"
    echo -e "  ${BOLD}1)${NC}  Enable SSH + auto-login + hostname  ${YELLOW}← only step on server with monitor${NC}"
    echo -e "  ${BOLD}2)${NC}  SSH key auth                        ${YELLOW}← from laptop, exit SSH first${NC}"
    echo -e "  ${BOLD}3)${NC}  System update"
    echo -e "  ${BOLD}4)${NC}  Enable auto-updates                 ${YELLOW}← security only, kernel excluded${NC}"
    echo -e "  ${BOLD}5)${NC}  Install Docker                      ${YELLOW}← log out & SSH back in after${NC}"
    echo ""
    echo -e "  ${DIM}-- Services --${NC}"
    echo -e "  ${BOLD}6)${NC}  Manage firewall                     ${DIM}← status, add/remove ports, defaults${NC}"
    echo -e "  ${BOLD}7)${NC}  Manage services                     ${DIM}← deploy, status, start/stop/restart, logs${NC}"
    echo ""
    echo -e "  ${DIM}-- Extras (optional, run anytime) --${NC}"
    echo -e "  ${BOLD}8)${NC}  Manage Tailscale                    ${DIM}← install, status, up/down${NC}"
    echo -e "  ${BOLD}9)${NC}  Manage WireGuard                    ${DIM}← install, peers, QR, remove${NC}"
    echo -e "  ${BOLD}10)${NC} Manage AdGuard                      ${DIM}← install DNS ad blocker, uses Tailscale${NC}"
    echo -e "  ${BOLD}11)${NC} Manage storage                      ${DIM}← USB drives, media/data paths${NC}"
    echo -e "  ${BOLD}12)${NC} Manage Syncthing                    ${DIM}← real-time bidirectional file sync${NC}"
    echo -e "  ${BOLD}13)${NC} Manage remote desktop               ${DIM}← install, access XFCE via RDP${NC}"
    echo -e "  ${BOLD}16)${NC} Connect phone (Files app)           ${DIM}← iPhone/Android open server folders over Tailscale${NC}"
    echo ""
    echo -e "  ${DIM}-- Immich photo management --${NC}"
    echo -e "  ${BOLD}i)${NC}  Immich (privcloud)                  ${DIM}← start/stop/status/update/backup${NC}"
    echo ""
    echo -e "  ${DIM}-- Tools --${NC}"
    echo -e "  ${BOLD}14)${NC} Manage sync and backups             ${DIM}← sync jobs, Immich backup, disk monitor${NC}"
    echo -e "  ${BOLD}15)${NC} Save to pass                        ${DIM}← from laptop, backup everything to pass${NC}"
    echo ""
    echo -e "  ${BOLD}s)${NC}  Status     ${BOLD}i)${NC}  Immich     ${BOLD}p)${NC}  Power     ${BOLD}r)${NC}  Reset password     ${BOLD}a)${NC}  Run all (3-7)     ${BOLD}0)${NC}  Exit"
    echo ""
}

step_ssh() {
    # Bootstrap step — must run on the server's physical console, not over SSH.
    # If we got here via SSH, the server already has SSH working and this step
    # would just reinstall things pointlessly (or confusingly install openssh
    # onto the laptop if run locally on the wrong machine).
    if [[ -n "${SSH_CLIENT:-}" || -n "${SSH_CONNECTION:-}" ]]; then
        fail "Step 1 is the bootstrap step — must run on the server with a physical monitor + keyboard."
        echo ""
        info "You're in an SSH session right now, which means SSH is already working on the server."
        info "Skip step 1 and continue with step 2 (SSH key auth) from your laptop."
        return 1
    fi
    if ! _is_server && [[ "$(hostname)" != "fedora" && "$(hostname)" != localhost* ]]; then
        # Heuristic: if hostname is neither "federver" nor a fresh-install default,
        # we're probably on the laptop running step 1 by accident.
        fail "Step 1 runs on the server, not the laptop."
        echo ""
        info "This is the bootstrap step. Go to the server, plug in monitor + keyboard,"
        info "open a terminal, and run: ${BOLD}cd privcloud && ./setup.sh${NC}, then pick 1."
        info "Once it's done, come back here to the laptop and run step 2 (SSH key auth)."
        return 1
    fi

    info "This enables remote access so you can unplug the monitor after."
    echo ""
    sudo dnf install -y openssh-server > /dev/null 2>&1
    sudo systemctl enable --now sshd

    sudo hostnamectl set-hostname federver
    ok "Hostname set to: federver"

    sudo mkdir -p /etc/lightdm/lightdm.conf.d
    cat <<EOF | sudo tee /etc/lightdm/lightdm.conf.d/autologin.conf > /dev/null
[Seat:*]
autologin-user=$USER
EOF
    ok "Auto-login enabled for: $USER"

    xfconf-query -c xfce4-screensaver -p /lock/enabled -s false 2>/dev/null || true
    xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null || true
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1
    ok "Screen lock and sleep disabled"

    # Create global commands: 'setup' and 'privcloud'
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    sudo tee /usr/local/bin/federver > /dev/null << WRAPPER
#!/bin/bash
exec $SCRIPT_DIR/setup.sh "\$@"
WRAPPER
    sudo chmod +x /usr/local/bin/federver
    sudo tee /usr/local/bin/privcloud > /dev/null << WRAPPER
#!/bin/bash
exec $SCRIPT_DIR/privcloud "\$@"
WRAPPER
    sudo chmod +x /usr/local/bin/privcloud
    ok "Commands available: 'federver' and 'privcloud' (from anywhere)"

    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}DONE — You can unplug the monitor now.${NC}"
    echo ""
    echo -e "  From your laptop, run:"
    echo -e "    ${BOLD}ssh $USER@$IP${NC}"
    echo ""
    echo -e "  Then run: ${BOLD}federver${NC} (from anywhere)"
    echo -e "  Run step 2 from laptop (not SSH) to set up key auth."
    echo -e "  Then SSH in and continue with Run all (3-7)."
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

step_sshkey() {
    info "Run this from your LAPTOP, not over SSH."
    info "Copies your SSH key to the server and disables password login."
    echo ""

    if [[ ! -f ~/.ssh/id_ed25519.pub && ! -f ~/.ssh/id_rsa.pub ]]; then
        info "No SSH key found. Generating one..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
        ok "Key generated: ~/.ssh/id_ed25519"
    fi

    info "Copying SSH key to server (enter the password one last time)..."
    ssh-copy-id "$SERVER_USER@$SERVER_IP"
    ok "Key copied."

    info "Testing key login..."
    if ssh -o PasswordAuthentication=no "$SERVER_USER@$SERVER_IP" "echo ok" > /dev/null 2>&1; then
        ok "Key login works!"
        echo ""
        info "Disabling password login on server..."
        ssh -t "$SERVER_USER@$SERVER_IP" "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo systemctl restart sshd"
        ok "Password login disabled. Key-only from now on."
        echo ""
        info "Save your key to pass:"
        echo -e "    ${BOLD}cat ~/.ssh/id_ed25519 | pass insert -m ssh/federver-key${NC}"
    else
        fail "Key login failed. Password login NOT disabled. Check your key."
        return 1
    fi
}

step_update() {
    info "Updating all packages to latest versions..."
    sudo dnf upgrade -y
    ok "System updated."
}

step_autoupdates() {
    info "Installs automatic userspace security updates."
    info "Kernel is excluded — reboot for new kernels manually when you're home."
    echo ""
    sudo dnf install -y dnf5-plugin-automatic
    local conf="/etc/dnf/dnf5-plugins/automatic.conf"
    if [[ ! -f "$conf" ]]; then
        sudo mkdir -p /etc/dnf/dnf5-plugins
        sudo cp /usr/share/dnf5/dnf5-plugins/automatic.conf "$conf"
    fi
    # Security advisories only (skip routine updates)
    sudo sed -i 's/^upgrade_type = .*/upgrade_type = security/' "$conf"
    # Actually apply the updates (default is download-only)
    sudo sed -i 's/^apply_updates = .*/apply_updates = yes/' "$conf"
    # Belt-and-suspenders: exclude kernel packages even if a kernel ships
    # under a security advisory. Kernel updates require a reboot, and we
    # don't want unattended kernel swaps on a headless home server.
    if ! grep -q '^exclude = ' "$conf"; then
        sudo sed -i '/^\[base\]/a exclude = kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-headers' "$conf"
    else
        sudo sed -i 's/^exclude = .*/exclude = kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-headers/' "$conf"
    fi
    sudo systemctl enable --now dnf-automatic.timer
    ok "Auto-updates enabled (security only, kernel excluded)."
}

step_docker() {
    info "Docker runs all your services (Immich, Navidrome, FileBrowser, etc)."
    echo ""
    sudo dnf install -y dnf-plugins-core
    sudo dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER
    ok "Docker installed."
    echo ""
    warn "IMPORTANT: Log out and SSH back in before continuing!"
    echo -e "     ${BOLD}exit${NC}"
    echo -e "     ${BOLD}ssh $USER@$(hostname -I | awk '{print $1}')${NC}"
    echo -e "     ${BOLD}cd privcloud && ./setup.sh${NC}   (then pick step 6)"
}

_fw_defaults() {
    info "Applying default firewall rules..."
    sudo firewall-cmd --permanent --add-service=ssh > /dev/null
    sudo firewall-cmd --permanent --add-port=2283/tcp > /dev/null   # Immich
    sudo firewall-cmd --permanent --add-port=4533/tcp > /dev/null   # Navidrome
    sudo firewall-cmd --permanent --add-port=8080/tcp > /dev/null   # FileBrowser
    sudo firewall-cmd --permanent --add-port=3001/tcp > /dev/null   # Uptime Kuma
    sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 2>/dev/null || true
    sudo firewall-cmd --reload > /dev/null
    ok "Defaults applied: SSH, Immich (2283), Navidrome (4533), FileBrowser (8080), Uptime Kuma (3001), Tailscale trusted."
}

_fw_status() {
    echo ""
    echo -e "  ${BOLD}Firewall status${NC}"
    echo ""
    sudo firewall-cmd --list-all | sed 's/^/    /'
}

_fw_add() {
    echo ""
    read -p "  Port (e.g. 8443) or service (e.g. https): " what
    [[ -z "$what" ]] && { fail "Nothing entered."; return 1; }
    if [[ "$what" =~ ^[0-9]+(/tcp|/udp)?$ ]]; then
        [[ "$what" != */* ]] && what="$what/tcp"
        sudo firewall-cmd --permanent --add-port="$what" && sudo firewall-cmd --reload > /dev/null \
            && ok "Opened port $what."
    else
        sudo firewall-cmd --permanent --add-service="$what" && sudo firewall-cmd --reload > /dev/null \
            && ok "Added service $what."
    fi
}

_fw_remove() {
    _fw_status
    echo ""
    read -p "  Port (e.g. 8443/tcp) or service (e.g. https) to remove: " what
    [[ -z "$what" ]] && { fail "Nothing entered."; return 1; }
    if [[ "$what" =~ ^[0-9]+(/tcp|/udp)$ ]]; then
        sudo firewall-cmd --permanent --remove-port="$what" && sudo firewall-cmd --reload > /dev/null \
            && ok "Closed port $what."
    else
        sudo firewall-cmd --permanent --remove-service="$what" && sudo firewall-cmd --reload > /dev/null \
            && ok "Removed service $what."
    fi
}

step_firewall() {
    echo -e "  ${BOLD}1)${NC} Status / list all"
    echo -e "  ${BOLD}2)${NC} Add port or service"
    echo -e "  ${BOLD}3)${NC} Remove port or service"
    echo -e "  ${BOLD}4)${NC} Apply defaults                ${DIM}(SSH + service ports + trust Tailscale)${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " fw_choice
    case $fw_choice in
        1) _fw_status ;;
        2) _fw_add ;;
        3) _fw_remove ;;
        4) _fw_defaults ;;
        0|*) return ;;
    esac
}

# First Tailscale IPv4 of this node (empty when none; stderr silenced). The one
# place that asks tailscale for the address; shipped to the server with `declare -f`.
_ts_ipv4() { tailscale ip -4 2>/dev/null | head -1; }

# One-line Tailscale record: "<BackendState> <key-expiry date|disabled|-> <days left|-> <ip|->".
# BackendState is the only reliable "up AND logged in" signal: after the node
# key expires, tailscaled stays active and `tailscale status` / `tailscale ip`
# can still succeed, but the state is NeedsLogin. Self-contained (no jq) so it
# can be shipped to the server with `declare -f _ts_ipv4 _ts_state`.
_ts_state() {
    type -P tailscale &>/dev/null || { echo "NotInstalled - - -"; return; }
    local js state exp days="-" ip self=0
    js=$(tailscale status --self --peers=false --json 2>/dev/null) || true
    state=$(sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' <<<"$js" | head -1)
    exp=$(sed -n 's/.*"KeyExpiry": *"\([^"]*\)".*/\1/p' <<<"$js" | head -1)
    grep -q '"Self": *{' <<<"$js" && self=1
    if [[ -n "$exp" ]]; then
        # Round UP: 12h left is "1 day", so 0 (shown "expired") means really expired.
        local diff=$(( $(date -d "$exp" +%s) - $(date +%s) ))
        days=$(( diff > 0 ? (diff + 86399) / 86400 : 0 ))
        exp=${exp%%T*}
    elif (( self )); then
        exp=disabled    # Self present, no KeyExpiry: expiry turned off
    else
        exp=-           # no Self (logged out / fresh): key state unknown
    fi
    ip=$(_ts_ipv4)
    echo "${state:-Stopped} $exp $days ${ip:--}"
}

# IP field of a _ts_state record ("-" when none).
_ts_ip() { cut -d' ' -f4 <<<"$1"; }

# True only when a _ts_state record is Running (up AND logged in). With no
# argument, checks the local _ts_state. Prefer this over `tailscale ip`,
# which still prints a stale IP after the node key expires.
_ts_running() {
    local rec
    if (( $# )); then rec=$1; else rec=$(_ts_state); fi
    [[ "${rec%% *}" == Running ]]
}

# Colored one-word state for a _ts_state record.
_ts_word() {
    local state exp days ip
    read -r state exp days ip <<<"$1"
    case "$state" in
        Running)      echo "${GREEN}connected${NC}" ;;
        NeedsLogin)
            if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days <= 0 )); then
                echo "${RED}logged out${NC} ${DIM}(key expired - run: sudo tailscale up)${NC}"
            else
                echo "${RED}logged out${NC} ${DIM}(run: sudo tailscale up)${NC}"
            fi ;;
        NotInstalled) echo "${DIM}not installed${NC}" ;;
        *)            echo "${RED}disconnected${NC} ${DIM}($state)${NC}" ;;
    esac
}

# Key-expiry label for a _ts_state record. Expiry < 30 days goes yellow.
_ts_key() {
    local state exp days ip
    read -r state exp days ip <<<"$1"
    if [[ "$exp" == disabled ]]; then echo "${GREEN}never expires${NC}"
    elif [[ "$days" == - ]];   then echo "${DIM}unknown${NC}"
    elif (( days <= 0 ));      then echo "${RED}expired $exp${NC}"
    elif (( days < 30 ));      then echo "${YELLOW}expires $exp (${days} days)${NC}"
    else echo "expires $exp ${DIM}(${days} days)${NC}"
    fi
}

# Hint to turn off key expiry for a _ts_state record. Silent when expiry is
# already disabled, Tailscale is not installed, or there is no record.
_ts_expiry_hint() {
    local state exp rest
    read -r state exp rest <<<"$1"
    [[ -n "$state" && "$state" != NotInstalled && "$state" != Unreachable && "$exp" != disabled ]] || return 0
    echo -e "    ${DIM}Turn off expiry: login.tailscale.com/admin/machines -> this machine -> ... -> Disable key expiry${NC}"
}

# State / IP / Key lines for one side. $2=server adds the hint to turn off
# key expiry: a server should never silently drop off the tailnet.
_ts_print_state() {
    local state exp days ip
    read -r state exp days ip <<<"$1"
    if [[ "$state" == Unreachable ]]; then
        echo -e "    State:  ${RED}unreachable${NC}"
        return 0
    fi
    echo -e "    State:  $(_ts_word "$1")"
    _ts_running "$1" || ip=-    # never show a stale IP for a node that isn't Running
    echo -e "    IP:     ${BOLD}$ip${NC}"
    echo -e "    Key:    $(_ts_key "$1")"
    [[ "$2" == server ]] && _ts_expiry_hint "$1"
    return 0
}

_ts_status() {
    echo ""
    if ! command -v tailscale &>/dev/null; then
        fail "Tailscale not installed."
        return 1
    fi
    echo -e "  ${BOLD}Tailscale status${NC}"
    _ts_print_state "$(_ts_state)" server
    echo -e "    Host:   ${BOLD}$(hostname)${NC} ${DIM}(MagicDNS)${NC}"
    echo ""
    tailscale status 2>/dev/null | sed 's/^/    /' || true
}

_ts_up()   { info "Connecting..."; sudo tailscale up && ok "Connected."; }
_ts_down() { info "Disconnecting..."; sudo tailscale down && ok "Disconnected."; }

_ts_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE Tailscale (server side)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} tailscale down + logout (removes node from your tailnet)"
    echo -e "    ${RED}•${NC} systemctl disable --now tailscaled"
    echo -e "    ${RED}•${NC} dnf remove -y tailscale"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} You lose remote access to this server via tailnet"
    echo -e "    ${YELLOW}•${NC} MagicDNS name '${BOLD}federver${NC}' stops resolving from any device"
    echo -e "    ${YELLOW}•${NC} If AdGuard was routing tailnet DNS through this server, that"
    echo -e "      path breaks — edit Tailscale admin console DNS before uninstalling"
    echo -e "    ${YELLOW}•${NC} Phones/laptops that used ${BOLD}http://federver:PORT${NC} URLs must"
    echo -e "      switch to the LAN IP (${BOLD}http://192.168.x.x:PORT${NC}) or reconnect at home"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} Tailscale on your laptop untouched"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete tailscale || return 0

    _ts_remove_local || return 1
    ok "Tailscale removed."
}

# Remove Tailscale from the machine this runs on, then verify the binary is
# really gone. logout/down can legitimately fail on an already-logged-out
# node, so only the end state counts. Returns 0 only if verified.
_ts_remove_local() {
    info "Bringing tailnet connection down..."
    sudo tailscale logout > /dev/null 2>&1 || true
    sudo tailscale down > /dev/null 2>&1 || true
    info "Disabling tailscaled..."
    sudo systemctl disable --now tailscaled > /dev/null 2>&1 || true
    info "Removing package..."
    sudo dnf remove -y tailscale > /dev/null 2>&1 || true
    hash -r
    if type -P tailscale > /dev/null; then
        fail "Tailscale is still installed - dnf remove failed. Try: sudo dnf remove tailscale"
        return 1
    fi
}

_ts_install() {
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo systemctl enable --now tailscaled
    ok "Tailscale installed."
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ACTION NEEDED${NC}"
    echo ""
    echo -e "  If you don't have a Tailscale account yet:"
    echo -e "    1. Go to ${BLUE}https://login.tailscale.com${NC} on your phone/laptop"
    echo -e "    2. Sign up (free) with Google, GitHub, or email"
    echo ""
    echo -e "  If you already have one, just continue."
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  Press Enter when ready..." -r

    echo ""
    info "Authenticating this server with Tailscale..."
    info "A URL will appear below. Open it in your browser and approve."
    echo ""
    sudo tailscale up
    echo ""

    local ts_ip
    if _ts_running; then
        ts_ip=$(_ts_ipv4)
        ok "Tailscale connected! IP: $ts_ip"
        echo ""
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}NEXT: Install Tailscale on your phone/laptop${NC}"
        echo ""
        echo -e "  1. Install the Tailscale app on your phone and/or laptop"
        echo -e "     ${BLUE}https://tailscale.com/download${NC}"
        echo -e "  2. Log in with the ${BOLD}same account${NC} you just used"
        local ts_host=$(hostname)
        echo -e "  3. Now you can access all services from anywhere:"
        echo -e "     Immich:       ${BLUE}http://$ts_host:2283${NC}"
        echo -e "     Navidrome:    ${BLUE}http://$ts_host:4533${NC}"
        echo -e "     FileBrowser:  ${BLUE}http://$ts_host:8080${NC}"
        echo -e "     Uptime Kuma:  ${BLUE}http://$ts_host:3001${NC}"
        echo -e "     ${DIM}(MagicDNS resolves '$ts_host' automatically — or use IP: $ts_ip)${NC}"
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "  Press Enter when done..." -r
    else
        fail "Tailscale not connected. Run 'sudo tailscale up' manually."
    fi
}

_ts_install_laptop() {
    echo -e "  ${BOLD}── Laptop side ──${NC}"
    if command -v tailscale &>/dev/null; then
        ok "Tailscale already installed on this laptop."
    else
        if ! command -v dnf &>/dev/null; then
            warn "Not a dnf-based system. Install Tailscale manually:"
            info "  https://tailscale.com/download"
            return 0
        fi
        info "Installing Tailscale via dnf..."
        sudo dnf install -y tailscale > /dev/null 2>&1 || {
            fail "dnf install failed."
            return 1
        }
        sudo systemctl enable --now tailscaled > /dev/null 2>&1
        ok "Tailscale installed and tailscaled running."
    fi

    # Bring the laptop up on the tailnet if it isn't already
    if _ts_running; then
        local laptop_ts_ip
        laptop_ts_ip=$(_ts_ipv4)
        ok "Laptop already on the tailnet: $laptop_ts_ip"
    else
        echo ""
        info "Authenticating the laptop with Tailscale..."
        info "A URL will appear below. Open it in your browser and approve."
        echo ""
        sudo tailscale up
        echo ""
    fi
    echo ""
}

_ts_stop_both() {
    warn "Disconnect Tailscale on both laptop and server?"
    warn "Remote access via Tailscale will stop working."
    read -p "  [y/N] " -n 1 -r; echo ""
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
    info "Disconnecting..."
    sudo tailscale down 2>/dev/null && ok "Laptop: disconnected." || warn "Laptop: not connected."
    ssh -t "$SERVER_USER@$SERVER_IP" "sudo tailscale down 2>/dev/null" \
        && ok "Server: disconnected." || warn "Server: not connected."
}

_ts_start_both() {
    info "Connecting Tailscale on both laptop and server..."
    sudo tailscale up 2>/dev/null && ok "Laptop: connected." || warn "Laptop: failed."
    ssh -t "$SERVER_USER@$SERVER_IP" "sudo tailscale up" || warn "Server: failed."
}

_ts_restart_both() {
    info "Restarting Tailscale on both laptop and server..."
    sudo systemctl restart tailscaled 2>/dev/null && ok "Laptop: restarted." || warn "Laptop: failed."
    ssh -t "$SERVER_USER@$SERVER_IP" "sudo systemctl restart tailscaled 2>/dev/null" \
        && ok "Server: restarted." || warn "Server: failed."
}

# True when this laptop reaches the server over Tailscale: the resolver swapped
# SERVER_IP for SERVER_HOST_TS (roaming), or SERVER_IP is itself a tailnet
# address (100.64.0.0/10, CGNAT range Tailscale uses). Never true on the server.
_ts_connected_via_ts() {
    _is_server && return 1
    [[ -n "$SERVER_HOST_TS" && "$SERVER_IP" == "$SERVER_HOST_TS" ]] && return 0
    [[ "$SERVER_IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+$ ]]
}

_ts_uninstall_both() {
    # $1: "laptop" | "server" removes just that side (partial state); default both.
    local side="${1:-both}" rc=0 srv srv_failed=0 via_ts=0
    _ts_connected_via_ts && via_ts=1
    # Removing Tailscale on the server would cut the ssh session it runs over,
    # and removing only the laptop half would leave a half-state: refuse both.
    if (( via_ts )) && [[ "$side" != laptop ]]; then
        fail "You're connected to the server over Tailscale - removing it there would cut this connection. Run this from home (LAN) or on the server itself."
        [[ "$side" == both ]] && info "Nothing was changed (laptop side not removed either)."
        return 1
    fi
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ "$side" == both ]]; then
        echo -e "  ${RED}DELETE Tailscale (both laptop and server)${NC}"
    else
        echo -e "  ${RED}DELETE Tailscale ($side only)${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    [[ "$side" != server ]] && echo -e "    ${RED}•${NC} Laptop: tailscale logout + disable tailscaled + dnf remove"
    [[ "$side" != laptop ]] && echo -e "    ${RED}•${NC} Server: tailscale logout + disable tailscaled + dnf remove"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} No remote access to the server from anywhere"
    echo -e "    ${YELLOW}•${NC} MagicDNS name 'federver' stops resolving"
    echo -e "    ${YELLOW}•${NC} AdGuard DNS routing via tailnet stops"
    echo -e "    ${YELLOW}•${NC} Phones with Tailscale can't reach services remotely"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} Tailscale on phones untouched (remove via their app settings)"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    (( via_ts )) && warn "You're connected to the server over Tailscale - removing it here will drop that connection."
    _confirm_delete tailscale || return 0

    # Server first: a laptop that reaches the server over Tailscale would cut
    # its own route by logging out before the server half ran.
    if [[ "$side" != laptop ]]; then
        info "Removing from server..."
        # One TTY session so sudo's password prompt works and its cached
        # credential covers every command (a separate non-TTY session gets no
        # credential and every sudo silently fails).
        ssh -t "$SERVER_USER@$SERVER_IP" 'sudo tailscale logout >/dev/null 2>&1; sudo tailscale down >/dev/null 2>&1; sudo systemctl disable --now tailscaled >/dev/null 2>&1; sudo dnf remove -y tailscale >/dev/null 2>&1' 2>/dev/null || true
        # Verify the end state; don't trust that the commands ran. The snippet
        # always exits 0 and names what it found, so only a real ssh failure
        # reads as "unreachable".
        srv=$(_server_probe 'if type -P tailscale >/dev/null; then echo installed; else echo absent; fi')
        case "$srv" in
            absent)      ok "Server: removed." ;;
            installed)   fail "Server: Tailscale is still installed - sudo/dnf remove failed. Try on the server: sudo dnf remove tailscale"; rc=1 ;;
            unreachable) fail "Server: could not confirm removal (server unreachable)."; rc=1 ;;
            *)           fail "Server: could not confirm removal (unexpected probe result: $srv)."; rc=1 ;;
        esac
        (( rc == 0 )) || srv_failed=1
    fi

    if [[ "$side" != server ]]; then
        info "Removing from laptop..."
        if _ts_remove_local; then ok "Laptop: removed."; else fail "Laptop: NOT removed."; rc=1; fi
        (( srv_failed )) && warn "Server half was NOT completed - remove it on the server directly (sudo dnf remove tailscale) once it is reachable."
    fi
    return $rc
}

step_tailscale() {
    # Server-side (via --run from an SSH hop, or user on federver directly):
    # run the server-only management submenu.
    if _is_server; then
        _ts_server_step
        return
    fi

    info "Tailscale lets you access this server from anywhere (phone, laptop)"
    info "without port forwarding. Like a private VPN."
    echo ""

    # Which sides have Tailscale? Not both -> the gate handles it (offer to
    # install, or manage the one side that exists); it never installs on its own.
    local lap_state="" srv_state="" g=0
    command -v tailscale &>/dev/null && lap_state="installed ($(_ts_state | cut -d' ' -f1))"
    srv_state=$(_server_probe "$(declare -f _ts_ipv4 _ts_state); if type -P tailscale >/dev/null; then echo \"installed (\$(_ts_state | cut -d' ' -f1))\"; fi")
    _two_sided_gate "Tailscale" "$lap_state" "$srv_state" _ts_install_laptop "_ts_server_step" _ts_uninstall_both || g=$?
    (( g == 10 )) || return $g

    # Both installed — show status + unified management submenu
    echo -e "  ${BOLD}── Laptop ──${NC}"
    _ts_print_state "$(_ts_state)"
    echo ""

    echo -e "  ${BOLD}── Server ──${NC}"
    local srv_out srv_ts srv_host
    srv_out=$(ssh "$SERVER_USER@$SERVER_IP" "$(declare -f _ts_ipv4 _ts_state); _ts_state; hostname" 2>/dev/null) \
        || srv_out="Unreachable - - -"
    srv_ts=$(head -1 <<<"$srv_out"); srv_host=$(sed -n 2p <<<"$srv_out")
    _ts_print_state "$srv_ts" server
    [[ -n "$srv_host" ]] && echo -e "    Host:   ${BOLD}$srv_host${NC} ${DIM}(MagicDNS)${NC}"

    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh status"
    echo -e "  ${BOLD}2)${NC} Connect both             ${DIM}<- tailscale up${NC}"
    echo -e "  ${BOLD}3)${NC} Disconnect both          ${DIM}<- tailscale down${NC}"
    echo -e "  ${BOLD}4)${NC} Restart both             ${DIM}<- restart tailscaled service${NC}"
    echo -e "  ${BOLD}5)${NC} Re-authenticate server   ${DIM}<- new login URL${NC}"
    echo -e "  ${BOLD}6)${NC} ${RED}Uninstall both${NC}           ${DIM}<- remove from laptop + server${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " ts_choice
    case $ts_choice in
        1) step_tailscale ;;
        2) _ts_start_both ;;
        3) _ts_stop_both ;;
        4) _ts_restart_both ;;
        5) _on_server _ts_install ;;
        6) _ts_uninstall_both ;;
        0|*) return ;;
    esac
}

_ts_server_step() {
    if ! command -v tailscale &>/dev/null; then
        _ts_install
        return
    fi

    _ts_status
    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh status"
    echo -e "  ${BOLD}2)${NC} Connect              ${DIM}<- tailscale up${NC}"
    echo -e "  ${BOLD}3)${NC} Disconnect           ${DIM}<- tailscale down${NC}"
    echo -e "  ${BOLD}4)${NC} Re-authenticate      ${DIM}<- new login URL${NC}"
    echo -e "  ${BOLD}5)${NC} ${RED}Uninstall${NC}            ${DIM}<- remove tailscaled + package${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " ts_choice
    case $ts_choice in
        1) _ts_status ;;
        2) _ts_up ;;
        3) _ts_down ;;
        4) _ts_install ;;
        5) _ts_uninstall ;;
        0|*) return ;;
    esac
}

step_storage() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- drives, mounts, paths${NC}"
    echo -e "  ${BOLD}2)${NC} Mount USB drive"
    echo -e "  ${BOLD}3)${NC} Unmount USB drive"
    echo -e "  ${BOLD}4)${NC} Change music location      ${DIM}<- Navidrome${NC}"
    echo -e "  ${BOLD}5)${NC} Change data location       ${DIM}<- FileBrowser root${NC}"
    echo -e "  ${BOLD}6)${NC} Change Immich location     ${DIM}<- Immich photos + database${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " storage_choice

    case $storage_choice in
        1) _storage_status ;;
        2) _storage_mount ;;
        3) _storage_unmount ;;
        4) _storage_change_music ;;
        5) _storage_change_files ;;
        6) _storage_change_immich ;;
        0|*) return ;;
    esac
}

# Returns the actual source of a container's mount target.
# Shows a real host path when bind-mounted; labels Docker named/anonymous
# volumes as such so the status screen never lies with "not set".
_storage_mount_source() {
    local container="$1"
    local target="$2"
    if ! sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q "^${container}$"; then
        echo ""
        return
    fi
    local info
    info=$(sg docker -c "docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Name}}|{{.Destination}}{{println}}{{end}}' $container" 2>/dev/null \
           | awk -F'|' -v t="$target" '$4==t {print $1"|"$2"|"$3; exit}')
    [[ -z "$info" ]] && { echo ""; return; }
    local type src name
    type=$(echo "$info" | cut -d'|' -f1)
    src=$(echo  "$info" | cut -d'|' -f2)
    name=$(echo "$info" | cut -d'|' -f3)
    case "$type" in
        bind)   echo "$src" ;;
        volume) if [[ "$name" =~ ^[0-9a-f]{32,}$ ]]; then
                    echo "(Docker anonymous volume)"
                else
                    echo "(Docker volume: $name)"
                fi ;;
        *)      echo "(Docker $type)" ;;
    esac
}

# Verify that PATH's data drive is backed by a REAL mounted filesystem before a
# container bind-mounts from it. An x-systemd.automount entry leaves an autofs
# stub at the mount point that passes `mountpoint -q` even when the actual disk
# never mounted (wrong/duplicate fstab UUID, hot-unplug). Docker then fails with
# "no such device" and silently creates empty dirs on the system disk that look
# like data loss. Only /mnt/* paths are guarded - internal /home paths never
# need a separate mount. The mount point (first two components, /mnt/data) goes
# to _drive_verdict: ok or empty (a fresh drive) starts; anything else, and "no
# findmnt to ask", refuses. Returns 0 if safe to start, 1 (with guidance) if not.
_require_data_mount() {
    local path="$1"
    [[ "$path" == /mnt/* ]] || return 0
    # Mount point is the first two components, e.g. /mnt/data.
    local mp v; mp="/$(echo "${path#/}" | cut -d/ -f1-2)"
    v=$(_drive_verdict "$mp")
    case "$v" in ok|empty) return 0 ;; esac
    if [[ "$v" == unknown ]]; then
        fail "Cannot check whether the data drive is mounted at $mp (findmnt is missing) - not starting."
    else
        fail "Data drive is not mounted at $mp (check: $v)."
    fi
    info "Services bind-mount your photos/music/files from here. Starting now"
    info "would fail with 'no such device' and create empty folders on the"
    info "system disk that look like data loss."
    info "Fix it: ${BOLD}federver → 11 → 2${NC} (Mount USB drive), then retry."
    return 1
}

_storage_status() {
    echo ""
    local FILES_LOCATION MUSIC_LOCATION UPLOAD_LOCATION DB_DATA_LOCATION
    FILES_LOCATION=$(_env_get FILES_LOCATION "$SCRIPT_DIR/.env")
    MUSIC_LOCATION=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")
    UPLOAD_LOCATION=$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")
    DB_DATA_LOCATION=$(_env_get DB_DATA_LOCATION "$SCRIPT_DIR/.env")

    # A partition's transport (TRAN) is reported only on its parent disk, so a
    # USB partition (e.g. sdb1) has an empty TRAN and used to leak into the
    # Internal list while its parent disk was correctly filtered into USB. Build
    # the full set of USB device names (disk + partitions) up front and filter
    # the Internal listing against it.
    local usb_disks usb_names="" d
    usb_disks=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}')
    for d in $usb_disks; do
        usb_names+=" $(lsblk -rno NAME "/dev/$d" 2>/dev/null | tr '\n' ' ')"
    done

    echo -e "  ${BOLD}Internal drives${NC}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL -n | grep -v loop | while IFS= read -r line; do
        local dev
        dev=$(echo "$line" | awk '{print $1}' | tr -d '├─└─│ ')
        case " $usb_names " in *" $dev "*) continue ;; esac
        echo "    $line"
    done
    echo ""

    # USB drives (usb_disks computed above)
    local usb_drives=""
    for d in $usb_disks; do
        usb_drives+="$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL "/dev/$d" -n 2>/dev/null)"$'\n'
    done
    usb_drives=$(echo "$usb_drives" | sed '/^$/d')
    if [[ -n "$usb_drives" ]]; then
        echo -e "  ${BOLD}USB drives${NC}"
        echo "$usb_drives" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo -e "  ${BOLD}USB drives${NC}"
        echo -e "    ${DIM}none detected${NC}"
    fi
    echo ""

    # Mental model: data / media / immich. Show where each is actually
    # backed from — .env path if set, Docker volume inspection if not.
    local data_path="${FILES_LOCATION:-}"
    local media_path="${MUSIC_LOCATION:-}"
    local immich_path="${UPLOAD_LOCATION:-}"
    local db_path="${DB_DATA_LOCATION:-}"

    # Fall back to actual Docker mount source when .env is silent.
    [[ -z "$data_path"   ]] && data_path=$(_storage_mount_source filebrowser /srv)
    [[ -z "$media_path"  ]] && media_path=$(_storage_mount_source navidrome /music)
    [[ -z "$immich_path" ]] && immich_path=$(_storage_mount_source immich_server /usr/src/app/upload)
    [[ -z "$db_path"     ]] && db_path=$(_storage_mount_source immich_postgres /var/lib/postgresql/data)

    echo -e "  ${BOLD}Storage paths${NC}   ${DIM}(data / media / immich)${NC}"
    echo -e "    data:    ${data_path:-${RED}not set${NC}}   ${DIM}(FileBrowser)${NC}"
    echo -e "    media:   ${media_path:-${RED}not set${NC}}   ${DIM}(Navidrome)${NC}"
    echo -e "    immich:  ${immich_path:-${RED}not set${NC}}   ${DIM}(photos)${NC}"
    echo -e "             ${db_path:-${RED}not set${NC}}   ${DIM}(Immich Postgres)${NC}"
    echo ""

    echo -e "  ${BOLD}Disk usage${NC}"
    df -h 2>/dev/null | awk 'NR==1 || ($1 ~ /^\/dev\// && $1 !~ /loop/ && !seen[$1]++){mp=$6; for(i=7;i<=NF;i++) mp=mp" "$i; printf "    %-22s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,mp}'

    # Flag any /mnt/* data path whose drive isn't actually mounted — an autofs
    # stub or unmounted point that would make services die with "no such device"
    # while everything above still looks fine.
    local p mp seen_mp=""
    for p in "$data_path" "$media_path" "$immich_path"; do
        [[ "$p" == /mnt/* ]] || continue
        mp="/$(echo "${p#/}" | cut -d/ -f1-2)"
        case " $seen_mp " in *" $mp "*) continue ;; esac
        seen_mp+=" $mp"
        local v; v=$(_drive_verdict "$mp")
        case "$v" in
            ok|empty) ;;
            unknown)
                echo ""
                warn "Cannot check whether $mp is mounted (findmnt is missing)." ;;
            *)
                echo ""
                warn "$mp is NOT mounted (real disk absent; check: $v)."
                info "Services using it will fail to start. Mount: ${BOLD}federver → 11 → 2${NC}." ;;
        esac
    done

    _storage_check_fstab_options
}

# Detect fstab entries written by older versions of this script (defaults,nofail)
# and offer to upgrade them to nofail,x-systemd.automount,... — old options
# silently skip the mount on USB enumeration races, leaving an empty stub dir
# that looks like data loss. Status is the natural place to surface this.
_storage_check_fstab_options() {
    local stale
    stale=$(grep -E '^[^#].* defaults,nofail .*' /etc/fstab 2>/dev/null | awk '{print $2}')
    [[ -z "$stale" ]] && return 0

    echo ""
    echo -e "  ${YELLOW}⚠ fstab uses outdated mount options${NC}"
    while IFS= read -r mp; do
        echo -e "    $mp   ${DIM}(defaults,nofail — silent skip on USB race)${NC}"
    done <<< "$stale"
    echo -e "    ${DIM}Recommended:${NC} nofail,x-systemd.automount,x-systemd.device-timeout=10s"
    echo ""
    read -p "  Repair now? [Y/n] " -n 1 -r
    echo ""
    [[ "$REPLY" =~ ^[Nn]$ ]] && return 0

    sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    sudo sed -i -E 's|([[:space:]])defaults,nofail([[:space:]])|\1nofail,x-systemd.automount,x-systemd.device-timeout=10s\2|g' /etc/fstab
    sudo systemctl daemon-reload
    while IFS= read -r mp; do
        sudo umount "$mp" 2>/dev/null || true
    done <<< "$stale"
    sudo mount -a
    ok "Repaired. Backup at /etc/fstab.bak.*"
}

_storage_mount() {
    echo ""
    info "Plug in a USB drive, then select the partition to mount."
    echo ""

    # Show only USB drives
    local usb_parts
    local usb_disks
    usb_disks=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}')
    usb_parts=""
    for d in $usb_disks; do
        usb_parts+="$(lsblk -rno NAME,SIZE,FSTYPE,LABEL "/dev/$d" 2>/dev/null | awk '$3!=""')"$'\n'
    done
    usb_parts=$(echo "$usb_parts" | sed '/^$/d')

    if [[ -z "$usb_parts" ]]; then
        fail "No USB drives detected. Is one plugged in?"
        return 1
    fi

    echo -e "  ${BOLD}USB partitions:${NC}"
    local idx=1
    declare -a part_arr
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local fstype=$(echo "$line" | awk '{print $3}')
        local label=$(echo "$line" | awk '{print $4}')
        echo -e "    ${BOLD}$idx)${NC} /dev/$name  ${size}  ${fstype}  ${label:-no label}"
        part_arr[$idx]="$name"
        idx=$((idx + 1))
    done <<< "$usb_parts"

    echo ""
    read -p "  Which partition? " part_choice
    local partition="${part_arr[$part_choice]}"

    if [[ -z "$partition" ]]; then
        fail "Invalid choice."
        return 1
    fi

    # Ask mount point
    read -p "  Mount point [/mnt/data]: " mount_point
    mount_point="${mount_point:-/mnt/data}"

    sudo mkdir -p "$mount_point"
    local uuid=$(sudo blkid -s UUID -o value "/dev/$partition")
    local fstype=$(sudo blkid -s TYPE -o value "/dev/$partition")

    if [[ -z "$uuid" ]]; then
        fail "Could not read UUID for /dev/$partition."
        return 1
    fi

    # Remove any STALE fstab entries for this mount point that point at a
    # DIFFERENT device. Two lines for the same mount point (e.g. an old drive's
    # UUID left behind after a swap) make systemd's autofs generator bind the
    # wrong device, so every access fails with "no such device" while the mount
    # point still looks mounted. This is the single most common cause of
    # "Navidrome/FileBrowser won't start" after changing drives.
    local stale
    stale=$(awk -v mp="$mount_point" -v keep="UUID=$uuid" \
            '$1 !~ /^#/ && $2==mp && $1!=keep {print $1}' /etc/fstab 2>/dev/null)
    if [[ -n "$stale" ]]; then
        warn "Stale fstab entr(ies) for $mount_point point at another device:"
        echo "$stale" | sed 's/^/      /'
        read -p "  Remove them so only this drive mounts here? [Y/n] " -n 1 -r; echo ""
        if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
            sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
            local tmp_fstab; tmp_fstab=$(mktemp)
            sudo awk -v mp="$mount_point" -v keep="UUID=$uuid" \
                '!($1 !~ /^#/ && $2==mp && $1!=keep)' /etc/fstab > "$tmp_fstab" \
                && sudo cp "$tmp_fstab" /etc/fstab
            rm -f "$tmp_fstab"
            ok "Removed stale entries (backup at /etc/fstab.bak.*)."
        fi
    fi

    if grep -qE "^UUID=$uuid[[:space:]]" /etc/fstab 2>/dev/null; then
        ok "Already in fstab."
    else
        echo "UUID=$uuid $mount_point $fstype nofail,x-systemd.automount,x-systemd.device-timeout=10s 0 2" | sudo tee -a /etc/fstab > /dev/null
        ok "Added to fstab."
    fi

    # Reload units, clear any cached automount failure from the old config, then
    # mount and VERIFY the real device is there — not just an autofs stub. The
    # old code trusted `mountpoint -q`, which is true for the autofs placeholder
    # even when the actual disk never mounted.
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$(systemd-escape -p --suffix=mount "$mount_point")" \
                                "$(systemd-escape -p --suffix=automount "$mount_point")" 2>/dev/null || true
    sudo umount -l "$mount_point" 2>/dev/null || true
    local mnt_err
    mnt_err=$(sudo mount "$mount_point" 2>&1) || { fail "Mount failed: $mnt_err"; return 1; }

    local real_src
    real_src=$(findmnt -frno SOURCE "$mount_point" 2>/dev/null)
    if [[ "$real_src" == "/dev/$partition" ]]; then
        ok "Mounted /dev/$partition at $mount_point (verified real device)."
    else
        fail "$mount_point reports mounted but the real disk isn't there (source: ${real_src:-none})."
        info "Check for duplicate /etc/fstab entries or a failed automount unit."
        return 1
    fi

    echo ""
    info "Contents:"
    ls "$mount_point" 2>/dev/null || true
}

# Print what's holding a mountpoint busy, in plain words, so a failed unmount
# never leaves the user with a bare "target is busy". Best-effort: lists Docker
# containers whose bind-mounts sit on the drive, plus any process (desktop app,
# shell, scanner) with a file open or cwd there. Uses fuser (psmisc, present on
# Fedora) for processes and `docker inspect` for container binds.
_storage_show_busy() {
    local mp="$1" found=""
    local c src

    for c in $(sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null); do
        while IFS= read -r src; do
            case "$src" in
                "$mp"|"$mp"/*)
                    warn "  container '$c'  — stop it: federver → 7 → 3"
                    found=1; break ;;
            esac
        done < <(sg docker -c "docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' '$c'" 2>/dev/null)
    done

    local pid cmd
    while read -r pid; do
        [[ -z "$pid" ]] && continue
        cmd=$(ps -o args= -p "$pid" 2>/dev/null)
        warn "  process $pid  — ${cmd:0:70}"
        found=1
    done < <(sudo fuser -m "$mp" 2>/dev/null | grep -oE '[0-9]+' | sort -un)

    [[ -z "$found" ]] && info "  (couldn't pin it down — try: ${BOLD}sudo fuser -mv $mp${NC})"
}

_storage_unmount() {
    echo ""

    # List USB *partitions* that are actually mounted. Built from findmnt so we
    # skip bare disks (e.g. /dev/sdb with no filesystem) and read the real, fully
    # resolved mount path. The old lsblk+awk approach mistook the parent disk for
    # a mount (its empty MOUNTPOINT field collapsed under `-r`), so users could
    # pick a non-mountpoint and the code "succeeded" without unmounting anything.
    local usb_disks entries="" d part mp sz
    usb_disks=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}')
    for d in $usb_disks; do
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            mp=$(findmnt -nro TARGET "/dev/$part" 2>/dev/null | head -1)
            [[ -z "$mp" ]] && continue          # not mounted → not a candidate
            sz=$(lsblk -drno SIZE "/dev/$part" 2>/dev/null)
            entries+="${part}|${mp}|${sz}"$'\n'
        done < <(lsblk -rno NAME "/dev/$d")
    done
    entries=$(echo "$entries" | sed '/^$/d')

    if [[ -z "$entries" ]]; then
        fail "No mounted USB drives found."
        return 1
    fi

    echo -e "  ${BOLD}Mounted USB drives:${NC}"
    local idx=1
    declare -a mp_arr name_arr
    local name size
    while IFS='|' read -r name mp size; do
        echo -e "    ${BOLD}$idx)${NC} /dev/$name  ${mp}  ${size}"
        name_arr[$idx]="$name"
        mp_arr[$idx]="$mp"
        idx=$((idx + 1))
    done <<< "$entries"

    echo ""
    read -p "  Which drive to unmount? " umount_choice
    local mpoint="${mp_arr[$umount_choice]}"
    local devname="${name_arr[$umount_choice]}"

    if [[ -z "$mpoint" ]]; then
        fail "Invalid choice."
        return 1
    fi

    warn "This will unmount /dev/$devname from $mpoint."
    warn "Navidrome/FileBrowser read from the data drive — stop them first"
    warn "(federver → 7 → 3) or the unmount will fail with 'target is busy'."
    read -p "  Continue? [y/N] " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled."; return; }

    # Drop the automount unit first so it can't silently remount on next access.
    sudo systemctl stop "$(systemd-escape -p --suffix=automount "$mpoint")" 2>/dev/null || true

    # Unmount and CHECK the result — never claim success on a failed umount.
    local umount_err
    if ! umount_err=$(sudo umount "$mpoint" 2>&1); then
        fail "Could not unmount $mpoint: ${umount_err:-unknown error}"
        case "$umount_err" in
            *busy*|*"in use"*)
                echo ""
                warn "Still in use by:"
                _storage_show_busy "$mpoint"
                echo ""
                info "Stop the services above (federver → 7 → 3) and close any app or"
                info "shell using files on the drive, then retry the unmount."
                ;;
            *)
                info "If it's a service, stop it (federver → 7 → 3) and retry."
                ;;
        esac
        return 1
    fi

    # Only after a real unmount, remove the fstab entry (by the partition's UUID)
    # and reload — and only say so when we actually changed fstab.
    local uuid removed=""
    uuid=$(sudo blkid -s UUID -o value "/dev/$devname" 2>/dev/null)
    if [[ -n "$uuid" ]] && grep -q "$uuid" /etc/fstab 2>/dev/null; then
        sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
        sudo sed -i "\|UUID=$uuid|d" /etc/fstab
        sudo systemctl daemon-reload
        removed=" and removed from fstab"
    fi

    ok "Unmounted /dev/$devname from $mpoint${removed}."
    info "Safe to unplug the drive."
}

# Helper to update .env and redeploy affected containers
_set_env() {
    local key="$1" val="$2" file="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

# Copy the repo's Navidrome smart-playlist (.nsp) templates into the active
# music folder. The files must live inside MUSIC_LOCATION (mounted as /music),
# so this runs whenever the music folder is (re)established — on Deploy and
# after a music-location change — to keep them following the current folder.
_install_smart_playlists() {
    local music_dir src dest
    music_dir=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")
    src="$SCRIPT_DIR/tools/navidrome/playlists"
    [[ -n "$music_dir" && -d "$src" ]] || return 0
    dest="$music_dir/playlists"
    sudo mkdir -p "$dest" || return 0
    if sudo cp "$src"/*.nsp "$dest"/ 2>/dev/null; then
        ok "Smart playlists installed to: $dest"
        info "They appear in Navidrome after its next scan (on startup, or within 1h)."
    fi
    return 0
}

_storage_change_music() {
    echo ""
    local MUSIC_LOCATION
    MUSIC_LOCATION=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")

    info "Current music location: ${MUSIC_LOCATION:-not set}"
    info "Used by: Navidrome (music streaming)"
    echo ""
    read -p "  New music path: " new_path

    if [[ -z "$new_path" ]]; then
        fail "Path is required."
        return 1
    fi

    new_path="${new_path/#\~/$HOME}"

    if [[ ! -d "$new_path" ]]; then
        read -p "  '$new_path' doesn't exist. Create it? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            return
        fi
        sudo mkdir -p "$new_path"
        sudo chown "$USER:$USER" "$new_path"
        ok "Created $new_path"
    fi

    _set_env "MUSIC_LOCATION" "$new_path" "$SCRIPT_DIR/.env"
    ok "Updated .env: MUSIC_LOCATION=$new_path"

    # Re-install smart playlists into the new folder before Navidrome restarts
    # (they live inside the music folder, so a moved folder loses them).
    _install_smart_playlists

    echo ""
    info "Redeploying Navidrome..."
    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d --force-recreate navidrome" 2>&1 | grep -v "^$"

    ok "Done. Navidrome now uses: $new_path"
}

_storage_change_files() {
    echo ""
    local FILES_LOCATION
    FILES_LOCATION=$(_env_get FILES_LOCATION "$SCRIPT_DIR/.env")

    info "Current files location: ${FILES_LOCATION:-not set}"
    info "Used by: FileBrowser (upload/manage)"
    echo ""
    read -p "  New files path: " new_path

    if [[ -z "$new_path" ]]; then
        fail "Path is required."
        return 1
    fi

    new_path="${new_path/#\~/$HOME}"

    if [[ ! -d "$new_path" ]]; then
        read -p "  '$new_path' doesn't exist. Create it? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            return
        fi
        sudo mkdir -p "$new_path"
        sudo chown "$USER:$USER" "$new_path"
        ok "Created $new_path"
    fi

    _set_env "FILES_LOCATION" "$new_path" "$SCRIPT_DIR/.env"
    ok "Updated .env: FILES_LOCATION=$new_path"

    echo ""
    info "Redeploying FileBrowser..."
    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d --force-recreate filebrowser" 2>&1 | grep -v "^$"

    ok "Done. FileBrowser now uses: $new_path"
}

_storage_change_immich() {
    echo ""
    local UPLOAD_LOCATION DB_DATA_LOCATION
    UPLOAD_LOCATION=$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")
    DB_DATA_LOCATION=$(_env_get DB_DATA_LOCATION "$SCRIPT_DIR/.env")

    info "Current Immich paths:"
    echo -e "    Photos:    ${UPLOAD_LOCATION:-not set}"
    echo -e "    Database:  ${DB_DATA_LOCATION:-not set}"
    echo ""
    warn "Changing this does NOT move existing data."
    warn "Move files manually first, then update the path here."
    echo ""
    read -p "  New Immich path (e.g. /mnt/data/immich): " new_base

    if [[ -z "$new_base" ]]; then
        fail "Path is required."
        return 1
    fi

    new_base="${new_base/#\~/$HOME}"

    local new_upload="${new_base}/upload"
    local new_db="${new_base}/postgres"

    echo ""
    info "Will set:"
    echo -e "    Photos:    $new_upload"
    echo -e "    Database:  $new_db"
    echo ""
    read -p "  Continue? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return
    fi

    if [[ ! -d "$new_upload" ]]; then
        sudo mkdir -p "$new_upload" "$new_db"
        sudo chown -R "$USER:$USER" "$new_base"
        ok "Created directories"
    fi

    _set_env "UPLOAD_LOCATION" "$new_upload" "$SCRIPT_DIR/.env"
    _set_env "DB_DATA_LOCATION" "$new_db" "$SCRIPT_DIR/.env"
    ok "Updated .env"

    echo ""
    info "Redeploying Immich..."
    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d --force-recreate immich-server database" 2>&1 | grep -v "^$"

    ok "Done. Immich now uses: $new_base"
    echo ""
    warn "If you moved existing data, verify with: privcloud status"
}

_services_status() {
    echo ""
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed."
        return 1
    fi

    # Fetch container list + stats (same data as step_status uses)
    local CONTAINERS DSTATS
    CONTAINERS=$(sg docker -c "$(declare -f _ps_autostart); _ps_autostart docker" 2>/dev/null)
    DSTATS=$(sg docker -c "docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}'" 2>/dev/null)

    echo -e "  ${BOLD}Server containers${NC}"
    if [[ -n "$CONTAINERS" ]]; then
        echo "$CONTAINERS" | while IFS='|' read -r name status; do
            local cpu="" mem=""
            if [[ -n "$DSTATS" ]]; then
                local line
                line=$(echo "$DSTATS" | awk -F'|' -v n="$name" '$1==n{print $2"|"$3; exit}')
                cpu=$(echo "$line" | cut -d'|' -f1)
                mem=$(echo "$line" | cut -d'|' -f2 | awk '{print $1}')
            fi
            local suffix=""
            [[ -n "$cpu" ]] && suffix="$suffix  ${DIM}cpu ${cpu}${NC}"
            [[ -n "$mem" ]] && suffix="$suffix  ${DIM}mem ${mem}${NC}"
            if echo "$status" | grep -qi "unhealthy\|exit\|restart\|^stopped"; then
                echo -e "    ${RED}✗${NC} $(printf '%-24s' "$name")  $status$suffix"
            elif echo "$status" | grep -qi "healthy\|^Up "; then
                echo -e "    ${GREEN}✓${NC} $(printf '%-24s' "$name")  $status$suffix"
            else
                echo -e "    ${YELLOW}!!${NC} $(printf '%-24s' "$name")  $status$suffix"
            fi
        done
    else
        echo -e "    ${DIM}No containers found${NC}"
    fi

    # Check for known standalone containers that might be completely removed
    local all_names
    all_names=$(echo "$CONTAINERS" | cut -d'|' -f1)
    if ! echo "$all_names" | grep -q '^adguard$'; then
        echo -e "    ${RED}✗${NC} $(printf '%-24s' "adguard")  ${RED}not created${NC} ${DIM}(install: federver → 10)${NC}"
    fi
    if ! echo "$all_names" | grep -q '^syncthing$'; then
        echo -e "    ${RED}✗${NC} $(printf '%-24s' "syncthing")  ${RED}not created${NC} ${DIM}(install: federver → 12)${NC}"
    fi

    echo ""
    local IP HOST TS_IP="" has_adguard=0
    IP=$(hostname -I | awk '{print $1}')
    HOST=$(hostname)
    _ts_running && TS_IP=$(_ts_ipv4)
    echo "$all_names" | grep -q '^adguard$' && has_adguard=1
    local has_syncthing=0
    echo "$all_names" | grep -q '^syncthing$' && echo "$CONTAINERS" | grep '^syncthing|Up' -q && has_syncthing=1

    echo -e "  ${BOLD}Service URLs (local network)${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Navidrome:    ${BLUE}http://$IP:4533${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"
    [[ "$has_adguard"   == 1 ]] && echo -e "    AdGuard:      ${BLUE}http://$IP${NC}"
    [[ "$has_syncthing" == 1 ]] && echo -e "    Syncthing:    ${BLUE}http://$IP:8384${NC}"

    if [[ -n "$TS_IP" ]]; then
        echo ""
        echo -e "  ${BOLD}Service URLs (remote via Tailscale)${NC}"
        echo -e "    Immich:       ${BLUE}http://$HOST:2283${NC}"
        echo -e "    Navidrome:    ${BLUE}http://$HOST:4533${NC}"
        echo -e "    FileBrowser:  ${BLUE}http://$HOST:8080${NC}"
        echo -e "    Uptime Kuma:  ${BLUE}http://$HOST:3001${NC}"
        [[ "$has_adguard"   == 1 ]] && echo -e "    AdGuard:      ${BLUE}http://$HOST${NC}"
        [[ "$has_syncthing" == 1 ]] && echo -e "    Syncthing:    ${BLUE}http://$HOST:8384${NC}"
        echo -e "    ${DIM}(MagicDNS resolves '$HOST' on any Tailscale device — or use IP $TS_IP)${NC}"
    fi
}

# Show a numbered list of containers (running or all) + an "All" option,
# read a selection, and echo either a container name or the literal "all".
# Returns 1 if the user cancels. Use running=0 to list stopped containers
# too (for Start/Resume), running=1 for only-running (for Stop/Restart/Logs).
_pick_container() {
    local running="${1:-1}"
    local names
    if [[ "$running" == 1 ]]; then
        names=$(sudo docker ps --format '{{.Names}}' 2>/dev/null)
    else
        names=$(sudo docker ps -a --format '{{.Names}}' 2>/dev/null)
    fi
    if [[ -z "$names" ]]; then
        fail "No containers found." >&2
        return 1
    fi
    echo "" >&2
    echo -e "  ${BOLD}a)${NC} ${BOLD}All${NC}" >&2
    local idx=1
    declare -a arr
    local all_statuses
    all_statuses=$(_ps_autostart sudo docker 2>/dev/null)
    while IFS= read -r n; do
        local status
        status=$(echo "$all_statuses" | awk -F'|' -v name="$n" '$1==name{print $2; exit}')
        echo -e "  ${BOLD}$idx)${NC} $(printf '%-24s' "$n") ${DIM}${status}${NC}" >&2
        arr[$idx]="$n"
        idx=$((idx + 1))
    done <<< "$names"
    echo -e "  ${BOLD}0)${NC} Back" >&2
    echo "" >&2
    read -p "  Choose: " pick >&2
    if [[ "$pick" == "a" || "$pick" == "A" ]]; then
        echo "all"; return 0
    elif [[ "$pick" == "0" || -z "$pick" ]]; then
        return 1
    elif [[ -n "${arr[$pick]:-}" ]]; then
        echo "${arr[$pick]}"; return 0
    fi
    return 1
}

_services_action() {
    local action="$1"
    local running_filter=1
    [[ "$action" == "start" ]] && running_filter=0
    local target
    target=$(_pick_container "$running_filter") || { info "Cancelled."; return; }

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Pre-flight: starting a container that bind-mounts the data drive while that
    # drive isn't mounted fails with "no such device" and silently writes empty
    # dirs to the system disk. Guard the data-backed services before we try.
    if [[ "$action" == "start" ]]; then
        local _media _files
        _media=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null)
        _files=$(_env_get FILES_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null)
        case "$target" in
            navidrome)   _require_data_mount "${_media:-/mnt/data/media}" || return 1 ;;
            filebrowser) _require_data_mount "${_files:-/mnt/data}"       || return 1 ;;
            all)         _require_data_mount "${_files:-/mnt/data}"       || return 1 ;;
        esac
    fi

    local rc=0
    if [[ "$target" == "all" ]]; then
        # Confirm before stopping everything — easy to hit by accident.
        if [[ "$action" == "stop" ]]; then
            echo ""
            warn "This will stop ALL containers on the server."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
        fi
        cd "$SCRIPT_DIR"
        case "$action" in
            start)
                # compose up -d creates anything missing but never re-applies a
                # restart policy to an existing container, so the per-container
                # rule runs after it (covers adguard/syncthing too).
                sg docker -c "docker compose up -d"; rc=$?
                _svc_power_all start || rc=1
                ;;
            stop)    _svc_power_all stop    || rc=1 ;;
            restart) _svc_power_all restart || rc=1 ;;
        esac
    else
        # Extras with both-sides lifecycle have their own submenus.
        # Redirect so the laptop side is handled too.
        case "$target" in
            syncthing)
                warn "Syncthing has a laptop + server instance."
                info "Use ${BOLD}federver → 12${NC} to ${action} both sides."
                return 0
                ;;
            adguard)
                info "Use ${BOLD}federver → 10${NC} to manage AdGuard."
                return 0
                ;;
        esac
        case "$action" in
            start|stop|restart) _svc_power "$action" "$target" || rc=$? ;;
        esac
    fi

    if (( rc == 0 )); then
        ok "${action^} complete."
    else
        fail "${action^} failed for ${target} (exit $rc)."
        info "Check logs: ${BOLD}federver → 7 → 5${NC}  (or: docker logs <name>)"
        return 1
    fi
}

_services_logs() {
    echo ""
    echo -e "  ${BOLD}Running containers:${NC}"
    local names
    names=$(sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null)
    if [[ -z "$names" ]]; then
        fail "No containers running."
        return 1
    fi
    local idx=1
    declare -a name_arr
    while IFS= read -r n; do
        echo -e "    ${BOLD}$idx)${NC} $n"
        name_arr[$idx]="$n"
        idx=$((idx + 1))
    done <<< "$names"
    echo ""
    read -p "  Which container? " c
    local name="${name_arr[$c]}"
    [[ -z "$name" ]] && { fail "Invalid choice."; return 1; }
    echo ""
    info "Last 50 lines from $name (Ctrl+C to exit follow mode)..."
    sg docker -c "docker logs --tail 50 -f '$name'" || true
}

# Shared helper: print laptop Tailscale + Syncthing state. Runs locally on
# the laptop, used by step_status and step_services_wrapper.
_show_laptop_services() {
    echo -e "  ${BOLD}Laptop services${NC}"
    local st_state="${RED}stopped${NC}" ts_rec ts_state
    ts_rec=$(_ts_state)
    ts_state=$(_ts_word "$ts_rec")
    [[ "$ts_rec" == Running* ]] && ts_state+="  ${DIM}($(_ts_ip "$ts_rec"))${NC}"
    if systemctl --user is-active syncthing &>/dev/null; then
        st_state="${GREEN}running${NC}  ${DIM}(http://localhost:8384)${NC}"
    elif ! command -v syncthing &>/dev/null; then
        st_state="${DIM}not installed${NC}"
    fi
    echo -e "    Tailscale:  $ts_state"
    echo -e "    Syncthing:  $st_state"
    echo ""
}

# Data-drive guard for the picker's start paths. The picker runs on the laptop
# but the drive is on the server, so the check (and the .env it reads, same keys
# and defaults as _services_action) runs there over ssh. Unreachable = refused.
_picker_data_guard() { # navidrome|filebrowser|all
    local var def
    case "$1" in
        navidrome)       var=MUSIC_LOCATION; def=/mnt/data/media ;;
        filebrowser|all) var=FILES_LOCATION; def=/mnt/data ;;
        *) return 0 ;;
    esac
    ssh "$SERVER_USER@$SERVER_IP" "$(declare -p GREEN RED YELLOW BOLD DIM NC _DRIVE_ROOTS; declare -f _env_get _drive_verdict _require_data_mount fail info); p=\$(_env_get $var \"\$HOME/privcloud/.env\" 2>/dev/null); _require_data_mount \"\${p:-$def}\""
}

# Unified service picker: shows laptop services + server containers in one
# list. Runs locally on the laptop, SSHes once to get server container states.
# Usage: _unified_service_picker start|stop|restart
_unified_service_picker() {
    local action="$1"

    # ── 1. Collect laptop service states ──
    local ts_laptop="disconnected" st_laptop="stopped" ts_rec
    ts_rec=$(_ts_state)
    case "$ts_rec" in
        Running*)    ts_laptop="connected ($(_ts_ip "$ts_rec"))" ;;
        NeedsLogin*) ts_laptop="logged out" ;;
    esac
    if systemctl --user is-active syncthing &>/dev/null; then
        st_laptop="running"
    elif ! command -v syncthing &>/dev/null; then
        st_laptop="not installed"
    fi

    # ── 2. Collect server container states via single SSH call ──
    local server_data
    server_data=$(ssh "$SERVER_USER@$SERVER_IP" \
        "$(declare -f _ps_autostart); _ps_autostart docker 2>/dev/null") || {
        fail "Could not reach server."
        return 1
    }

    # ── 3. Extract Tailscale server state ──
    local ts_server="disconnected"
    local ts_server_raw
    ts_server_raw=$(ssh "$SERVER_USER@$SERVER_IP" "$(declare -f _ts_ipv4 _ts_state); _ts_state" 2>/dev/null) || true
    case "$ts_server_raw" in
        Running*)    ts_server="connected" ;;
        NeedsLogin*) ts_server="logged out" ;;
    esac

    # ── 4. Extract Syncthing server state from docker data ──
    local st_server="not created"
    local st_server_line
    st_server_line=$(echo "$server_data" | grep '^syncthing|' || true)
    if [[ -n "$st_server_line" ]]; then
        st_server="${st_server_line#syncthing|}"
    fi

    # ── 5. Check for known standalone containers that might be removed ──
    local adguard_status=""
    local adguard_line
    adguard_line=$(echo "$server_data" | grep '^adguard|' || true)
    if [[ -n "$adguard_line" ]]; then
        adguard_status="${adguard_line#adguard|}"
    else
        adguard_status="not created"
    fi

    # ── 6. Build the display list ──
    # Each entry: "name|display_label|section|state_text|is_running"
    # section: B=both-sides, S=server-container
    declare -a entries
    local idx=0

    # Both-sides: fully running only if ALL sides are up. If any side is
    # down, the service shows in the Start picker (needs starting somewhere).
    local ts_running=0 st_running=0
    [[ "$ts_laptop" == connected* && "$ts_server" == "connected" ]] && ts_running=1
    [[ "$st_laptop" == "running" && "$st_server" == Up* ]] && st_running=1

    # Tailscale
    entries[$idx]="tailscale|Tailscale|B|laptop: $ts_laptop / server: $ts_server|$ts_running"
    idx=$((idx + 1))

    # Syncthing (both-sides)
    entries[$idx]="syncthing|Syncthing|B|laptop: $st_laptop / server: $st_server|$st_running"
    idx=$((idx + 1))

    # Server containers (excluding syncthing, already shown above)
    while IFS='|' read -r cname cstatus; do
        [[ -z "$cname" ]] && continue
        [[ "$cname" == "syncthing" ]] && continue
        [[ "$cname" == "adguard" ]] && continue
        local is_running=0
        [[ "$cstatus" == Up* ]] && is_running=1
        entries[$idx]="$cname|$cname|S|$cstatus|$is_running"
        idx=$((idx + 1))
    done <<< "$server_data"

    # AdGuard as server container
    local ag_running=0
    [[ "$adguard_status" == Up* ]] && ag_running=1
    entries[$idx]="adguard|adguard|S|$adguard_status|$ag_running"
    idx=$((idx + 1))

    # ── 7. Filter based on action ──
    declare -a filtered
    local fidx=0
    for entry in "${entries[@]}"; do
        local is_running="${entry##*|}"
        local state_text
        state_text=$(echo "$entry" | cut -d'|' -f4)
        case "$action" in
            start)
                # Show stopped/exited/disconnected/not-created services
                [[ "$is_running" == "1" ]] && continue
                ;;
            stop)
                # Show only running services
                [[ "$is_running" == "0" ]] && continue
                ;;
            restart)
                # Show all (running makes most sense, but show everything)
                ;;
        esac
        filtered[$fidx]="$entry"
        fidx=$((fidx + 1))
    done

    if [[ ${#filtered[@]} -eq 0 ]]; then
        info "No services available to ${action}."
        return 0
    fi

    # ── 8. Display ──
    echo ""
    echo -e "  ${BOLD}a)${NC} ${BOLD}All${NC}"

    local display_idx=1 printed_both=0 printed_server=0
    declare -a pick_map  # maps display number → entry

    for entry in "${filtered[@]}"; do
        local section
        section=$(echo "$entry" | cut -d'|' -f3)
        local label
        label=$(echo "$entry" | cut -d'|' -f2)
        local state_text
        state_text=$(echo "$entry" | cut -d'|' -f4)

        if [[ "$section" == "B" && "$printed_both" -eq 0 ]]; then
            echo -e "  ${DIM}── Both sides ──${NC}"
            printed_both=1
        elif [[ "$section" == "S" && "$printed_server" -eq 0 ]]; then
            echo -e "  ${DIM}── Server containers ──${NC}"
            printed_server=1
        fi

        echo -e "  ${BOLD}${display_idx})${NC} $(printf '%-24s' "$label") ${DIM}${state_text}${NC}"
        pick_map[$display_idx]="$entry"
        display_idx=$((display_idx + 1))
    done

    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " pick

    # ── 9. Execute choice ──
    if [[ "$pick" == "a" || "$pick" == "A" ]]; then
        # All
        if [[ "$action" == "stop" ]]; then
            echo ""
            warn "This will stop ALL services (laptop + server)."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
        fi
        [[ "$action" == start ]] && { _picker_data_guard all || return 1; }
        # Both-sides services
        "_ts_${action}_both"
        "_syncthing_${action}_both"
        # Server containers via SSH
        local all_rc=0
        if [[ "$action" == start ]]; then
            # compose up -d creates what is missing but never re-applies a
            # restart policy; the per-container rule after it does.
            ssh "$SERVER_USER@$SERVER_IP" "cd ~/privcloud && sg docker -c 'docker compose up -d'" || all_rc=1
        fi
        _svc_power_all_remote "$action" || all_rc=1
        if (( all_rc != 0 )); then
            fail "${action^} did not complete for every service (see above)."
            return 1
        fi
        ok "${action^} complete (all services)."
        return 0
    fi

    if [[ "$pick" == "0" || -z "$pick" ]]; then
        info "Cancelled."
        return 0
    fi

    local chosen="${pick_map[$pick]:-}"
    if [[ -z "$chosen" ]]; then
        fail "Invalid choice."
        return 1
    fi

    local cname
    cname=$(echo "$chosen" | cut -d'|' -f1)
    local section
    section=$(echo "$chosen" | cut -d'|' -f3)
    local state_text
    state_text=$(echo "$chosen" | cut -d'|' -f4)

    # Handle "not created" containers
    if [[ "$state_text" == "not created" ]]; then
        case "$cname" in
            adguard)   warn "Container doesn't exist. Use ${BOLD}federver → 10${NC} to install it." ;;
            syncthing) warn "Container doesn't exist. Use ${BOLD}federver → 12${NC} to install it." ;;
            *)         warn "Container '$cname' doesn't exist." ;;
        esac
        return 0
    fi

    # Both-sides services
    if [[ "$section" == "B" ]]; then
        case "$cname" in
            tailscale)  "_ts_${action}_both" ;;
            syncthing)  "_syncthing_${action}_both" ;;
        esac
        return 0
    fi

    # Server container — confirm before stop
    if [[ "$action" == "stop" ]]; then
        warn "Stop ${BOLD}$cname${NC} on the server?"
        read -p "  [y/N] " -n 1 -r; echo ""
        [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return 0; }
    fi

    [[ "$action" == start ]] && { _picker_data_guard "$cname" || return 1; }
    if ! _svc_power_remote "$action" "$cname"; then
        fail "${action^} failed: $cname"
        return 1
    fi
    ok "${action^} complete: $cname"
}

# Laptop-side wrapper for option 7. Shows the submenu locally, collects
# laptop service info for Status, and SSHes to the server for everything else.
step_services_wrapper() {
    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- running containers + URLs${NC}"
    echo -e "  ${BOLD}2)${NC} Start                      ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}3)${NC} Stop                       ${DIM}<- pick one or All (stays off across reboots)${NC}"
    echo -e "  ${BOLD}4)${NC} Restart                    ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}5)${NC} Logs                       ${DIM}<- tail -f a container${NC}"
    echo -e "  ${BOLD}6)${NC} Deploy / redeploy          ${DIM}<- first install or change data paths${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " svc_choice
    case $svc_choice in
        1)
            # Status: show laptop services locally, then SSH for server status
            _show_laptop_services
            _on_server _services_status
            ;;
        2) _unified_service_picker start ;;
        3) _unified_service_picker stop ;;
        4) _unified_service_picker restart ;;
        5) _on_server _services_logs ;;
        6) _on_server step_deploy ;;
        0|*) return ;;
    esac
}

step_services() {
    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- running containers + URLs${NC}"
    echo -e "  ${BOLD}2)${NC} Start                      ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}3)${NC} Stop                       ${DIM}<- pick one or All (stays off across reboots)${NC}"
    echo -e "  ${BOLD}4)${NC} Restart                    ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}5)${NC} Logs                       ${DIM}<- tail -f a container${NC}"
    echo -e "  ${BOLD}6)${NC} Deploy / redeploy          ${DIM}<- first install or change data paths${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " svc_choice
    case $svc_choice in
        1) _services_status ;;
        2) _services_action start ;;
        3) _services_action stop ;;
        4) _services_action restart ;;
        5) _services_logs ;;
        6) step_deploy ;;
        0|*) return ;;
    esac
}

step_deploy() {
    info "Deploys all services: Immich, Navidrome, FileBrowser, Watchtower, Uptime Kuma."
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ── Ask for base data path ──
    info "What this does: starts (or updates) all the service containers."
    info "It is safe to re-run — it does NOT erase your photos, music, or files,"
    info "and services that haven't changed keep running untouched."
    echo ""
    info "The 'base data path' is the one parent folder where ALL your data lives"
    info "(Immich photos, music, FileBrowser files). Pick it once; press Enter to"
    info "keep the default on later runs."
    echo ""
    info "Default: /mnt/data (USB drive)"
    info "Internal drive example: /home/$SERVER_USER/data"
    echo ""
    read -p "  Base data path [Enter = /mnt/data, 0 = cancel]: " base_path
    if [[ "$base_path" == "0" ]]; then
        info "Cancelled — no changes made."
        return 0
    fi
    base_path="${base_path:-/mnt/data}"
    base_path="${base_path/#\~/$HOME}"

    # Set up .env
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    fi

    _set_env "UPLOAD_LOCATION" "${base_path}/immich/upload" "$SCRIPT_DIR/.env"
    _set_env "DB_DATA_LOCATION" "${base_path}/immich/postgres" "$SCRIPT_DIR/.env"
    _set_env "MEDIA_LOCATION" "${base_path}/media" "$SCRIPT_DIR/.env"

    # MUSIC_LOCATION: preserve a custom folder set via Storage > Change music
    # location. Re-running Deploy used to silently revert it to the default,
    # which would also strip out the smart-playlist (.nsp) files inside it.
    local default_music="${base_path}/media/My Music"
    local existing_music example_music
    existing_music=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")
    example_music=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env.example")
    if [[ -n "$existing_music" && "$existing_music" != "$default_music" \
          && "$existing_music" != "$example_music" ]]; then
        warn "Custom music location in use: $existing_music"
        read -p "  Keep it? [Enter = keep, or type 'reset' to use $default_music]: " _music_reset
        if [[ "$_music_reset" == "reset" ]]; then
            _set_env "MUSIC_LOCATION" "$default_music" "$SCRIPT_DIR/.env"
            ok "Music location reset to $default_music"
        else
            info "Keeping custom music location: $existing_music"
        fi
    else
        _set_env "MUSIC_LOCATION" "$default_music" "$SCRIPT_DIR/.env"
    fi

    _set_env "FILES_LOCATION" "${base_path}" "$SCRIPT_DIR/.env"

    UPLOAD_LOCATION=$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")
    DB_DATA_LOCATION=$(_env_get DB_DATA_LOCATION "$SCRIPT_DIR/.env")
    MEDIA_LOCATION=$(_env_get MEDIA_LOCATION "$SCRIPT_DIR/.env")
    MUSIC_LOCATION=$(_env_get MUSIC_LOCATION "$SCRIPT_DIR/.env")

    # Bail before creating dirs or starting containers if the data drive isn't
    # mounted — otherwise mkdir writes empty folders to the system disk under the
    # unmounted stub and every data-backed container fails with "no such device".
    _require_data_mount "$base_path" || return 1

    sudo mkdir -p "$UPLOAD_LOCATION" "$DB_DATA_LOCATION" "$MEDIA_LOCATION" "$MUSIC_LOCATION" 2>/dev/null || true

    # Seed smart playlists into the music folder before Navidrome starts, so its
    # startup scan picks them up.
    _install_smart_playlists

    cd "$SCRIPT_DIR"
    if ! sg docker -c "docker compose up -d"; then
        echo ""
        fail "One or more containers failed to start."
        info "Check logs: ${BOLD}federver → 7 → 5${NC}  (or: docker compose logs)"
        return 1
    fi

    IP=$(hostname -I | awk '{print $1}')
    echo ""
    ok "Services running!"
    echo ""
    echo -e "  ${BOLD}Access from your browser:${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Navidrome:    ${BLUE}http://$IP:4533${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"
    echo ""
    info "Watchtower auto-updates all containers daily at 4am."
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SETUP EACH SERVICE${NC}"
    echo ""
    echo -e "  ${BOLD}Navidrome${NC} (port 4533)"
    echo -e "    Open in browser, create admin account. Music is served from /music."
    echo -e "    Download ${BOLD}Arpeggi${NC} from the App Store for iPhone playback"
    echo -e "    (background playback + offline cache via Subsonic API)."
    echo ""
    echo -e "  ${BOLD}FileBrowser${NC} (port 8080)"
    # Generate a random password, persist it across container recreations,
    # and save it to an owner-only file so the user can retrieve it later.
    local fb_pass
    fb_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
    local fb_pass_file="$HOME/.privcloud/filebrowser.pass"
    mkdir -p "$(dirname "$fb_pass_file")"
    # umask in a subshell so the file is created 0600, not created-then-chmod'd
    # (no world-readable window).
    ( umask 077; printf '%s\n' "$fb_pass" > "$fb_pass_file" )
    sleep 2
    sg docker -c "docker stop filebrowser" > /dev/null 2>&1
    # Pass the password through the container's environment (-e), never
    # interpolated into the shell string — special characters can't break the
    # command or inject. Check the result instead of swallowing it: a silent
    # failure would leave the default credentials active.
    export FB_NEW_PASS="$fb_pass"
    if sg docker -c 'docker run --rm -e FB_NEW_PASS --entrypoint sh -v privcloud_filebrowser-db:/database filebrowser/filebrowser:latest -c "filebrowser users update admin --password \"\$FB_NEW_PASS\" --database /database/filebrowser.db"' > /dev/null 2>&1; then
        unset FB_NEW_PASS
        sg docker -c "docker start filebrowser" > /dev/null 2>&1
        echo -e "    Login: ${BOLD}admin${NC} / ${BOLD}$fb_pass${NC}"
        echo -e "    Saved to: ${BLUE}$fb_pass_file${NC} (retrieve with: ${BOLD}cat $fb_pass_file${NC})"
    else
        unset FB_NEW_PASS
        sg docker -c "docker start filebrowser" > /dev/null 2>&1
        warn "Could not set the FileBrowser admin password automatically."
        warn "Default credentials may still be active — set one via: ${BOLD}federver → r → 1${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Uptime Kuma${NC} (port 3001)"
    echo -e "    Create admin account, then add monitors (use server IP, not localhost):"
    echo -e "    + New Monitor → HTTP → http://$IP:2283/api/server/ping (Immich)"
    echo -e "    + New Monitor → HTTP → http://$IP:4533 (Navidrome)"
    echo -e "    + New Monitor → HTTP → http://$IP:8080 (FileBrowser)"
    echo -e "    Optional: set up Telegram/email alerts in Settings → Notifications"
    echo ""
    echo -e "  See README or run ${BOLD}s)${NC} for full setup details."
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Docker container log rotation — disk-fill prevention. Idempotent: the
    # function no-ops when daemon.json already has max-size set.
    echo ""
    step_logrotation
}

# Read a single KEY from .env without sourcing the file. `source` trips
# on unquoted values with spaces (e.g. MUSIC_LOCATION=/mnt/data/media/My Music),
# so we parse one line at a time, strip any surrounding quotes, and
# preserve spaces verbatim.
_env_get() {
    local key="$1" file="$2"
    [[ ! -f "$file" ]] && return 0
    local line value
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1)
    [[ -z "$line" ]] && return 0
    value="${line#${key}=}"
    # Strip optional surrounding quotes (single or double)
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    echo "$value"
}

# Populate a `mounts` array (in the caller's scope) with -v bind-mount
# flags for the three semantic sync paths: data / media / immich.
# Reads .env for FILES_LOCATION, MEDIA_LOCATION, UPLOAD_LOCATION, falling
# back to the stock privcloud layout if the var isn't set.
_syncthing_build_mounts() {
    local SCRIPT_DIR env_file
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="$SCRIPT_DIR/.env"

    local data_path media_path immich_path upload
    data_path=$(_env_get FILES_LOCATION "$env_file")
    media_path=$(_env_get MEDIA_LOCATION "$env_file")
    upload=$(_env_get UPLOAD_LOCATION "$env_file")
    [[ -z "$data_path"  ]] && data_path="/mnt/data/data"
    [[ -z "$media_path" ]] && media_path="/mnt/data/media"
    if [[ -n "$upload" ]]; then
        immich_path=$(dirname "$upload")
    else
        immich_path="/home/$USER/data/immich"
    fi

    mounts=()
    local p seen=""
    for p in "$data_path" "$media_path" "$immich_path"; do
        [[ -z "$p" ]] && continue
        [[ "$seen" == *":$p:"* ]] && continue
        if sudo test -d "$p"; then
            mounts+=(-v "${p}:${p}")
            seen+=":$p:"
        fi
    done
}

_syncthing_show_paths() {
    local SCRIPT_DIR env_file
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="$SCRIPT_DIR/.env"
    echo ""
    echo -e "  ${BOLD}Paths currently bind-mounted into the Syncthing container${NC}"
    sudo docker inspect -f '{{range .Mounts}}    {{.Source}} → {{.Destination}}{{println}}{{end}}' syncthing 2>/dev/null
    echo ""
    echo -e "  ${BOLD}Expected from .env (data / media / immich)${NC}"
    local data_path media_path upload immich_path
    data_path=$(_env_get FILES_LOCATION "$env_file");   data_path="${data_path:-/mnt/data/data}"
    media_path=$(_env_get MEDIA_LOCATION "$env_file"); media_path="${media_path:-/mnt/data/media}"
    upload=$(_env_get UPLOAD_LOCATION "$env_file")
    if [[ -n "$upload" ]]; then
        immich_path=$(dirname "$upload")
    else
        immich_path="/home/$USER/data/immich"
    fi
    echo -e "    data:    $data_path"
    echo -e "    media:   $media_path"
    echo -e "    immich:  $immich_path"
    echo ""
    info "If the .env paths differ from what's mounted, pick 'Reapply paths"
    info "from .env' to recreate the container with the new mounts."
    info "(Pairings and folder shares are kept — they live in /opt/syncthing.)"
}

# True only when the docker query SUCCEEDED and the named container is absent.
# A failed query (permissions, daemon down) must not read as "removed".
_container_gone() {
    local names
    names=$(sudo docker ps -a --format '{{.Names}}' 2>/dev/null) || return 1
    ! grep -qx "$1" <<<"$names"
}

# Close Syncthing's firewall ports; non-zero if ANY firewall-cmd step failed.
# Self-contained so it can be shipped to the server with `declare -f`.
_syncthing_fw_close() {
    sudo firewall-cmd --permanent --remove-port=8384/tcp  > /dev/null 2>&1 \
        && sudo firewall-cmd --permanent --remove-port=22000/tcp > /dev/null 2>&1 \
        && sudo firewall-cmd --permanent --remove-port=22000/udp > /dev/null 2>&1 \
        && sudo firewall-cmd --permanent --remove-port=21027/udp > /dev/null 2>&1 \
        && sudo firewall-cmd --reload > /dev/null 2>&1
}

_syncthing_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE Syncthing (server side)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} Stop + remove the syncthing container on the server"
    echo -e "    ${RED}•${NC} Close firewall ports 8384/tcp, 22000/tcp+udp, 21027/udp"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} Real-time file sync between server and other devices stops"
    echo -e "    ${YELLOW}•${NC} Paired devices show the server as 'Disconnected'"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} /opt/syncthing/ — device identity (cert.pem/key.pem), config,"
    echo -e "      pairings, folder shares — so a future reinstall keeps the same ID"
    echo -e "    ${GREEN}•${NC} Syncthing on your laptop (systemd user service) untouched"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete syncthing || return 0

    info "Removing syncthing container..."
    sudo docker rm -f syncthing > /dev/null 2>&1 || true
    if ! _container_gone syncthing; then
        fail "Container 'syncthing' is still present (or docker could not be queried) - not removed."
        return 1
    fi

    info "Closing firewall ports..."
    if ! _syncthing_fw_close; then
        fail "Container removed, but the firewall ports were NOT closed (8384/tcp, 22000/tcp+udp, 21027/udp)."
        return 1
    fi

    ok "Syncthing removed."
    echo -e "  ${DIM}Config kept at /opt/syncthing. To wipe entirely:${NC} sudo rm -rf /opt/syncthing"
    echo -e "  ${DIM}Laptop Syncthing left running. Stop with:${NC} systemctl --user disable --now syncthing"
}

_syncthing_reapply_paths() {
    warn "This will stop the Syncthing container and recreate it with"
    warn "fresh bind mounts read from .env (data / media / immich)."
    info "Pairings and folder shares stay intact — they live under /opt/syncthing."
    read -p "  Continue? [y/N] " -n 1 -r
    echo ""
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return 0; }

    info "Stopping + removing container..."
    sudo docker rm -f syncthing > /dev/null 2>&1 || true

    local -a mounts
    _syncthing_build_mounts
    mounts+=(-v /opt/syncthing:/var/syncthing)

    info "Restarting with new mounts..."
    sudo docker run -d \
        --name syncthing \
        --network=host \
        --restart=unless-stopped \
        -e PUID=$(id -u) \
        -e PGID=$(id -g) \
        -e STGUIADDRESS=0.0.0.0:8384 \
        "${mounts[@]}" \
        syncthing/syncthing:latest > /dev/null
    sleep 2
    if _syncthing_is_running; then
        ok "Syncthing restarted with new sync paths."
        _syncthing_show_paths
    else
        fail "Container failed to start. Check logs."
        sudo docker logs --tail 20 syncthing 2>&1 || true
    fi
}

_syncthing_device_id() {
    # Read the server's Device ID. Syncthing 1.x has `syncthing --device-id`,
    # Syncthing 2.x restructured the CLI and that flag was removed, so we
    # try several variants in order and extract the ID pattern from
    # whichever one produces usable output. grep -oE matches the ID
    # wherever it appears (yaml/json/plain), head -1 takes the first.
    local attempt id cmd
    for attempt in $(seq 1 20); do
        for cmd in \
            'syncthing --device-id' \
            'syncthing show device-id' \
            'syncthing cli show system' \
            'cat /var/syncthing/config/config.xml'
        do
            id=$(sudo docker exec syncthing sh -c "$cmd" 2>/dev/null \
                 | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -1 || echo "")
            [[ -n "$id" ]] && { echo "$id"; return 0; }
        done
        sleep 1
    done
    echo ""
}

_syncthing_is_running() {
    sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^syncthing$'
}

_syncthing_exists() {
    sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^syncthing$'
}

_syncthing_status() {
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "  ${BOLD}Syncthing${NC}"
    if _syncthing_is_running; then
        local uptime
        uptime=$(sudo docker ps --filter name=syncthing --format '{{.Status}}' 2>/dev/null)
        echo -e "    State:     ${GREEN}running${NC}  ${DIM}($uptime)${NC}"
        echo -e "    Dashboard: ${BLUE}http://$IP:8384${NC}"
        local id
        id=$(_syncthing_device_id)
        if [[ -n "$id" ]]; then
            echo -e "    Device ID: ${BOLD}$id${NC}"
        fi
    elif _syncthing_exists; then
        local rp
        rp=$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' syncthing 2>/dev/null)
        echo -e "    State:     ${RED}stopped${NC}$([[ "$rp" == no ]] && echo " (autostart off)")"
    else
        echo -e "    State:     ${DIM}not installed${NC}"
    fi
}

_syncthing_show_device_id() {
    local id
    id=$(_syncthing_device_id)
    if [[ -n "$id" ]]; then
        echo ""
        echo -e "  ${BOLD}Server Device ID${NC} ${DIM}(paste into clients to pair):${NC}"
        echo -e "    ${BOLD}$id${NC}"
    else
        fail "Device ID unavailable (container not running?)."
    fi
}

_syncthing_install() {
    local IP
    IP=$(hostname -I | awk '{print $1}')

    # Open firewall: 8384 web UI, 22000/tcp+udp sync, 21027/udp LAN discovery
    info "Opening firewall ports (8384 web UI, 22000 sync, 21027 discovery)..."
    sudo firewall-cmd --permanent --add-port=8384/tcp  > /dev/null 2>&1
    sudo firewall-cmd --permanent --add-port=22000/tcp > /dev/null 2>&1
    sudo firewall-cmd --permanent --add-port=22000/udp > /dev/null 2>&1
    sudo firewall-cmd --permanent --add-port=21027/udp > /dev/null 2>&1
    sudo firewall-cmd --reload > /dev/null 2>&1
    ok "Firewall: 8384/tcp, 22000/tcp+udp, 21027/udp open."

    sudo mkdir -p /opt/syncthing
    sudo chown -R "$(id -u):$(id -g)" /opt/syncthing 2>/dev/null || true

    # Build the bind-mount list from .env semantic paths. Defaults match
    # the three privcloud categories: data / media / immich.
    local -a mounts
    _syncthing_build_mounts
    mounts+=(-v /opt/syncthing:/var/syncthing)

    info "Starting Syncthing container..."
    sudo docker run -d \
        --name syncthing \
        --network=host \
        --restart=unless-stopped \
        -e PUID=$(id -u) \
        -e PGID=$(id -g) \
        -e STGUIADDRESS=0.0.0.0:8384 \
        "${mounts[@]}" \
        syncthing/syncthing:latest > /dev/null
    sleep 3
    if [[ "$DRY_RUN" != "1" ]] && ! _syncthing_is_running; then
        fail "Syncthing container failed to start."
        sudo docker logs --tail 20 syncthing 2>&1 || true
        return 1
    fi
    ok "Syncthing running."
    sleep 2

    echo ""
    _syncthing_show_device_id

    _syncthing_show_paths

    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}NEXT: Pair your devices${NC}"
    echo ""
    echo -e "  Laptop is already installed (option 12 handled it)."
    echo -e "  For ${BOLD}phones${NC}:"
    echo -e "    Android: install ${BOLD}Syncthing${NC} from F-Droid or Play Store"
    echo -e "    iOS:     install ${BOLD}Möbius Sync${NC} from the App Store"
    echo ""
    echo -e "  ${BOLD}Then pair each device with the server:${NC}"
    echo -e "    1. On the device, open Syncthing → ${BOLD}Add Remote Device${NC}"
    echo -e "    2. Paste the server's Device ID shown above → Save"
    echo -e "    3. On the server dashboard (${BLUE}http://$IP:8384${NC}),"
    echo -e "       accept the incoming device request"
    echo -e "    4. Create a shared folder on one side → accept on the other"
    echo ""
    echo -e "  ${DIM}First-time server dashboard visit will prompt for GUI username${NC}"
    echo -e "  ${DIM}+ password — set them (the UI is LAN-reachable). After that,${NC}"
    echo -e "  ${DIM}run federver → 15 (Save to pass) to back up the device identity${NC}"
    echo -e "  ${DIM}— losing cert.pem/key.pem means re-pairing every client.${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    ok "Syncthing installed."
}

_syncthing_install_laptop() {
    echo -e "  ${BOLD}── Laptop side ──${NC}"
    if command -v syncthing &>/dev/null; then
        ok "Syncthing already installed on this laptop."
    else
        if ! command -v dnf &>/dev/null; then
            warn "Not a dnf-based system. Install Syncthing manually:"
            info "  https://syncthing.net/downloads/"
            return 0
        fi
        info "Installing Syncthing via dnf..."
        sudo dnf install -y syncthing > /dev/null 2>&1 || {
            fail "dnf install failed."
            return 1
        }
        ok "Syncthing installed."
    fi

    # User-level systemd service — runs as the logged-in user, no sudo needed
    if systemctl --user is-active syncthing &>/dev/null; then
        ok "Syncthing user service already running."
    else
        info "Enabling Syncthing user service..."
        systemctl --user enable --now syncthing 2>/dev/null && ok "Service enabled + started."
    fi

    # Read the laptop's Device ID. `syncthing --device-id` prints warnings
    # to STDOUT when the cert isn't ready yet, so validate the output
    # matches the real format (8 groups of 7 uppercase chars, 7 hyphens).
    # Short retry window because after `systemctl --user enable --now` the
    # cert is usually ready within a second or two; no point waiting 20s.
    local attempt laptop_id=""
    for attempt in $(seq 1 10); do
        laptop_id=$(syncthing --device-id 2>/dev/null | grep -E '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$' | head -1 || echo "")
        [[ -n "$laptop_id" ]] && break
        sleep 1
    done

    echo -e "  Laptop dashboard: ${BLUE}http://localhost:8384${NC}"
    if [[ -n "$laptop_id" ]]; then
        echo -e "  ${BOLD}Laptop Device ID:${NC} ${BOLD}$laptop_id${NC}"
    else
        warn "Laptop Device ID not ready yet — check with: ${BOLD}syncthing --device-id${NC}"
    fi
    echo ""
}

_syncthing_stop_both() {
    warn "Stop Syncthing on both laptop and server?"
    read -p "  [y/N] " -n 1 -r; echo ""
    [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
    info "Stopping..."
    systemctl --user stop syncthing 2>/dev/null && ok "Laptop: stopped." || warn "Laptop: not running."
    _svc_power_remote stop syncthing \
        && ok "Server: stopped." || warn "Server: could not stop (is it installed?)."
}

_syncthing_start_both() {
    info "Starting Syncthing on both laptop and server..."
    systemctl --user start syncthing 2>/dev/null && ok "Laptop: started." || warn "Laptop: failed to start."
    # ssh -t for sudo TTY. NOT inside $() — that captures the prompt.
    _svc_power_remote start syncthing \
        && ok "Server: started." \
        || { warn "Server: failed to start."; info "If container has bad config: federver → 12 to reinstall."; }
}

_syncthing_restart_both() {
    info "Restarting Syncthing on both laptop and server..."
    systemctl --user restart syncthing 2>/dev/null && ok "Laptop: restarted." || warn "Laptop: failed."
    _svc_power_remote restart syncthing \
        && ok "Server: restarted." || warn "Server: failed."
}

# Laptop half of the Syncthing uninstall. Returns 0 only if verified gone.
_syncthing_uninstall_laptop() {
    info "Removing from laptop..."
    systemctl --user disable --now syncthing 2>/dev/null || true
    sudo dnf remove -y syncthing > /dev/null 2>&1 || true
    hash -r
    if type -P syncthing > /dev/null; then
        fail "Laptop: syncthing is still installed - dnf remove failed. Try: sudo dnf remove syncthing"
        return 1
    fi
    ok "Laptop: removed."
}

# Server half, driven from the laptop. docker needs no sudo (the server user
# is in the docker group), so it runs in a plain ssh and is then verified.
# firewall-cmd does need root, and sudo's credential doesn't cross ssh
# sessions, so it gets its own TTY session (one prompt covers every command).
# Returns 0 only if the container is gone AND the ports are closed.
_syncthing_uninstall_server_remote() {
    local err state
    info "Removing from server..."
    err=$(ssh "$SERVER_USER@$SERVER_IP" 'docker rm -f syncthing' 2>&1 >/dev/null) || true
    state=$(_syncthing_server_probe)
    case "$state" in
        "") ;;
        unreachable)  fail "Server: could not confirm removal (server unreachable)."; return 1 ;;
        docker-error) fail "Server: could not query docker to confirm removal. ${err}"; return 1 ;;
        *)            fail "Server: container still present (${state}). ${err}"; return 1 ;;
    esac
    info "Closing firewall ports (sudo password may be asked)..."
    if ! ssh -t "$SERVER_USER@$SERVER_IP" "$(declare -f _syncthing_fw_close); _syncthing_fw_close"; then
        fail "Server: container removed, but the firewall ports were NOT closed (8384/tcp, 22000/tcp+udp, 21027/udp)."
        return 1
    fi
    ok "Server: removed."
}

_syncthing_uninstall_both() {
    # $1: "laptop" | "server" removes just that side (partial state); default both.
    local side="${1:-both}" rc=0
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ "$side" == both ]]; then
        echo -e "  ${RED}DELETE Syncthing (both laptop and server)${NC}"
    else
        echo -e "  ${RED}DELETE Syncthing ($side only)${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    [[ "$side" != server ]] && echo -e "    ${RED}•${NC} Laptop: systemctl --user disable --now syncthing + dnf remove"
    [[ "$side" != laptop ]] && echo -e "    ${RED}•${NC} Server: stop + remove Docker container, close firewall ports"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} Real-time file sync between all devices stops"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    [[ "$side" != laptop ]] && echo -e "    ${GREEN}•${NC} Server: /opt/syncthing/ (identity, config, pairings)"
    [[ "$side" != server ]] && echo -e "    ${GREEN}•${NC} Laptop: ~/.local/state/syncthing/ (identity, config)"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete syncthing || return 0

    [[ "$side" != server ]] && { _syncthing_uninstall_laptop || rc=1; }
    [[ "$side" != laptop ]] && { _syncthing_uninstall_server_remote || rc=1; }

    if (( rc == 0 )); then
        echo ""
        [[ "$side" != laptop ]] && echo -e "  ${DIM}Server config kept at /opt/syncthing${NC}"
        [[ "$side" != server ]] && echo -e "  ${DIM}Laptop config kept at ~/.local/state/syncthing${NC}"
    fi
    return $rc
}

# Server-side Syncthing state for the laptop menu (read-only, non-TTY, no sudo:
# the server user is in the docker group). Prints: running | stopped | "" (not
# installed) | unreachable | docker-error (docker can't be queried, so a failed
# query never reads as "removed" or "not installed").
_syncthing_server_probe() {
    _server_probe "n=\$(docker ps -a --format '{{.Names}}' 2>/dev/null) || { echo docker-error; exit 0; }
if grep -qx syncthing <<<\"\$n\"; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx syncthing; then echo running; else echo stopped; fi
fi"
}

step_syncthing() {
    info "Syncthing syncs folders between devices in real-time, peer-to-peer."
    info "Continuous bidirectional sync with conflict resolution."
    echo ""

    # Server-side (via --run from an SSH hop, or user on federver directly):
    # run the server-only management submenu.
    if _is_server; then
        _syncthing_server_step
        return
    fi

    # ── Laptop-side: which sides are installed? ──
    # Not both -> the gate handles it (offer to install, or manage the one side
    # that exists); opening this menu never installs anything by itself.
    local lap_state="" srv_state="" g=0
    if command -v syncthing &>/dev/null; then
        lap_state="installed (stopped)"
        systemctl --user is-active syncthing &>/dev/null && lap_state="installed (running)"
    fi
    srv_state=$(_syncthing_server_probe)
    if [[ "$srv_state" == docker-error ]]; then
        # Not "not installed": offering an install here could clobber a live container.
        fail "Cannot query docker on the server - changing nothing."
        return 1
    fi
    [[ -n "$srv_state" && "$srv_state" != unreachable ]] && srv_state="installed ($srv_state)"
    _two_sided_gate "Syncthing" "$lap_state" "$srv_state" _syncthing_install_laptop "_syncthing_server_step" _syncthing_uninstall_both || g=$?
    (( g == 10 )) || return $g

    # Both installed — show unified status + management submenu
    echo -e "  ${BOLD}── Laptop ──${NC}"
    local laptop_state="stopped"
    systemctl --user is-active syncthing &>/dev/null && laptop_state="${GREEN}running${NC}"
    local laptop_id
    laptop_id=$(syncthing --device-id 2>/dev/null | grep -E '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$' | head -1 || echo "")
    echo -e "    State:     $laptop_state"
    echo -e "    Dashboard: ${BLUE}http://localhost:8384${NC}"
    [[ -n "$laptop_id" ]] && echo -e "    Device ID: ${BOLD}$laptop_id${NC}"
    echo ""

    echo -e "  ${BOLD}── Server ──${NC}"
    ssh "$SERVER_USER@$SERVER_IP" bash -s <<'REMOTE_STATUS'
        state="stopped"
        [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' syncthing 2>/dev/null)" = no ] && state="stopped (autostart off)"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^syncthing$'; then
            uptime=$(docker ps --filter name=syncthing --format '{{.Status}}' 2>/dev/null)
            state="running  ($uptime)"
        fi
        ip=$(hostname -I | awk '{print $1}')
        echo "    State:     $state"
        echo "    Dashboard: http://$ip:8384"
        # Try several CLI shapes for Device ID (Syncthing 1.x vs 2.x)
        id=""
        for cmd in 'syncthing --device-id' 'syncthing show device-id' 'syncthing cli show system' 'cat /var/syncthing/config/config.xml'; do
            id=$(docker exec syncthing sh -c "$cmd" 2>/dev/null | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -1 || echo "")
            [[ -n "$id" ]] && break
        done
        [[ -n "$id" ]] && echo "    Device ID: $id"
REMOTE_STATUS

    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh status"
    echo -e "  ${BOLD}2)${NC} Show Device IDs            ${DIM}<- for pairing new clients${NC}"
    echo -e "  ${BOLD}3)${NC} Start both"
    echo -e "  ${BOLD}4)${NC} Stop both                  ${DIM}<- stays off across reboots${NC}"
    echo -e "  ${BOLD}5)${NC} Restart both"
    echo -e "  ${BOLD}6)${NC} Show sync paths            ${DIM}<- server-side container mounts${NC}"
    echo -e "  ${BOLD}7)${NC} Reapply paths from .env    ${DIM}<- recreate server container${NC}"
    echo -e "  ${BOLD}8)${NC} Logs (server)              ${DIM}<- tail -f syncthing logs${NC}"
    echo -e "  ${BOLD}9)${NC} ${RED}Uninstall both${NC}             ${DIM}<- remove from laptop + server${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " st_choice
    case $st_choice in
        1) step_syncthing ;;
        2)
            echo ""
            [[ -n "$laptop_id" ]] && echo -e "  ${BOLD}Laptop:${NC} $laptop_id"
            local server_id
            server_id=$(ssh "$SERVER_USER@$SERVER_IP" 'for cmd in "syncthing --device-id" "syncthing show device-id" "syncthing cli show system" "cat /var/syncthing/config/config.xml"; do id=$(docker exec syncthing sh -c "$cmd" 2>/dev/null | grep -oE "[A-Z0-9]{7}(-[A-Z0-9]{7}){7}" | head -1); [[ -n "$id" ]] && echo "$id" && break; done' 2>/dev/null)
            [[ -n "$server_id" ]] && echo -e "  ${BOLD}Server:${NC} $server_id"
            ;;
        3) _syncthing_start_both ;;
        4) _syncthing_stop_both ;;
        5) _syncthing_restart_both ;;
        6) _on_server _syncthing_show_paths ;;
        7) _on_server _syncthing_reapply_paths ;;
        8) ssh -t "$SERVER_USER@$SERVER_IP" "sudo docker logs --tail 50 -f syncthing" || true ;;
        9) _syncthing_uninstall_both ;;
        0|*) return ;;
    esac
}

# Server-side install-or-manage. Runs on federver, either called directly
# or via `./setup.sh --run _syncthing_server_step` from an _on_server hop.
_syncthing_server_step() {
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed. Run step 5 first."
        return 1
    fi

    # Fresh install path
    if ! _syncthing_exists; then
        _syncthing_install
        return
    fi

    # Already exists — show status + management submenu
    _syncthing_status
    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh status"
    echo -e "  ${BOLD}2)${NC} Show Device ID             ${DIM}<- for pairing new clients${NC}"
    echo -e "  ${BOLD}3)${NC} Show sync paths            ${DIM}<- what the UI can browse${NC}"
    echo -e "  ${BOLD}4)${NC} Reapply paths from .env    ${DIM}<- recreate container with fresh mounts${NC}"
    echo -e "  ${BOLD}5)${NC} Start"
    echo -e "  ${BOLD}6)${NC} Stop"
    echo -e "  ${BOLD}7)${NC} Restart"
    echo -e "  ${BOLD}8)${NC} Logs                       ${DIM}<- tail -f syncthing logs${NC}"
    echo -e "  ${BOLD}9)${NC} ${RED}Uninstall${NC}                  ${DIM}<- stop + remove container, keep /opt/syncthing${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " st_choice
    case $st_choice in
        1) _syncthing_status ;;
        2) _syncthing_show_device_id ;;
        3) _syncthing_show_paths ;;
        4) _syncthing_reapply_paths ;;
        5) info "Starting...";   _svc_power start syncthing   && ok "Started."   || fail "Start failed." ;;
        6) info "Stopping...";   _svc_power stop syncthing    && ok "Stopped."   || fail "Stop failed." ;;
        7) info "Restarting..."; _svc_power restart syncthing && ok "Restarted." || fail "Restart failed." ;;
        8)
            info "Last 50 lines (Ctrl+C to exit follow mode)..."
            sudo docker logs --tail 50 -f syncthing || true
            ;;
        9) _syncthing_uninstall ;;
        0|*) return ;;
    esac
}

_rdp_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE Remote Desktop (xrdp)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} systemctl disable --now xrdp"
    echo -e "    ${RED}•${NC} Re-enable lightdm (local display manager)"
    echo -e "    ${RED}•${NC} Close firewall port 3389/tcp"
    echo -e "    ${RED}•${NC} dnf remove -y xrdp"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} You can't RDP into the server anymore"
    echo -e "    ${YELLOW}•${NC} To see the desktop again you'll need a physical monitor +"
    echo -e "      keyboard, or re-enable a display manager yourself"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} XFCE desktop packages (xfce4-session, xfwm4, xfce4-panel,"
    echo -e "      xfdesktop) — removing them is more disruptive than it's worth"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete xrdp || return 0

    local bad=0
    info "Stopping xrdp..."
    sudo systemctl disable --now xrdp > /dev/null 2>&1 || true
    info "Re-enabling lightdm..."
    if ! sudo systemctl enable --now lightdm > /dev/null 2>&1; then
        fail "Could not enable/start lightdm."
        bad=1
    fi
    info "Closing firewall port 3389/tcp..."
    if ! { sudo firewall-cmd --permanent --remove-port=3389/tcp > /dev/null 2>&1 \
        && sudo firewall-cmd --reload > /dev/null 2>&1; }; then
        fail "Firewall port 3389/tcp was NOT closed."
        bad=1
    fi
    info "Removing xrdp package..."
    sudo dnf remove -y xrdp > /dev/null 2>&1 || true
    # Verify the end state, not that the commands ran.
    if rpm -q xrdp > /dev/null 2>&1; then
        fail "xrdp package is still installed - dnf remove failed. Try: sudo dnf remove xrdp"
        bad=1
    fi
    if systemctl is-active --quiet xrdp 2>/dev/null || systemctl is-enabled --quiet xrdp 2>/dev/null; then
        fail "xrdp service is still active or enabled."
        bad=1
    fi
    if (( bad )); then
        fail "Remote desktop removal did not finish - see above."
        return 1
    fi
    ok "Remote desktop removed."
}

step_remotedesktop() {
    # If already installed, offer uninstall or reconnect info. Otherwise
    # fall through to fresh install.
    if command -v xrdp &>/dev/null && systemctl is-enabled xrdp &>/dev/null; then
        local IP
        IP=$(hostname -I | awk '{print $1}')
        ok "Remote desktop (xrdp) is already installed."
        echo -e "  Connect: RDP client → ${BOLD}$IP${NC} (or ${BOLD}$(hostname)${NC} via Tailscale)"
        echo -e "           Username: ${BOLD}$USER${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Restart xrdp"
        echo -e "  ${BOLD}2)${NC} ${RED}Uninstall${NC}                ${DIM}<- removes xrdp, re-enables lightdm${NC}"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choose: " rdp_choice
        case "$rdp_choice" in
            1) info "Restarting xrdp..."; sudo systemctl restart xrdp && ok "Restarted." ;;
            2) _rdp_uninstall ;;
            0|*) return ;;
        esac
        return 0
    fi

    info "Installs xrdp for remote desktop access to the XFCE desktop."
    info "Connect from any device using an RDP client."
    echo ""

    # Install xrdp and XFCE session deps
    info "Installing xrdp..."
    sudo dnf install -y xrdp xfce4-session xfwm4 xfce4-panel xfdesktop > /dev/null 2>&1

    # Configure XFCE as the window manager for xrdp
    sudo tee /etc/xrdp/startwm.sh > /dev/null << 'XRDPEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
XRDPEOF
    sudo chmod +x /etc/xrdp/startwm.sh

    # Disable local display (conflicts with xrdp)
    sudo systemctl disable --now lightdm 2>/dev/null || true
    ok "Local display (lightdm) disabled — desktop is now remote-only."

    sudo systemctl enable --now xrdp
    ok "xrdp installed and running."

    # Open firewall port
    sudo firewall-cmd --permanent --add-port=3389/tcp 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    ok "Firewall port 3389 opened."

    IP=$(hostname -I | awk '{print $1}')
    local ts_ip
    ts_ip=$(_ts_ipv4); ts_ip=${ts_ip:-not connected}

    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}HOW TO CONNECT${NC}"
    echo ""
    echo -e "  ${BOLD}From your laptop (Fedora/Linux):${NC}"
    echo -e "    Install Remmina: ${BOLD}sudo dnf install remmina${NC}"
    echo -e "    Open Remmina → New → Protocol: RDP"
    echo -e "    Server: ${BOLD}$IP${NC} (local) or ${BOLD}$(hostname)${NC} (Tailscale)"
    echo -e "    Username: ${BOLD}$USER${NC}"
    echo -e "    Password: your server password"
    echo ""
    echo -e "  ${BOLD}From Mac:${NC}"
    echo -e "    Install 'Microsoft Remote Desktop' from App Store"
    echo -e "    Add PC → same server/username/password"
    echo ""
    echo -e "  ${BOLD}From iPhone/iPad:${NC}"
    echo -e "    Install 'RD Client' from App Store"
    echo -e "    Add PC → server: ${BOLD}$(hostname)${NC} (via Tailscale)"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

_wg_show_instructions() {
    local peer_name="$1" peer_conf="$2" device_type="$3" endpoint="$4"
    local WG_DIR="/etc/wireguard"

    case $device_type in
        1)  # Phone
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${YELLOW}SETUP: $peer_name (phone)${NC}"
            echo ""
            echo -e "  1. Install ${BOLD}WireGuard${NC} app:"
            echo -e "     iPhone: App Store → search 'WireGuard'"
            echo -e "     Android: Play Store → search 'WireGuard'"
            echo -e "  2. Open the app → tap ${BOLD}+${NC} → ${BOLD}Scan from QR code${NC}"
            echo -e "  3. Scan this QR code:"
            echo ""
            echo "$peer_conf" | qrencode -t UTF8
            echo ""
            echo -e "  4. Give it a name (e.g. '${peer_name}')"
            echo -e "  5. Toggle the switch to connect"
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            ;;
        2)  # Linux
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${YELLOW}SETUP: $peer_name (Linux)${NC}"
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo -e "  Copy this config:"
            echo ""
            echo "$peer_conf"
            echo ""
            read -p "  Press Enter when copied..." -r

            echo ""
            echo -e "  ${BOLD}Now on your laptop:${NC}"
            echo ""
            echo -e "  1. Get fedvpn (if you don't have it):"
            echo -e "     ${BOLD}scp $USER@${endpoint}:~/privcloud/fedvpn /tmp/fedvpn${NC}"
            echo -e "     ${BOLD}sudo cp /tmp/fedvpn /usr/local/bin/fedvpn && sudo chmod +x /usr/local/bin/fedvpn${NC}"
            echo ""
            echo -e "  2. Run ${BOLD}fedvpn${NC} → ${BOLD}1 (setup)${NC} → paste the config → ${BOLD}Ctrl+D${NC}"
            echo ""
            echo -e "  3. ${BOLD}fedvpn${NC} → ${BOLD}2${NC} to connect"
            echo ""
            echo -e "  ${DIM}To get this config later:${NC}"
            echo -e "  ${DIM}ssh -t $USER@${endpoint} \"sudo cat ${WG_DIR}/${peer_name}.conf\"${NC}"
            ;;
        3)  # Mac
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${YELLOW}SETUP: $peer_name (Mac)${NC}"
            echo ""
            echo -e "  1. Install WireGuard:"
            echo -e "     ${BOLD}brew install wireguard-tools${NC}  (Homebrew)"
            echo -e "     Or ${BOLD}Mac App Store${NC} → search 'WireGuard'"
            echo ""
            echo -e "  2. Save this config to a file (e.g. ~/Downloads/${peer_name}.conf):"
            echo -e "  ${DIM}───────────────────────────────────────${NC}"
            echo "$peer_conf"
            echo -e "  ${DIM}───────────────────────────────────────${NC}"
            echo ""
            echo -e "  3. CLI: ${BOLD}sudo wg-quick up ~/Downloads/${peer_name}.conf${NC}"
            echo -e "     GUI: WireGuard app → ${BOLD}Import Tunnel(s) from File${NC}"
            echo ""
            echo -e "  Disconnect: ${BOLD}sudo wg-quick down ${peer_name}${NC} or toggle off in app"
            echo ""
            echo -e "  Or scan QR with phone and AirDrop:"
            echo ""
            echo "$peer_conf" | qrencode -t UTF8
            echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            ;;
        *)
            echo "$peer_conf" | qrencode -t UTF8
            echo -e "  Config: ${BOLD}$WG_DIR/${peer_name}.conf${NC}"
            ;;
    esac
}

_wg_remove_peer() {
    local WG_DIR="/etc/wireguard"

    # List peers from wg0.conf (source of truth)
    local names
    names=$(sudo grep "^# " "$WG_DIR/wg0.conf" 2>/dev/null | sed 's/^# //')

    if [[ -z "$names" ]]; then
        fail "No peers to remove."
        return
    fi

    echo ""
    echo -e "  ${BOLD}Current peers:${NC}"
    local idx=1
    declare -a name_arr
    while IFS= read -r n; do
        echo -e "    ${BOLD}$idx)${NC} $n"
        name_arr[$idx]="$n"
        idx=$((idx + 1))
    done <<< "$names"
    echo ""
    read -p "  Which peer to remove? [number] " peer_choice

    local peer_name="${name_arr[$peer_choice]:-}"
    if [[ -z "$peer_name" ]]; then
        fail "Invalid choice."
        return
    fi

    echo ""
    read -p "  Remove peer '${peer_name}'? [y/N] " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled."; return; }

    # Remove the [Peer] block whose body contains "# <name>"
    # Paragraph-mode awk: RS="" treats blank-line-separated blocks as records.
    # index() is literal (not regex) so names with hyphens/dots are safe.
    local tmp
    tmp=$(mktemp)
    sudo awk -v name="$peer_name" '
        BEGIN { RS=""; ORS="\n\n" }
        /^\[Peer\]/ { if (index("\n" $0 "\n", "\n# " name "\n") > 0) next }
        { print }
    ' "$WG_DIR/wg0.conf" > "$tmp"
    sudo cp "$tmp" "$WG_DIR/wg0.conf"
    sudo chmod 600 "$WG_DIR/wg0.conf"
    rm -f "$tmp"

    # Delete the peer's client config if it exists
    if sudo test -f "$WG_DIR/${peer_name}.conf"; then
        sudo rm -f "$WG_DIR/${peer_name}.conf"
    fi

    # Hot-reload without dropping other peers' connections.
    # wg syncconf reads a stripped config (no PostUp/PostDown) and applies deltas live.
    if ! sudo bash -c "wg syncconf wg0 <(wg-quick strip wg0)" 2>/dev/null; then
        sudo systemctl restart wg-quick@wg0
    fi

    ok "Peer '${peer_name}' removed."
}

_wg_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE WireGuard${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} systemctl disable --now wg-quick@wg0"
    echo -e "    ${RED}•${NC} Close firewall port 51820/udp"
    echo -e "    ${RED}•${NC} dnf remove -y wireguard-tools qrencode"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} The full-tunnel VPN stops. All paired devices (phones,"
    echo -e "      laptop) lose remote-VPN access to the server"
    echo -e "    ${YELLOW}•${NC} Tailscale is a separate system and keeps working"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} /etc/wireguard/ — server + peer configs (so you can reinstall"
    echo -e "      without re-generating keys or re-scanning QR codes)"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete wireguard || return 0

    local bad=0
    info "Stopping wg0..."
    sudo systemctl disable --now wg-quick@wg0 > /dev/null 2>&1 || true
    info "Closing firewall port 51820/udp..."
    if ! { sudo firewall-cmd --permanent --remove-port=51820/udp > /dev/null 2>&1 \
        && sudo firewall-cmd --reload > /dev/null 2>&1; }; then
        fail "Firewall port 51820/udp was NOT closed."
        bad=1
    fi
    info "Removing packages..."
    sudo dnf remove -y wireguard-tools qrencode > /dev/null 2>&1 || true
    # Verify the end state, not that the commands ran.
    if rpm -q wireguard-tools > /dev/null 2>&1 || rpm -q qrencode > /dev/null 2>&1; then
        fail "wireguard-tools/qrencode still installed - dnf remove failed. Try: sudo dnf remove wireguard-tools qrencode"
        bad=1
    fi
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
        fail "wg-quick@wg0 is still active or enabled."
        bad=1
    fi
    if (( bad )); then
        fail "WireGuard removal did not finish - see above."
        return 1
    fi
    ok "WireGuard removed."
    echo -e "  ${DIM}Configs kept at /etc/wireguard. To wipe entirely:${NC} sudo rm -rf /etc/wireguard"
}

step_wireguard() {
    info "WireGuard routes ALL your traffic through this server."
    info "Unlike Tailscale (access server only), this is a full VPN."
    info "Use it for privacy, bypassing geo-restrictions, or securing public WiFi."
    echo ""

    WG_DIR="/etc/wireguard"
    local wg_port=51820
    local wg_subnet="10.100.0"
    local is_new_install=false

    # Check if already installed
    if sudo test -f "$WG_DIR/wg0.conf"; then
        ok "WireGuard is already installed."
        echo ""

        # Show existing peers
        echo -e "  ${BOLD}Current peers:${NC}"
        sudo grep "^# " "$WG_DIR/wg0.conf" 2>/dev/null | sed 's/^# /    /'
        echo ""

        # Count existing peers to determine next IP
        local existing_peers=$(sudo grep -c "^\[Peer\]" "$WG_DIR/wg0.conf" 2>/dev/null || echo "0")

        echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- interface state, peer handshakes, transfer${NC}"
        echo -e "  ${BOLD}2)${NC} Add new peer"
        echo -e "  ${BOLD}3)${NC} Show peer config (to set up a device)"
        echo -e "  ${BOLD}4)${NC} Remove peer"
        echo -e "  ${BOLD}5)${NC} Reinstall (regenerate all keys — existing peers stop working)"
        echo -e "  ${BOLD}6)${NC} ${RED}Uninstall${NC}                  ${DIM}<- remove wg-quick + package${NC}"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choose [1/2/3/4/5/6/0]: " wg_action

        case $wg_action in
            0) return 2 ;;
            1)
                echo ""
                if sudo wg show wg0 &>/dev/null; then
                    echo -e "  ${BOLD}Interface${NC}"
                    sudo wg show wg0 | sed 's/^/    /'
                else
                    fail "wg0 interface is down."
                    info "Bring it up: sudo systemctl start wg-quick@wg0"
                fi
                return
                ;;
            4) _wg_remove_peer; return ;;
            5) is_new_install=true ;;
            6) _wg_uninstall; return ;;
            3)
                # Show existing peer configs
                echo ""
                local conf_files=$(sudo find "$WG_DIR" -name "*.conf" ! -name "wg0.conf" 2>/dev/null)
                if [[ -z "$conf_files" ]]; then
                    fail "No peer configs found."
                    return
                fi
                echo -e "  ${BOLD}Available configs:${NC}"
                local idx=1
                declare -a conf_arr
                for f in $conf_files; do
                    local name=$(basename "$f" .conf)
                    echo -e "    ${BOLD}$idx)${NC} $name"
                    conf_arr[$idx]="$f"
                    idx=$((idx + 1))
                done
                echo ""
                read -p "  Which peer? " peer_choice
                local chosen="${conf_arr[$peer_choice]}"
                if [[ -n "$chosen" ]]; then
                    echo ""
                    echo -e "  ${BOLD}Config for $(basename "$chosen" .conf):${NC}"
                    echo ""
                    sudo cat "$chosen"
                    echo ""
                    echo -e "  ${DIM}On laptop: fedvpn → 1 (setup) → paste above → Ctrl+D${NC}"
                    echo -e "  ${DIM}On phone: WireGuard app → scan QR below${NC}"
                    echo ""
                    sudo cat "$chosen" | qrencode -t UTF8
                fi
                return
                ;;
            2)
                # Add peer mode
                local server_public=$(sudo cat "$WG_DIR/server_public.key")
                local server_ip=$(hostname -I | awk '{print $1}')
                local endpoint="${server_ip}"

                read -p "  How many new peers to add [1]: " peer_count
                peer_count="${peer_count:-1}"

                for i in $(seq 1 "$peer_count"); do
                    local peer_num=$((existing_peers + i))
                    local peer_ip="${wg_subnet}.$((peer_num + 1))"

                    echo ""
                    echo -e "  ${BOLD}── New peer $i ──${NC}"
                    read -p "  Name for this device: " peer_name
                    peer_name="${peer_name:-peer${peer_num}}"

                    echo ""
                    echo -e "  What type of device is '${BOLD}$peer_name${NC}'?"
                    echo -e "  ${BOLD}1)${NC} Phone (iPhone/Android)"
                    echo -e "  ${BOLD}2)${NC} Laptop/Desktop (Linux)"
                    echo -e "  ${BOLD}3)${NC} Laptop/Desktop (Mac)"
                    echo -e "  ${BOLD}4)${NC} Laptop/Desktop (Windows)"
                    read -p "  Device type [1-4]: " device_type

                    local peer_private=$(wg genkey)
                    local peer_public=$(echo "$peer_private" | wg pubkey)
                    local peer_psk=$(wg genpsk)

                    # Append to server config
                    sudo tee -a "$WG_DIR/wg0.conf" > /dev/null <<PEEREOF

[Peer]
# ${peer_name}
PublicKey = ${peer_public}
PresharedKey = ${peer_psk}
AllowedIPs = ${peer_ip}/32
PEEREOF

                    local peer_conf="[Interface]
PrivateKey = ${peer_private}
Address = ${peer_ip}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${server_public}
PresharedKey = ${peer_psk}
Endpoint = ${endpoint}:${wg_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"

                    echo "$peer_conf" | sudo tee "$WG_DIR/${peer_name}.conf" > /dev/null
                    sudo chmod 600 "$WG_DIR/${peer_name}.conf"

                    echo ""
                    ok "Peer '${peer_name}' added (IP: ${peer_ip})"

                    # Show device-specific instructions
                    _wg_show_instructions "$peer_name" "$peer_conf" "$device_type" "$endpoint"

                    if (( i < peer_count )); then
                        echo ""
                        read -p "  Press Enter for next peer..." -r
                    fi
                done

                # Hot-reload (keeps existing peers connected)
                if ! sudo bash -c "wg syncconf wg0 <(wg-quick strip wg0)" 2>/dev/null; then
                    sudo systemctl restart wg-quick@wg0
                fi
                ok "WireGuard reloaded with new peers."
                return
                ;;
            *) return ;;
        esac
    fi

    # ── Fresh install ──
    info "Installing WireGuard..."
    sudo dnf install -y wireguard-tools qrencode > /dev/null 2>&1
    ok "WireGuard installed."

    sudo mkdir -p "$WG_DIR"
    # Lock the directory to root before writing any keys, so there's no window
    # where a freshly tee'd private key is readable by other local users.
    sudo chmod 700 "$WG_DIR"

    info "Generating server keys..."
    wg genkey | sudo tee "$WG_DIR/server_private.key" > /dev/null
    sudo cat "$WG_DIR/server_private.key" | wg pubkey | sudo tee "$WG_DIR/server_public.key" > /dev/null
    sudo chmod 600 "$WG_DIR/server_private.key"
    ok "Server keys generated."

    local server_private=$(sudo cat "$WG_DIR/server_private.key")
    local server_public=$(sudo cat "$WG_DIR/server_public.key")

    # Get the main network interface
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)

    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ADD PEERS${NC}"
    echo ""
    echo -e "  How many devices do you want to connect?"
    echo -e "  (phone, laptop, partner's phone, etc.)"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  Number of peers [1]: " peer_count
    peer_count="${peer_count:-1}"

    # Detect main network interface
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    info "Network interface: $iface"

    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-wireguard.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null

    # Open firewall port permanently
    sudo firewall-cmd --permanent --add-port=${wg_port}/udp 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true

    # Build server config (PostUp/PostDown must be single lines)
    local post_up="iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE"
    local post_down="iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE"

    local server_conf="[Interface]
Address = ${wg_subnet}.1/24
ListenPort = ${wg_port}
PrivateKey = ${server_private}
PostUp = ${post_up}
PostDown = ${post_down}"

    local server_ip
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    # Use local IP as endpoint (Tailscale + WireGuard creates routing loops)
    # For remote WireGuard, set up port forwarding on your router (port 51820 → server)
    local endpoint="${server_ip}"
    info "Endpoint: ${endpoint}:${wg_port}"
    info "For remote access, forward port ${wg_port}/udp on your router to ${server_ip}"

    for i in $(seq 1 "$peer_count"); do
        echo ""
        echo -e "  ${BOLD}── Peer $i of $peer_count ──${NC}"
        echo ""
        read -p "  Name for this device (e.g. phone, laptop, wife-phone): " peer_name
        peer_name="${peer_name:-peer$i}"

        echo ""
        echo -e "  What type of device is '${BOLD}$peer_name${NC}'?"
        echo -e "  ${BOLD}1)${NC} Phone (iPhone/Android)"
        echo -e "  ${BOLD}2)${NC} Laptop/Desktop (Linux)"
        echo -e "  ${BOLD}3)${NC} Laptop/Desktop (Mac)"
        read -p "  Device type [1-3]: " device_type

        local peer_ip="${wg_subnet}.$((i + 1))"

        # Generate peer keys
        local peer_private=$(wg genkey)
        local peer_public=$(echo "$peer_private" | wg pubkey)
        local peer_psk=$(wg genpsk)

        # Add peer to server config
        server_conf="${server_conf}

[Peer]
# ${peer_name}
PublicKey = ${peer_public}
PresharedKey = ${peer_psk}
AllowedIPs = ${peer_ip}/32"

        # Create peer config
        local peer_conf="[Interface]
PrivateKey = ${peer_private}
Address = ${peer_ip}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${server_public}
PresharedKey = ${peer_psk}
Endpoint = ${endpoint}:${wg_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"

        # Save peer config
        echo "$peer_conf" | sudo tee "$WG_DIR/${peer_name}.conf" > /dev/null
        sudo chmod 600 "$WG_DIR/${peer_name}.conf"

        echo ""
        ok "Peer '${peer_name}' configured (IP: ${peer_ip})"
        echo -e "  Config saved: ${BOLD}$WG_DIR/${peer_name}.conf${NC}"
        echo ""

        _wg_show_instructions "$peer_name" "$peer_conf" "$device_type" "$endpoint"

        if (( i < peer_count )); then
            echo ""
            read -p "  Press Enter for next peer..." -r
        fi
    done

    # Write server config
    echo "$server_conf" | sudo tee "$WG_DIR/wg0.conf" > /dev/null
    sudo chmod 600 "$WG_DIR/wg0.conf"

    # Enable and start
    sudo systemctl enable --now wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0

    # Open firewall
    sudo firewall-cmd --permanent --add-port=${wg_port}/udp 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true

    echo ""
    ok "WireGuard running!"
    echo ""
    echo -e "  ${BOLD}Server:${NC}    ${wg_subnet}.1"
    echo -e "  ${BOLD}Port:${NC}      ${wg_port}/udp"
    echo -e "  ${BOLD}Endpoint:${NC}  ${endpoint}:${wg_port}"
    echo -e "  ${BOLD}Peers:${NC}     ${peer_count}"
    echo ""
    echo -e "  ${BOLD}Peer configs saved in:${NC} $WG_DIR/"
    echo -e "  ${BOLD}Check status:${NC} sudo wg show"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Phone:${NC}  WireGuard app → scan QR"
    echo -e "  ${BOLD}Linux:${NC}  ${BOLD}fedvpn${NC} → 1 (setup) → paste config → 2 (connect)"
    echo -e "  ${BOLD}Mac:${NC}    WireGuard app (brew or App Store) → import config"
}

step_immich() {
    if _is_server; then
        if command -v privcloud &>/dev/null; then
            privcloud
        else
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            "$SCRIPT_DIR/privcloud"
        fi
    else
        info "Opening Immich manager on the server via SSH..."
        ssh -t "$SERVER_USER@$SERVER_IP" "cd ~/privcloud && GIT_TERMINAL_PROMPT=0 git pull --ff-only -q 2>/dev/null; ./privcloud"
    fi
}

step_adguard() {
    info "AdGuard Home is a network-wide DNS ad & tracker blocker."
    info "Runs in Docker, blocks ads on every device that uses it as DNS."
    echo ""

    # Prereq: Docker
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed. Run step 5 first."
        return 1
    fi

    local IP TS_IP="" ts_rec="NotInstalled - - -"
    IP=$(hostname -I | awk '{print $1}')

    # ── Pre-check 1: Tailscale. AdGuard is only useful if something routes
    # traffic through it. Tailscale with "Override local DNS" is the only
    # rollout path we recommend (router DHCP-DNS and per-device manual DNS
    # both have too many footguns — see the install-level docs). If it's
    # missing, surface that BEFORE touching the system, not at the end.
    if command -v tailscale &>/dev/null; then
        ts_rec=$(_ts_state)
        _ts_running "$ts_rec" && TS_IP=$(_ts_ipv4)
    fi
    if [[ -z "$TS_IP" && "$DRY_RUN" != "1" ]]; then
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}Tailscale is not installed (or not connected).${NC}"
        [[ "${ts_rec%% *}" != NotInstalled ]] && echo -e "  Key: $(_ts_key "$ts_rec")"
        echo ""
        echo -e "  AdGuard needs a way to route devices' DNS lookups to it."
        echo -e "  The recommended path is ${BOLD}Tailscale global DNS${NC} — one setting,"
        echo -e "  every tailnet device uses AdGuard automatically (at home + roaming)."
        echo ""
        echo -e "  Without Tailscale you'd have to manually set DNS on every device,"
        echo -e "  which is fragile on Linux (IPv6 RA leaks) and iOS (Private Relay)."
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Cancel and install Tailscale first (step 8)   ${DIM}← recommended${NC}"
        echo -e "  ${BOLD}2)${NC} Continue anyway (I'll set DNS manually per device)"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choose [1/2/0]: " ts_choice
        case "$ts_choice" in
            2) info "Continuing without Tailscale — manual per-device DNS on you." ;;
            *) info "Cancelled. Run step 8 to install Tailscale, then come back."; return 0 ;;
        esac
        echo ""
    fi

    # ── Idempotent: container already exists (running or stopped)?
    # Open management submenu instead of re-running `docker run`, which
    # would collide with the existing container name.
    if [[ "$DRY_RUN" != "1" ]] && sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^adguard$'; then
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^adguard$'; then
            ok "AdGuard is already running."
        else
            warn "AdGuard container exists but is stopped. Starting it..."
            _svc_power start adguard && ok "Started." || { fail "Could not start AdGuard."; return 1; }
        fi
        echo -e "  Dashboard: ${BLUE}http://$IP${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Show Tailscale DNS guide"
        echo -e "  ${BOLD}2)${NC} Show upstream + fallback DNS guide"
        echo -e "  ${BOLD}3)${NC} Show blocklist + bypass guide"
        echo -e "  ${BOLD}4)${NC} Restart container"
        echo -e "  ${BOLD}5)${NC} Logs"
        echo -e "  ${BOLD}6)${NC} ${RED}Uninstall${NC}"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choose: " ag_choice
        case "$ag_choice" in
            1) [[ -n "$TS_IP" ]] && _adguard_tailscale_guide "$TS_IP" || warn "Tailscale not detected." ;;
            2) _adguard_dns_upstream_guide ;;
            3) _adguard_blocklist_guide ;;
            4) info "Restarting..."; _svc_power restart adguard && ok "Restarted." || fail "Restart failed." ;;
            5) sudo docker logs --tail 50 -f adguard || true ;;
            6) _adguard_uninstall ;;
            0|*) return ;;
        esac
        return 0
    fi

    # ── Pre-check 2: systemd-resolved stub listener. Fedora ships with
    # systemd-resolved binding 127.0.0.53:53 by default. AdGuard needs host
    # port 53, so we have to turn that off. This touches system DNS config,
    # so explain it and get an explicit OK before modifying anything.
    if [[ "$DRY_RUN" == "1" ]] || sudo ss -tulpn 2>/dev/null | grep -qE '127\.0\.0\.5[34].*:53'; then
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}systemd-resolved is holding port 53.${NC}"
        echo ""
        echo -e "  Standard on Fedora. AdGuard needs port 53, so we'll disable"
        echo -e "  systemd-resolved's stub listener. Concretely:"
        echo ""
        echo -e "    1. Create ${DIM}/etc/systemd/resolved.conf.d/disable-stub.conf${NC}"
        echo -e "       with ${BOLD}DNSStubListener=no${NC}"
        echo -e "    2. Point ${DIM}/etc/resolv.conf${NC} at ${DIM}/run/systemd/resolve/resolv.conf${NC}"
        echo -e "    3. Restart ${DIM}systemd-resolved${NC}"
        echo ""
        echo -e "  Local name resolution keeps working — systemd-resolved still runs,"
        echo -e "  just not on port 53. If you have a custom DNS setup on this host,"
        echo -e "  cancel here and review ${DIM}/etc/systemd/resolved.conf${NC} first."
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        read -p "  Disable the stub listener and continue? [Y/n] " -n 1 -r
        echo ""
        if [[ "$REPLY" =~ ^[Nn]$ ]]; then
            info "Cancelled. No changes made."
            return 0
        fi

        info "Disabling systemd-resolved stub listener..."
        sudo mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf > /dev/null
        sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        sudo systemctl restart systemd-resolved
        sleep 1
        if [[ "$DRY_RUN" != "1" ]] && sudo ss -tulpn 2>/dev/null | grep -qE '(^|\s)[^:]*:53\s'; then
            fail "Port 53 still occupied after disabling the stub listener:"
            sudo ss -tulpn | grep ':53 ' || true
            return 1
        fi
        ok "Port 53 freed."
        echo ""
    fi

    # ── Open firewall ports: 53 for DNS, 80 for the admin UI. No port 3000:
    # by pre-seeding a minimal config that points the HTTP listener at :80,
    # AdGuard runs its own first-run wizard on :80 directly — no hardcoded
    # port-3000 detour, no credentials collected here.
    info "Opening firewall ports (53 DNS, 80 admin UI)..."
    sudo firewall-cmd --permanent --add-port=53/udp > /dev/null
    sudo firewall-cmd --permanent --add-port=53/tcp > /dev/null
    sudo firewall-cmd --permanent --add-port=80/tcp > /dev/null
    sudo firewall-cmd --reload > /dev/null
    ok "Firewall: 53/udp, 53/tcp, 80/tcp open."

    # ── Pre-seed a minimal config: just move the HTTP listener off the
    # default 3000 and onto 80. AdGuard sees no `users:` block and still
    # runs its normal first-run setup wizard — it just runs on the port we
    # told it to. User creates their own admin account in the browser.
    sudo mkdir -p /opt/adguard/work /opt/adguard/conf
    sudo tee /opt/adguard/conf/AdGuardHome.yaml > /dev/null <<'ADGUARDEOF'
http:
  address: 0.0.0.0:80
schema_version: 20
ADGUARDEOF

    # ── Launch container
    info "Starting AdGuard Home container..."
    sudo docker run -d \
        --name adguard \
        --network=host \
        --restart=unless-stopped \
        -v /opt/adguard/work:/opt/adguardhome/work \
        -v /opt/adguard/conf:/opt/adguardhome/conf \
        adguard/adguardhome:latest > /dev/null
    sleep 2
    if [[ "$DRY_RUN" != "1" ]] && ! sudo docker ps --format '{{.Names}}' | grep -q '^adguard$'; then
        fail "AdGuard container failed to start."
        sudo docker logs --tail 20 adguard 2>&1 || true
        return 1
    fi
    ok "AdGuard running."

    # ── Point the user at AdGuard's own wizard on port 80
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ACTION NEEDED: Finish AdGuard's setup wizard${NC}"
    echo ""
    echo -e "  1. Open ${BLUE}http://$IP${NC} in your laptop browser"
    echo -e "  2. Leave ${BOLD}Admin Web Interface${NC} and ${BOLD}DNS Server${NC} at their defaults → Next"
    echo -e "  3. Create your ${BOLD}admin username + password${NC} ${RED}(save them)${NC}"
    echo -e "  4. Finish the wizard"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "  Press Enter once the wizard is done..." -r

    # ── Tailscale DNS guidance (only if Tailscale is present)
    echo ""
    if [[ -n "$TS_IP" ]]; then
        _adguard_tailscale_guide "$TS_IP"
        echo ""
        _adguard_dns_upstream_guide
        echo ""
        _adguard_blocklist_guide
    else
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}AdGuard is running, but no devices are pointed at it yet.${NC}"
        echo ""
        echo -e "  ${BOLD}Quick test (one phone, 30 seconds):${NC}"
        echo -e "    iPhone: Settings → Wi-Fi → ${BOLD}(i)${NC} next to your SSID →"
        echo -e "            Configure DNS → ${BOLD}Manual${NC} → add ${BOLD}$IP${NC} → Save"
        echo -e "    Android: Wi-Fi → long-press your SSID → Modify network →"
        echo -e "             Advanced → IP settings ${BOLD}Static${NC} → DNS 1 = ${BOLD}$IP${NC}"
        echo -e "    Then browse for a minute and open ${BLUE}http://$IP${NC} →"
        echo -e "    ${BOLD}Query Log${NC} tab — you should see entries streaming in."
        echo ""
        echo -e "  ${BOLD}Real rollout (all devices, at home + roaming):${NC}"
        echo -e "    1. Run ${BOLD}federver → 8${NC} to install Tailscale"
        echo -e "    2. Re-run ${BOLD}federver → 10${NC} — this time it'll detect Tailscale"
        echo -e "       and print the admin-console steps to route every tailnet device"
        echo -e "       through AdGuard in one shot."
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi

    echo ""
    ok "AdGuard Home installed."
    echo -e "  Dashboard: ${BLUE}http://$IP${NC}"
    echo -e "  Query log: dashboard → ${BOLD}Query Log${NC} tab (red = blocked)"
}

# Ask the user to literally type the service name to confirm a destructive
# action. Blank input or a mismatch cancels. Returns 0 on match, 1 otherwise.
# Uses printf for the prompt because `read -p` doesn't interpret the color
# escape sequences, which would show up as literal \033[1m text.
_confirm_delete() {
    local name="$1"
    local reply
    printf "  Type \"${BOLD}${RED}${name}${NC}\" to confirm deletion (blank = cancel): "
    read -r reply
    if [[ -z "$reply" ]]; then
        info "Cancelled. Nothing deleted."
        return 1
    fi
    if [[ "$reply" != "$name" ]]; then
        fail "Input '${reply}' did not match '${name}'. Cancelled. Nothing deleted."
        return 1
    fi
    return 0
}

_adguard_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE AdGuard Home${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} Stop + remove the adguard container"
    echo -e "    ${RED}•${NC} Close firewall ports 53/udp, 53/tcp, 80/tcp"
    echo -e "    ${RED}•${NC} Re-enable systemd-resolved's stub listener on port 53"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} DNS ad/tracker blocking stops on every device that uses this"
    echo -e "      server as DNS — they'll resolve ad domains again"
    echo -e "    ${YELLOW}•${NC} If Tailscale is pointing global DNS at this server, those"
    echo -e "      queries will fail until you change Tailscale DNS in the admin console"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} /opt/adguard/ — config, filter lists, query log history"
    echo -e "    ${GREEN}•${NC} Core privcloud services (Immich, Navidrome, etc.) untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete adguard || return 0

    local bad=0
    info "Removing adguard container..."
    sudo docker rm -f adguard > /dev/null 2>&1 || true
    if ! _container_gone adguard; then
        fail "Container 'adguard' is still present (or docker could not be queried) - not removed."
        return 1
    fi

    info "Closing firewall ports 53/udp, 53/tcp, 80/tcp..."
    if ! { sudo firewall-cmd --permanent --remove-port=53/udp > /dev/null 2>&1 \
        && sudo firewall-cmd --permanent --remove-port=53/tcp > /dev/null 2>&1 \
        && sudo firewall-cmd --permanent --remove-port=80/tcp > /dev/null 2>&1 \
        && sudo firewall-cmd --reload > /dev/null 2>&1; }; then
        fail "Firewall ports 53/udp, 53/tcp, 80/tcp were NOT closed."
        bad=1
    fi

    info "Re-enabling systemd-resolved stub listener..."
    if ! { sudo rm -f /etc/systemd/resolved.conf.d/disable-stub.conf \
        && sudo systemctl restart systemd-resolved > /dev/null 2>&1; }; then
        fail "Could not restore systemd-resolved's stub listener."
        bad=1
    fi

    if (( bad )); then
        fail "AdGuard container removed, but cleanup above did not finish."
        return 1
    fi
    ok "AdGuard removed."
    echo -e "  ${DIM}Config kept at /opt/adguard. To wipe entirely:${NC} sudo rm -rf /opt/adguard"
}

# Shared between fresh-install and "already running" paths so the message
# stays consistent.
_adguard_tailscale_guide() {
    local ts_ip="$1"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ACTION NEEDED: Point Tailscale DNS at AdGuard${NC}"
    echo ""
    echo -e "  Every tailnet device (phones, laptops) will then use AdGuard"
    echo -e "  automatically — at home and on the go, no per-device config."
    echo ""
    echo -e "  1. Open ${BLUE}https://login.tailscale.com/admin/dns${NC}"
    echo -e "  2. Under the ${BOLD}DNS${NC} tab → ${BOLD}Nameservers${NC} → ${BOLD}Global nameservers${NC}"
    echo -e "     → ${BOLD}Add nameserver${NC} → ${BOLD}Custom${NC}"
    echo -e "  3. IP: ${BOLD}$ts_ip${NC}"
    echo -e "  4. Save"
    echo -e "  5. Toggle ${BOLD}Override local DNS${NC} ON"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Prints the recommended AdGuard upstream + fallback DNS config. Displayed
# after install (post Tailscale guide) and available from the manage menu.
# Point: resilience. If AdGuard's primary upstream flakes, the fallback
# catches it — your traffic keeps resolving instead of dying on DNS.
_adguard_dns_upstream_guide() {
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}RECOMMENDED: AdGuard upstream + fallback DNS${NC}"
    echo ""
    echo -e "  Make sure if AdGuard's primary upstream fails, traffic still"
    echo -e "  resolves through a fallback. Open ${BLUE}http://federver${NC} →"
    echo -e "  ${BOLD}Settings → DNS settings${NC}, and paste these:"
    echo ""
    echo -e "  ${BOLD}Field                Value${NC}"
    echo -e "  ────────────────     ────────────────────────────────────────"
    echo -e "  Upstream DNS         ${BOLD}9.9.9.9${NC}  ${BOLD}149.112.112.112${NC}"
    echo -e "  Fallback DNS         ${BOLD}1.1.1.1${NC}  ${BOLD}8.8.8.8${NC}"
    echo -e "  Load balancing       ${BOLD}Parallel requests${NC}"
    echo ""
    echo -e "  Click ${BOLD}Apply${NC} at the bottom. Plain DNS to Quad9 (malware"
    echo -e "  filter), Cloudflare + Google as fallback — no single failure cuts"
    echo -e "  DNS. ${BOLD}Not DoH:${NC} AdGuard's DoH client hit unexpected-EOF"
    echo -e "  failures against Quad9's DoH endpoint (silent dropped queries,"
    echo -e "  half-loaded pages) — plain DNS has no persistent connection to"
    echo -e "  go stale, so that failure mode doesn't exist."
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Prints the blocklist + extra ad-network setup for AdGuard. Displayed after
# install (post upstream guide) and available from the manage menu.
# Point: apps that use their own encrypted DNS (DoH/DoT) skip AdGuard; block
# those resolver names and they fall back to it.
_adguard_blocklist_guide() {
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}RECOMMENDED: Block DNS bypass + extra ad networks${NC}"
    echo ""
    echo -e "  Some apps skip AdGuard by using their own encrypted DNS"
    echo -e "  (DoH/DoT). Blocking those resolvers' names makes them fall"
    echo -e "  back to AdGuard. Apps that hardcode a resolver IP (1.1.1.1,"
    echo -e "  8.8.8.8) can't be stopped by DNS — only by routing traffic"
    echo -e "  through an exit node; not covered here."
    echo ""
    echo -e "  ${BOLD}Step 1: bypass blocklist${NC}"
    echo -e "  Open ${BLUE}http://federver${NC} → ${BOLD}Filters → DNS blocklists${NC} →"
    echo -e "  ${BOLD}Add blocklist → Add a custom list${NC}:"
    echo -e "    Name   ${BOLD}Encrypted DNS bypass${NC}"
    echo -e "    URL    ${BOLD}https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh.txt${NC}"
    echo -e "  Save, keep it enabled."
    echo ""
    echo -e "  ${BOLD}Step 2: extra rules${NC}"
    echo -e "  ${BOLD}Filters → Custom filtering rules${NC}, paste, ${BOLD}Apply${NC}:"
    echo -e "    ${BOLD}@@||tailscale.com^${NC}"
    echo -e "    ${BOLD}@@||tailscale.io^${NC}"
    echo -e "    ${BOLD}||locsensads.com^${NC}"
    echo -e "    ${BOLD}||readpeak.com^${NC}"
    echo -e "    ${BOLD}||pubmatic.com^${NC}"
    echo -e "    ${BOLD}||openx.net^${NC}"
    echo -e "    ${BOLD}||smartadserver.com^${NC}"
    echo -e "    ${BOLD}||applovin.com^${NC}"
    echo -e "    ${BOLD}||unityads.unity3d.com^${NC}"
    echo -e "    ${BOLD}||vungle.com^${NC}"
    echo -e "    ${BOLD}||inmobi.com^${NC}"
    echo -e "  ${DIM}The two @@ lines keep Tailscale reachable whatever a list"
    echo -e "  blocks. AppsFlyer/Google ad domains are left out on purpose:"
    echo -e "  they can break app links and logins.${NC}"
    echo ""
    echo -e "  ${BOLD}Step 3: check${NC}"
    echo -e "  ${BOLD}Query log${NC} → filter ${BOLD}Blocked${NC} → look for entries whose rule"
    echo -e "  is from ${BOLD}Encrypted DNS bypass${NC}. A quiet list is normal: most"
    echo -e "  bypass happens by IP, so dns.* names may never show."
    echo -e "  Blocking ${BOLD}mask.icloud.com${NC} turns off iCloud Private Relay on"
    echo -e "  this network (the iPhone says so) — intended, otherwise"
    echo -e "  Safari's DNS skips AdGuard."
    echo ""
    echo -e "  ${BOLD}Phone tip:${NC} iPhone Mail → Settings → Apps → Mail → Privacy"
    echo -e "  Protection → ${BOLD}Protect Mail Activity${NC} ON (hides opens and your"
    echo -e "  IP from email trackers)."
    echo ""
    echo -e "  ${DIM}AdGuard's own upstream is plain IPs, not DoH names, so it is"
    echo -e "  unaffected by this blocklist.${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Suggest the best external-drive destination for backups: the really mounted
# (per _drive_verdict: not an autofs stub) media drive with the most free space that is NOT on the same filesystem as $1 (the
# source). Echoes "<mountpoint>/privcloud-backup", or nothing if none found.
_pick_backup_default() {
    local src="$1" src_fs best="" best_avail=0 mp avail fs
    src_fs=$(df -P "$src" 2>/dev/null | awk 'NR==2{print $1}')
    for mp in /run/media/*/* /media/*/* /mnt/*; do
        [ -d "$mp" ] || continue
        case $(_drive_verdict "$mp") in ok|empty) ;; *) continue ;; esac   # a real /dev mount, not an autofs stub
        fs=$(df -P "$mp" 2>/dev/null | awk 'NR==2{print $1}')
        [ -n "$fs" ] && [ "$fs" != "$src_fs" ] || continue
        avail=$(df -P "$mp" 2>/dev/null | awk 'NR==2{print $4}')
        if [ "${avail:-0}" -gt "$best_avail" ]; then best_avail=$avail; best="$mp"; fi
    done
    [ -n "$best" ] && echo "$best/privcloud-backup"
    # Always succeed: a "no external drive" result is empty output, not a
    # failure. Under `set -e` a non-zero return here would abort the caller's
    # `default_dir=$(_pick_backup_default …)` before the fallback runs.
    return 0
}

# Echo BACKUP_DIR from the installed backup script, or nothing if not set up.
_configured_backup_dir() {
    sed -n 's/^BACKUP_DIR="\(.*\)"$/\1/p' /usr/local/bin/immich-backup.sh 2>/dev/null | head -1 | grep -v '^__BACKUP_DIR__$' || true
}

step_immich_backup() {
    info "Schedules an automatic Immich backup (systemd timer, no downtime)."
    info "Each run: a Postgres dump (albums, faces, metadata — hard to recreate)"
    info "plus a live rsync of your photo originals. pg_dumpall and rsync are"
    info "both safe while Immich runs, so the stack is never stopped."
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local DB_DATA_LOCATION UPLOAD_LOCATION default_dir src_dir
    DB_DATA_LOCATION=$(_env_get DB_DATA_LOCATION "$SCRIPT_DIR/.env")
    UPLOAD_LOCATION=$(_env_get UPLOAD_LOCATION "$SCRIPT_DIR/.env")
    src_dir="${UPLOAD_LOCATION:-$DB_DATA_LOCATION}"

    # Prefer an external/removable drive so the backup survives the source disk
    # dying. Pick the mounted media drive with the most free space; fall back to
    # the legacy in-tree backups dir (same drive — warned about below).
    # An existing schedule's destination always wins: Enter must keep it, never
    # repoint the job at a fresh (empty) folder.
    default_dir=$(_configured_backup_dir)
    [ -n "$default_dir" ] || default_dir=$(_pick_backup_default "$src_dir")
    default_dir=${default_dir:-$(realpath -m "${DB_DATA_LOCATION:-/home/$USER/data/immich/postgres}/../backups")}

    read -p "  Backup destination [${default_dir}, q=back]: " BACKUP_DIR
    [[ "$BACKUP_DIR" == "q" ]] && return 2
    BACKUP_DIR="${BACKUP_DIR:-$default_dir}"
    BACKUP_DIR=$(realpath -m "$BACKUP_DIR")
    sudo mkdir -p "$BACKUP_DIR"

    # A backup on the same disk as the photos dies with that disk. Warn loudly.
    if [ -n "$src_dir" ] && [ -e "$src_dir" ]; then
        local src_fs dst_fs
        src_fs=$(df -P "$src_dir" 2>/dev/null | awk 'NR==2{print $1}')
        dst_fs=$(df -P "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $1}')
        if [ -n "$src_fs" ] && [ "$src_fs" == "$dst_fs" ]; then
            warn "Destination is on the SAME drive as your photos ($src_fs)."
            warn "A disk failure would lose the originals AND the backup."
            warn "An external/USB drive is strongly advised."
            local ok_same; read -p "  Continue anyway? [y/N]: " ok_same
            [[ "$ok_same" =~ ^[Yy]$ ]] || return 2
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Cadence:${NC}"
    echo -e "    ${BOLD}1)${NC} Daily at 3am          ${DIM}← keeps last 7 days${NC}"
    echo -e "    ${BOLD}2)${NC} Weekly                ${DIM}← keeps last 3 weeks${NC}"
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    local cadence oncal retention_days
    read -p "  Choice [0-2]: " cadence
    case $cadence in
        0|"") return 2 ;;
        1) oncal="*-*-* 03:00:00"; retention_days=7 ;;
        2)
            echo ""
            echo -e "  ${BOLD}Which day?${NC}"
            echo -e "    ${BOLD}1)${NC} Sunday  ${BOLD}2)${NC} Monday  ${BOLD}3)${NC} Saturday"
            echo -e "    ${BOLD}0)${NC} Back"
            echo ""
            local day; read -p "  Choice [0-3]: " day
            case $day in
                0|"") return 2 ;;
                1) oncal="Sun *-*-* 03:00:00" ;;
                2) oncal="Mon *-*-* 03:00:00" ;;
                3) oncal="Sat *-*-* 03:00:00" ;;
                *) fail "Invalid choice."; return 1 ;;
            esac
            retention_days=21   # 3 weeks of weekly dumps
            ;;
        *) fail "Invalid choice."; return 1 ;;
    esac

    # Tear down the legacy step-8 cron line if it exists, so we don't double-run.
    local cur new
    cur=$(_cron_get root) || { fail "Could not read root's crontab - legacy cron entry not touched."; return 1; }
    if grep -q immich-backup <<<"$cur"; then
        info "Removing legacy cron entry (replaced by systemd timer)..."
        new=$(_cron_drop "$cur" "" immich-backup)
        _cron_set root "$new" || { fail "Could not update root's crontab - legacy cron entry may still be active."; return 1; }
    fi

    # Install/refresh the script. Logs go to /var/log/immich-backup.log so the
    # Last-runs table parser keeps working unchanged.
    sudo tee /usr/local/bin/immich-backup.sh > /dev/null <<'BACKUPEOF'
#!/bin/bash
# Full Immich backup: database (online pg_dump) + photo originals (live rsync).
# Neither step stops the stack — pg_dumpall is transactionally consistent and
# UPLOAD_LOCATION holds write-once originals, so both are safe while Immich runs.
# Managed by setup.sh (federver → Immich backup) and privcloud → backup → scheduled.
BACKUP_DIR="__BACKUP_DIR__"
UPLOAD_LOCATION="__UPLOAD_LOCATION__"
RETENTION_DAYS=__RETENTION__
LOG="/var/log/immich-backup.log"
exec >>"$LOG" 2>&1

TIMESTAMP=$(date +%Y%m%d-%H%M)
# Everything lives under BACKUP_DIR/immich so the destination can hold other
# backups too: db dumps in immich/db, photo mirror in immich/photos.
DB_DIR="$BACKUP_DIR/immich/db"
PHOTOS_DIR="$BACKUP_DIR/immich/photos"
mkdir -p "$DB_DIR" "$PHOTOS_DIR"
rc=0

# 1) Database — logical dump, online-consistent, no downtime. Dumps stay in
# immich/db as immich-db-*.sql.gz and rotate by retention.
if docker exec immich_postgres pg_dumpall -U postgres | gzip > "$DB_DIR/immich-db-$TIMESTAMP.sql.gz"; then
    find "$DB_DIR" -name "immich-db-*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
    echo "$(date): DB dump ok → immich/db/immich-db-$TIMESTAMP.sql.gz"
else
    rc=$?
    rm -f "$DB_DIR/immich-db-$TIMESTAMP.sql.gz"
    echo "$(date): DB dump FAILED (exit $rc)"
fi

# 2) Photos — live rsync of originals into immich/photos. Append only (never
# --delete): an unattended job must not propagate an accidental deletion.
# Excludes (anchored to the data root so they can't match a same-named photo
# subfolder): skip Immich's own DB dumps in backups/ (we already dump the DB
# ourselves into immich/db/ — no point mirroring a second copy) and the
# regenerable caches thumbs/ and encoded-video/ (Immich rebuilds these after a
# restore). This keeps the backup to the irreplaceable originals + metadata.
if [ -n "$UPLOAD_LOCATION" ] && [ -d "$UPLOAD_LOCATION" ]; then
    if command -v rsync >/dev/null 2>&1; then
        if rsync -a \
            --exclude='/backups/' \
            --exclude='/thumbs/' \
            --exclude='/encoded-video/' \
            "$UPLOAD_LOCATION/" "$PHOTOS_DIR/"; then
            echo "$(date): Photos synced → $PHOTOS_DIR/"
        else
            rc=$?
            echo "$(date): Photos rsync FAILED (exit $rc)"
        fi
    else
        echo "$(date): rsync not found — photos skipped"; rc=1
    fi
else
    echo "$(date): UPLOAD_LOCATION missing ($UPLOAD_LOCATION) — photos skipped"; rc=1
fi

# Final line is parsed by the status screen — keep the exact "Backup complete" phrase.
if [ "$rc" -eq 0 ]; then
    echo "$(date): Backup complete → $BACKUP_DIR"
    exit 0
else
    echo "$(date): Backup FAILED (exit $rc) — systemd will retry"
    exit "$rc"
fi
BACKUPEOF
    sudo sed -i "s|__BACKUP_DIR__|$BACKUP_DIR|g; s|__UPLOAD_LOCATION__|$UPLOAD_LOCATION|g; s|__RETENTION__|$retention_days|g" /usr/local/bin/immich-backup.sh
    sudo chmod +x /usr/local/bin/immich-backup.sh

    # systemd unit: Type=oneshot with Restart=on-failure gives us 3 retries
    # ~30 min apart. Persistent=true on the timer catches up missed runs after
    # a server-off window — the key gain over cron.
    sudo tee /etc/systemd/system/immich-backup.service > /dev/null <<'UNITEOF'
[Unit]
Description=Immich Postgres backup
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/immich-backup.sh
Restart=on-failure
RestartSec=30min
StartLimitBurst=3
StartLimitIntervalSec=3h
UNITEOF

    sudo tee /etc/systemd/system/immich-backup.timer > /dev/null <<TIMEREOF
[Unit]
Description=Immich Postgres backup schedule

[Timer]
OnCalendar=${oncal}
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
TIMEREOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now immich-backup.timer >/dev/null

    echo ""
    ok "Immich backup configured (systemd timer):"
    echo -e "    Schedule:    ${BOLD}${oncal}${NC}"
    echo -e "    Destination: ${BOLD}$BACKUP_DIR${NC}"
    echo -e "    Includes:    ${BOLD}database + photos${NC} ${DIM}(no downtime)${NC}"
    echo -e "      • DB dumps → ${DIM}$BACKUP_DIR/immich/db/immich-db-*.sql.gz${NC}"
    echo -e "      • Photos   → ${DIM}$BACKUP_DIR/immich/photos/${NC} ${DIM}(rsync, append-only)${NC}"
    echo -e "    Retention:   ${BOLD}${retention_days} days${NC} ${DIM}(DB dumps; photos kept as a live mirror)${NC}"
    echo -e "    Persistent:  ${BOLD}yes${NC} ${DIM}(catches up missed runs)${NC}"
    echo -e "    On failure:  ${BOLD}3 retries 30min apart${NC}"
    echo ""
    # The timer only fires at the next scheduled tick (Persistent=true just
    # catches up a tick missed while the box was off — it never triggers an
    # initial run). So offer to run once now: confirms it works and seeds the
    # first backup instead of waiting up to a week.
    local run_now; read -p "  Run the first backup now to verify it works? [Y/n]: " run_now
    if [[ ! "$run_now" =~ ^[Nn] ]]; then
        _immich_backup_run || true   # a start failure must not skip the hints below
    fi

    echo ""
    info "Manage it anytime:  privcloud → 9  (Scheduled - Status / Run now / Remove)"
    info "View log:           tail /var/log/immich-backup.log"
}

# Start the scheduled backup now, detached under systemd so it keeps running
# even if the SSH session closes. Shows a few log lines for confidence.
_immich_backup_run() {
    if [ ! -x /usr/local/bin/immich-backup.sh ]; then
        warn "No scheduled Immich backup is configured yet."
        info "Set one up first: privcloud → 9 → 2  (or federver → 14 → 6)."
        return 0
    fi
    if ! sudo -v; then
        fail "Need sudo to start the backup — nothing was started."
        return 1
    fi
    info "Starting backup (runs under systemd — continues even if you disconnect)..."
    sudo systemctl start --no-block immich-backup.service || { fail "Could not start the backup service."; return 1; }
    sleep 3
    echo ""
    info "Recent log (it keeps running in the background):"
    if [ -s /var/log/immich-backup.log ]; then
        tail -n 6 /var/log/immich-backup.log 2>/dev/null | sed 's/^/    /'
    else
        echo "    (starting…)"
    fi
    echo ""
    info "Watch live:  tail -f /var/log/immich-backup.log"
}

# Immich-backup-only status (Option C): report just THIS backup's schedule and
# recent runs, then point to federver → 14 → 1 for the full server job list —
# no dumping of unrelated cron jobs here. The backup can be scheduled two ways,
# detected by BEHAVIOUR (what the job runs) not by a fixed name:
#   • systemd timer  immich-backup.timer   (federver-managed, the modern path)
#   • a root cron line that runs the backup script / writes its log
# A third reality is handled honestly: the log shows past runs but nothing
# schedules it now (removed → backups OFF), and the case where we simply could
# not read root cron without a password (never claim "off" on missing data).
_immich_backup_status() {
    local mechanism="" oncal="" next="" enabled="" cron_checked=0 cron_matches=""

    if [ "$(systemctl show immich-backup.timer -p LoadState --value 2>/dev/null)" = "loaded" ]; then
        mechanism="timer"
        # OnCalendar is NOT a queryable `systemctl show` property (reads empty →
        # "?"). `systemctl cat` prints the unit wherever it lives, plus drop-ins.
        oncal=$(systemctl cat immich-backup.timer 2>/dev/null | sed -n 's/^OnCalendar=//p' | head -1)
        next=$(systemctl list-timers immich-backup.timer --no-pager 2>/dev/null | awk '/immich-backup/{print $1,$2,$3,$4; exit}')
        enabled=$(systemctl is-enabled immich-backup.timer 2>/dev/null)
    else
        # No timer — look for root cron line(s) that run the Immich backup,
        # matched by what they DO (script / db dump / log) so a generically
        # named line still registers. ALL matches are kept (there may be more
        # than one). sudo -n: never prompt, skip if locked.
        local cronall
        if cronall=$(sudo -n crontab -l 2>/dev/null); then
            cron_checked=1
            cron_matches=$(printf '%s\n' "$cronall" | grep -vE '^[[:space:]]*#' \
                | grep -E 'immich-backup\.sh|immich-db|immich-backup\.log')
        fi
        [ -n "$cron_matches" ] && mechanism="cron"
    fi

    # When did a backup last actually run, per the log? Drives the "last run"
    # line for cron and the "was running, now OFF" warning.
    local last_log_run=""
    if [ -s /var/log/immich-backup.log ]; then
        last_log_run=$(grep -E 'Backup (complete|FAILED)' /var/log/immich-backup.log 2>/dev/null | tail -1 | sed 's/: Backup.*//')
    fi

    # Same table styling as federver → 14 → 1 (_sync_show_status): one BLUE rule,
    # a BOLD header, and the identical %-20s %-18s %-16s %-10s %s column widths —
    # so this Immich-only view reads as the same "clean status" the fleet view does.
    local RULE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    echo -e "  ${BOLD}Scheduled tasks${NC}"
    echo -e "  ${BLUE}${RULE}${NC}"
    printf "  ${BOLD}%-20s %-18s %-16s %-10s %s${NC}\n" "Name" "Schedule" "When" "Type" "Note"
    echo -e "  ${BLUE}${RULE}${NC}"

    if [ "$mechanism" = "timer" ]; then
        # Next-run + enabled state ride in the Note column (the fleet table has no
        # dedicated columns for them) so the detail isn't lost to the table format.
        local note="next: ${next:-unknown}"
        [ "$enabled" = "enabled" ] || note="DISABLED — ${note}"
        printf "  %-20s %-18s %-16s %-10s %s\n" "immich-backup" "${oncal:-unknown}" "systemd" "backup" "$note"
    elif [ "$mechanism" = "cron" ]; then
        # One row per matching cron line; human schedule in When, raw spec in Schedule.
        printf '%s\n' "$cron_matches" | while IFS= read -r l; do
            [ -z "$l" ] && continue
            local spec when
            spec=$(echo "$l" | awk '{print $1,$2,$3,$4,$5}')
            when=$(_cron_to_english "$spec" 2>/dev/null || echo "$spec")
            printf "  %-20s %-18s %-16s %-10s %s\n" "immich-backup" "$spec" "$when" "backup" "(legacy cron)"
        done
    elif [ "$cron_checked" -eq 1 ]; then
        # No timer, root cron readable, no Immich line → genuinely off.
        if [ -n "$last_log_run" ]; then
            printf "  %-20s %-18s %-16s %-10s ${YELLOW}%s${NC}\n" "immich-backup" "—" "OFF" "backup" "removed — log shows past runs"
        else
            printf "  %-20s %-18s %-16s %-10s ${YELLOW}%s${NC}\n" "immich-backup" "—" "none" "backup" "not configured"
        fi
    else
        # Couldn't read root cron without a password — never assert "off" on data
        # we couldn't see.
        printf "  %-20s %-18s %-16s %-10s ${DIM}%s${NC}\n" "immich-backup" "?" "?" "backup" "root cron unreadable (needs sudo)"
    fi

    # Last runs — same table as the fleet view, but one row PER run (newest last,
    # up to 8) so the Immich detail view keeps its history instead of a single row.
    echo ""
    echo -e "  ${BOLD}Last runs${NC}"
    echo -e "  ${BLUE}${RULE}${NC}"
    printf "  ${BOLD}%-20s %-20s %s${NC}\n" "Name" "Last run" "Status"
    echo -e "  ${BLUE}${RULE}${NC}"
    if [ -s /var/log/immich-backup.log ] && grep -qE 'Backup (complete|FAILED)' /var/log/immich-backup.log 2>/dev/null; then
        grep -E 'Backup (complete|FAILED)' /var/log/immich-backup.log | tail -n 8 | while IFS= read -r line; do
            local when=${line%%: Backup*} status
            if [[ "$line" == *"Backup complete"* ]]; then
                status="${GREEN}✓ ok${NC}"
            else
                status="${RED}✗ failed${NC}"
            fi
            printf "  %-20s %-20s " "immich-backup" "$when"
            echo -e "$status"
        done
    else
        printf "  %-20s %-20s ${DIM}%s${NC}\n" "immich-backup" "never" "—"
    fi

    # For the "off"/"unreadable" states, keep the actionable guidance the table
    # rows can't carry — but below the tables so the clean layout stays intact.
    if [ "$mechanism" != "timer" ] && [ "$mechanism" != "cron" ]; then
        echo ""
        if [ "$cron_checked" -eq 1 ]; then
            info "Re-enable:  Backup → Scheduled - Set up  (privcloud → 9 → 2, or federver → 14 → 6)."
        else
            info "Verify by hand:  sudo crontab -l | grep -i immich"
            info "Set up the schedule:  Backup → Scheduled - Set up  (privcloud → 9 → 2, or federver → 14 → 6)."
        fi
    fi

    # Option C: this screen is Immich-only. The full list of everything scheduled
    # on the server lives in its own view — point there instead of duplicating it.
    echo ""
    echo -e "  ${DIM}▸ Other scheduled jobs on this server → federver → 14 → 1${NC}"
}

# Remove the schedule (timer + service + script). Leaves existing backup files
# on disk untouched.
_immich_backup_remove() {
    # A schedule can take three forms: the systemd timer, the managed script, or
    # a legacy root-cron line (matched by what it RUNS, readable without a
    # password). Detect the cron form too — otherwise a cron-only schedule (no
    # timer, no script) would bail here as "nothing to remove" while Status still
    # reports it scheduled, leaving a backup running that the user thinks is gone.
    local legacy_cron
    legacy_cron=$(sudo -n crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -E 'immich-backup\.sh|immich-db|immich-backup\.log')
    if [ ! -f /etc/systemd/system/immich-backup.timer ] && [ ! -e /usr/local/bin/immich-backup.sh ] && [ -z "$legacy_cron" ]; then
        warn "No scheduled Immich backup to remove."
        return 0
    fi

    # Show exactly WHAT will be removed before asking, so this isn't a blind
    # delete. There's only ONE Immich backup schedule by design — the
    # immich-backup.* timer/service/script (plus any legacy root-cron remnant) —
    # so this lists those specific artifacts and the cadence, not "some job".
    # Other scheduled tasks (sync jobs, disk-check) are separate and untouched.
    echo ""
    echo -e "  ${BOLD}About to remove the Immich backup schedule:${NC}"
    if [ "$(systemctl show immich-backup.timer -p LoadState --value 2>/dev/null)" = "loaded" ]; then
        local oncal next
        oncal=$(systemctl cat immich-backup.timer 2>/dev/null | sed -n 's/^OnCalendar=//p' | head -1)
        next=$(systemctl list-timers immich-backup.timer --no-pager 2>/dev/null | awk '/immich-backup/{print $1,$2,$3,$4; exit}')
        printf "    %-13s %s\n" "Timer:"   "immich-backup.timer  ${DIM}(${oncal:-unknown}${next:+, next $next})${NC}"
        printf "    %-13s %s\n" "Service:" "immich-backup.service"
    fi
    [ -e /usr/local/bin/immich-backup.sh ] && printf "    %-13s %s\n" "Script:" "/usr/local/bin/immich-backup.sh"
    if [ -n "$legacy_cron" ]; then
        printf "    %-13s\n" "Legacy cron:"
        printf '%s\n' "$legacy_cron" | sed 's/^/      /'
    fi

    echo ""
    warn "This removes the SCHEDULE only — existing backup files are NOT deleted."
    local c; read -p "  Remove this scheduled Immich backup? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || { info "Kept."; return 2; }

    # Acquire sudo ONCE up front. This menu is called as `... || true`, which
    # disables `set -e` inside the function — so without this check the sudo
    # commands below could all fail (no password / Ctrl-C) and we'd still fall
    # through to a false "removed". Bail cleanly instead, changing nothing.
    if ! sudo -v; then
        fail "Need sudo to remove the schedule — nothing was changed."
        return 1
    fi

    sudo systemctl disable --now immich-backup.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/immich-backup.timer /etc/systemd/system/immich-backup.service
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo rm -f /usr/local/bin/immich-backup.sh
    # Clear any legacy cron line too — match the SAME pattern detection uses (what
    # the line RUNS), not just the literal "immich-backup", so a line that runs an
    # immich-db dump is actually removed instead of detected-but-left-behind.
    local cron_pat='immich-backup\.sh|immich-db|immich-backup\.log'
    local cur new
    cur=$(_cron_get root) || { fail "Could not read root's crontab - cron line not removed."; return 1; }
    if grep -qE "$cron_pat" <<<"$cur"; then
        new=$(_cron_drop "$cur" E "$cron_pat")
        _cron_set root "$new" || { fail "Could not update root's crontab - the cron line may still be active."; return 1; }
    fi

    # Verify it's actually gone before claiming success — timer, script, AND any
    # active (non-comment) cron line.
    local cron_left
    cron_left=$(sudo crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -E "$cron_pat")
    if [ -f /etc/systemd/system/immich-backup.timer ] || [ -e /usr/local/bin/immich-backup.sh ] || [ -n "$cron_left" ]; then
        fail "Removal did not complete — the schedule may still be active."
        info "Check it: privcloud → 9 → 3 (Scheduled - Status)."
        return 1
    fi
    ok "Scheduled Immich backup removed. Backup files left intact."
}

# Management submenu for the scheduled backup, used by federver → 14 → 6.
# (privcloud's Backup menu was flattened in v0.9.13 — it calls step_immich_backup
# / _immich_backup_status / _immich_backup_run / _immich_backup_remove directly
# rather than going through this submenu, but drives the same single schedule.)
# `|| true` on each action: a step returning 2 (Back) must not abort under set -e.
step_immich_backup_menu() {
    echo ""
    echo -e "  ${BOLD}Scheduled Immich backup${NC}"
    echo -e "    ${BOLD}1)${NC} Set up / change schedule"
    echo -e "    ${BOLD}2)${NC} Status      ${DIM}← schedule, next/last run, recent runs${NC}"
    echo -e "    ${BOLD}3)${NC} Run now     ${DIM}← start a backup in the background${NC}"
    echo -e "    ${BOLD}4)${NC} Remove      ${DIM}← delete the schedule (keeps backup files)${NC}"
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    # Single pass: run one action, then return to the caller's menu (federver
    # → 14 → 6 redraws a fresh menu) rather than looping here and re-prompting
    # after each action. Back/invalid → 2 so the caller treats it as a clean
    # "Back" with no DONE banner.
    local c; read -p "  Choice [0-4]: " c
    case "$c" in
        1) step_immich_backup    || true ;;
        2) _immich_backup_status || true ;;
        3) _immich_backup_run    || true ;;
        4) _immich_backup_remove || true ;;
        0|"") return 2 ;;
        *) fail "Invalid choice."; return 2 ;;
    esac
    return 0
}

# Print the disk-check script (stdout). $1 = Kuma push base URL, $2 = .env path.
# Split from step_disk_monitor so the exact script that gets installed can be
# dry-run (DISKCHECK_DRYRUN=1) before it is ever scheduled.
_disk_check_script() {
    # DRIVE_ROOTS: the same roots as _drive_verdict (this script runs standalone from cron).
    printf '#!/bin/bash\nPUSH_URL=%q\nENV_FILE=%q\nDRIVE_ROOTS=%q\n' "$1" "$2" "$_DRIVE_ROOTS"
    cat <<'DISKEOF'
# Exit codes: 0 healthy | 1 alert (Kuma down) | 3 healthy but the Kuma push
# failed | 4 blind config (dry-run only: nothing checkable). Not 2: bash itself
# exits 2 on a syntax/usage error, which must not read as a config problem.
# DISKCHECK_DRYRUN=1: print what would be watched; no curl, no log/state write.
THRESHOLD=85
LOG="/var/log/disk-check.log"
# One-line state file, overwritten every run (never grows): "<date> ok" or
# "<date> ALERT <msg>". The menu's "Last run" reads this; the log is alerts only.
STATE="/var/log/disk-check.last"
FSTAB="/etc/fstab"
umask 022   # keep the state file world-readable so the menu can read it without sudo
NOW=$(date '+%Y-%m-%d %H:%M')

envget() {
    local line v
    line=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" 2>/dev/null | head -1)
    v="${line#*=}"
    v="${v#"${v%%[![:space:]]*}"}"                       # trim leading space
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;              # "quoted": up to closing quote
        \'*) v="${v#\'}"; v="${v%%\'*}" ;;
        *) v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}" ;;  # drop ' # comment', trim
    esac
    printf '%s' "$v"
}

# Declared intent: the longest /etc/fstab mountpoint (field 2, non-comment
# lines) that is a prefix of $1. Empty when fstab says nothing about the path.
fstab_mount_for() {
    local best="" mp
    while read -r _ mp _; do
        mp="${mp//\\040/ }"; mp="${mp%/}"
        case "$mp" in /?*) ;; *) continue ;; esac        # skips "/", swap, none, blanks
        case "$1" in "$mp"|"$mp"/*) (( ${#mp} > ${#best} )) && best="$mp" ;; esac
    done < <(grep -v '^[[:space:]]*#' "$FSTAB" 2>/dev/null)
    printf '%s' "$best"
}

# Is $1 under a removable-drive root (so it must sit on a real /dev mount)?
on_drive() {
    local r
    for r in $DRIVE_ROOTS; do
        case "$1" in "$r"/*) return 0 ;; esac
    done
    return 1
}

MOUNTS=(/)
WATCH=()
PROBLEMS=()
NLOC=0      # data locations configured in .env
NRES=0      # ... that exist and were checked
CONFIG_BAD=0

if [ ! -f "$ENV_FILE" ]; then
    PROBLEMS+=("config not found: $ENV_FILE"); CONFIG_BAD=1
elif [ ! -r "$ENV_FILE" ]; then
    PROBLEMS+=("config unreadable: $ENV_FILE"); CONFIG_BAD=1
else
    for key in FILES_LOCATION MUSIC_LOCATION UPLOAD_LOCATION DB_DATA_LOCATION; do
        p=$(envget "$key")
        [ -z "$p" ] && continue
        NLOC=$((NLOC+1))
        case "$p" in /*) ;; *) p="$(dirname "$ENV_FILE")/$p" ;; esac
        pc=$(readlink -f -- "$p" 2>/dev/null) || pc=""
        [ -n "$pc" ] && p="$pc"
        want=$(fstab_mount_for "$p")
        if [ ! -e "$p" ]; then
            # An fstab-declared mount whose directory is gone = absent automount drive.
            if [ -n "$want" ]; then PROBLEMS+=("$p not mounted"); else PROBLEMS+=("$p missing"); fi
            continue
        fi
        NRES=$((NRES+1))
        t=$(findmnt -n -o TARGET -T "$p" 2>/dev/null | tail -n 1)
        if [ -z "$t" ]; then
            PROBLEMS+=("$p not mounted"); continue
        fi
        if [ "$t" = "/" ]; then
            if [ -n "$want" ]; then
                # fstab says a drive belongs here but the path resolves to /.
                PROBLEMS+=("$p not mounted"); continue
            fi
            # No fstab line (udisks/automount): an EMPTY dir under a removable-drive
            # prefix is the leftover stub of an absent drive.
            if on_drive "$p" && [ -z "$(ls -A "$p" 2>/dev/null)" ]; then
                PROBLEMS+=("$p not mounted"); continue
            fi
        elif on_drive "$p"; then
            # A mount point that is not a /dev device is an autofs placeholder
            # (SOURCE systemd-1) of a drive that never mounted.
            s=$(findmnt -n -o SOURCE -T "$p" 2>/dev/null | tail -n 1)
            case "$s" in /dev/*) ;; *) PROBLEMS+=("$p not mounted"); continue ;; esac
        fi
        seen=false
        for m in "${MOUNTS[@]}"; do [ "$m" = "$t" ] && seen=true; done
        $seen || MOUNTS+=("$t")
    done
    if [ "$NLOC" -eq 0 ]; then
        PROBLEMS+=("no data locations in $ENV_FILE"); CONFIG_BAD=1
    fi
fi

for m in "${MOUNTS[@]}"; do
    USAGE=$(df -P "$m" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
    case "$USAGE" in
        ''|*[!0-9]*) PROBLEMS+=("$m usage unreadable"); WATCH+=("$m (?)") ;;
        *) WATCH+=("$m (${USAGE}%)")
           [ "$USAGE" -gt "$THRESHOLD" ] && PROBLEMS+=("$m ${USAGE}%") ;;
    esac
done

if [ -n "$DISKCHECK_DRYRUN" ]; then
    echo "Watching: $(IFS=,; echo "${WATCH[*]}" | sed 's/,/, /g')"
    echo "Config: $ENV_FILE"
    for pr in "${PROBLEMS[@]}"; do echo "Problem: $pr"; done
    # Nothing configured is checkable = a blind monitor: refuse, never "ok".
    [ "$CONFIG_BAD" -eq 0 ] && [ "$NRES" -eq 0 ] && { echo "Problem: no configured data location exists"; CONFIG_BAD=1; }
    [ "$CONFIG_BAD" -eq 1 ] && exit 4
    [ ${#PROBLEMS[@]} -gt 0 ] && exit 1
    exit 0
fi

if [ ${#PROBLEMS[@]} -gt 0 ]; then
    MSG=$(IFS=,; echo "${PROBLEMS[*]}")
    STATUS=down
    echo "$(date): WARNING - $MSG" >> "$LOG"
    echo "$NOW ALERT $MSG" > "$STATE"
else
    MSG=OK
    STATUS=up
    echo "$NOW ok" > "$STATE"
fi
chmod 644 "$STATE" 2>/dev/null
# -f: an HTTP error (bad token -> 404) fails too. stderr dropped so the token
# URL can never reach a log or cron mail; only the exit code is kept.
curl -sf -m 15 -G --data-urlencode "status=$STATUS" --data-urlencode "msg=$MSG" "$PUSH_URL" > /dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "$(date): WARNING - Kuma push failed (curl exit $rc)" >> "$LOG"
    EXTRA=""; [ "$STATUS" = down ] && EXTRA="; $MSG"
    echo "$NOW ALERT Kuma push failed (curl exit $rc)$EXTRA" > "$STATE"
    exit 3
fi
[ "$STATUS" = up ]
DISKEOF
}

# After a refused install: say what is (not) running. -e, not -x: the script is
# root-only 0700, so -x is false for the non-root user running this step.
_disk_check_existing_note() {
    if [ -e /usr/local/bin/disk-check.sh ]; then
        warn "A previously installed disk-check is still installed and unchanged - it may be outdated."
        info "Re-run federver -> 14 -> 7 from the privcloud folder to replace it."
    else
        info "No disk-check is installed - nothing installed."
    fi
}

# Print the Push URL baked into the installed script (empty = not found). The
# script is root:root 0700, so read it with sudo; the generator wrote the line
# with printf %q, which leaves a plain http URL untouched - anything else (an
# escaped character, another scheme) is not trusted and counts as not found.
_disk_check_url_from_script() {
    local line u
    [[ -e /usr/local/bin/disk-check.sh ]] || return 0    # nothing installed: no sudo prompt
    line=$(sudo grep -m1 '^PUSH_URL=' /usr/local/bin/disk-check.sh 2>/dev/null) || return 0
    u="${line#PUSH_URL=}"
    [[ "$u" =~ ^https?://[A-Za-z0-9._:/-]+/api/push/[A-Za-z0-9]+$ ]] && printf '%s' "$u"
    return 0
}

# Print the Push URL of Kuma's one active push monitor named "disk-space" (case
# and spaces ignored, so "Disk Space" matches), read-only from its DB. $1 = host IP.
# Zero or several matches, or any docker/sqlite failure = empty (ambiguous or unknown).
_disk_check_url_from_kuma() {
    local rows
    rows=$(timeout 15 docker exec uptime_kuma sqlite3 -readonly /app/data/kuma.db \
        "select push_token from monitor where type='push' and active=1 and lower(replace(name,' ','-'))='disk-space'" 2>/dev/null) || return 0
    [[ "$rows" =~ ^[A-Za-z0-9]+$ ]] && printf 'http://%s:3001/api/push/%s' "$1" "$rows"
    return 0
}

# Remove the installed disk-check (cron line + script) after a typed confirm,
# then verify the end state. Blank or wrong confirm changes nothing.
_disk_check_remove() {
    local cur new reply rc=0
    cur=$(_cron_get root) || { fail "Could not read root's crontab - nothing removed."; return 1; }
    if ! grep -q disk-check <<<"$cur" && [[ ! -e /usr/local/bin/disk-check.sh ]]; then
        info "No disk-check is installed - nothing to remove."
        return 0
    fi
    printf "  Type \"${BOLD}${RED}disk-check${NC}\" to confirm removal (blank = cancel): "
    read -r reply
    if [[ -z "$reply" ]]; then info "Cancelled. Nothing removed."; return 0; fi
    if [[ "$reply" != "disk-check" ]]; then fail "Input '${reply}' did not match 'disk-check'. Cancelled. Nothing removed."; return 0; fi
    new=$(_cron_drop "$cur" "" disk-check)
    _cron_set root "$new" || { fail "Could not update root's crontab - disk-check cron NOT removed."; return 1; }
    sudo rm -f /usr/local/bin/disk-check.sh || rc=$?
    cur=$(_cron_get root) || { fail "Removed, but could not re-read root's crontab to confirm."; return 1; }
    if grep -q disk-check <<<"$cur" || [[ -e /usr/local/bin/disk-check.sh ]]; then
        fail "disk-check is NOT fully removed (rm exit $rc) - check: sudo crontab -l; ls -l /usr/local/bin/disk-check.sh"
        return 1
    fi
    ok "disk-check removed: cron line and script are gone."
    return 0
}

# Age in seconds of a disk-check.last line ("<YYYY-MM-DD HH:MM> ok|ALERT ..."),
# empty if unparsable. Mirrors the Status view's calculation (that one runs
# remotely inside an ssh script, so it cannot call this helper).
_disk_check_last_age() {
    local t
    t=$(date -d "${1:0:16}" +%s 2>/dev/null) || return 0
    echo $(( $(date +%s) - t ))
}

# "Current" block shown when an existing monitor/URL was found: masked Push URL,
# the real root cron line, and the last run (world-readable, no sudo).
_disk_check_current() {
    local url="$1" src="$2" other="${3:-}" cron cronline lastf=/var/log/disk-check.last last age
    echo -e "  ${BOLD}Current${NC}"
    echo -e "    Push URL:  ${url%%/api/push/*}/api/push/…${url: -4}   ${DIM}(from ${src})${NC}"
    # $3 = the installed script's URL when it differs from Kuma's (shown masked too).
    [[ -n "$other" ]] && echo -e "    Script's:  ${other%%/api/push/*}/api/push/…${other: -4}   ${DIM}(installed script - differs, not used)${NC}"
    if cron=$(_cron_get root 2>/dev/null); then
        cronline=$(grep disk-check <<<"$cron" | head -n 1)
        if [[ -n "$cronline" ]]; then echo -e "    Cron:      $cronline"
        else echo -e "    Cron:      ${RED}not scheduled${NC}"; fi
    else
        echo -e "    Cron:      ${YELLOW}unknown (could not read root's crontab)${NC}"
    fi
    if [[ -r "$lastf" && -s "$lastf" ]]; then
        last=$(head -n 1 "$lastf"); age=$(_disk_check_last_age "$last")
        if [[ "$last" == *" ok" ]]; then echo -ne "    Last run:  ${GREEN}${last}${NC}"
        else echo -ne "    Last run:  ${RED}${last}${NC}"; fi
        if [[ "$age" =~ ^-?[0-9]+$ ]] && (( age > 720 )); then echo -ne " ${RED}(stale)${NC}"; fi
        echo ""
    else
        echo -e "    Last run:  never"
    fi
    echo ""
}

step_disk_monitor() {
    info "Configures a 5-minute heartbeat to your Uptime Kuma 'Disk Space' monitor."
    info "An existing Push URL is found and reused; nothing is removed unless you choose r."
    echo ""

    local IP cur kept new push_url found src choice
    IP=$(hostname -I | awk '{print $1}')

    # Reuse a known URL before asking for one (the script first, then Kuma's DB).
    local kuma script_url="" mismatch=""
    found=$(_disk_check_url_from_script); src="the installed script"
    if [[ -z "$found" ]]; then
        found=$(_disk_check_url_from_kuma "$IP"); src="Uptime Kuma"
    else
        # Kuma is the truth: a script left with a stale token pushes into the void
        # (the monitor never turns green). Compare tokens; if they differ, use Kuma's.
        kuma=$(_disk_check_url_from_kuma "$IP")
        if [[ -n "$kuma" && "${kuma##*/api/push/}" != "${found##*/api/push/}" ]]; then
            mismatch="Installed script's Push URL differs from Kuma's (…${found: -4} vs …${kuma: -4})"
            script_url="$found"; found="$kuma"; src="Uptime Kuma"
        fi
    fi

    # The box is always shown (it is the reference for how the monitor is configured).
    local title="Set up the Kuma monitor first"
    [[ -n "$found" ]] && title="Kuma monitor settings"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}${title}${NC}"
    echo ""
    echo -e "  1. Open ${BLUE}http://$IP:3001${NC}"
    echo -e "  2. Add New Monitor → Monitor Type: ${BOLD}Push${NC}"
    echo -e "  3. Friendly Name: ${BOLD}Disk Space${NC}"
    echo -e "  4. Heartbeat Interval: ${BOLD}360${NC}  ${DIM}(seconds — matches the 5-min cron)${NC}"
    echo -e "  5. Heartbeat Retry Interval: ${BOLD}60${NC}"
    echo -e "  6. Max Retries: ${BOLD}2${NC}"
    echo -e "  7. Click ${BOLD}Save${NC}, then copy the ${BOLD}Push URL${NC} from the monitor page"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ -n "$found" ]]; then
        [[ -n "$mismatch" ]] && warn "$mismatch"
        _disk_check_current "$found" "$src" "$script_url"
        while true; do
            # EOF (closed stdin) = back with no changes, never "use it".
            read -p "  Enter = use it, p = paste a different URL, r = remove the monitor, q = back: " choice || choice=q
            case "$choice" in
                "") push_url="$found"; break ;;
                p|P) break ;;
                r|R) _disk_check_remove; return $? ;;
                q|Q) return 2 ;;
                *) warn "Enter, p, r or q." ;;
            esac
        done
    fi

    if [[ -z "$push_url" ]]; then
        read -p "  Paste the Push URL (q/Enter = back): " push_url
        if [[ -z "$push_url" || "$push_url" == "q" ]]; then
            info "No changes."
            return 2
        fi
    fi

    # Kuma's copied Push URL already carries "?status=up&msg=OK&ping=". Keep only
    # the base so the script appends exactly one query string (a second "?" made
    # Kuma read the first status=up, so "down" never registered).
    push_url="${push_url%%\?*}"

    # The .env the monitor reads is the one every other menu step uses:
    # $SCRIPT_DIR/.env, i.e. the repo checkout (~/privcloud on the server). A copy
    # of setup.sh run from elsewhere has no .env beside it, and the dry-run below
    # refuses to install rather than bake a path that does not exist.
    local SCRIPT_DIR env_file tmp dry_out dry_rc=0
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="$SCRIPT_DIR/.env"

    # Generate, then dry-run the exact script (as this user, no curl, no writes)
    # and show what it resolved. Nothing is installed or scheduled until it passes.
    tmp=$(mktemp) || { fail "Could not create a temp file - disk-check NOT installed."; return 1; }
    # The temp file holds the Kuma push URL: remove it on every way out of this
    # function (return or Ctrl-C/TERM). Traps are shell-global, so the handler
    # clears itself; INT/TERM then re-raise so the default behaviour is unchanged.
    trap "rm -f '$tmp'; trap - RETURN INT TERM" RETURN
    trap "rm -f '$tmp'; trap - RETURN INT TERM; kill -INT \$BASHPID" INT
    trap "rm -f '$tmp'; trap - RETURN INT TERM; kill -TERM \$BASHPID" TERM
    _disk_check_script "$push_url" "$env_file" > "$tmp"
    info "Checking what the monitor will watch..."
    dry_out=$(DISKCHECK_DRYRUN=1 bash "$tmp" 2>&1) || dry_rc=$?
    echo "$dry_out" | sed 's/^/    /'
    if (( dry_rc == 4 )); then
        fail "The monitor would be blind (see above) - disk-check NOT installed."
        info "Run this from the repo checkout that holds your .env (federver -> 14 -> 7, or ~/privcloud/setup.sh on the server)."
        _disk_check_existing_note
        return 1
    elif (( dry_rc != 0 && dry_rc != 1 )); then
        fail "Monitor script error (dry-run exit $dry_rc) - disk-check NOT installed."
        _disk_check_existing_note
        return 1
    elif (( dry_rc == 1 )); then
        warn "Problems above are real: they will show in Kuma as down. Installing anyway - that is the monitor's job."
    fi

    # root:root 0700 in one step: the script holds the Kuma push token.
    local inst_rc=0
    sudo install -o root -g root -m 700 "$tmp" /usr/local/bin/disk-check.sh || inst_rc=$?
    rm -f "$tmp"
    (( inst_rc == 0 )) || { fail "Could not install /usr/local/bin/disk-check.sh - NOT scheduled."; return 1; }

    cur=$(_cron_get root) || { fail "Could not read root's crontab - disk-check NOT scheduled."; return 1; }
    kept=$(_cron_drop "$cur" "" disk-check)
    new="${kept:+$kept$'\n'}*/5 * * * * /usr/local/bin/disk-check.sh"
    if ! _cron_set root "$new"; then
        fail "Could not write root's crontab (or it did not read back as expected) - disk-check NOT scheduled."
        info "Check it: sudo crontab -l"
        return 1
    fi

    info "Sending first heartbeat to Kuma..."
    local hb_rc=0
    sudo /usr/local/bin/disk-check.sh || hb_rc=$?
    case "$hb_rc" in
        0) ok "Heartbeat sent — Kuma monitor should turn green within ~6 min." ;;
        1) warn "Heartbeat sent as DOWN (see the problems above)." ;;
        *) fail "The first heartbeat did not reach Kuma: $(cat /var/log/disk-check.last 2>/dev/null)"
           info "Check the Push URL and that Kuma is reachable from this server. It stays scheduled and retries every 5 minutes." ;;
    esac
    echo ""
    ok "Disk space check runs every 5 minutes (alerts above 85%)."
    info "Last run: cat /var/log/disk-check.last   Alert history: cat /var/log/disk-check.log"
}

step_logrotation() {
    info "Limits Docker container log sizes to prevent disk filling up."
    echo ""

    sudo mkdir -p /etc/docker
    if ! grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
        sudo tee /etc/docker/daemon.json > /dev/null <<'LOGJSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
LOGJSON
        sudo systemctl restart docker
        ok "Log rotation configured: max 10MB per log, 3 files per container."
        info "Existing containers need restart to pick up new log settings."
    else
        ok "Already configured."
    fi
}

# ── Mirror mode (rsync --delete) for 14 → 2 / 3 / 5 ──────────────────────────
# Copies are append-only unless the user types "delete" at _mirror_ask. A mirror
# first passes a source guard (an empty/unmounted source would wipe the
# destination), then a dry run that lists what would be deleted, then a typed
# y/N. A scheduled job keeps its mode in its record (see "Sync jobs" below) and every
# run repeats the guard (_mirror_guard) and an unattended wipe cap.

# ── One drive-mount verdict ──────────────────────────────────────────────────
# Every "is this path really on a mounted drive?" question asks _drive_verdict;
# callers only map its answer. Shipped to the server / into job scripts together
# with _DRIVE_ROOTS (declare -p _DRIVE_ROOTS; declare -f _drive_verdict).
_DRIVE_ROOTS="/mnt /media /run/media"   # paths under these are drive-backed (a constant: no env override)

# _drive_verdict <path> prints exactly one of
#   ok        the path is there (and, under _DRIVE_ROOTS, on a real mount)
#   missing   the path is not there (an existing folder we cannot list is not missing:
#             its emptiness is unknown, so it counts as not empty)
#   empty     there, but nothing in it (under _DRIVE_ROOTS: on a real mount)
#   unmounted under _DRIVE_ROOTS but a bare folder on the system disk, or an
#             autofs/stub mount: findmnt must find a mount that is not / and
#             whose SOURCE is a /dev/* device
#   unknown   under _DRIVE_ROOTS and findmnt is not installed: cannot tell
# Callers that delete, start services or create folders must refuse on anything
# but ok (and empty where an empty folder is fine); a path outside _DRIVE_ROOTS
# is not drive-backed, so only missing/empty/ok apply. Always returns 0.
# One listing pokes the path first, which wakes an idle automount. A drive path
# that is not ok is looked at up to 3 times, 1 s apart (a slow spin-up must not
# read as unplugged); a healthy drive never waits.
_drive_verdict() {
    local p=$1 r t s i v list known drive=""
    for r in $_DRIVE_ROOTS; do
        if [[ "$p" == "$r"/* ]]; then drive=1; fi
    done
    for i in 1 2 3; do
        known=1
        list=$(ls -A -- "$p" 2>/dev/null) || known=""
        if [[ -z "$known" && ! -e "$p" ]]; then
            v=missing
        elif [[ -n "$drive" ]]; then
            command -v findmnt >/dev/null || { echo unknown; return 0; }
            t=$(findmnt -n -o TARGET -T "$p" 2>/dev/null) || t=""
            s=$(findmnt -n -o SOURCE -T "$p" 2>/dev/null) || s=""
            if [[ -z "$t" || "$t" == / || "$s" != /dev/* ]]; then v=unmounted
            elif [[ -n "$known" && -z "$list" ]]; then v=empty
            else v=ok; fi
        elif [[ -n "$known" && -z "$list" ]]; then v=empty
        else v=ok; fi
        if [[ "$v" == ok || -z "$drive" ]]; then break; fi
        [[ "$i" == 3 ]] || sleep 1
    done
    echo "$v"
}

# Source guard: _mirror_guard <local|server|sudo> <path>. rc 0 = safe to mirror.
#   Otherwise sets _mirror_why (source missing | source empty | drive not mounted |
#   could not check source: no verdict came back, e.g. server unreachable, or
#   findmnt missing - fail closed).
#   Asks _drive_verdict; server = the path is on the federver box (checked over
#   ssh, same function); sudo = same, as root, through _server_sudo_run (needs _SRV_PW).
_mirror_guard() {
    local loc=$1 p=$2 v=""
    case $loc in
        local)  v=$(_drive_verdict "$p") ;;
        server) v=$({ declare -p _DRIVE_ROOTS; declare -f _drive_verdict; echo "_drive_verdict $(_shq "$p")"; } \
                    | ssh "$SERVER_USER@$SERVER_IP" 'bash -s' 2>/dev/null) || v="" ;;
        sudo)   v=$(_server_sudo_run "$(declare -p _DRIVE_ROOTS; declare -f _drive_verdict); _drive_verdict $(_shq "$p")") || v="" ;;
    esac
    v=$(printf '%s' "$v" | tr -d '\r' | tail -n 1)
    case $v in
        ok)        return 0 ;;
        missing)   _mirror_why="source missing" ;;
        empty)     _mirror_why="source empty" ;;
        unmounted) _mirror_why="drive not mounted" ;;
        *)         _mirror_why="could not check source" ;;
    esac
    return 1
}

_mirror_refuse() {
    echo -e "  ${RED}✗ Source $1 is empty or its drive isn't mounted - a mirror would delete everything at the destination. Refused.${NC}"
    info "Check the drive is plugged in and mounted, or press Enter at the copy-mode question for append only."
}

# A mirror that would delete more files than this, or a whole top-level folder,
# needs the exact count typed instead of a y/N (_mirror_preview).
MIRROR_WIPE_MIN=1000

# Drop keys typed ahead (a leftover Enter must not answer the next question).
# Only on a terminal; a pipe or heredoc on stdin is left alone.
_mirror_flush() {
    if [[ -t 0 ]]; then
        while read -r -t 0.05 -n 10000 _; do :; done
    fi
    return 0
}

# The one question. Sets sync_mode=append|mirror; only the exact word "delete"
# selects mirror.
_mirror_ask() {
    local reply=""
    echo ""
    echo -e "  ${YELLOW}Deleted at source → also delete at destination?${NC}"
    echo -en "  Enter = no, ${GREEN}append only${NC} · type \"${RED}delete${NC}\" = ${RED}mirror${NC}: "
    _mirror_flush
    IFS= read -r reply || reply=""
    if [[ "$reply" == delete ]]; then
        sync_mode=mirror
    else
        sync_mode=append
        ok "Append only - nothing at the destination will be deleted."
    fi
}

# The red "Mode: mirror" line of a copy's summary box (nothing for append).
_mirror_banner() {
    if [[ "$sync_mode" == mirror ]]; then
        echo -e "  ${RED}Mode: mirror - deletes destination files that are gone from the source${NC}"
    fi
}

# Dry-run command for an append-form copy command ("rsync <any flags> ...").
# --out-format=%o|%n prints "del.|<name>" for every deletion.
_mirror_dry_cmd() { _rsync_with "$1" "-n --delete --out-format='%o|%n'"; }

# Same command with a flag after "rsync" (--delete, or the literal $DELFLAG).
_rsync_with() { printf 'rsync %s %s' "$2" "${1#rsync }"; }

# What a dry-run list (rsync --out-format='%o|%n') would delete, counted. Files are
# listed by name; a directory counts only when no deleted file sits under it (those go
# with their files) = an empty folder. One awk pass: totals, then one G line per
# top-level folder (count, files, empty folders, whole-folder flag, name). A folder is
# "whole" when its own "name/" entry is in the list (rsync prints it when the
# directory goes entirely). Sets _mirror_nf (files), _mirror_nd (empty folders),
# _mirror_nwhole (whole top-level folders) and _mirror_groups (the G lines).
# The interactive preview and the unattended wipe cap both count with this.
_mirror_scan() {  # list_file
    local sum
    sum=$(awk 'function top(x,   j) { j = index(x, "/"); return j ? substr(x, 1, j) : "(top level)" }
        /^del\.\|/ { p = substr($0, 6)
            if (p ~ /\/$/) { d[++nd] = p; next }
            nf++; t = top(p); cnt[t]++; seen[t] = 1
            while ((i = match(p, /\/[^\/]*$/)) > 0) { p = substr(p, 1, i - 1); if ((p "/") in has) break; has[p "/"] = 1 } }
        END { for (i = 1; i <= nd; i++) { t = top(d[i]); seen[t] = 1
                if (!(d[i] in has)) { ne++; em[t]++ }
                if ((d[i] in has) && index(d[i], "/") == length(d[i])) whole[t] = 1 }
              print "T", nf + 0, ne + 0
              for (t in seen) { if (t in whole) nw++; printf "G %d %d %d %d %s\n", cnt[t] + em[t], cnt[t] + 0, em[t] + 0, (t in whole), t }
              print "W", nw + 0 }' "$1")
    read -r _ _mirror_nf _mirror_nd <<<"$(grep '^T ' <<<"$sum")"
    read -r _ _mirror_nwhole <<<"$(grep '^W ' <<<"$sum")"
    _mirror_groups=$(grep '^G ' <<<"$sum") || _mirror_groups=""
}

# After _mirror_scan: is the deletion wipe-sized (a whole top-level folder, or more
# than MIRROR_WIPE_MIN files)? Interactive: the exact count must be typed. Unattended
# job: skipped. rc 0 = wipe-sized.
_mirror_wipe_sized() {
    (( _mirror_nf + _mirror_nd > 0 && (_mirror_nwhole > 0 || _mirror_nf > MIRROR_WIPE_MIN) ))
}

# Guard + dry run + typed y/N. _mirror_preview <loc> <src> <dest-label> <dry-cmd> <copy|save>
#   copy: prints the summary only; the caller asks later with _mirror_confirm
#   save: scheduled job, asks "Save this job as mirror?" itself
# rc 0 = go ahead (_mirror_n = files + empty folders that will be deleted, plus
# _mirror_what / _mirror_want for the question); 1 = refused, failed or cancelled
# - the caller copies / saves nothing.
_mirror_preview() {
    local loc=$1 src=$2 dest=$3 dry=$4 ask=$5 rc=0 nf nd what="" sdir list
    _mirror_n=0; _mirror_want=""; _mirror_what=""
    if ! _mirror_guard "$loc" "$src"; then _mirror_refuse "$src"; return 1; fi
    # The dry run reads both trees and can take minutes, so say what is going on
    # and (on a terminal) tick the elapsed seconds on that line. The full output
    # streams into a private list file (names can be private), never a shell
    # variable: a mirror into the wrong folder can list millions of files.
    sdir=${XDG_STATE_HOME:-$HOME/.local/state}/federver
    list=$sdir/mirror-preview-$(date +%Y%m%d-%H%M%S).txt
    if ! ( umask 077; mkdir -p "$sdir" && : > "$list" ) 2>/dev/null; then
        fail "Could not create the preview list file in $sdir - nothing changed."; return 1
    fi
    local pid t=0 nd nc live msg="Checking what a mirror would delete (nothing is copied)"
    if [[ -t 1 ]]; then printf '  %s...' "$msg"; else echo "  $msg..."; fi
    if [[ "$loc" == sudo ]]; then
        _server_sudo_run "exec 2>&1; $dry" > "$list" &
    else
        bash -c "$dry" > "$list" 2>&1 &
    fi
    pid=$!
    # Ctrl-C: stop the dry run (it ignores SIGINT as a background job), drop the
    # partial list, copy / save nothing. Trap is scoped to this wait.
    local intr=0 oldtrap
    oldtrap=$(trap -p INT)
    trap 'intr=1; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null' INT
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1; t=$((t + 1))
            # what rsync has found so far, read from the list file (one awk pass)
            read -r nd nc < <(awk '/^del\.\|/ { d++; next } /^(send|recv)\|/ { c++ }
                END { print d + 0, c + 0 }' "$list")
            live=""
            if (( nd + nc > 0 )); then
                live=" · $(sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta' <<<"$nd") to delete"
                live+=" · $(sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta' <<<"$nc") to copy so far"
            fi
            printf '\r\033[K  %s... %ds%s' "$msg" "$t" "$live"
        done
    fi
    wait "$pid" || rc=$?
    (( intr )) && { wait "$pid" 2>/dev/null || true; }
    if [[ -n "$oldtrap" ]]; then eval "$oldtrap"; else trap - INT; fi
    [[ -t 1 ]] && printf '\r\033[K'
    if (( intr )); then
        rm -f "$list"
        echo ""; info "Cancelled - nothing changed."
        return 1
    fi
    if (( rc != 0 )); then
        rm -f "$list"
        fail "Could not preview the deletions (rsync exit $rc) - nothing changed."
        return 1
    fi
    _mirror_scan "$list"
    nf=$_mirror_nf; nd=$_mirror_nd
    _mirror_n=$((nf + nd))
    if (( _mirror_n == 0 )); then rm -f "$list"; else
        local old=()   # keep only the newest 5 lists
        mapfile -t old < <(ls -1 "$sdir"/mirror-preview-*.txt 2>/dev/null | sort -r | tail -n +6)
        (( ${#old[@]} )) && rm -f -- "${old[@]}"
    fi
    [[ "$ask" == save ]] && echo -e "  ${YELLOW}⚠ Every scheduled run will delete destination files that are gone from the source.${NC}"
    if (( nf > 0 )); then
        what="${nf} file$([[ $nf == 1 ]] || echo s)"
        (( nd > 0 )) && what+=" (+ ${nd} empty folder$([[ $nd == 1 ]] || echo s))"
        echo -e "  ${YELLOW}⚠ ${what} would be deleted at ${dest}:${NC}"
    elif (( nd > 0 )); then
        what="${nd} empty folder$([[ $nd == 1 ]] || echo s)"
        echo -e "  ${YELLOW}⚠ ${what} would be removed at ${dest}:${NC}"
    else
        ok "Nothing to delete - destination has no extra files."
        [[ "$ask" == copy ]] && return 0
    fi
    if (( _mirror_n > 0 )); then
        # Top 5 top-level folders by count; the rest are summed up.
        local _c _f _e _w _name ng=0 line
        while read -r _ _c _f _e _w _name; do
            ng=$((ng + 1)); (( ng > 5 )) && continue
            line="$_f file$([[ $_f == 1 ]] || echo s)"
            (( _f == 0 )) && line="$_e empty folder$([[ $_e == 1 ]] || echo s)"
            (( _f > 0 && _e > 0 )) && line+=" (+ $_e empty folder$([[ $_e == 1 ]] || echo s))"
            (( _w )) && line+="  ← whole folder deleted"
            printf '    %s  %s\n' "$(sed 's/[[:cntrl:]]//g' <<<"$_name")" "$line"
        done < <(sort -k2,2nr -k6 <<<"$_mirror_groups")
        (( ng > 5 )) && echo "    ... and $((ng - 5)) more folders"
        echo "  Full list: $list"
    fi
    # What the one question will say (asked by _mirror_delete_q): a wipe-sized
    # deletion needs the exact count typed instead of a y/N.
    _mirror_what=$what
    _mirror_want=""
    _mirror_wipe_sized && _mirror_want=$(( nf > 0 ? nf : nd ))
    # A one-time copy asks after its summary box (_mirror_confirm); a scheduled
    # job asks here, once, at creation.
    [[ "$ask" == save ]] && { _mirror_delete_q save; return; }
    return 0
}

# The deletion question: typed count when the wipe guard applied, else y/N.
# Wording follows the mode: copy = "... and copy", save = "... save this job".
# rc 0 = confirmed; 1 = cancelled (nothing changed).
_mirror_delete_q() {  # copy|save
    local reply=""
    _mirror_flush   # keys typed during the dry run / before the box must not answer it
    if [[ -n "$_mirror_want" ]]; then
        if [[ "$1" == save ]]; then
            echo -en "  ${RED}Type ${_mirror_want} to save this job as mirror, Enter = cancel:${NC} "
        else
            echo -en "  ${RED}Type ${_mirror_want} to delete and copy, Enter = cancel:${NC} "
        fi
        read -r reply || reply=""
        if [[ "$reply" == "$_mirror_want" ]]; then return 0; fi
        info "Cancelled - nothing changed."
        return 1
    fi
    if [[ "$1" == save ]]; then
        printf '  Save this job as mirror? [y/N]: '
    else
        printf '  Delete these %s and copy? [y/N]: ' "$_mirror_what"
    fi
    read -r reply || reply=""
    if [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then return 0; fi
    info "Cancelled - nothing changed."
    return 1
}

# The single confirmation of a one-time copy, asked right after its summary box.
# Append (or a mirror with nothing to delete): Proceed? [y/N]. Mirror with
# deletions: the deletion question from the preview replaces Proceed?.
# rc 0 = go; 1 = cancelled.
_mirror_confirm() {
    if [[ "$sync_mode" == mirror ]] && (( _mirror_n > 0 )); then _mirror_delete_q copy; return; fi
    _mirror_flush
    read -p "  Proceed? [y/N] " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]] || { info "Cancelled."; return 1; }
}

# Source size for the "From:" line. A symlink to a folder is measured as the
# folder (trailing slash); plain `du -sh link` measures the link itself: 0.
_src_size() {
    local p=$1
    [[ -d "$p" ]] && p=${p%/}/
    du -sh "$p" 2>/dev/null | awk '{print $1}'
}

# One-time copies: ask the mode and, for a mirror, guard + preview + confirm.
# rc 0 = go on (sync_mode set; also fills the caller's mirror_flag array with
# --delete for a mirror), 2 = refused / cancelled (nothing changed).
_mirror_gate() {  # src_loc src_path dest_label append_cmd
    mirror_flag=()
    _mirror_ask
    [[ "$sync_mode" == mirror ]] || return 0
    _mirror_preview "$1" "$2" "$3" "$(_mirror_dry_cmd "$4")" copy || return 2
    mirror_flag=(--delete)
    return 0
}

# ── Sync jobs: one record, one launcher, one run ─────────────────────────────
# A recurring sync job is a record $HOME/.local/share/sync-jobs/<name>.job (KEY=VALUE,
# one line each, private, read WITHOUT `source`) plus a two-line launcher
# $HOME/.local/bin/sync-<name>.sh that cron / the systemd timer run:
#     exec <this script> --run-job <name>
# Nothing about the server (user, address) and no function is copied into either: the
# run (_sync_job_run) loads the record and the config file and picks the address then.
# Creating or editing a job rewrites the record; nothing patches script text.
_SYNC_REC_KEYS="name direction src_loc src dest_loc dest copy_mode mode sched_kind sched created"

# Write the record from the J_<key> globals (atomic: temp file + mv, mode 600).
_sync_rec_write() {
    local f="$HOME/.local/share/sync-jobs/$J_name.job" tmp k v
    for k in $_SYNC_REC_KEYS; do
        v=J_$k; v=${!v}
        if [[ "$v" == *$'\n'* ]]; then fail "A job value cannot hold a line break ($k) - nothing saved."; return 1; fi
    done
    mkdir -p "${f%/*}" || return 1
    tmp=$(umask 077; mktemp "$f.XXXXXX") || return 1
    for k in $_SYNC_REC_KEYS; do v=J_$k; printf '%s=%s\n' "$k" "${!v}"; done > "$tmp"
    mv -f "$tmp" "$f"
}

# Load <name>'s record into the J_<key> globals (plain KEY=VALUE parse, values literal).
# rc 1 = no such record or one without the fields a run needs.
_sync_rec_load() {  # name
    local f="$HOME/.local/share/sync-jobs/$1.job" line k
    [[ -f "$f" ]] || return 1
    for k in $_SYNC_REC_KEYS; do printf -v "J_$k" '%s' ""; done
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        k=${line%%=*}
        case " $_SYNC_REC_KEYS " in *" $k "*) printf -v "J_$k" '%s' "${line#*=}" ;; esac
    done < "$f"
    [[ "$J_name" == "$1" && "$J_direction" =~ ^(upload|download)$ && -n "$J_src" && -n "$J_dest" && "$J_mode" =~ ^(append|mirror)$ ]]
}

# The launcher cron and the timer run: two lines, no logic, nothing about the server.
_sync_write_launcher() {  # name
    local f="$HOME/.local/bin/sync-$1.sh" tmp
    mkdir -p "${f%/*}" || return 1
    tmp=$(mktemp "$f.XXXXXX") || return 1
    printf '#!/bin/bash\nexec %s --run-job %s\n' "$(_shq "$_FV_SELF")" "$(_shq "$1")" > "$tmp"
    chmod 755 "$tmp"
    if bash -n "$tmp" 2>/dev/null && mv -f "$tmp" "$f"; then return 0; fi
    rm -f "$tmp"; return 1
}

# Job names are [a-z0-9_-]. _sync_default_name turns a path into one; _sync_valid_name
# prints the one-line reason and returns 1 when a typed name has any other character.
_sync_default_name() {  # path
    local n=${1%/}
    n=${n##*/}; n=${n,,}; n=${n//[^a-z0-9_-]/-}
    printf '%s' "${n:-job}"
}
_sync_valid_name() {  # name
    local bad=${1//[a-z0-9_-]/}
    if [[ -z "$1" ]]; then echo "a job name cannot be empty"; return 1; fi
    if [[ -n "$bad" ]]; then echo "'${bad:0:1}' is not allowed in a job name (use a-z, 0-9, - and _)"; return 1; fi
}

# The rsync operands of the loaded record (J_*), for the address in SERVER_IP:
#   _sj_src / _sj_dst  what rsync gets,   _sj_shown  the destination folder as the user
#   sees it (the folder's own name is added in copy mode "folder"),
#   _sj_cmd  the append-form command line (what the mirror preview dry-runs).
_sync_job_operands() {
    local s=${J_src%/} d=${J_dest%/} rs
    _sj_shown=$d; [[ "$J_copy_mode" == folder ]] && _sj_shown=$d/${s##*/}
    rs=$s/; [[ "$J_copy_mode" == folder ]] && rs=$s
    if [[ "$J_direction" == upload ]]; then
        _sj_src=$rs; _sj_dst="$SERVER_USER@$SERVER_IP:$d/"
    else
        _sj_src="$SERVER_USER@$SERVER_IP:$rs"; _sj_dst="$d/"
    fi
    _sj_cmd="rsync $_RSYNC_FLAGS $(_shq "$_sj_src") $(_shq "$_sj_dst")"
}

# Everything one run does, for the loaded record. rc = rsync's own exit code (or 255
# server unreachable, 2 no server configured, 1 the destination could not be made);
# 100 = a mirror was refused (guard or wipe cap): already logged, nothing deleted.
# Never uses sudo and never needs a terminal: it runs from cron.
_sync_job_steps() {  # [nocap]
    local nocap=${1:-} ep rc=0 list n
    local SERVER_IP=$SERVER_IP   # this run's address stays inside this run
    if [[ -z "$SERVER_USER" || -z "$SERVER_IP" ]]; then
        echo "No server set: SERVER_USER / SERVER_IP missing (${FEDERVER_CONFIG})."; return 2
    fi
    ep=$(_pick_server_endpoint) || {
        echo "Server unreachable: neither $SERVER_IP nor ${SERVER_HOST_TS:-(no Tailscale name set)} answered on port 22."; return 255; }
    SERVER_IP=$ep
    _sync_job_operands
    if [[ "$J_mode" == mirror ]]; then
        if ! _mirror_guard "$J_src_loc" "$J_src"; then
            printf '%s: SKIPPED %s - %s (mirror refused, nothing deleted)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$J_name" "$_mirror_why"
            return 100
        fi
    fi
    if [[ "$J_direction" == upload ]]; then
        ssh "$SERVER_USER@$SERVER_IP" "mkdir -p $(_shq "$_sj_shown")" || rc=$?
    else
        mkdir -p -- "$_sj_shown" || rc=$?
    fi
    if (( rc != 0 )); then echo "Could not create the destination $_sj_shown (exit $rc); nothing here runs as root."; return $((rc == 255 ? 255 : 1)); fi
    if [[ "$J_mode" == mirror && -z "$nocap" ]]; then
        # Same count and limit as the interactive preview, but nobody is here to type
        # the count: a wipe-sized deletion is skipped, never done.
        list=$(mktemp) || return 1
        bash -c "$(_mirror_dry_cmd "$_sj_cmd")" > "$list" 2>&1 || rc=$?
        if (( rc != 0 && rc != 24 )); then
            rm -f "$list"; echo "Could not check what a mirror would delete (rsync exit $rc) - nothing deleted."; return $rc
        fi
        _mirror_scan "$list"; rm -f "$list"
        if _mirror_wipe_sized; then
            n=$(( _mirror_nf > 0 ? _mirror_nf : _mirror_nd ))
            printf '%s: SKIPPED %s - would delete %s %s (over the mirror limit), nothing deleted\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$J_name" "$n" "$([[ $_mirror_nf -gt 0 ]] && echo files || echo 'empty folders')"
            return 100
        fi
        rc=0
    fi
    local -a args
    read -ra args <<<"$_RSYNC_FLAGS"
    [[ "$J_mode" == mirror ]] && args+=(--delete)
    rsync "${args[@]}" "$_sj_src" "$_sj_dst" || rc=$?
    return $rc
}

# Run the loaded record once and log the way Status reads it: a start line and a
# "Sync finished: <name> (exit N)" line with rsync's real code. 24 (files vanished
# while copying) counts as success. A refused mirror logs its own SKIPPED line instead
# and returns 0. Decision: exit 24 -> "ok (some files vanished)".
_sync_job_go() {  # [nocap]
    local rc=0 note=""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: $J_name"
    _sync_job_steps "$1" || rc=$?
    (( rc == 100 )) && return 0
    if (( rc == 24 )); then rc=0; note=", some files vanished"; fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: $J_name (exit ${rc}${note})"
    return $rc
}

# The one place a recurring job runs (cron, timer, Run now, the first run after
# creating it): load the record, run it. nocap = the user has just confirmed the
# deletions, so the unattended wipe cap does not apply.
_sync_job_run() {  # name [nocap]
    if ! _sync_rec_load "$1"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: $1"
        echo "No usable job record for '$1' ($HOME/.local/share/sync-jobs/$1.job)."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: $1 (exit 2)"
        return 2
    fi
    _sync_job_go "${2:-}"
}

# A job's copy mode from its record: mirror | append | "-" (no usable record).
_sync_rec_mode() {  # name
    if _sync_rec_load "$1"; then echo "$J_mode"; else echo "-"; fi
}

# ── Converting an old job script (the only code that reads one) ──────────────
# Before the launcher design each job was a generated script holding its own rsync
# line. _sync_job_import_legacy reads only the fields that generator ever wrote
# (header comments, MODE=, one rsync line) and converts a job when EVERYTHING maps;
# anything ambiguous leaves the script untouched, with the reason in _import_why.
# It never edits script text: the old script is copied to <script>.bak, then the
# launcher replaces it (one atomic mv, so cron never sees a missing file).

# Split one shell line into words, honouring only the quoting printf %q / a plain
# hand-written line can hold: backslash escapes, 'single', "double without $ ` or \".
# The literal word $DELFLAG is kept as a word. Anything else with meaning to the
# shell ($ ; | & < > ( ) ` #, $'...') refuses. Never evaluates anything. -> _tok[]
_sync_tokenize() {  # line ; rc 1 = unusual, _tok_why says what
    local s=$1 i=0 n=${#1} c cur="" have=0 mode=n
    _tok=(); _tok_why=""
    while (( i < n )); do
        c=${s:i:1}; i=$((i + 1))
        case $mode in
            n)
                case $c in
                    ' '|$'\t') if (( have )); then _tok+=("$cur"); cur=""; have=0; fi ;;
                    "'") mode=s; have=1 ;;
                    '"') mode=d; have=1 ;;
                    '\') (( i < n )) || { _tok_why="a line ending in a backslash"; return 1; }
                         cur+=${s:i:1}; i=$((i + 1)); have=1 ;;
                    '$') if (( ! have )) && [[ "${s:i-1:8}" == '$DELFLAG' && ( $((i + 7)) -ge $n || "${s:i+7:1}" == ' ' ) ]]; then
                             _tok+=('$DELFLAG'); i=$((i + 7))
                         else _tok_why="a \$ in the rsync line"; return 1; fi ;;
                    ';'|'|'|'&'|'<'|'>'|'('|')'|'`') _tok_why="'$c' in the rsync line"; return 1 ;;
                    '#') if (( have )); then cur+=$c; else _tok_why="a # in the rsync line"; return 1; fi ;;
                    *) cur+=$c; have=1 ;;
                esac ;;
            s) if [[ "$c" == "'" ]]; then mode=n; else cur+=$c; fi ;;
            d) case $c in
                   '"') mode=n ;;
                   '$'|'`'|'\') _tok_why="'$c' inside double quotes"; return 1 ;;
                   *) cur+=$c ;;
               esac ;;
        esac
    done
    if [[ "$mode" != n ]]; then _tok_why="an unclosed quote"; return 1; fi
    if (( have )); then _tok+=("$cur"); fi
    return 0
}

# Convert <name>'s old script (cron line / timer already known: kind + schedule).
# rc 0 = converted (record + launcher written, old script kept as .bak, one notice
# line printed); 1 = refused, _import_why holds the reason and the script is untouched.
_sync_job_import_legacy() {  # name sched_kind sched
    local name=$1 kind=$2 sched=$3 sp="$HOME/.local/bin/sync-$1.sh"
    local line inblock=0 h_name="" h_dir="" h_src="" h_dest="" created="" mode=append delflag="" guard=""
    local f_user="" f_ip="" nrsync=0 rline="" first
    _import_why=""
    [[ -f "$sp" ]] || { _import_why="script not found"; return 1; }
    while IFS= read -r line; do
        if (( inblock )); then
            case $line in
                '# <<< copy mode'*) inblock=0 ;;
                MODE=*)    mode=${line#MODE=} ;;
                DELFLAG=*) delflag=${line#DELFLAG=} ;;
                '_mirror_guard '*' || {')
                    _sync_tokenize "${line% || \{}" || { _import_why="unusual guard line ($_tok_why)"; return 1; }
                    guard="${_tok[1]} ${_tok[2]}" ;;
            esac
            continue
        fi
        case $line in
            '')                    ;;
            '#!'*)                 ;;
            '# >>> copy mode'*)    inblock=1 ;;
            '# Sync job: '*)       h_name=${line#'# Sync job: '} ;;
            '# Direction: '*)      h_dir=${line#'# Direction: '} ;;
            '# Source: '*)         h_src=${line#'# Source: '} ;;
            '# Destination: '*)    h_dest=${line#'# Destination: '} ;;
            '# Created: '*)        created=${line#'# Created: '} ;;
            '#'*)                  ;;
            'exec >>"'*)
                [[ "$line" == "exec >>\"$HOME/.local/share/sync-jobs/$name.log\" 2>&1" ]] \
                    || { _import_why="a log path other than the standard one"; return 1; } ;;
            'SERVER_USER="'*)      f_user=${line#'SERVER_USER="'}; f_user=${f_user%'"'} ;;
            'SERVER_IP="'*)        f_ip=${line#'SERVER_IP="'}; f_ip=${f_ip%'"'} ;;
            'echo "[$(date '*'] Starting sync: '*) ;;
            'echo "[$(date '*'] Sync finished: '*) ;;
            'rc=$?'|'exit $rc'|'exit $?') ;;
            'rsync '*)             nrsync=$((nrsync + 1)); rline=$line ;;
            'ssh -t '*'sudo mkdir -p '*|'sudo mkdir -p '*) ;;   # the old sudo prep of the destination
            *rsync*)               first=${line%% *}; _import_why="rsync is run through another command ($first)"; return 1 ;;
            *)                     _import_why="a line this tool did not write: ${line:0:40}"; return 1 ;;
        esac
    done < <(tr -d '\r' < "$sp")
    (( inblock )) && { _import_why="an unclosed copy-mode block"; return 1; }
    (( nrsync == 1 )) || { _import_why="$([[ $nrsync == 0 ]] && echo 'no rsync line' || echo 'more than one rsync line')"; return 1; }
    [[ -n "$h_name" ]] || { _import_why="missing header: Sync job"; return 1; }
    [[ -n "$h_dir" ]]  || { _import_why="missing header: Direction"; return 1; }
    [[ -n "$h_src" ]]  || { _import_why="missing header: Source"; return 1; }
    [[ -n "$h_dest" ]] || { _import_why="missing header: Destination"; return 1; }
    [[ "$h_name" == "$name" ]] || { _import_why="the header names a different job ($h_name)"; return 1; }
    [[ "$h_dir" == upload || "$h_dir" == download ]] || { _import_why="unknown direction '$h_dir'"; return 1; }
    [[ "$mode" == append || "$mode" == mirror ]] || { _import_why="unknown MODE '$mode'"; return 1; }

    _sync_tokenize "$rline" || { _import_why="unusual rsync line ($_tok_why)"; return 1; }
    local -a ops=(); local t has_del=""
    for t in "${_tok[@]:1}"; do
        case $t in
            '$DELFLAG') has_del=1 ;;
            -avh|--progress|-s) ;;
            -*) _import_why="unknown rsync flag $t"; return 1 ;;
            *)  ops+=("$t") ;;
        esac
    done
    (( ${#ops[@]} == 2 )) || { _import_why="the rsync line does not have exactly one source and one destination"; return 1; }
    if [[ "$mode" == mirror ]]; then
        [[ -n "$has_del" && "$delflag" == --delete ]] || { _import_why="the mode says mirror but the rsync line does not delete"; return 1; }
    else
        [[ -z "$delflag" ]] || { _import_why="the mode says append but DELFLAG deletes"; return 1; }
    fi
    # operands -> source, destination, copy mode; the remote side must be user@host:path
    local o_src=${ops[0]} o_dst=${ops[1]} src dest cm host
    if [[ "$h_dir" == upload ]]; then
        host=${o_dst%%:*}; [[ "$o_dst" == *:* && "$host" == *@* ]] || { _import_why="the destination is not user@host:path"; return 1; }
        dest=${o_dst#*:}; src=$o_src
        [[ "$o_src" == */ ]] && cm=contents || cm=folder
    else
        host=${o_src%%:*}; [[ "$o_src" == *:* && "$host" == *@* ]] || { _import_why="the source is not user@host:path"; return 1; }
        src=${o_src#*:}; dest=$o_dst
        [[ "$src" == */ ]] && cm=contents || cm=folder
    fi
    if [[ -n "$f_user$f_ip" && "$host" != "$f_user@$f_ip" ]]; then _import_why="the rsync host ($host) differs from SERVER_USER@SERVER_IP in the script"; return 1; fi
    src=${src%/}; dest=${dest%/}
    [[ -n "$src" && -n "$dest" ]] || { _import_why="an empty source or destination"; return 1; }
    [[ "${h_src%/}" == "$src" ]] || { _import_why="the header Source ($h_src) and the rsync line ($src) disagree"; return 1; }
    local shown=$dest; [[ "$cm" == folder ]] && shown=$dest/${src##*/}
    [[ "${h_dest%/}" == "$shown" ]] || { _import_why="the header Destination ($h_dest) and the rsync line ($shown) disagree"; return 1; }
    if [[ "$mode" == mirror ]]; then
        local want="local"; [[ "$h_dir" == download ]] && want=server
        [[ "$guard" == "$want $src" ]] || { _import_why="the mirror guard does not match the source"; return 1; }
    fi
    # everything maps: write the record, keep the old script, then swap in the launcher
    J_name=$name; J_direction=$h_dir; J_src=$src; J_dest=$dest; J_copy_mode=$cm; J_mode=$mode
    if [[ "$h_dir" == upload ]]; then J_src_loc=local; J_dest_loc=server; else J_src_loc=server; J_dest_loc=local; fi
    J_sched_kind=$kind; J_sched=$sched; J_created=${created:-converted}
    local bak="$sp.bak" n=1
    while [[ -e "$bak" ]]; do n=$((n + 1)); bak="$sp.bak$n"; done
    _sync_rec_write || { _import_why="could not write the job record"; return 1; }
    if ! cp -p "$sp" "$bak" || ! _sync_write_launcher "$name"; then
        rm -f "$HOME/.local/share/sync-jobs/$name.job"
        _import_why="could not write the launcher (old script untouched)"; return 1
    fi
    info "Converted '$name' to a launcher (old script kept as $bak)."
}

# Convert every scheduled job that still has an old script and no record. Called when
# Status opens. Jobs that cannot be converted are left as they are; _sync_cannot[name]
# holds why, for the Status row.
_sync_import_all_legacy() {
    declare -gA _sync_cannot=()
    local i name
    _sync_registry_load
    for i in "${!_sync_jobs[@]}"; do
        name=${_sync_jobs[i]}
        [[ -f "$HOME/.local/share/sync-jobs/$name.job" || ! -f "$HOME/.local/bin/sync-$name.sh" ]] && continue
        _sync_job_import_legacy "$name" "${_sync_job_types[i]}" "${_sync_job_scheds[i]}" || _sync_cannot[$name]=$_import_why
    done
}

# Status cell for a copy mode, padded to 8: mirror = red (it deletes), append
# plain, anything else (a monitor) "-".
_sync_mode_cell() {
    case "$1" in
        mirror) printf '%b%-8s%b' "$RED" mirror "$NC" ;;
        append) printf '%-8s' append ;;
        *)      printf '%-8s' "-" ;;
    esac
}

# The "last: ..." text of a job (Status rows and Last runs): ok green, skipped yellow, failed red.
_sync_result_text() {  # job_name -> the coloured "last: ..." text of its last run
    local kind when exitc
    IFS='|' read -r kind when exitc <<<"$(_sync_last_result "$HOME/.local/share/sync-jobs/$1.log")"
    case "$kind" in
        ok)      echo -e "${GREEN}last: ok${NC}" ;;
        vanished) echo -e "${GREEN}last: ok (some files vanished)${NC}" ;;
        skipped) echo -e "${YELLOW}last: skipped${exitc:+ ($exitc)}${NC}" ;;
        fail)    echo -e "${RED}last: failed (exit ${exitc})${NC}" ;;
        running) echo -e "${YELLOW}last: running?${NC}" ;;
        *)       echo -e "${DIM}last: never${NC}" ;;
    esac
}
# Last result of a sync job from its log: "kind|when|exit", kind = ok | vanished (ok,
# rsync 24) | fail | skipped (the mirror guard or the wipe cap refused; the third field
# is its reason) | running (started, no finish line) | never.
_sync_last_result() {  # log_path
    local l when exitc
    [[ -f "$1" ]] || { echo "never||"; return 0; }
    l=$(grep -E 'Sync finished|: SKIPPED ' "$1" 2>/dev/null | tail -n 1) || l=""
    if [[ -z "$l" ]]; then
        when=$(date -d "@$(stat -c %Y "$1")" '+%Y-%m-%d %H:%M' 2>/dev/null) || when="?"
        echo "running|${when}|"; return 0
    fi
    if [[ "$l" == *": SKIPPED "* ]]; then
        exitc=${l#*: SKIPPED }; exitc=${exitc#* - }            # the reason, without the job name
        exitc=${exitc% (mirror refused, nothing deleted)}; exitc=${exitc%, nothing deleted}
        echo "skipped|${l:0:16}|${exitc}"; return 0
    fi
    when=$(grep -oP '\[\K[^\]]+' <<<"$l" | cut -c1-16) || when="?"
    exitc=$(grep -oP 'exit \K[0-9]+' <<<"$l") || exitc=""
    if [[ "$exitc" == 0 && "$l" == *"some files vanished"* ]]; then echo "vanished|${when}|0"
    elif [[ "$exitc" == 0 ]]; then echo "ok|${when}|0"
    else echo "fail|${when}|${exitc}"; fi
}

# 14 → 3 → Change copy mode.
_sync_change_mode() {  # job_name
    local job=$1
    if ! _sync_rec_load "$job"; then
        fail "'$job' has no job record (an old script that could not be converted - see Status). Copy mode not changed."
        return 1
    fi
    echo ""
    info "Current copy mode: $J_mode"
    _mirror_ask
    if [[ "$sync_mode" == mirror ]]; then
        _sync_job_operands
        _mirror_preview "$J_src_loc" "$J_src" "$_sj_shown" "$(_mirror_dry_cmd "$_sj_cmd")" save || return 2
    fi
    J_mode=$sync_mode
    _sync_rec_write || return 1
    ok "'${job}' is now ${sync_mode}."
}
# Make the destination folder before a job's first run, as the user at the keyboard:
# sudo is fine here (it asks), unlike in the unattended run, which only does mkdir -p.
# A failure is only a warning: the run reports what is really wrong.
_sync_prepare_dest() {  # uses the loaded J_* record and _sj_shown
    if [[ "$J_direction" == upload ]]; then
        ssh -t "$SERVER_USER@$SERVER_IP" "sudo mkdir -p $(_shq "$_sj_shown") && sudo chown $(_shq "$SERVER_USER:$SERVER_USER") $(_shq "$_sj_shown")" \
            || warn "Could not prepare $_sj_shown on the server as root."
    else
        sudo mkdir -p "$_sj_shown" || warn "Could not prepare $_sj_shown."
    fi
}

# Run a sync once now, or schedule it as a recurring job.
#   direction upload|download, src = the picked source path, dest = the picked
#   destination folder, copy_mode folder|contents, mode append|mirror (from _mirror_ask).
_sync_execute_or_schedule() {
    local direction="$1" src="$2" dest="$3" copy_mode="$4" mode="${5:-append}"
    J_name=""; J_direction=$direction; J_src=$src; J_dest=$dest; J_copy_mode=$copy_mode; J_mode=$mode
    J_sched_kind=""; J_sched=""; J_created=$(date '+%Y-%m-%d %H:%M')
    if [[ "$direction" == upload ]]; then J_src_loc=local; J_dest_loc=server; else J_src_loc=server; J_dest_loc=local; fi
    _sync_job_operands
    local dry_cmd=""
    [[ "$mode" == mirror ]] && dry_cmd=$(_mirror_dry_cmd "$_sj_cmd")

    echo ""
    echo -e "  ${BOLD}1)${NC} Run now"
    echo -e "  ${BOLD}2)${NC} Schedule as recurring job"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choice [1/2/0]: " action
    case $action in
        0) return 2 ;;
        1)
            if [[ "$mode" == mirror ]]; then
                _mirror_preview "$J_src_loc" "$src" "$_sj_shown" "$dry_cmd" copy || return 2
                # Run now has no summary box: the deletion question is the one question.
                (( _mirror_n > 0 )) && { _mirror_delete_q copy || return 2; }
            fi
            _sync_prepare_dest
            J_name=${src%/}; J_name=${J_name##*/}
            _sync_job_go nocap || { fail "Sync failed."; return 1; }
            echo ""
            if [[ "$mode" == mirror ]]; then
                ok "Mirror complete - ${_mirror_n} deleted, destination matches source."
            else
                ok "Sync complete."
            fi
            ;;
        2)
            local sched_out sched_kind sched_spec job_name reason
            sched_out=$(_sync_pick_schedule) || return 1
            sched_kind="${sched_out%% *}"
            sched_spec="${sched_out#* }"

            local default_name
            default_name=$(_sync_default_name "$src")
            while :; do
                read -p "  Name for this job [${default_name}, q=back]: " job_name || return 1
                [[ "$job_name" == "q" ]] && return
                job_name="${job_name:-$default_name}"
                job_name=${job_name,,}; job_name=${job_name// /-}
                if ! reason=$(_sync_valid_name "$job_name"); then fail "$reason"; continue; fi
                if [[ -e "$HOME/.local/bin/sync-${job_name}.sh" || -e "$HOME/.local/share/sync-jobs/${job_name}.job" ]]; then
                    fail "A job named '${job_name}' already exists - pick another name (or delete it first)."; continue
                fi
                break
            done

            if [[ "$mode" == mirror ]]; then
                _mirror_preview "$J_src_loc" "$src" "$_sj_shown" "$dry_cmd" save || return 2
            fi

            local script_path="$HOME/.local/bin/sync-${job_name}.sh"
            local log_path="$HOME/.local/share/sync-jobs/${job_name}.log"
            J_name=$job_name; J_sched_kind=$sched_kind; J_sched=$sched_spec
            _sync_rec_write || return 1
            _sync_write_launcher "$job_name" || { fail "Could not write the launcher $script_path."; return 1; }

            if [[ "$sched_kind" == "timer" ]]; then
                _sync_install_timer "$job_name" "$script_path" "$sched_spec"
                ok "Scheduled sync job '${job_name}' (systemd timer)"
                info "Timer:  ~/.config/systemd/user/sync-${job_name}.timer"
                info "Script: $script_path"
                info "Log:    $log_path"
                info "Schedule: weekly (${sched_spec}), catches missed runs"
            else
                _cron_add_sync "$job_name" "$sched_spec" "$script_path" || return 1
                ok "Scheduled sync job '${job_name}' (cron)"
                info "Script: $script_path"
                info "Log:    $log_path"
                info "Schedule: $sched_spec"
            fi
            echo ""
            info "Running once now to verify..."
            _sync_prepare_dest
            local run_rc=0
            _sync_job_run "$job_name" nocap 2>&1 | tee -a "$log_path"; run_rc=${PIPESTATUS[0]}
            (( run_rc == 0 )) || { fail "Sync failed on initial run."; return 1; }
            echo ""
            ok "Initial sync complete. Job scheduled."
            ;;
        *)
            fail "Invalid choice."
            return 1
            ;;
    esac
}

# Translate a 5-field cron expression into short plain English.
_cron_to_english() {
    local expr="$1"
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "$expr"

    # Helper: translate hour to human time
    _hour_str() {
        local h="$1"
        if (( h == 0 )); then echo "midnight"
        elif (( h < 12 )); then echo "${h}am"
        elif (( h == 12 )); then echo "noon"
        else echo "$((h-12))pm"
        fi
    }

    # Helper: translate day-of-week number to name
    _dow_str() {
        case "$1" in
            0|7) echo "Sunday" ;; 1) echo "Monday" ;; 2) echo "Tuesday" ;;
            3) echo "Wednesday" ;; 4) echo "Thursday" ;; 5) echo "Friday" ;;
            6) echo "Saturday" ;; *) echo "day $1" ;;
        esac
    }

    # Simple interval patterns
    case "$expr" in
        "* * * * *")     echo "every minute"; return ;;
        "*/5 * * * *")   echo "every 5 min"; return ;;
        "*/10 * * * *")  echo "every 10 min"; return ;;
        "*/15 * * * *")  echo "every 15 min"; return ;;
        "*/30 * * * *")  echo "every 30 min"; return ;;
        "0 * * * *")     echo "every hour"; return ;;
        "0 */2 * * *")   echo "every 2 hours"; return ;;
        "0 */3 * * *")   echo "every 3 hours"; return ;;
        "0 */6 * * *")   echo "every 6 hours"; return ;;
        "0 */12 * * *")  echo "every 12 hours"; return ;;
    esac

    # Daily at a specific hour (no day-of-week restriction)
    if [[ "$min" == "0" && "$hour" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "daily at $(_hour_str "$hour")"; return
    fi

    # Weekly: specific day-of-week at a specific hour
    if [[ "$min" == "0" && "$hour" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" =~ ^[0-7]$ ]]; then
        echo "every $(_dow_str "$dow") at $(_hour_str "$hour")"; return
    fi

    # Comma-separated hours (e.g. 0 9,18 * * *)
    if [[ "$min" == "0" && "$hour" == *,* && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        local times=""
        IFS=',' read -ra hrs <<< "$hour"
        for h in "${hrs[@]}"; do
            [[ -n "$times" ]] && times+=", "
            times+="$(_hour_str "$h")"
        done
        echo "daily at $times"; return
    fi

    # Fallback: return the raw expression
    echo "$expr"
}

# Prompt the user for a schedule. Echoes one of the following to stdout:
#   cron <5-field expression>
#   timer <OnCalendar spec>         (jitter is always 6h, applied at install)
# All UI goes to stderr so callers can capture the result cleanly.
_sync_pick_schedule() {
    {
        echo ""
        echo -e "  ${BOLD}Schedule:${NC}"
        echo ""
        echo -e "    ${BOLD}1)${NC} Every hour"
        echo -e "    ${BOLD}2)${NC} Every 6 hours"
        echo -e "    ${BOLD}3)${NC} Daily at 2am"
        echo -e "    ${BOLD}4)${NC} Once a week, any time   ${DIM}(systemd timer, catches missed runs)${NC}"
        echo -e "    ${BOLD}5)${NC} Custom cron expression"
        echo -e "    ${BOLD}0)${NC} Back"
        echo ""
    } >&2
    local sched_choice schedule
    read -p "  Schedule [0-5]: " sched_choice >&2
    [[ -z "$sched_choice" || "$sched_choice" == "0" ]] && return 1
    case $sched_choice in
        1) echo "cron 0 * * * *"; return ;;
        2) echo "cron 0 */6 * * *"; return ;;
        3) echo "cron 0 2 * * *"; return ;;
        4)
            {
                echo ""
                echo -e "  ${BOLD}Which day?${NC}"
                echo ""
                echo -e "    ${BOLD}1)${NC} Saturday"
                echo -e "    ${BOLD}2)${NC} Sunday"
                echo -e "    ${BOLD}3)${NC} Any day this week"
                echo -e "    ${BOLD}0)${NC} Back"
                echo ""
            } >&2
            local day_choice oncal
            read -p "  Day [0-3]: " day_choice >&2
            [[ -z "$day_choice" || "$day_choice" == "0" ]] && return 1
            case $day_choice in
                1) oncal="Sat" ;;
                2) oncal="Sun" ;;
                3) oncal="weekly" ;;
                *) fail "Invalid choice." >&2; return 1 ;;
            esac
            echo "timer ${oncal}"
            return
            ;;
        5)
            {
                echo ""
                echo -e "  ${DIM}Cron format: 5 fields separated by spaces${NC}"
                echo -e "  ${DIM}┌───── minute (0-59)${NC}"
                echo -e "  ${DIM}│ ┌───── hour (0-23)${NC}"
                echo -e "  ${DIM}│ │ ┌───── day of month (1-31)${NC}"
                echo -e "  ${DIM}│ │ │ ┌───── month (1-12)${NC}"
                echo -e "  ${DIM}│ │ │ │ ┌───── day of week (0-6, Sun=0)${NC}"
                echo -e "  ${DIM}│ │ │ │ │${NC}"
                echo -e "  ${DIM}* * * * *    * = every, /N = every N, number = at exactly${NC}"
                echo ""
                echo -e "  ${DIM}Examples: */30 * * * * = every 30 min${NC}"
                echo -e "  ${DIM}          0 9,18 * * * = twice a day at 9am and 6pm${NC}"
                echo -e "  ${DIM}          0 2 * * 1    = every Monday at 2am${NC}"
                echo ""
            } >&2
            local attempts=0
            while (( attempts < 3 )); do
                read -p "  Cron expression: " schedule >&2
                if [[ -z "$schedule" ]]; then
                    fail "Empty schedule. Aborting." >&2
                    return 1
                fi
                local human
                human=$(_cron_to_english "$schedule")
                echo "" >&2
                echo -e "  That means: ${BOLD}$human${NC}" >&2
                read -p "  Correct? [Y/n] " -n 1 -r >&2; echo "" >&2
                [[ ! "$REPLY" =~ ^[Nn]$ ]] && break
                attempts=$((attempts + 1))
                if (( attempts >= 3 )); then
                    fail "3 attempts. Aborting." >&2
                    return 1
                fi
                echo "" >&2
                info "Try again:" >&2
            done
            ;;
        *) fail "Invalid choice." >&2; return 1 ;;
    esac
    echo "cron $schedule"
}

# Install (or rewrite) a systemd --user timer for a sync job.
#   $1 = job name        (e.g. photos)
#   $2 = script path     (e.g. $HOME/.local/bin/sync-photos.sh)
#   $3 = OnCalendar spec (e.g. "Sat", "Sun", "weekly")
_sync_install_timer() {
    local job_name="$1" script_path="$2" oncal="$3"
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"

    cat > "$unit_dir/sync-${job_name}.service" <<UNIT
[Unit]
Description=Sync job: ${job_name}

[Service]
Type=oneshot
ExecStart=${script_path}
UNIT

    cat > "$unit_dir/sync-${job_name}.timer" <<UNIT
[Unit]
Description=Sync job timer: ${job_name}

[Timer]
OnCalendar=${oncal}
Persistent=true
RandomizedDelaySec=6h

[Install]
WantedBy=timers.target
UNIT

    # Ensure user services run when logged out. Idempotent.
    loginctl enable-linger "$USER" >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    systemctl --user enable --now "sync-${job_name}.timer" >/dev/null
}

# Remove a systemd --user timer + service for a sync job.
_sync_remove_timer() {
    local job_name="$1"
    local unit_dir="$HOME/.config/systemd/user"
    systemctl --user disable --now "sync-${job_name}.timer" >/dev/null 2>&1 || true
    rm -f "$unit_dir/sync-${job_name}.service" "$unit_dir/sync-${job_name}.timer"
    systemctl --user daemon-reload
}

_sync_edit_job() {
    echo ""
    echo -e "  ${BOLD}Edit a sync job${NC}"
    echo ""

    if ! _sync_list_jobs; then
        info "No sync jobs to edit."
        return
    fi

    echo ""
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Pick a job [number]: " pick
    [[ -z "$pick" || "$pick" == "0" ]] && return
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi

    local i=$((pick-1))
    local job_name="${_sync_jobs[i]}"
    local old_line="${_sync_job_lines[i]}"
    local job_type="${_sync_job_types[i]}"
    local sched="${_sync_job_scheds[i]}" is_paused=false human
    [[ -n "${_sync_job_paused[i]}" ]] && is_paused=true
    if [[ "$job_type" == "cron" ]]; then
        human=$(_cron_to_english "$sched")
    else
        human="weekly (${sched}), catches missed runs"
    fi

    echo ""
    echo -e "  ${BOLD}${job_name}${NC}  [${sched}] — ${human}  ${DIM}(${job_type})${NC}$($is_paused && echo " ${YELLOW}(paused)${NC}")  $(_sync_mode_cell "$(_sync_rec_mode "$job_name")")"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "    ${BOLD}1)${NC} Change schedule"
    if $is_paused; then
        echo -e "    ${BOLD}2)${NC} Resume"
    else
        echo -e "    ${BOLD}2)${NC} Pause"
    fi
    echo -e "    ${BOLD}3)${NC} Run now"
    echo -e "    ${BOLD}4)${NC} View last log"
    echo -e "    ${BOLD}5)${NC} Delete"
    echo -e "    ${BOLD}6)${NC} Change copy mode"
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choice [0-6]: " action
    case $action in
        1) _sync_change_schedule "$job_name" "$old_line" "$job_type" ;;
        2)
            if [[ "$job_type" == "cron" ]]; then
                local new_line
                if $is_paused; then
                    new_line=${old_line#'#PAUSED#'}
                    _cron_replace_line "$old_line" "$new_line" || return 1
                    ok "Resumed '${job_name}'"
                else
                    new_line="#PAUSED#${old_line}"
                    _cron_replace_line "$old_line" "$new_line" || return 1
                    ok "Paused '${job_name}'"
                fi
            else
                if $is_paused; then
                    systemctl --user enable --now "sync-${job_name}.timer" >/dev/null
                    ok "Resumed '${job_name}'"
                else
                    systemctl --user disable --now "sync-${job_name}.timer" >/dev/null
                    ok "Paused '${job_name}'"
                fi
            fi
            ;;
        3)
            local script_path="$HOME/.local/bin/sync-${job_name}.sh"
            if [[ ! -x "$script_path" ]]; then
                fail "Script not found: $script_path"
                return
            fi
            echo ""
            info "Running ${job_name}..."
            if [[ "$job_type" == "timer" ]]; then
                systemctl --user start "sync-${job_name}.service" || { fail "Service failed."; return; }
            else
                bash "$script_path" || { fail "Sync job failed."; return; }
            fi
            ok "'${job_name}' completed."
            echo -e "  $(_sync_result_text "$job_name")"
            ;;
        4)
            local log_path="$HOME/.local/share/sync-jobs/${job_name}.log"
            if [[ ! -f "$log_path" ]]; then
                if [[ "$job_type" == "timer" ]]; then
                    echo ""
                    echo -e "  ${DIM}Journal for sync-${job_name}.service:${NC}"
                    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                    journalctl --user -u "sync-${job_name}.service" -n 30 --no-pager 2>/dev/null | sed 's/^/  /'
                else
                    info "No log yet at $log_path"
                fi
                return
            fi
            echo ""
            echo -e "  ${DIM}Last 30 lines of ${log_path}:${NC}"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            tail -n 30 "$log_path" | sed 's/^/  /'
            ;;
        5) _sync_job_delete "$job_name" "$job_type" "$old_line" ;;
        6) _sync_change_mode "$job_name" ;;
        0) return ;;
        *) fail "Invalid choice." ;;
    esac
}

# Keep the job's record in step with a schedule change (an unconverted old job has none).
_sync_rec_set_schedule() {  # name kind spec
    _sync_rec_load "$1" || return 0
    J_sched_kind=$2; J_sched=$3
    _sync_rec_write
}

_sync_change_schedule() {
    local job_name="$1" old_line="$2" old_type="$3"
    local sched_out sched_kind sched_spec msg
    sched_out=$(_sync_pick_schedule) || return 1
    sched_kind="${sched_out%% *}"
    sched_spec="${sched_out#* }"

    local script_path="$HOME/.local/bin/sync-${job_name}.sh"

    if [[ "$sched_kind" == "timer" ]]; then
        # cron → timer tears the cron line down first; timer → timer just reinstalls.
        if [[ "$old_type" == "cron" ]]; then _cron_remove_line "$old_line" || return 1; fi
        _sync_install_timer "$job_name" "$script_path" "$sched_spec"
        msg="timer (${sched_spec})"
    elif [[ "$old_type" == "timer" ]]; then
        _sync_remove_timer "$job_name"
        _cron_add_sync "$job_name" "$sched_spec" "$script_path" || return 1
        msg=$(_cron_to_english "$sched_spec")
    else
        # Cron → cron: preserve the #PAUSED# prefix and the command field.
        _sync_cron_split "$old_line"
        local prefix="" rest=$_cs_cmd
        [[ -n "$_cs_paused" ]] && prefix="#PAUSED#"
        _cron_replace_line "$old_line" "${prefix}${sched_spec} ${rest}" || return 1
        msg=$(_cron_to_english "$sched_spec")
    fi
    _sync_rec_set_schedule "$job_name" "$sched_kind" "$sched_spec" || return 1
    ok "Schedule updated for '${job_name}' → ${msg}"
}
_sync_show_status() {
    # Fetch server-side crons FIRST (may prompt for sudo password) so the
    # password prompt appears before any table rendering.
    local server_crons="" server_timer_oncal=""
    # cron_known: did we really read root's crontab? (An empty crontab is a valid
    # read; a failed read is "unknown", never "not scheduled".)
    local cron_known=false server_scripts=""
    info "Fetching server scheduled tasks..."
    local pw_rc=0
    _server_sudo_pw_prompt || pw_rc=$?
    if (( pw_rc == 0 )); then
        # crontab -l exits 1 when root simply has no crontab, so success is
        # signalled by the trailing marker (the script ran to the end), not the
        # exit code. No marker = the read failed.
        server_crons=$(_server_sudo_run 'crontab -l 2>/dev/null; echo __CRON_READ_OK__') || true
        unset _SRV_PW
        if [[ "$server_crons" == *__CRON_READ_OK__ ]]; then
            cron_known=true
            server_crons="${server_crons%__CRON_READ_OK__}"
        else
            server_crons=""
            warn "Could not read root's crontab - schedules below are shown as unknown."
        fi
    elif (( pw_rc == 2 )); then
        warn "Server unreachable - root crontab not read; the schedule list below is incomplete."
    else
        warn "Wrong sudo password - root crontab not read; the schedule list below may be incomplete (not 'no cron')."
    fi
    # Which scripts exist (never used to invent a schedule - only to show a row
    # for them when the crontab could not be read or has no line for them).
    server_scripts=$(ssh "$SERVER_USER@$SERVER_IP" '
        [[ -x /usr/local/bin/immich-backup.sh ]] && echo immich-backup
        [[ -e /usr/local/bin/disk-check.sh ]]    && echo disk-check  # root 0700: -e, not -x
        true
    ' 2>/dev/null) || server_scripts=""
    # immich-backup migrated from cron to systemd timer (federver → 14 → 6).
    # If the timer is present, prefer its OnCalendar over any legacy cron line.
    # Read OnCalendar via `systemctl cat` — `systemctl show -p OnCalendar` is
    # always empty (it isn't a show property), which is why this used to blank.
    server_timer_oncal=$(ssh "$SERVER_USER@$SERVER_IP" 'systemctl cat immich-backup.timer 2>/dev/null | sed -n "s/^OnCalendar=//p" | head -1') || server_timer_oncal=""

    _sync_import_all_legacy
    echo ""
    echo -e "  ${BOLD}Scheduled tasks${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  ${BOLD}%-20s %-18s %-16s %-10s %-8s %s${NC}\n" "Name" "Schedule" "When" "Type" "Copy" "Note"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Render immich-backup from systemd timer if available, else fall back
    # to the legacy cron line.
    if [[ -n "$server_timer_oncal" ]]; then
        printf "  %-20s %-18s %-16s %-10s %-8s %s\n" "immich-backup" "$server_timer_oncal" "systemd" "backup" "append" "(14 → 6)"
    fi
    if [[ -n "$server_crons" ]]; then
        echo "$server_crons" | while IFS= read -r line; do
            [[ "$line" =~ ^#|^$ ]] && continue
            if echo "$line" | grep -q "immich-backup" && [[ -z "$server_timer_oncal" ]]; then
                local sched when
                sched=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                when=$(_cron_to_english "$sched")
                printf "  %-20s %-18s %-16s %-10s %-8s %s\n" "immich-backup" "$sched" "$when" "backup" "append" "(14 → 6, legacy cron)"
            elif echo "$line" | grep -q "disk-check"; then
                local sched when
                sched=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                when=$(_cron_to_english "$sched")
                printf "  %-20s %-18s %-16s %-10s %-8s %s\n" "disk-check" "$sched" "$when" "monitor" "-" "(14 → 7)"
            fi
        done
    fi
    # Scripts installed but with no real cron line: say so, don't invent one.
    local _n
    for _n in immich-backup disk-check; do
        grep -qx "$_n" <<<"$server_scripts" || continue
        if [[ "$_n" == immich-backup ]]; then
            [[ -n "$server_timer_oncal" ]] && continue
            grep -q "immich-backup" <<<"$server_crons" && continue
        else
            grep -q "disk-check" <<<"$server_crons" && continue
        fi
        local _hint="14 → 7"; [[ "$_n" == immich-backup ]] && _hint="14 → 6"
        if $cron_known; then
            echo -e "  ${YELLOW}$(printf '%-20s %-18s' "$_n" "not scheduled")${NC} reinstall via $_hint"
        else
            echo -e "  ${YELLOW}$(printf '%-20s %-18s' "$_n" "schedule unknown")${NC} root crontab not read"
        fi
    done

    # Laptop-side sync jobs: cron lines and systemd --user timers, one registry
    local i name sched when direction mode tag script_path
    _sync_registry_load
    for i in "${!_sync_jobs[@]}"; do
        name=${_sync_jobs[i]}; sched=${_sync_job_scheds[i]}
        script_path="$HOME/.local/bin/sync-${name}.sh"
        if _sync_rec_load "$name"; then direction=$J_direction; mode=$J_mode; else direction=sync; mode=-; fi
        if [[ "${_sync_job_types[i]}" == cron ]]; then
            when=$(_cron_to_english "$sched"); tag=""
            [[ -n "${_sync_job_paused[i]}" ]] && tag="${YELLOW}(paused)${NC}"
        else
            when="weekly"; tag="${DIM}timer${NC}"
            [[ -n "${_sync_job_paused[i]}" ]] && tag="${YELLOW}(paused)${NC}"
        fi
        printf "  %-20s %-18s %-16s %-10s " "$name" "$sched" "$when" "$direction"
        echo -e "$(_sync_mode_cell "$mode") $(_sync_result_text "$name") $tag"
        if [[ -n "${_sync_cannot[$name]+x}" ]]; then
            echo -e "  ${YELLOW}  cannot convert: ${_sync_cannot[$name]}${NC} ${DIM}($script_path)${NC}"
        fi
    done

    # Check outside subshells (pipe subshells can't propagate state)
    local has_server=false has_laptop=false
    [[ -n "$server_timer_oncal" ]] && has_server=true
    [[ -n "$server_crons" ]] && echo "$server_crons" | grep -qE "immich-backup|disk-check" && has_server=true
    [[ -n "$server_scripts" ]] && has_server=true
    (( ${#_sync_jobs[@]} > 0 )) && has_laptop=true
    if [[ "$has_server" == "false" && "$has_laptop" == "false" ]]; then
        echo ""
        info "No scheduled tasks found."
        echo ""
        return
    fi

    # ── Last runs ──
    # Server jobs: one SSH call (sudo cached above) reads mtime + last line of
    # each known log. Laptop jobs: parse the "Sync finished" marker the script
    # emits at exit (see _sync_show_paths/sync script template).
    local server_runs=""
    if [[ "$has_server" == "true" ]]; then
        # Logs are root-owned but mode 644 (default cron-redirect umask), so
        # the unprivileged SSH user can read them. Avoid sudo here — this SSH
        # has no tty, so sudo would silently fail and every row would render
        # as "never" (false negative, masks real failures).
        server_runs=$(ssh "$SERVER_USER@$SERVER_IP" '
            f=/var/log/immich-backup.log
            if [[ -r "$f" && -s "$f" ]]; then
                printf "immich-backup|%s||%s\n" "$(stat -c "%y" "$f" | cut -c1-16)" "$(tail -n 1 "$f")"
            else
                printf "immich-backup|never||\n"
            fi
            # disk-check: state file "<YYYY-MM-DD HH:MM> ok|ALERT <msg>" (rewritten each run).
            f=/var/log/disk-check.last
            if [[ -r "$f" && -s "$f" ]]; then
                l=$(head -n 1 "$f")
                # Age in seconds, computed with the server clock for both ends.
                age=""
                if t=$(date -d "${l:0:16}" +%s 2>/dev/null); then age=$(( $(date +%s) - t )); fi
                printf "disk-check|%s|%s|%s\n" "${l:0:16}" "$age" "${l:17}"
            else
                printf "disk-check|never||\n"
            fi
        ' 2>/dev/null) || server_runs=""
    fi

    echo ""
    echo -e "  ${BOLD}Last runs${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  ${BOLD}%-20s %-20s %s${NC}\n" "Name" "Last run" "Status"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -n "$server_runs" ]]; then
        while IFS='|' read -r name when age last; do
            [[ -z "$name" ]] && continue
            local status
            if [[ "$name" == "disk-check" ]]; then
                # Read from the per-run state file (disk-check.last), not the
                # alert-only log. Missing = old script not yet reinstalled.
                if [[ "$when" == "never" ]]; then
                    when="—"
                    status="${DIM}no run recorded (reinstall via 14 → 7)${NC}"
                elif [[ "$age" =~ ^-?[0-9]+$ ]] && (( age > 720 )); then
                    # Cron runs every 5 min; >12 min old means it stopped running.
                    status="${YELLOW}⚠ stale (last ${when})${NC}"
                elif [[ "$last" == ok ]]; then
                    status="${GREEN}✓ ok${NC}"
                elif [[ "$last" == ALERT\ * ]]; then
                    status="${YELLOW}⚠ ${last#ALERT }${NC}"
                else
                    status="${YELLOW}? check /var/log/disk-check.last${NC}"
                fi
            elif [[ "$when" == "never" ]]; then
                status="${DIM}—${NC}"
            elif [[ "$name" == "immich-backup" ]]; then
                if echo "$last" | grep -q "Backup complete"; then
                    status="${GREEN}✓ ok${NC}"
                else
                    status="${YELLOW}? check log${NC}"
                fi
            else
                status="${DIM}—${NC}"
            fi
            printf "  %-20s %-20s " "$name" "$when"
            echo -e "$status"
        done <<<"$server_runs"
    fi

    # Laptop sync jobs (cron + timer share the same log file path).
    local log_dir="$HOME/.local/share/sync-jobs"
    if [[ -d "$log_dir" ]]; then
        local logf
        for logf in "$log_dir"/*.log; do
            [[ -f "$logf" ]] || continue
            local jname when kind exitc
            jname=$(basename "$logf" .log)
            IFS='|' read -r kind when exitc <<<"$(_sync_last_result "$logf")"
            printf "  %-20s %-20s " "$jname" "$when"
            echo -e "$(_sync_result_text "$jname")"
        done
    fi

    echo ""
}

# One crontab line split into _cs_paused ("1" for a #PAUSED# line), _cs_sched (its five
# schedule fields) and _cs_cmd (what it runs). The only place the #PAUSED# convention
# and the field layout are read; the registry and Change schedule both use it.
_sync_cron_split() {  # line
    local l=$1
    _cs_paused=""
    if [[ "$l" == '#PAUSED#'* ]]; then _cs_paused=1; l=${l#'#PAUSED#'}; fi
    _cs_sched=""; _cs_cmd=""
    [[ "$l" == '#'* ]] && return 0
    local a b c d e rest
    read -r a b c d e rest <<<"$l"
    _cs_sched="$a $b $c $d $e"; _cs_cmd=$rest
}

# Every laptop sync job (cron lines that run a sync-<name>.sh, plus systemd --user
# timers sync-<name>.timer) into parallel arrays, in list order: _sync_jobs (name),
# _sync_job_types (cron|timer), _sync_job_scheds (5 cron fields | OnCalendar spec),
# _sync_job_paused ("1" or ""), _sync_job_lines (the raw cron line | the OnCalendar
# spec). The name is the launcher's basename between "sync-" and ".sh" (parameter
# expansion, so a dot in a name is fine). List, Edit, Delete and Status read this.
_sync_registry_load() {
    _sync_jobs=(); _sync_job_types=(); _sync_job_scheds=(); _sync_job_paused=(); _sync_job_lines=()
    local line base name unit_dir="$HOME/.config/systemd/user" tf oncal
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _sync_cron_split "$line"
        [[ "$_cs_cmd" == */sync-*.sh ]] || continue
        base=${_cs_cmd##*/}; name=${base#sync-}; name=${name%.sh}
        _sync_jobs+=("$name"); _sync_job_types+=(cron); _sync_job_scheds+=("$_cs_sched")
        _sync_job_paused+=("$_cs_paused"); _sync_job_lines+=("$line")
    done <<< "$(crontab -l 2>/dev/null || true)"
    if [[ -d "$unit_dir" ]]; then
        for tf in "$unit_dir"/sync-*.timer; do
            [[ -f "$tf" ]] || continue
            base=${tf##*/}; name=${base#sync-}; name=${name%.timer}
            oncal=$(awk -F= '/^OnCalendar=/{print $2; exit}' "$tf")
            _sync_jobs+=("$name"); _sync_job_types+=(timer); _sync_job_scheds+=("$oncal"); _sync_job_lines+=("$oncal")
            if [[ "$(systemctl --user is-enabled "sync-${name}.timer" 2>/dev/null)" == enabled ]]; then
                _sync_job_paused+=("")
            else
                _sync_job_paused+=(1)
            fi
        done
    fi
}

# Print the numbered job list from the registry (a menu number is an array index + 1).
# rc 1 = no jobs.
_sync_list_jobs() {
    local i tag
    _sync_registry_load
    for i in "${!_sync_jobs[@]}"; do
        tag=""
        [[ -n "${_sync_job_paused[i]}" ]] && tag=" ${YELLOW}(paused)${NC}"
        echo -e "    ${BOLD}$((i + 1)))${NC} ${_sync_jobs[i]}  [${_sync_job_scheds[i]}]  ${DIM}${_sync_job_types[i]}${NC}${tag}"
    done
    (( ${#_sync_jobs[@]} > 0 ))
}

# Delete a job: typed confirm, then its cron line or timer, launcher/script, record and
# log. The one delete used by the Delete menu and by Edit -> Delete. rc 0 also when the
# user cancels (nothing removed); 1 = the cron line could not be removed.
_sync_job_delete() {  # name type line
    local name=$1 type=$2 line=$3
    echo ""
    _confirm_delete "sync-${name}" || return 0
    if [[ "$type" == cron ]]; then
        _cron_remove_line "$line" || return 1
    else
        _sync_remove_timer "$name"
    fi
    rm -f "$HOME/.local/bin/sync-${name}.sh" "$HOME/.local/share/sync-jobs/${name}.log" "$HOME/.local/share/sync-jobs/${name}.job"
    ok "Deleted sync job '${name}'"
}

_sync_delete_job() {
    echo ""
    echo -e "  ${BOLD}Delete a sync job${NC}"
    echo ""

    if ! _sync_list_jobs; then
        info "No sync jobs to delete."
        return
    fi

    echo ""
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Pick a job [number]: " pick
    [[ -z "$pick" || "$pick" == "0" ]] && return
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi
    _sync_job_delete "${_sync_jobs[$((pick-1))]}" "${_sync_job_types[$((pick-1))]}" "${_sync_job_lines[$((pick-1))]}"
}
# Path-picker helpers shared by step_sync (recurring sync jobs) and
# _sync_one_time_backup (ad-hoc rsync). Set globals: local_path, server_path,
# sources, copy_mode.
_list_local_sources() {
    echo ""
    echo -e "  ${BOLD}Laptop paths:${NC}"
    echo ""
    local i=1
    sources=()

    for mnt in "$HOME/Documents" "$HOME/Pictures" "$HOME/Downloads"; do
        if [[ -d "$mnt" ]]; then
            echo "    $i) $mnt"
            sources[$i]="$mnt"
            i=$((i + 1))
        fi
    done

    local usb_mounts=$(ls -d /run/media/"$USER"/*/ /media/"$USER"/*/ 2>/dev/null || true)
    if [[ -n "$usb_mounts" ]]; then
        echo ""
        echo -e "  ${BOLD}USB drives:${NC}"
        for mnt in $usb_mounts; do
            mnt="${mnt%/}"
            size=$(df -h "$mnt" | tail -1 | awk '{print $3 " used / " $2}')
            echo "    $i) $mnt  ($size)"
            sources[$i]="$mnt"
            i=$((i + 1))
        done
    fi

    echo ""
    info "Or type a path directly"
    echo ""
}

_pick_local_path() {
    local validate="$1"
    local show_presets="${2:-true}"
    local attempts=0
    while (( attempts < 3 )); do
        if [[ "$show_presets" == "true" ]]; then
            _list_local_sources
            read -p "  Choose [number, path, q=back]: " choice
            [[ "$choice" == "q" ]] && return 2
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local_path="${sources[$choice]}"
            else
                local_path="$choice"
            fi
        else
            read -p "  Absolute path [q=back]: " choice
            [[ "$choice" == "q" ]] && return 2
            local_path="$choice"
        fi

        local_path="${local_path//\'/}"
        local_path="${local_path//\"/}"
        local_path="${local_path%/}"
        if [[ -z "$local_path" ]]; then
            ((attempts++))
            (( attempts < 3 )) && fail "Empty path. Try again. ($((3-attempts)) attempts left)" || { fail "3 invalid attempts. Aborting."; return 1; }
            continue
        fi

        if [[ "$validate" == "true" ]]; then
            if [[ -e "$local_path" ]]; then
                echo ""
                echo -e "  ${BOLD}Contents of $local_path:${NC}"
                if [[ -d "$local_path" ]]; then ls "$local_path"; else echo "  $(basename "$local_path")"; fi
                break
            fi
            ((attempts++))
            (( attempts < 3 )) && fail "'$local_path' does not exist. Try again. ($((3-attempts)) attempts left)" || { fail "3 invalid attempts. Aborting."; return 1; }
        else
            break
        fi
    done
}

_pick_server_path() {
    local validate="$1"
    local show_presets="${2:-true}"
    if [[ "$show_presets" == "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Server paths:${NC}"
        echo "    1) /home/$SERVER_USER/data  (internal drive)"
        echo "    2) /mnt/data           (USB drive)"
        echo ""
        info "Or type a path directly (e.g. /mnt/data/media/My Music)"
        echo ""
    fi
    local attempts=0
    while (( attempts < 3 )); do
        if [[ "$show_presets" == "true" ]]; then
            read -p "  Choose [number, path, q=back]: " choice
            [[ "$choice" == "q" ]] && return 2
            case $choice in
                1) server_path="/home/$SERVER_USER/data" ;;
                2) server_path="/mnt/data" ;;
                *) server_path="$choice" ;;
            esac
        else
            read -p "  Absolute path [q=back]: " choice
            [[ "$choice" == "q" ]] && return 2
            server_path="$choice"
        fi

        server_path="${server_path//\'/}"
        server_path="${server_path//\"/}"
        server_path="${server_path%/}"
        if [[ -z "$server_path" ]]; then
            ((attempts++))
            (( attempts < 3 )) && fail "Empty path. Try again. ($((3-attempts)) attempts left)" || { fail "3 invalid attempts. Aborting."; return 1; }
            continue
        fi

        if [[ "$validate" == "true" ]]; then
            if ssh "$SERVER_USER@$SERVER_IP" "test -e $(_shq "$server_path")" 2>/dev/null; then
                echo ""
                echo -e "  ${BOLD}Contents of server:$server_path:${NC}"
                ssh "$SERVER_USER@$SERVER_IP" "if [ -d $(_shq "$server_path") ]; then ls $(_shq "$server_path"); else basename $(_shq "$server_path"); fi"
                break
            fi
            ((attempts++))
            (( attempts < 3 )) && fail "'$server_path' does not exist on server. Try again. ($((3-attempts)) attempts left)" || { fail "3 invalid attempts. Aborting."; return 1; }
        else
            break
        fi
    done
}

# Ask how a directory should be copied — in plain words, not rsync jargon — and
# draw a tree of exactly what the destination will look like for the choice, so
# the user confirms intent by seeing the result rather than remembering trailing
# slashes. Sets copy_mode=folder|contents; callers turn that into rsync's slash.
# A single file needs no question — it lands in the destination folder.
# Args: src_path  is_dir(true|false)  dst_path  src_loc(local|server)
_pick_copy_mode() {
    local src_path="$1"
    local is_dir="$2"
    local dst_path="$3"
    local src_loc="${4:-local}"
    local src_name; src_name=$(basename "$src_path")
    copy_mode="contents"

    # Non-directory (single file): it simply goes into the destination folder.
    [[ "$is_dir" != "true" ]] && return 0

    echo ""
    echo -e "  ${BOLD}How should \"${src_name}\" be copied?${NC}"
    echo -e "    ${BOLD}1)${NC} The whole folder    ${DIM}→ a \"${src_name}\" folder is created inside the destination${NC}"
    echo -e "    ${BOLD}2)${NC} Only its contents   ${DIM}→ files land directly in the destination${NC}"
    echo -e "    ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Select [1/2]: " mode
    [[ -z "$mode" || "$mode" == "0" ]] && return 2
    [[ "$mode" == "2" ]] && copy_mode="contents" || copy_mode="folder"

    # Top-level listing of the source, used only to draw the preview tree.
    local listing
    if [[ "$src_loc" == "server" ]]; then
        listing=$(ssh "$SERVER_USER@$SERVER_IP" "ls -1 $(_shq "$src_path") 2>/dev/null")
    else
        listing=$(ls -1 "$src_path" 2>/dev/null)
    fi

    echo ""
    echo -e "  ${BOLD}Destination will look like this:${NC}"
    echo -e "    ${dst_path}/"
    if [[ "$copy_mode" == "folder" ]]; then
        echo -e "    └── ${src_name}/"
        _print_tree_entries "$listing" "        "
    else
        _print_tree_entries "$listing" "    "
    fi
    echo ""
    return 0
}

# Render up to 6 entries of a newline-separated listing as a tree branch under
# INDENT, with "… and N more" when truncated, or a sudo note when the listing is
# empty (e.g. a root-owned 0700 source we can't read without sudo).
_print_tree_entries() {
    local listing="$1"
    local indent="$2"
    if [[ -z "$listing" ]]; then
        echo -e "${indent}└── ${DIM}(can't list without sudo — everything will still be copied)${NC}"
        return
    fi
    local total shown n more i=0 line
    total=$(printf '%s\n' "$listing" | grep -c .)
    shown=$(printf '%s\n' "$listing" | grep . | head -6)
    n=$(printf '%s\n' "$shown" | grep -c .)
    more=$(( total - n ))
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        i=$((i + 1))
        if (( i == n && more <= 0 )); then
            echo -e "${indent}└── ${line}"
        else
            echo -e "${indent}├── ${line}"
        fi
    done <<< "$shown"
    (( more > 0 )) && echo -e "${indent}└── ${DIM}… and ${more} more${NC}"
    return 0
}

_sync_one_time_backup() {
    local mirror_flag=()
    info "One-time rsync. Pick source and destination; runs once, no schedule."
    info "Run this from your LAPTOP, not over SSH."
    echo ""

    local direction
    local dir_attempts=0
    while (( dir_attempts < 3 )); do
        echo -e "  ${BOLD}1)${NC} Upload:   laptop → server"
        echo -e "  ${BOLD}2)${NC} Download: server → laptop"
        echo -e "  ${BOLD}3)${NC} Local:    laptop → laptop    ${DIM}(e.g. backup to a USB drive)${NC}"
        echo -e "  ${BOLD}4)${NC} Server:   server → server    ${DIM}(e.g. /mnt/data → backup USB on the server)${NC}"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choice [1/2/3/4/0]: " direction
        [[ "$direction" == "0" ]] && return 2
        [[ "$direction" =~ ^[1234]$ ]] && break
        ((dir_attempts++))
        if (( dir_attempts < 3 )); then
            fail "Invalid choice. Try again. ($((3-dir_attempts)) attempts left)"
            echo ""
        else
            fail "3 invalid attempts. Aborting."
            return 1
        fi
    done

    case $direction in
        1)
            echo ""
            echo -e "  ${BOLD}-- Source (laptop) --${NC}"
            _pick_local_path true || return
            local src_path="$local_path"
            echo ""
            echo -e "  ${BOLD}-- Destination (server) --${NC}"
            _pick_server_path false || return
            local dst_path="$server_path"

            local is_dir="false"
            [[ -d "$src_path" ]] && is_dir="true"
            _pick_copy_mode "$src_path" "$is_dir" "$dst_path" "local" || return
            local rsync_src="$src_path/"
            local dest_display="$dst_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$src_path"
                dest_display="$dst_path/$(basename "$src_path")"
            fi
            _mirror_gate local "$src_path" "$dest_display" "rsync $_RSYNC_FLAGS $(_shq "$rsync_src") $(_shq "$SERVER_USER@$SERVER_IP:$dst_path/")" || return

            local src_size=$(_src_size "$src_path")
            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↑ One-time upload: laptop → server${NC}"
            echo -e "  From: $src_path ($src_size)"
            echo -e "  To:   $SERVER_USER@$SERVER_IP:$dest_display"
            _mirror_banner
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            _mirror_confirm || return

            ssh -t "$SERVER_USER@$SERVER_IP" "sudo mkdir -p $(_shq "$dest_display") && sudo chown $SERVER_USER:$SERVER_USER $(_shq "$dest_display")" || { fail "Could not prepare destination."; return 1; }
            rsync $_RSYNC_FLAGS "${mirror_flag[@]}" "$rsync_src" "$SERVER_USER@$SERVER_IP:$dst_path/" || { fail "Backup failed."; return 1; }
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}-- Source (server) --${NC}"
            _pick_server_path true || return
            local src_path="$server_path"
            echo ""
            echo -e "  ${BOLD}-- Destination (laptop) --${NC}"
            _pick_local_path false || return
            local dst_path="$local_path"

            local is_dir="false"
            ssh "$SERVER_USER@$SERVER_IP" "test -d $(_shq "$src_path")" 2>/dev/null && is_dir="true"
            _pick_copy_mode "$src_path" "$is_dir" "$dst_path" "server" || return
            local rsync_src="$src_path/"
            local dest_display="$dst_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$src_path"
                dest_display="$dst_path/$(basename "$src_path")"
            fi

            # A privileged copy can be needed on EITHER end, independently:
            #  • Source unreadable as your SSH user (root-owned Immich backup) →
            #    read it on the server under sudo.
            #  • Destination not writable as you (e.g. a USB drive whose mount root
            #    is root-owned) → write it locally under sudo.
            # Probe each. Source: look for any unreadable path (as your user).
            local needs_priv=false
            if ssh "$SERVER_USER@$SERVER_IP" "find $(_shq "$src_path") ! -readable -print -quit 2>/dev/null" | grep -q .; then
                needs_priv=true
            fi
            # Destination: is the deepest already-existing ancestor writable by you?
            local dst_needs_priv=false _probe="$dst_path"
            while [ -n "$_probe" ] && [ "$_probe" != "/" ] && [ ! -e "$_probe" ]; do _probe=$(dirname "$_probe"); done
            [ -n "$_probe" ] && [ ! -w "$_probe" ] && dst_needs_priv=true

            # The sudo copy streams a tar, which can't delete: append only, no question.
            if $needs_priv || $dst_needs_priv; then
                sync_mode=append
                info "ℹ Needs sudo (tar copy) — append only; mirror isn't possible for this copy."
            else
                _mirror_gate server "$src_path" "$dest_display" "rsync $_RSYNC_FLAGS $(_shq "$SERVER_USER@$SERVER_IP:$rsync_src") $(_shq "$dst_path/")" || return
            fi

            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↓ One-time download: server → laptop${NC}"
            echo -e "  From: $SERVER_USER@$SERVER_IP:$src_path"
            echo -e "  To:   $dest_display"
            _mirror_banner
            $needs_priv     && echo -e "  ${DIM}Source is root-owned — federver reads it under sudo.${NC}"
            $dst_needs_priv && echo -e "  ${DIM}Destination isn't writable — it's written under local sudo.${NC}"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            _mirror_confirm || return

            # Authorize LOCAL sudo for this one copy, if the destination needs it.
            # Local sudo tickets survive between commands (same controlling terminal
            # → tty_tickets matches), so the same grant covers the mkdir and the
            # copy. If WE had to prompt for it (it wasn't already cached/NOPASSWD),
            # remember that so we can drop the ticket again at the end — the point
            # is to lend sudo for this copy, not to leave it open afterwards.
            local dst_sudo="" primed_sudo=false
            if $dst_needs_priv; then
                dst_sudo="sudo -n"
                if ! sudo -n true 2>/dev/null; then
                    info "Local sudo is needed to write to ${dst_path}."
                    sudo -v || { fail "Local sudo failed — nothing copied."; return 1; }
                    primed_sudo=true
                fi
            fi

            $dst_sudo mkdir -p "$dst_path" || { $primed_sudo && sudo -k 2>/dev/null; fail "Could not create destination."; return 1; }

            if $needs_priv || $dst_needs_priv; then
                # At least one end needs sudo. rsync can't take an interactive sudo
                # on its own SSH login (a primed ticket doesn't carry across SSH
                # logins — sudo keys it per parent process), so stream a tar through
                # one pipeline where WE own both ends:
                #   reader  = ssh [sudo -S] tar -cf -   (server side; sudo only if source root-owned)
                #   writer  = [sudo -n] tar -xf -       (laptop side; sudo only if dest unwritable)
                # The server sudo password goes in over the encrypted SSH stdin via
                # a printf BUILTIN (never in `ps`), is read silently, and is unset
                # right after; the local sudo password is the interactive prompt
                # above. The printf stage is always present (empty when the source
                # isn't privileged — tar ignores its stdin) so PIPESTATUS indices
                # are stable: [0]=printf [1]=ssh/read [2]=write.
                #
                # tar's working dir mirrors rsync's folder/contents distinction:
                #   dir, contents → cd into the source, archive "."   (contents land in dst)
                #   dir, folder   → cd into the parent, archive the basename (the dir lands in dst)
                #   single file   → cd into the parent, archive the name (the file lands in dst);
                #                   _pick_copy_mode forces "contents" for a file, but `tar -C
                #                   <file>` is invalid, so a file must take the parent/basename form.
                local tar_cd tar_arg
                if [[ "$is_dir" == "true" && "$copy_mode" == "contents" ]]; then
                    tar_cd="$src_path"; tar_arg="."
                else
                    tar_cd=$(dirname "$src_path"); tar_arg=$(basename "$src_path")
                fi

                # -p '' silences sudo's own prompt; remote stderr is dropped so it
                # can't corrupt the tar stream.
                local remote_cmd="tar -C $(_shq "$tar_cd") -cf - $(_shq "$tar_arg") 2>/dev/null"

                # No pv on the laptop → offer it now, before the server password
                # prompt and the copy output (the dnf sudo prompt is the laptop's).
                # Enter = yes. A failed install never aborts the copy.
                if ! command -v pv >/dev/null 2>&1; then
                    read -p "  Install pv for a progress bar? [Y/n] " -n 1 -r
                    echo ""
                    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                        sudo dnf install -y pv > /dev/null 2>&1 || true
                        command -v pv >/dev/null 2>&1 || warn "pv not installed - copying without a progress bar."
                    fi
                fi

                local server_pw=""
                if $needs_priv; then
                    read -rsp "  federver sudo password: " server_pw; echo
                    remote_cmd="sudo -S -p '' $remote_cmd"
                fi

                # Optional progress bar: if `pv` is installed on the laptop, get the
                # source's total bytes (same privilege as the read, password over
                # stdin via the printf builtin — never on argv) and put `pv -s <bytes>`
                # between ssh and the local tar. tar adds header/padding overhead, so
                # the % can slightly overshoot or finish early — it's approximate. If
                # the size lookup fails, pv still runs without -s (bytes + rate only).
                local pv_stage=() size_cmd size_bytes=""
                if command -v pv >/dev/null 2>&1; then
                    info "Sizing source..."
                    size_cmd="du -sb $(_shq "$src_path") 2>/dev/null | cut -f1"
                    $needs_priv && size_cmd="sudo -S -p '' du -sb $(_shq "$src_path") 2>/dev/null | cut -f1"
                    size_bytes=$(printf '%s\n' "$server_pw" | ssh "$SERVER_USER@$SERVER_IP" "$size_cmd" 2>/dev/null | head -n1)
                    pv_stage=(pv)
                    [[ "$size_bytes" =~ ^[0-9]+$ ]] && pv_stage=(pv -s "$size_bytes")
                    info "Copying… (progress below; % is approximate)"
                else
                    info "Copying (no per-file progress for privileged copies)…"
                fi
                # The trailing `&& … || …` puts the pipeline in an AND-OR list,
                # which is exempt from `set -e`, so we always reach the PIPESTATUS
                # check (and the error message) even if a caller didn't neutralize
                # errexit. Capturing in both branches keeps PIPESTATUS intact.
                # --no-same-owner/--no-same-permissions: when the writer runs as root
                # (dest under sudo) don't let a server-supplied archive restore
                # setuid/setgid bits or foreign ownership onto the laptop — otherwise
                # a compromised server could land a setuid-root file here.
                local st rd_i=1 wr_i=2   # no pv: 0=printf 1=ssh/read 2=write
                if [ "${#pv_stage[@]}" -gt 0 ]; then
                    wr_i=3               # with pv: 0=printf 1=ssh/read 2=pv 3=write
                    printf '%s\n' "$server_pw" \
                      | ssh "$SERVER_USER@$SERVER_IP" "$remote_cmd" \
                      | "${pv_stage[@]}" \
                      | $dst_sudo tar --no-same-owner --no-same-permissions -C "$dst_path" -xf - \
                      && st=("${PIPESTATUS[@]}") || st=("${PIPESTATUS[@]}")
                else
                    printf '%s\n' "$server_pw" \
                      | ssh "$SERVER_USER@$SERVER_IP" "$remote_cmd" \
                      | $dst_sudo tar --no-same-owner --no-same-permissions -C "$dst_path" -xf - \
                      && st=("${PIPESTATUS[@]}") || st=("${PIPESTATUS[@]}")
                fi
                unset server_pw
                $primed_sudo && sudo -k 2>/dev/null   # drop the one-time ticket we opened
                if [ "${st[rd_i]}" -ne 0 ] || [ "${st[wr_i]}" -ne 0 ]; then
                    fail "Download failed (read exit ${st[rd_i]}, write exit ${st[wr_i]}) — wrong password, unreachable server, or a write error. Nothing was changed on the server; re-run to overwrite any partial files on the laptop."
                    return 1
                fi
            else
                rsync $_RSYNC_FLAGS "${mirror_flag[@]}" "$SERVER_USER@$SERVER_IP:$rsync_src" "$dst_path/" || { fail "Backup failed."; return 1; }
            fi
            ;;
        3)
            echo ""
            echo -e "  ${BOLD}-- Source (laptop) --${NC}"
            _pick_local_path true || return
            local src_path="$local_path"
            echo ""
            echo -e "  ${BOLD}-- Destination (laptop) --${NC}"
            _pick_local_path false || return
            local dst_path="$local_path"

            local is_dir="false"
            [[ -d "$src_path" ]] && is_dir="true"
            _pick_copy_mode "$src_path" "$is_dir" "$dst_path" "local" || return
            local rsync_src="$src_path/"
            local dest_display="$dst_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$src_path"
                dest_display="$dst_path/$(basename "$src_path")"
            fi
            _mirror_gate local "$src_path" "$dest_display" "rsync $_RSYNC_FLAGS $(_shq "$rsync_src") $(_shq "$dst_path/")" || return

            local src_size=$(_src_size "$src_path")
            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↪ One-time local copy: laptop → laptop${NC}"
            echo -e "  From: $src_path ($src_size)"
            echo -e "  To:   $dest_display"
            _mirror_banner
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            _mirror_confirm || return

            mkdir -p "$dst_path" || { fail "Could not create destination."; return 1; }
            rsync $_RSYNC_FLAGS "${mirror_flag[@]}" "$rsync_src" "$dst_path/" || { fail "Backup failed."; return 1; }
            ;;
        4)
            echo ""
            echo -e "  ${BOLD}-- Source (server) --${NC}"
            _pick_server_path true || return
            local src_path="$server_path"
            echo ""
            echo -e "  ${BOLD}-- Destination (server) --${NC}"
            info "Type the destination, e.g. a backup USB at /run/media/$SERVER_USER/<label>"
            _pick_server_path false || return
            local dst_path="$server_path"

            # Both paths live on the server; rsync runs there over one SSH session.
            local is_dir="false"
            ssh "$SERVER_USER@$SERVER_IP" "test -d $(_shq "$src_path")" 2>/dev/null && is_dir="true"
            _pick_copy_mode "$src_path" "$is_dir" "$dst_path" "server" || return
            local rsync_src="$src_path/"
            local dest_display="$dst_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$src_path"
                dest_display="$dst_path/$(basename "$src_path")"
            fi

            # A mirror's guard, preview and copy all run as root on the server over
            # non-TTY ssh with ONE password prompt (_server_sudo_run); an append copy
            # keeps the interactive `ssh -t sudo` below.
            local append_cmd="rsync -avh --progress $(_shq "$rsync_src") $(_shq "$dst_path/")"
            _mirror_ask
            if [[ "$sync_mode" == mirror ]]; then
                local pw_rc=0
                _server_sudo_pw_prompt || pw_rc=$?
                if (( pw_rc == 2 )); then fail "Server unreachable - nothing changed."; return 1; fi
                if (( pw_rc != 0 )); then fail "Wrong sudo password - nothing changed."; return 1; fi
                _mirror_preview sudo "$src_path" "$dest_display" "$(_mirror_dry_cmd "$append_cmd")" copy || { unset _SRV_PW; return 2; }
            fi

            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}⇄ One-time server copy: federver → federver${NC}"
            echo -e "  From: $SERVER_USER@$SERVER_IP:$src_path"
            echo -e "  To:   $SERVER_USER@$SERVER_IP:$dest_display"
            _mirror_banner
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            info "Runs with sudo on the server (Immich data is root-owned); you may be prompted for the server password."

            _mirror_confirm || { unset _SRV_PW; return; }

            if [[ "$sync_mode" == mirror ]]; then
                _server_sudo_run "exec 2>&1; mkdir -p $(_shq "$dest_display") && $(_rsync_with "$append_cmd" --delete)" || { unset _SRV_PW; fail "Mirror failed."; return 1; }
                unset _SRV_PW
            else
            # -t for the interactive sudo password prompt. mkdir the destination
            # first, then copy. Single-quoted paths handle spaces (e.g. "New Backup").
            ssh -t "$SERVER_USER@$SERVER_IP" "sudo mkdir -p $(_shq "$dest_display") && sudo rsync -avh --progress $(_shq "$rsync_src") $(_shq "$dst_path/")" || { fail "Backup failed."; return 1; }
            fi
            ;;
    esac

    echo ""
    if [[ "$sync_mode" == mirror ]]; then
        ok "Mirror complete - ${_mirror_n} deleted, destination matches source."
    else
        ok "Backup complete."
    fi
}

step_manage_sync() {
    echo ""
    echo -e "  ${BOLD}1)${NC} Status                            ${DIM}← all scheduled tasks${NC}"
    echo -e "  ${BOLD}2)${NC} Sync - New                        ${DIM}← transfer files, run now or schedule${NC}"
    echo -e "  ${BOLD}3)${NC} Sync - Edit job                   ${DIM}← schedule, pause, run, log, delete${NC}"
    echo -e "  ${BOLD}4)${NC} Sync - Delete a job"
    echo -e "  ${BOLD}5)${NC} Backup - One-time                 ${DIM}← ad-hoc rsync, no schedule${NC}"
    echo -e "  ${BOLD}6)${NC} Backup - Immich (scheduled)       ${DIM}← set up / status / run / remove (DB + photos)${NC}"
    echo -e "  ${BOLD}7)${NC} Monitor - Disk space              ${DIM}← Kuma heartbeat every 5 min${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choice [0-7]: " sync_choice
    case $sync_choice in
        1) _sync_show_status ;;
        2) step_sync ;;
        3) _sync_edit_job ;;
        4) _sync_delete_job ;;
        5) _sync_one_time_backup ;;
        6) _on_server step_immich_backup_menu ;;
        7) _on_server step_disk_monitor ;;
        0) return 2 ;;
        *) fail "Invalid choice." ;;
    esac
}

step_sync() {
    info "Transfer or delete files between this laptop and the server."
    info "Run this from your LAPTOP, not over SSH."
    echo ""
    local dir_attempts=0
    while (( dir_attempts < 3 )); do
        echo -e "  ${BOLD}1)${NC} Upload:   laptop → server"
        echo -e "  ${BOLD}2)${NC} Download: server → laptop"
        echo -e "  ${BOLD}3)${NC} Delete:   remove files"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choice [1/2/3/0]: " direction
        [[ "$direction" == "0" ]] && return 2
        [[ "$direction" =~ ^[123]$ ]] && break
        ((dir_attempts++))
        if (( dir_attempts < 3 )); then
            fail "Invalid choice. Try again. ($((3-dir_attempts)) attempts left)"
            echo ""
        else
            fail "3 invalid attempts. Aborting."
            return 1
        fi
    done

    case $direction in
        1)
            echo ""
            echo -e "  ${BOLD}-- Source (laptop) --${NC}"
            _pick_local_path true || return
            echo ""
            echo -e "  ${BOLD}-- Destination (server) --${NC}"
            _pick_server_path false || return

            [[ -d "$local_path" ]] && local is_dir="true" || local is_dir="false"
            _pick_copy_mode "$local_path" "$is_dir" "$server_path" "local" || return
            local rsync_src="$local_path/"
            local dest_display="$server_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$local_path"
                dest_display="$server_path/$(basename "$local_path")"
            fi
            _mirror_ask

            src_size=$(_src_size "$local_path")
            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↑ Upload: laptop → server${NC}"
            echo -e "  From: $local_path ($src_size)"
            echo -e "  To:   $SERVER_USER@$SERVER_IP:$dest_display"
            _mirror_banner
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            _sync_execute_or_schedule upload "$local_path" "$server_path" "$copy_mode" "$sync_mode"
            ;;

        2)
            echo ""
            echo -e "  ${BOLD}-- Source (server) --${NC}"
            _pick_server_path true || return
            echo ""
            echo -e "  ${BOLD}-- Destination (laptop) --${NC}"
            _pick_local_path false || return

            local is_dir="false"
            ssh "$SERVER_USER@$SERVER_IP" "test -d $(_shq "$server_path")" 2>/dev/null && is_dir="true"
            _pick_copy_mode "$server_path" "$is_dir" "$local_path" "server" || return
            local rsync_src="$server_path/"
            local dest_display="$local_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$server_path"
                dest_display="$local_path/$(basename "$server_path")"
            fi
            _mirror_ask

            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↓ Download: server → laptop${NC}"
            echo -e "  From: $SERVER_USER@$SERVER_IP:$server_path"
            echo -e "  To:   $dest_display"
            _mirror_banner
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            _sync_execute_or_schedule download "$server_path" "$local_path" "$copy_mode" "$sync_mode"
            ;;

        3)
            echo ""
            echo -e "  ${BOLD}Delete from:${NC}"
            echo -e "    ${BOLD}1)${NC} Laptop"
            echo -e "    ${BOLD}2)${NC} Server"
            echo -e "    ${BOLD}0)${NC} Back"
            echo ""
            read -p "  Where [0/1/2]: " del_where
            [[ -z "$del_where" || "$del_where" == "0" ]] && return 2

            case $del_where in
                1)
                    echo ""
                    _pick_local_path true false || return
                    local del_path="$local_path"
                    if [[ "$del_path" == "/" ]]; then fail "Invalid path."; return 1; fi
                    echo ""
                    echo -e "  ${RED}This will permanently delete: $del_path${NC}"
                    read -p "  Are you sure? [y/N] " -n 1 -r
                    echo ""
                    [[ ! $REPLY =~ ^[Yy]$ ]] && info "Cancelled." && return
                    sudo rm -rf "$del_path" || { fail "Delete failed."; return 1; }
                    ;;
                2)
                    echo ""
                    _pick_server_path true false || return
                    local del_path="$server_path"
                    if [[ "$del_path" == "/" ]]; then fail "Invalid path."; return 1; fi
                    echo ""
                    echo -e "  ${RED}This will permanently delete: $SERVER_USER@$SERVER_IP:$del_path${NC}"
                    read -p "  Are you sure? [y/N] " -n 1 -r
                    echo ""
                    [[ ! $REPLY =~ ^[Yy]$ ]] && info "Cancelled." && return
                    ssh -t "$SERVER_USER@$SERVER_IP" "sudo rm -rf '$del_path'" || { fail "Delete failed."; return 1; }
                    ;;
                *)
                    fail "Invalid choice."
                    return
                    ;;
            esac

            echo ""
            ok "Deleted."
            return
            ;;

    esac
}

step_status() {
    local remote=false
    if [[ "$(hostname)" != "federver" ]]; then
        remote=true
    fi

    if [[ "$remote" == "true" ]]; then
        local server_info
        server_info=$( { declare -p _DRIVE_ROOTS; declare -f _ts_ipv4 _ts_state _ps_autostart _smb_summary _drive_verdict _smb_folder_check _smb_sessions _smb_devices _smb_devname; cat <<'REMOTE_STATUS'
            echo "@@HOSTNAME@@$(hostname)"
            echo "@@IP@@$(hostname -I | awk '{print $1}')"
            echo "@@TS_STATE@@$(_ts_state)"
            echo "@@UPTIME@@$(uptime -p 2>/dev/null | sed 's/^up //')"
            echo "@@LOAD@@$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
            echo "@@FILES@@$(grep FILES_LOCATION ~/privcloud/.env 2>/dev/null | cut -d= -f2)"
            echo "@@MUSIC@@$(grep MUSIC_LOCATION ~/privcloud/.env 2>/dev/null | cut -d= -f2)"
            echo "@@UPLOAD@@$(grep UPLOAD_LOCATION ~/privcloud/.env 2>/dev/null | cut -d= -f2)"
            echo "@@DB@@$(grep DB_DATA_LOCATION ~/privcloud/.env 2>/dev/null | cut -d= -f2)"
            echo "@@MEM_START@@"
            free -h 2>/dev/null | awk '/^Mem:/{print "mem|"$2"|"$3"|"$7} /^Swap:/{print "swap|"$2"|"$3}'
            echo "@@MEM_END@@"
            echo "@@CONTAINERS_START@@"
            _ps_autostart docker 2>/dev/null
            echo "@@CONTAINERS_END@@"
            echo "@@DSTATS_START@@"
            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null
            echo "@@DSTATS_END@@"
            echo "@@USB_DISKS@@$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}' | paste -sd'|' -)"
            echo "@@DISK_START@@"
            df -h 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// && $1 !~ /loop/ && !seen[$1]++'
            echo "@@DISK_END@@"
            echo "@@SMB@@$(_smb_summary docker)"
            echo "@@SMB_DEV_START@@"
            _smb_devices docker
            echo "@@SMB_DEV_END@@"
REMOTE_STATUS
        } | ssh "$SERVER_USER@$SERVER_IP" bash -s ) || { fail "Cannot reach server at $SERVER_IP."; return 1; }

        HOSTNAME=$(echo "$server_info" | grep '@@HOSTNAME@@' | sed 's/@@HOSTNAME@@//')
        IP=$(echo "$server_info" | grep '@@IP@@' | sed 's/@@IP@@//')
        TS_STATE=$(echo "$server_info" | grep '@@TS_STATE@@' | sed 's/@@TS_STATE@@//')
        UPTIME=$(echo "$server_info" | grep '@@UPTIME@@' | sed 's/@@UPTIME@@//')
        LOAD=$(echo "$server_info" | grep '@@LOAD@@' | sed 's/@@LOAD@@//')
        FILES=$(echo "$server_info" | grep '@@FILES@@' | sed 's/@@FILES@@//')
        MUSIC=$(echo "$server_info" | grep '@@MUSIC@@' | sed 's/@@MUSIC@@//')
        UPLOAD=$(echo "$server_info" | grep '@@UPLOAD@@' | sed 's/@@UPLOAD@@//')
        DB=$(echo "$server_info" | grep '@@DB@@' | sed 's/@@DB@@//')
        MEM=$(echo "$server_info" | sed -n '/@@MEM_START@@/,/@@MEM_END@@/p' | grep -v '@@MEM')
        CONTAINERS=$(echo "$server_info" | sed -n '/@@CONTAINERS_START@@/,/@@CONTAINERS_END@@/p' | grep -v '@@CONTAINERS')
        DSTATS=$(echo "$server_info" | sed -n '/@@DSTATS_START@@/,/@@DSTATS_END@@/p' | grep -v '@@DSTATS')
        USB_DISKS=$(echo "$server_info" | grep '@@USB_DISKS@@' | sed 's/@@USB_DISKS@@//')
        DISK=$(echo "$server_info" | sed -n '/@@DISK_START@@/,/@@DISK_END@@/p' | grep -v '@@DISK')
        SMB=$(echo "$server_info" | grep '@@SMB@@' | sed 's/@@SMB@@//')
        SMB_DEV=$(echo "$server_info" | sed -n '/@@SMB_DEV_START@@/,/@@SMB_DEV_END@@/p' | grep -v '@@SMB_DEV')
    else
        HOSTNAME=$(hostname)
        IP=$(hostname -I | awk '{print $1}')
        TS_STATE=$(_ts_state)
        UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
        LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
        local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        FILES=$(grep FILES_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        MUSIC=$(grep MUSIC_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        UPLOAD=$(grep UPLOAD_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        DB=$(grep DB_DATA_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print "mem|"$2"|"$3"|"$7} /^Swap:/{print "swap|"$2"|"$3}')
        CONTAINERS=$(_ps_autostart docker 2>/dev/null)
        DSTATS=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null)
        USB_DISKS=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}' | paste -sd'|' -)
        DISK=$(df -h / /home /mnt/data 2>/dev/null | tail -n +2 | awk '!seen[$1]++')
        SMB=$(_smb_summary docker)
        SMB_DEV=$(_smb_devices docker)
    fi

    echo -e "  ${BOLD}Server${NC}"
    echo -e "    Hostname:   $HOSTNAME"
    echo -e "    Local IP:   $IP"
    local TS_IP
    TS_IP=""; _ts_running "$TS_STATE" && TS_IP=$(_ts_ip "$TS_STATE"); [[ "$TS_IP" == - ]] && TS_IP=""
    echo -e "    Tailscale:  $(_ts_word "$TS_STATE")${TS_IP:+  ${DIM}($TS_IP)${NC}}"
    echo -e "    TS key:     $(_ts_key "$TS_STATE")"
    _ts_expiry_hint "$TS_STATE"
    [[ -n "$UPTIME" ]] && echo -e "    Uptime:     $UPTIME"
    [[ -n "$LOAD"   ]] && echo -e "    Load avg:   $LOAD  ${DIM}(1m, 5m, 15m)${NC}"
    echo ""

    # Memory
    local mem_total mem_used mem_avail swap_total swap_used
    mem_total=$(echo "$MEM" | awk -F'|' '$1=="mem"{print $2}')
    mem_used=$(echo  "$MEM" | awk -F'|' '$1=="mem"{print $3}')
    mem_avail=$(echo "$MEM" | awk -F'|' '$1=="mem"{print $4}')
    swap_total=$(echo "$MEM" | awk -F'|' '$1=="swap"{print $2}')
    swap_used=$(echo  "$MEM" | awk -F'|' '$1=="swap"{print $3}')
    if [[ -n "$mem_total" ]]; then
        echo -e "  ${BOLD}Memory${NC}"
        echo -e "    RAM:        $mem_used used / $mem_total total  ${DIM}($mem_avail available)${NC}"
        if [[ -n "$swap_total" && "$swap_used" != "0B" ]]; then
            echo -e "    Swap:       $swap_used used / $swap_total total"
        fi
        echo ""
    fi

    echo -e "  ${BOLD}Disk${NC}"
    # Split into internal vs usb. USB_DISKS is a |-joined list of base disk
    # names (e.g. "sda|sdb"); a df row is USB if its device starts /dev/<name>
    # where <name> is in that list.
    local internal_rows=""
    local usb_rows=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local dev
        dev=$(echo "$line" | awk '{print $1}')
        local is_usb=0
        if [[ -n "$USB_DISKS" ]]; then
            local d
            IFS='|' read -ra _usb_arr <<< "$USB_DISKS"
            for d in "${_usb_arr[@]}"; do
                [[ -z "$d" ]] && continue
                if [[ "$dev" == "/dev/${d}"* ]]; then is_usb=1; break; fi
            done
        fi
        if [[ "$is_usb" == 1 ]]; then
            usb_rows+="$line"$'\n'
        else
            internal_rows+="$line"$'\n'
        fi
    done <<< "$DISK"

    if [[ -n "$internal_rows" ]]; then
        echo -e "    ${DIM}Internal${NC}"
        echo -n "$internal_rows" | awk '{mp=$6; for(i=7;i<=NF;i++) mp=mp" "$i; printf "      %-20s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,mp}'
    fi
    if [[ -n "$usb_rows" ]]; then
        echo -e "    ${DIM}USB${NC}"
        echo -n "$usb_rows" | awk '{mp=$6; for(i=7;i<=NF;i++) mp=mp" "$i; printf "      %-20s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,mp}'
    fi
    echo ""

    # Laptop services (only when running from the laptop)
    [[ "$remote" == "true" ]] && _show_laptop_services

    # Server containers + per-container CPU/MEM from docker stats
    echo -e "  ${BOLD}Server containers${NC}"
    if [[ -n "$CONTAINERS" ]]; then
        echo "$CONTAINERS" | while IFS='|' read -r name status; do
            local cpu="" mem=""
            if [[ -n "$DSTATS" ]]; then
                local line
                line=$(echo "$DSTATS" | awk -F'|' -v n="$name" '$1==n{print $2"|"$3; exit}')
                cpu=$(echo "$line" | cut -d'|' -f1)
                # Show only "used" side of "X MiB / Y GiB"
                mem=$(echo "$line" | cut -d'|' -f2 | awk '{print $1}')
            fi
            local suffix=""
            [[ -n "$cpu" ]] && suffix="$suffix  ${DIM}cpu ${cpu}${NC}"
            [[ -n "$mem" ]] && suffix="$suffix  ${DIM}mem ${mem}${NC}"
            # Containers without a HEALTHCHECK just report "Up X" — treat
            # those as OK (not warn). Only warn when the state is genuinely
            # ambiguous (Created, Paused, etc).
            if echo "$status" | grep -qi "unhealthy\|exit\|restart\|^stopped"; then
                echo -e "    ${RED}✗${NC} $(printf '%-24s' "$name")  $status$suffix"
            elif echo "$status" | grep -qi "healthy\|^Up "; then
                echo -e "    ${GREEN}✓${NC} $(printf '%-24s' "$name")  $status$suffix"
            else
                echo -e "    ${YELLOW}!!${NC} $(printf '%-24s' "$name")  $status$suffix"
            fi
        done
    else
        echo -e "    ${DIM}No containers running${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}File sharing (SMB)${NC}"
    _smb_summary_render "${SMB:-none}" "${SMB_DEV:-}"

    echo ""
    echo -e "  ${BOLD}Service URLs (local network)${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Navidrome:    ${BLUE}http://$IP:4533${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"
    echo "$CONTAINERS" | grep -q '^adguard|' && echo -e "    AdGuard:      ${BLUE}http://$IP${NC}"
    echo "$CONTAINERS" | grep -q '^syncthing|' && echo -e "    Syncthing:    ${BLUE}http://$IP:8384${NC}"

    if [[ "$TS_STATE" == Running* ]]; then
        echo ""
        echo -e "  ${BOLD}Service URLs (remote via Tailscale)${NC}"
        echo -e "    Immich:       ${BLUE}http://federver:2283${NC}"
        echo -e "    Navidrome:    ${BLUE}http://federver:4533${NC}"
        echo -e "    FileBrowser:  ${BLUE}http://federver:8080${NC}"
        echo -e "    Uptime Kuma:  ${BLUE}http://federver:3001${NC}"
        echo "$CONTAINERS" | grep -q '^adguard|' && echo -e "    AdGuard:      ${BLUE}http://federver${NC}"
        echo "$CONTAINERS" | grep -q '^syncthing|' && echo -e "    Syncthing:    ${BLUE}http://federver:8384${NC}"
        echo -e "    ${DIM}(or use Tailscale IP: $TS_IP)${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Data paths${NC}"
    [[ -n "$FILES" ]] && echo -e "    Files:       $FILES  ${DIM}(FileBrowser root)${NC}"
    [[ -n "$MUSIC" ]] && echo -e "    Music:       $MUSIC  ${DIM}(Navidrome)${NC}"
    if [[ -n "$UPLOAD" || -n "$DB" ]]; then
        [[ -n "$UPLOAD" ]] && echo -e "    Photos:      $UPLOAD  ${DIM}(Immich)${NC}"
        [[ -n "$DB" ]] && echo -e "    Database:    $DB  ${DIM}(Immich DB)${NC}"
    fi
}

step_power() {
    echo -e "  ${BOLD}1)${NC} Shutdown"
    echo -e "  ${BOLD}2)${NC} Restart"
    echo ""
    read -p "  Choose [1/2]: " power_choice

    # Run locally when on server, SSH from laptop.
    local runner
    if _is_server; then
        runner="sudo"
    else
        runner="ssh -t $SERVER_USER@$SERVER_IP sudo"
    fi

    case $power_choice in
        1)
            echo ""
            warn "Server will shut down."
            _is_server || warn "SSH connection will be lost."
            read -p "  Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ok "Shutting down..."
                $runner shutdown now
            else
                info "Cancelled."
            fi
            ;;
        2)
            echo ""
            warn "Server will restart."
            _is_server || warn "SSH connection will drop and reconnect in ~1-2 minutes."
            read -p "  Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ok "Restarting..."
                $runner reboot
            else
                info "Cancelled."
            fi
            ;;
        *)
            fail "Invalid choice."
            ;;
    esac
}

step_save_to_pass() {
    info "Run this from your LAPTOP (where pass is installed)."
    info "Fetches server config via SSH, saves everything to pass."
    echo ""

    if ! command -v pass &>/dev/null; then
        fail "pass is not installed on this machine."
        info "Install: sudo dnf install pass"
        return 1
    fi

    info "Connecting to $SERVER_USER@$SERVER_IP..."
    echo ""

    # Fetch all data from server in one SSH call
    local server_data pw_rc=0
    _server_sudo_pw_prompt || pw_rc=$?
    if (( pw_rc == 2 )); then fail "Cannot reach server at $SERVER_IP - nothing saved."; return 1; fi
    if (( pw_rc != 0 )); then fail "Wrong sudo password - nothing saved to pass."; return 1; fi
    # The script runs as root (via _server_sudo_run, which keeps the password
    # off the script's stdin) so the /etc and /opt reads work in this one
    # non-TTY session; HOME is kept as the login user's so ~/privcloud/.env
    # still resolves.
    local fetch_script
    fetch_script="$(declare -f _ts_ipv4 _ts_state _ts_running)
$(cat <<'FETCH'
echo "HOSTNAME=$(hostname)"
echo "LOCAL_IP=$(hostname -I | awk '{print $1}')"
TS_STATE=$(_ts_state)
echo "TS_STATE=$TS_STATE"
_ts_running "$TS_STATE" && echo "TS_IP=$(_ts_ipv4)"
echo "---ENV---"
cat ~/privcloud/.env 2>/dev/null || cat ~/data/.env 2>/dev/null || true
echo "---DOCKER_COMPOSE---"
cat ~/privcloud/docker-compose.yml 2>/dev/null || true
echo "---WG_SERVER---"
cat /etc/wireguard/wg0.conf 2>/dev/null || true
echo "---WG_PEERS---"
for f in $(find /etc/wireguard -name '*.conf' ! -name 'wg0.conf' 2>/dev/null); do
    echo "PEER_FILE=$(basename "$f" .conf)"
    cat "$f"
    echo "END_PEER_FILE"
done
echo "---ADGUARD---"
cat /opt/adguard/conf/AdGuardHome.yaml 2>/dev/null || true
echo "---SYNCTHING_ID---"
docker exec syncthing syncthing --device-id 2>/dev/null || true
echo "---SYNCTHING_CONFIG---"
cat /opt/syncthing/config/config.xml 2>/dev/null || true
echo "---SYNCTHING_CERT---"
cat /opt/syncthing/config/cert.pem 2>/dev/null || true
echo "---SYNCTHING_KEY---"
cat /opt/syncthing/config/key.pem 2>/dev/null || true
echo "---END---"
FETCH
)"
    server_data=$(_server_sudo_run "$fetch_script")
    unset _SRV_PW

    if [[ -z "$server_data" ]]; then
        fail "Could not connect to server."
        return 1
    fi

    # Parse server details
    local HOSTNAME=$(echo "$server_data" | grep "^HOSTNAME=" | cut -d= -f2)
    local IP=$(echo "$server_data" | grep "^LOCAL_IP=" | cut -d= -f2)
    local TS_IP=$(echo "$server_data" | grep "^TS_IP=" | cut -d= -f2)
    local TS_STATE=$(echo "$server_data" | grep "^TS_STATE=" | cut -d= -f2-)
    if ! _ts_running "$TS_STATE"; then
        TS_IP=""
        warn "Server Tailscale is not Running - skipping Tailscale IP and URLs."
    fi

    # Server details
    echo "$HOSTNAME" | pass insert -e -f privcloud/server/hostname 2>/dev/null && ok "privcloud/server/hostname"
    echo "$IP" | pass insert -e -f privcloud/server/local_ip 2>/dev/null && ok "privcloud/server/local_ip"
    echo "$SERVER_USER" | pass insert -e -f privcloud/server/user 2>/dev/null && ok "privcloud/server/user"

    if [[ -n "$TS_IP" ]]; then
        echo "$TS_IP" | pass insert -e -f privcloud/server/tailscale_ip 2>/dev/null && ok "privcloud/server/tailscale_ip"
    fi

    # SSH key (from laptop)
    local key_file=""
    if [[ -f ~/.ssh/id_ed25519 ]]; then
        key_file=~/.ssh/id_ed25519
    elif [[ -f ~/.ssh/id_rsa ]]; then
        key_file=~/.ssh/id_rsa
    fi

    if [[ -n "$key_file" ]]; then
        cat "$key_file" | pass insert -m -f privcloud/ssh/private_key 2>/dev/null && ok "privcloud/ssh/private_key"
        cat "${key_file}.pub" | pass insert -m -f privcloud/ssh/public_key 2>/dev/null && ok "privcloud/ssh/public_key"
    fi

    # Service URLs
    echo ""
    info "Service URLs..."
    local urls="Local:
Immich:       http://$IP:2283
Navidrome:    http://$IP:4533
FileBrowser:  http://$IP:8080
Uptime Kuma:  http://$IP:3001"

    if [[ -n "$TS_IP" ]]; then
        urls="$urls

Remote (Tailscale):
Immich:       http://$TS_IP:2283
Navidrome:    http://$TS_IP:4533
FileBrowser:  http://$TS_IP:8080
Uptime Kuma:  http://$TS_IP:3001"
    fi

    echo "$urls" | pass insert -m -f privcloud/services/urls 2>/dev/null && ok "privcloud/services/urls"

    # .env file
    local env_data=$(echo "$server_data" | sed -n '/^---ENV---$/,/^---DOCKER_COMPOSE---$/p' | sed '1d;$d')
    if [[ -n "$env_data" ]]; then
        echo "$env_data" | pass insert -m -f privcloud/config/env 2>/dev/null && ok "privcloud/config/env"
    fi

    # Docker compose
    local compose_data=$(echo "$server_data" | sed -n '/^---DOCKER_COMPOSE---$/,/^---WG_SERVER---$/p' | sed '1d;$d')
    if [[ -n "$compose_data" ]]; then
        echo "$compose_data" | pass insert -m -f privcloud/config/docker_compose 2>/dev/null && ok "privcloud/config/docker_compose"
    fi

    # WireGuard server config
    local wg_server=$(echo "$server_data" | sed -n '/^---WG_SERVER---$/,/^---WG_PEERS---$/p' | sed '1d;$d')
    if [[ -n "$wg_server" ]]; then
        echo ""
        info "WireGuard configs..."
        echo "$wg_server" | pass insert -m -f privcloud/wireguard/server_conf 2>/dev/null && ok "privcloud/wireguard/server_conf"
    fi

    # WireGuard peer configs
    local wg_peers=$(echo "$server_data" | sed -n '/^---WG_PEERS---$/,/^---ADGUARD---$/p' | sed '1d;$d')
    if [[ -n "$wg_peers" ]]; then
        local current_peer=""
        local peer_conf=""
        while IFS= read -r line; do
            if [[ "$line" == PEER_FILE=* ]]; then
                current_peer="${line#PEER_FILE=}"
                peer_conf=""
            elif [[ "$line" == "END_PEER_FILE" ]]; then
                if [[ -n "$current_peer" && -n "$peer_conf" ]]; then
                    echo "$peer_conf" | pass insert -m -f "privcloud/wireguard/peers/${current_peer}" 2>/dev/null && ok "privcloud/wireguard/peers/${current_peer}"
                fi
            else
                if [[ -n "$peer_conf" ]]; then
                    peer_conf="$peer_conf
$line"
                else
                    peer_conf="$line"
                fi
            fi
        done <<< "$wg_peers"
    fi

    # AdGuard Home config (contains admin user + bcrypt password hash + filter config)
    local adguard_data=$(echo "$server_data" | sed -n '/^---ADGUARD---$/,/^---SYNCTHING_ID---$/p' | sed '1d;$d')
    if [[ -n "$adguard_data" ]]; then
        echo ""
        info "AdGuard config..."
        echo "$adguard_data" | pass insert -m -f privcloud/adguard/config 2>/dev/null && ok "privcloud/adguard/config"
    fi

    # Syncthing identity — device ID + config.xml + cert.pem + key.pem.
    # The cert/key pair IS the node identity; losing them means re-pairing
    # every client. config.xml holds device list, folder shares, GUI creds.
    local st_id=$(echo "$server_data" | sed -n '/^---SYNCTHING_ID---$/,/^---SYNCTHING_CONFIG---$/p' | sed '1d;$d')
    local st_config=$(echo "$server_data" | sed -n '/^---SYNCTHING_CONFIG---$/,/^---SYNCTHING_CERT---$/p' | sed '1d;$d')
    local st_cert=$(echo "$server_data" | sed -n '/^---SYNCTHING_CERT---$/,/^---SYNCTHING_KEY---$/p' | sed '1d;$d')
    local st_key=$(echo "$server_data" | sed -n '/^---SYNCTHING_KEY---$/,/^---END---$/p' | sed '1d;$d')
    if [[ -n "$st_id" || -n "$st_config" ]]; then
        echo ""
        info "Syncthing identity..."
        [[ -n "$st_id"     ]] && echo "$st_id"     | pass insert -e -f privcloud/syncthing/device_id 2>/dev/null && ok "privcloud/syncthing/device_id"
        [[ -n "$st_config" ]] && echo "$st_config" | pass insert -m -f privcloud/syncthing/config    2>/dev/null && ok "privcloud/syncthing/config"
        [[ -n "$st_cert"   ]] && echo "$st_cert"   | pass insert -m -f privcloud/syncthing/cert      2>/dev/null && ok "privcloud/syncthing/cert"
        [[ -n "$st_key"    ]] && echo "$st_key"    | pass insert -m -f privcloud/syncthing/key       2>/dev/null && ok "privcloud/syncthing/key"
    fi

    echo ""
    ok "All saved to pass."
    echo ""
    info "pass show privcloud/                         # list everything"
    info "pass show privcloud/server/local_ip           # server IP"
    info "pass show privcloud/services/urls             # all service URLs"
    info "pass show privcloud/config/env                # .env (DB password, paths)"
    info "pass show privcloud/ssh/private_key           # SSH key"
    info "pass show privcloud/syncthing/device_id       # Syncthing device ID"
    info "pass show privcloud/syncthing/cert            # Syncthing node identity cert"
}

run_all() {
    step_update
    step_autoupdates
    step_docker
    _fw_defaults
    step_deploy   # now installs log rotation as its last step
}

step_reset_password() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local IP
    IP=$(hostname -I | awk '{print $1}')

    echo -e "  ${BOLD}1)${NC} FileBrowser     ${DIM}(port 8080)${NC}"
    echo -e "  ${BOLD}2)${NC} Immich          ${DIM}(port 2283)${NC}"
    echo -e "  ${BOLD}3)${NC} Navidrome       ${DIM}(port 4533)${NC}"
    echo -e "  ${BOLD}4)${NC} Uptime Kuma     ${DIM}(port 3001)${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Which service? " reset_choice

    case $reset_choice in
        1)
            echo ""
            warn "This will reset the FileBrowser admin password."
            # -s: don't echo the password to the terminal/scrollback.
            read -rsp "  New password: " new_pass; echo ""
            if [[ -z "$new_pass" ]]; then
                fail "Password is required."
                return 1
            fi
            sg docker -c "docker stop filebrowser" > /dev/null 2>&1
            # Password via the container environment (-e), not interpolated into
            # the shell string — no command injection, no breakage on quotes or
            # special characters. Check the exit status rather than swallow it.
            export FB_NEW_PASS="$new_pass"
            if ! sg docker -c 'docker run --rm -e FB_NEW_PASS --entrypoint sh -v privcloud_filebrowser-db:/database filebrowser/filebrowser:latest -c "filebrowser users update admin --password \"\$FB_NEW_PASS\" --database /database/filebrowser.db"' > /dev/null 2>&1; then
                unset FB_NEW_PASS
                sg docker -c "docker start filebrowser" > /dev/null 2>&1
                fail "Failed to update the FileBrowser password. The old password is unchanged."
                return 1
            fi
            unset FB_NEW_PASS
            sg docker -c "docker start filebrowser" > /dev/null 2>&1

            local fb_pass_file="$HOME/.privcloud/filebrowser.pass"
            mkdir -p "$(dirname "$fb_pass_file")"
            ( umask 077; printf '%s\n' "$new_pass" > "$fb_pass_file" )

            ok "Password reset for admin. Saved to $fb_pass_file"
            echo -e "    ${BLUE}http://$IP:8080${NC}"
            ;;
        2)
            echo ""
            warn "This will clear the Immich admin password."
            warn "Your photos and database are kept."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return
            fi
            cd "$SCRIPT_DIR"
            sg docker -c "docker exec immich_postgres psql -U postgres -d immich -c \"UPDATE users SET password = '' WHERE is_admin = true;\"" > /dev/null 2>&1
            ok "Admin password cleared. Open Immich to set a new one:"
            echo -e "    ${BLUE}http://$IP:2283${NC}"
            ;;
        3)
            echo ""
            warn "This will wipe Navidrome data and restart fresh."
            warn "You will need to re-register via the web UI."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return
            fi
            cd "$SCRIPT_DIR"
            sg docker -c "docker compose down navidrome" > /dev/null 2>&1
            sg docker -c "docker volume rm privcloud_navidrome-data" > /dev/null 2>&1
            sg docker -c "docker compose up -d navidrome" > /dev/null 2>&1
            ok "Navidrome reset. Open to create a new account:"
            echo -e "    ${BLUE}http://$IP:4533${NC}"
            ;;
        4)
            echo ""
            warn "This will wipe Uptime Kuma data and restart fresh."
            warn "You will need to re-add all monitors."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return
            fi
            cd "$SCRIPT_DIR"
            sg docker -c "docker compose down uptime-kuma" > /dev/null 2>&1
            sg docker -c "docker volume rm privcloud_uptime-kuma-data" > /dev/null 2>&1
            sg docker -c "docker compose up -d uptime-kuma" > /dev/null 2>&1
            ok "Uptime Kuma reset. Open to create new account:"
            echo -e "    ${BLUE}http://$IP:3001${NC}"
            ;;
        0|*) return ;;
    esac
}

# ── SMB file sharing (Samba) ─────────────────────────
# Server-only install: a Samba container on host networking so phones and
# laptops can open chosen folders over Tailscale (smb://<tailscale-ip>).
# Host networking (not a published port) so boot order vs Tailscale does not
# matter and smbd sees the real client IP; access is gated three ways: Samba
# `hosts allow` (tailnet range only), firewalld (tailscale0 is trusted, 445 is
# never opened on the public zone) and one password-protected user.
# Each shared folder is its own share (named after the folder), never "all".
# Floating tag + Watchtower, like the other services.
_SMB_IMAGE="ghcr.io/servercontainers/samba:smbd-only-latest"
_SMB_DIR="/opt/samba"   # kept on Uninstall; samba.env (login + password) and shares.conf, root 600
_SMB_SETTLE=1           # seconds between "is it up yet" polls
_SMB_POLL=3             # seconds between phone-connect polls
_SMB_WAIT_TRIES=40      # x _SMB_POLL = 2 minutes
_SMB_NAMES=(); _SMB_PATHS=(); _SMB_USER=""; _SMB_PW=""; _SMB_REAL=""

_smb_exists()  { sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx samba; }
_smb_running() { sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx samba; }
_smb_listening() { sudo ss -ltnH 'sport = :445' 2>/dev/null | grep -q .; }

# The files folder FileBrowser serves (same .env value the compose file mounts).
_smb_files_path() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _env_get FILES_LOCATION "$SCRIPT_DIR/.env"
}

# 16 alphanumeric characters: easy to type on a phone keyboard.
_smb_gen_password() {
    local raw pw
    raw=$(openssl rand -base64 96) || return 1
    pw=$(printf '%s' "$raw" | LC_ALL=C tr -dc 'A-Za-z0-9')
    pw=${pw:0:16}
    (( ${#pw} == 16 )) || return 1
    printf '%s' "$pw"
}

# A typed password must survive the env file and the container's own scripts:
# docker's env-file is literal (spaces, $, quotes are fine), but the image runs
# `echo -e "$password"`, which turns a backslash into an escape, and a leading
# "-" can be read as an echo option. Prints the reason and returns 1 if bad.
_smb_pw_check() {
    local p=$1
    if (( ${#p} < 8 )); then echo "too short (at least 8 characters)"; return 1; fi
    if (( ${#p} > 64 )); then echo "too long (64 characters at most)"; return 1; fi
    if printf '%s' "$p" | LC_ALL=C grep -q '[^ -~]'; then echo "plain keyboard characters only (no accents or control characters)"; return 1; fi
    if [[ "$p" == *\\* ]]; then echo "a backslash (\\) would be mangled by Samba - pick another character"; return 1; fi
    if [[ "$p" == -* ]]; then echo "must not start with -"; return 1; fi
    if [[ "$p" == " "* || "$p" == *" " ]]; then echo "no space at the start or end"; return 1; fi
    return 0
}

# Ask for a password. Enter (or g) = generate; otherwise typed twice. Sets
# _SMB_PW. Returns 1 if input ends (no terminal).
_smb_ask_password() { # prompt-text
    local a b why
    while true; do
        printf '  %s' "$1"
        IFS= read -r -s a || { echo ""; return 1; }
        echo ""
        if [[ -z "$a" || "$a" == g ]]; then
            _SMB_PW=$(_smb_gen_password) || { fail "Could not generate a password (openssl failed)."; return 1; }
            return 0
        fi
        if ! why=$(_smb_pw_check "$a"); then fail "Password $why."; continue; fi
        printf '  Type it again to confirm: '
        IFS= read -r -s b || { echo ""; return 1; }
        echo ""
        if [[ "$a" != "$b" ]]; then fail "The two passwords did not match. Try again."; continue; fi
        _SMB_PW=$a
        return 0
    done
}

# ── folders ──
# Share name from a folder: basename, unsupported characters become "-".
_smb_name_for() {
    local n
    n=$(basename "$1" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-32)
    echo "${n:-share}"
}

# Is $1 usable as a share name that is not taken yet? Prints the reason if not.
_smb_name_ok() {
    local n=$1 i
    if [[ ! "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then echo "use letters, digits, - and _ (max 32)"; return 1; fi
    case "${n,,}" in global|homes|printers|ipc|print) echo "that name is reserved"; return 1 ;; esac
    for i in "${!_SMB_NAMES[@]}"; do
        if [[ "${_SMB_NAMES[$i],,}" == "${n,,}" ]]; then echo "already used by ${_SMB_PATHS[$i]}"; return 1; fi
    done
    return 0
}

# Validate a folder to share. On success sets _SMB_REAL (resolved path); on
# failure prints the reason and returns 1.
_smb_check_path() {
    local p=$1 r i
    _SMB_REAL=""
    if [[ "$p" != /* ]]; then fail "Use a full path starting with / (got '$p')."; return 1; fi
    if [[ "$p" == *[:\|]* || "$p" == *$'\n'* ]]; then fail "A path with ':' or '|' can't be used here."; return 1; fi
    if [[ ! -e "$p" ]]; then fail "'$p' does not exist."; return 1; fi
    r=$(realpath -e -- "$p" 2>/dev/null) || { fail "Could not resolve '$p'."; return 1; }
    if [[ "$r" == *[:\|]* || "$r" == *$'\n'* ]]; then fail "The resolved path ($r) has a ':' or '|' and can't be used here."; return 1; fi
    if [[ ! -d "$r" ]]; then fail "'$r' is not a folder."; return 1; fi
    case "$r" in
        /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/var|/var/*|/root|/root/*|/opt|/opt/*|/home|/mnt)
            fail "'$r' is a system location - sharing it would expose the system. Pick a folder of your own."; return 1 ;;
        /run|/run/*) if [[ "$r" != /run/media/?* ]]; then fail "'$r' is a system location (only /run/media/... drives can be shared)."; return 1; fi ;;
    esac
    if [[ ! -w "$r" ]]; then fail "'$r' is not writable by $(id -un) - sharing it would not let you save files."; return 1; fi
    for i in "${!_SMB_PATHS[@]}"; do
        if [[ "${_SMB_PATHS[$i]}" == "$r" ]]; then fail "'$r' is already shared as \"${_SMB_NAMES[$i]}\"."; return 1; fi
    done
    _SMB_REAL=$r
}

# Validate + add one folder to the in-memory list; asks for another name on a
# clash. Returns 1 (nothing added) on a bad folder or if the name prompt is
# left blank.
_smb_add_folder() {
    local name why
    _smb_check_path "$1" || return 1
    name=$(_smb_name_for "$_SMB_REAL")
    while ! why=$(_smb_name_ok "$name"); do
        warn "Share name \"$name\": $why."
        printf '  Another name for %s (Enter = skip this folder): ' "$_SMB_REAL"
        read -r name || return 1
        [[ -z "$name" ]] && { info "Skipped."; return 1; }
    done
    _SMB_NAMES+=("$name"); _SMB_PATHS+=("$_SMB_REAL")
}

# Maps _drive_verdict to ok / missing / unmounted / unknown. An empty folder on a
# real mount is fine to share; a bare folder on the system disk (drive not
# plugged in) or an autofs/stub mount is "unmounted"; unknown (no findmnt) is
# not ok, so every action that needs ok refuses.
_smb_folder_check() {
    case $(_drive_verdict "$1") in
        ok|empty) echo ok ;;
        missing)  echo missing ;;
        unknown)  echo unknown ;;
        *)        echo unmounted ;;
    esac
}

_smb_folder_reason() { # check-result
    case "$1" in
        ok) ;;
        missing) echo "folder missing" ;;
        unknown) echo "cannot check the drive (findmnt missing)" ;;
        *) echo "drive not mounted" ;;
    esac
}

# Saved share list -> _SMB_NAMES/_SMB_PATHS (root-only file, so sudo).
_smb_load() {
    local line
    _SMB_NAMES=(); _SMB_PATHS=()
    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        _SMB_NAMES+=("${line%%|*}"); _SMB_PATHS+=("${line#*|}")
    done < <(sudo cat "$_SMB_DIR/shares.conf" 2>/dev/null)
    (( ${#_SMB_NAMES[@]} > 0 ))
}

# Login + password back from the root-only env file -> _SMB_USER/_SMB_PW.
_smb_cur_login() {
    local line
    line=$(sudo grep -m1 '^ACCOUNT_' "$_SMB_DIR/samba.env" 2>/dev/null)
    [[ -n "$line" ]] || return 1
    _SMB_USER=${line#ACCOUNT_}; _SMB_USER=${_SMB_USER%%=*}
    _SMB_PW=${line#*=}
}

# The container's whole config as an env file (read once by --env-file; the
# password never touches argv). One SAMBA_VOLUME_CONFIG_s<N> per folder (the
# image evals the variable name, so it must not contain the share name).
_smb_env_content() { # user uid gid password   (uses _SMB_NAMES/_SMB_PATHS)
    local u=$1 grp="" i
    [[ "$3" != "$2" ]] && grp="; force group = smbshare"
    [[ "$3" != "$2" ]] && printf 'GROUP_smbshare=%s\n' "$3"
    printf '%s\n' \
        "ACCOUNT_$u=$4" \
        "UID_$u=$2" \
        "SAMBA_GLOBAL_STANZA=hosts allow = 100.64.0.0/10 fd7a:115c:a1e0::/48 127.0.0.1 ::1;hosts deny = ALL;server min protocol = SMB2;server smb encrypt = desired"
    for i in "${!_SMB_NAMES[@]}"; do
        printf '%s\n' "SAMBA_VOLUME_CONFIG_s$i=[${_SMB_NAMES[$i]}]; path = /shares/${_SMB_NAMES[$i]}; valid users = $u; guest ok = no; read only = no; browseable = yes; force user = $u$grp; veto files = /lost+found/.Trash-*/; delete veto files = no"
    done
}

# Is 445 reachable from the LAN? Prints yes|no|unknown (firewalld not running).
# No --zone: asks the default zone, where _fw_defaults opens ports.
_smb_fw_state() {
    local p s
    p=$(sudo firewall-cmd --query-port=445/tcp 2>/dev/null) || p=${p:-unknown}
    s=$(sudo firewall-cmd --query-service=samba 2>/dev/null) || s=${s:-unknown}
    if [[ "$p" == yes || "$s" == yes ]]; then echo yes
    elif [[ "$p" == no && "$s" == no ]]; then echo no
    else echo unknown; fi
}

_smb_fw_fix() {
    echo -e "    ${YELLOW}sudo firewall-cmd --permanent --remove-port=445/tcp --remove-service=samba && sudo firewall-cmd --reload${NC}"
}

# Write config + (re)create the container from _SMB_USER/_SMB_PW and the folder
# list, then verify it is running and listening. Never says "done" on failure;
# after the old container is gone a failure says so loudly. A container that
# was stopped stays stopped with autostart off (_svc_power stop, as Stop does).
_smb_apply() {
    local uid gid envc listc i mounts=() n up=0 was_stopped=0
    # Never let docker auto-create a missing bind source: check every folder that
    # will be shared BEFORE anything is written or removed (the running share
    # stays as it is). Manage folders drops a removed folder from the list
    # first, so removing a broken one is not blocked by itself.
    local bad="" c
    for i in "${!_SMB_NAMES[@]}"; do
        c=$(_smb_folder_check "${_SMB_PATHS[$i]}")
        [[ "$c" == ok ]] || bad+="    ${_SMB_NAMES[$i]} -> ${_SMB_PATHS[$i]}: $(_smb_folder_reason "$c")"$'\n'
    done
    if [[ -n "$bad" ]]; then
        fail "Not applied - these folders are not available:"
        printf '%s' "$bad"
        if _smb_exists; then
            echo -e "  Mount the drive (or restore the folder) and try again, or remove the folder in ${BOLD}Manage folders${NC}. The running share was not touched."
        else
            echo -e "  Mount the drive (or restore the folder) and try again. Nothing was changed."
        fi
        return 1
    fi
    uid=$(id -u); gid=$(id -g)
    envc=$(_smb_env_content "$_SMB_USER" "$uid" "$gid" "$_SMB_PW")
    listc=$(for i in "${!_SMB_NAMES[@]}"; do printf '%s|%s\n' "${_SMB_NAMES[$i]}" "${_SMB_PATHS[$i]}"; done)
    info "Writing $_SMB_DIR/samba.env + shares.conf (root only, mode 600)..."
    if ! { sudo install -d -m 755 "$_SMB_DIR" \
        && printf '%s\n' "$envc"  | sudo install -m 600 /dev/stdin "$_SMB_DIR/samba.env" \
        && printf '%s\n' "$listc" | sudo install -m 600 /dev/stdin "$_SMB_DIR/shares.conf"; }; then
        fail "Could not write the config under $_SMB_DIR - nothing was changed."
        return 1
    fi
    for i in "${!_SMB_NAMES[@]}"; do mounts+=(-v "${_SMB_PATHS[$i]}:/shares/${_SMB_NAMES[$i]}"); done
    # Fetch the image before touching a running container, so a failed
    # download never takes down a working share.
    if ! sudo docker image inspect "$_SMB_IMAGE" > /dev/null 2>&1; then
        info "Downloading Samba image..."
        if ! sudo docker pull "$_SMB_IMAGE" > /dev/null; then
            fail "Could not download $_SMB_IMAGE (no internet, or the registry is unreachable). Nothing was started or removed."
            return 1
        fi
    fi
    if _smb_exists; then
        # A deliberate Stop must survive a config change: remember it, recreate
        # with the new config, then Stop again below.
        _smb_running || was_stopped=1
        info "Recreating the Samba container..."
        sudo docker rm -f samba > /dev/null 2>&1
        if ! _container_gone samba; then
            fail "Could not remove the old container - it is still running with the OLD settings."
            return 1
        fi
    else
        info "Starting Samba container..."
    fi
    if sudo docker run -d --name samba --network host --restart=unless-stopped \
            --env-file "$_SMB_DIR/samba.env" "${mounts[@]}" "$_SMB_IMAGE" > /dev/null; then
        for n in 1 2 3 4 5 6 7 8; do
            if _smb_running && _smb_listening; then up=1; break; fi
            sleep "$_SMB_SETTLE"
        done
    fi
    if (( ! up )); then
        echo -e "  ${RED}✗ FILE SHARING IS NOT RUNNING.${NC} The old container is gone and the new one did not come up."
        sudo docker logs --tail 20 samba 2>&1
        echo -e "  ${BOLD}Recover:${NC} run ${BOLD}federver -> 16${NC} again (it reuses your saved folders and password), or ${BOLD}Start${NC} if the menu offers it."
        return 1
    fi
    if (( was_stopped )); then
        _svc_power stop samba || { fail "Saved, but could not stop the new container again - it is running (autostart on). Use Stop."; return 1; }
        ok "Saved. File sharing is stopped - Start (4) to use it."
        return 0
    fi
    ok "Samba running on port 445."
}

# ── what phones are doing ──
# Prints "ip|share|since" per open share (smbstatus -S). Args: docker words.
_smb_sessions() {
    "$@" exec samba smbstatus -S 2>/dev/null | awk '
        /^-+$/ {go=1; next}
        go && NF>=5 {t=""; for (i=4;i<=NF-2;i++) t=t (t?" ":"") $i; print $3 "|" $1 "|" t}'
}

# Tailscale device name for a tailnet IP (falls back to the IP).
_smb_devname() {
    local n
    n=$(tailscale status 2>/dev/null | awk -v ip="$1" '$1==ip{print $2; exit}')
    echo "${n:-$1}"
}

# One line per connected device: "name|shares opened|since HH:MM" (or "since
# Thu 23:50" when the earliest open is not from today). smbstatus -S rows are
# grouped by client IP (a device with two shares is one line). smbstatus prints
# its time in UTC with a date, so each one is parsed whole by `date -d` and the
# earliest picked by epoch, shown in this host's local time.
_smb_devices() { # docker words
    local sess ip name shares min="" e i sh t fmt=%H:%M
    sess=$(_smb_sessions "$@")
    for ip in $(cut -d'|' -f1 <<<"$sess" | sort -u); do
        name=$(_smb_devname "$ip"); shares=""; min=""
        while IFS='|' read -r i sh t; do
            [[ "$i" == "$ip" ]] || continue
            shares+="${shares:+, }$sh"
            e=$(date -d "$t" +%s 2>/dev/null) || continue
            [[ -z "$min" || "$e" -lt "$min" ]] && min=$e
        done <<<"$sess"
        fmt=%H:%M
        if [[ -n "$min" && "$(date -d "@$min" +%F)" != "$(date +%F)" ]]; then
            fmt="%a %H:%M"   # a weekday is unique for up to 6 days back; older gets a date
            [[ ! "$(date -d "@$min" +%F)" > "$(date -d '7 days ago' +%F)" ]] && fmt="%-d %b %H:%M"
        fi
        echo "$name|$shares|${min:+$(date -d "@$min" +"$fmt")}"
    done
}

_smb_plural() { (( $1 == 1 )) && echo "$1 device" || echo "$1 devices"; }

# One line of facts: state|folders|folders-not-available|devices ("none" = no container).
_smb_summary() { # docker words
    local st n=0 bad=0 d p k
    st=$(_ps_autostart "$@" 2>/dev/null | sed -n 's/^samba|//p' | head -1)
    [[ -z "$st" ]] && { echo none; return; }
    while IFS='|' read -r d p; do
        [[ "$d" == /shares/* ]] || continue
        n=$((n+1)); [[ "$(_smb_folder_check "$p")" == ok ]] || bad=$((bad+1))
    done < <("$@" inspect -f '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' samba 2>/dev/null)
    k=$(_smb_sessions "$@" | cut -d'|' -f1 | sort -u | awk 'END{print NR}')
    case "$st" in
        Up*) echo "running|$n|$bad|$k" ;;
        "stopped (autostart off)") echo "stopped-off|$n|$bad|$k" ;;
        *) echo "stopped|$n|$bad|$k" ;;
    esac
}

_smb_summary_render() { # summary-line [devices-lines]   (the (s) Status section)
    local st n bad k extra="" nm sh since
    IFS='|' read -r st n bad k <<<"$1"
    (( bad )) && extra=" (${bad} ${RED}✗${NC} not mounted)"
    case "$st" in
        running)     echo -e "    ${GREEN}✓${NC} running · $n folders$extra · $(_smb_plural "$k") connected"
                     while IFS='|' read -r nm sh since; do
                         [[ -n "$nm" ]] && printf '      %-16s %s   since %s\n' "$nm" "$sh" "$since"
                     done <<<"${2:-}" ;;
        stopped-off) echo -e "    ${RED}✗ stopped (autostart off)${NC}" ;;
        stopped)     echo -e "    ${RED}✗ not running${NC}" ;;
        *)           echo -e "    ${DIM}not set up (federver → 16)${NC}" ;;
    esac
}

# Full status block for the submenu (folders from the saved list, so a down
# container still shows what it should be sharing).
_smb_status() {
    local st i c pol fw sess shares since name
    echo ""
    echo -e "  ${BOLD}File sharing (SMB)${NC}"
    st=$(_ps_autostart sudo docker 2>/dev/null | sed -n 's/^samba|//p' | head -1)
    if [[ "$st" == Up* ]]; then echo -e "    State:     ${GREEN}running${NC}  ${DIM}($st)${NC}"
    elif [[ -n "$st" ]]; then   echo -e "    State:     ${RED}${st}${NC}"
    else                        echo -e "    State:     ${RED}not set up${NC}"; return 0
    fi
    pol=$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' samba 2>/dev/null)
    if [[ "$pol" == no ]]; then echo -e "    Autostart: ${RED}off${NC}  ${DIM}(stays down after a reboot)${NC}"
    else echo -e "    Autostart: ${GREEN}on${NC}"; fi
    if _smb_listening; then echo -e "    Port 445:  ${GREEN}listening${NC}"
    else                    echo -e "    Port 445:  ${RED}not listening${NC}"; fi
    _smb_load || true
    echo -e "    Folders:"
    for i in "${!_SMB_NAMES[@]}"; do
        c=$(_smb_folder_check "${_SMB_PATHS[$i]}")
        if [[ "$c" == ok ]]; then echo -e "      ${GREEN}✓${NC} ${_SMB_NAMES[$i]}  ${DIM}${_SMB_PATHS[$i]}${NC}"
        else echo -e "      ${RED}✗${NC} ${_SMB_NAMES[$i]}  ${DIM}${_SMB_PATHS[$i]}${NC}  ${RED}$(_smb_folder_reason "$c")${NC}"; fi
    done
    case "$(_smb_fw_state)" in
        yes) echo -e "    Firewall:  ${RED}✗ 445 open on the LAN${NC}"; _smb_fw_fix ;;
        no)  echo -e "    Firewall:  ${GREEN}LAN closed${NC}  ${DIM}(Tailscale only)${NC}" ;;
        *)   echo -e "    Firewall:  ${YELLOW}unknown${NC}" ;;
    esac
    sess=$(_smb_devices sudo docker)
    echo -e "    Connected:"
    if [[ -z "$sess" ]]; then
        echo -e "      ${DIM}nobody right now (an iPhone drops idle connections: none = no recent use)${NC}"
    else
        while IFS='|' read -r name shares since; do
            echo -e "      $name  ${DIM}opened: $shares  since $since${NC}"
        done <<<"$sess"
    fi
}

# The connect box. Args are plain values so it can be tested.
_smb_connect_box() { # tailscale-ip user password
    local i
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Connect to your folders${NC}"
    echo ""
    echo -e "    Server:    ${BLUE}smb://$1${NC}"
    echo -e "    User:      ${BOLD}$2${NC}"
    echo -e "    Password:  ${BOLD}$3${NC}"
    echo -e "    Folders:   $(printf '%s ' "${_SMB_NAMES[@]}")"
    echo ""
    echo -e "  ${BOLD}iPhone / iPad${NC} (Tailscale app connected)"
    echo -e "    Files -> ... -> Connect to Server -> ${BOLD}smb://$1${NC} -> Connect"
    echo -e "    Registered User -> $2 + password above -> pick a folder"
    echo -e "  ${BOLD}Android${NC} (Material Files app, Tailscale connected)"
    echo -e "    Add storage -> SMB server -> host ${BOLD}$1${NC}, user $2 + password above"
    echo -e "  ${BOLD}Laptop${NC}: file manager -> Connect to server -> ${BOLD}smb://$1${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Optional live check after setup: poll smbstatus until a phone shows up.
_smb_wait_phone() {
    local n s ip share rc
    echo ""
    echo -e "  Connect your phone now — waiting... ${DIM}(Enter = skip)${NC}"
    for ((n = 0; n < _SMB_WAIT_TRIES; n++)); do
        rc=0; read -r -t "$_SMB_POLL" || rc=$?
        (( rc > 128 )) || { info "Skipped."; return 0; }   # Enter (0) or end of input
        s=$(_smb_sessions sudo docker | head -1)
        if [[ -n "$s" ]]; then
            ip=${s%%|*}; share=${s#*|}; share=${share%%|*}
            ok "$(_smb_devname "$ip") connected, opened \"$share\""
            return 0
        fi
    done
    warn "No phone connected within the wait. Common causes: Tailscale is off on the phone, or the password was typed wrong."
    info "Try later: federver -> 16 shows connected devices."
}

# ── set up ──
# Set up's Reuse found saved folders that are not available: ask per folder
# whether to drop it (y/N). A kept one makes _smb_apply refuse; nothing is written here.
_smb_offer_drop() {
    local i c r keepn=() keepp=()
    for i in "${!_SMB_NAMES[@]}"; do
        c=$(_smb_folder_check "${_SMB_PATHS[$i]}")
        if [[ "$c" != ok ]]; then
            echo -e "  ${RED}✗${NC} ${_SMB_NAMES[$i]} -> ${_SMB_PATHS[$i]}: $(_smb_folder_reason "$c")"
            printf '  Stop sharing "%s"? Files are NOT deleted. [y/N] ' "${_SMB_NAMES[$i]}"
            read -n 1 -r r
            echo ""
            [[ "$r" =~ ^[Yy]$ ]] && continue
        fi
        keepn+=("${_SMB_NAMES[$i]}"); keepp+=("${_SMB_PATHS[$i]}")
    done
    _SMB_NAMES=("${keepn[@]}"); _SMB_PATHS=("${keepp[@]}")
}

_smb_setup() {
    local user ip f first=1 saved=0 keep_pw=0
    user=$(id -un)
    echo -e "  Shares folders from this server with the Files app on iPhone/Android and with"
    echo -e "  laptops. Reachable over Tailscale only, never from the open home network."
    echo ""
    echo -e "  ${BOLD}What Set up installs:${NC}"
    echo -e "    • Samba file server as a Docker container \"samba\""
    echo -e "      (image $_SMB_IMAGE, downloaded now, ~20 MB RAM)"
    echo -e "    • Settings in $_SMB_DIR (folders + password, root only)"
    echo -e "    • Nothing installed on the system itself (no dnf packages)"
    echo -e "  Same rules as the other containers: autostart on (Stop turns it off),"
    echo -e "  Watchtower keeps it updated, included in Start All / Stop All and (s) Status."
    echo -e "  Uninstall removes the container and keeps $_SMB_DIR."
    echo ""
    printf '  Continue? [Y/n] '
    read -n 1 -r
    echo ""
    if [[ "$REPLY" =~ ^[Nn]$ ]]; then info "Cancelled. Nothing changed."; return 0; fi
    echo ""
    if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        fail "Login name '$user' is not usable as a Samba user (lowercase letters, digits, _ and - only)."
        return 1
    fi
    ip=$(_ts_ipv4)
    if [[ -z "$ip" ]]; then
        fail "Tailscale is not connected on this server. File sharing is tailnet-only - run federver -> 8 first."
        return 1
    fi
    ok "Tailscale connected ($ip)"
    if _smb_listening; then
        fail "Port 445 is already in use:"
        sudo ss -ltnpH 'sport = :445' 2>/dev/null | sed 's/^/    /'
        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx samba-poc; then
            echo -e "  The Samba proof-of-concept container is still there. Remove it first:"
            echo -e "    ${YELLOW}cd ~/samba-poc && docker compose -p samba-poc down && rm -rf ~/samba-poc${NC}"
        else
            echo -e "  Stop that service (a host Samba? ${YELLOW}sudo systemctl disable --now smb${NC}) and retry."
        fi
        return 1
    fi
    ok "Port 445 is free"
    case "$(_smb_fw_state)" in
        yes) fail "Firewall: port 445 is open to the home network (default zone). Close it first:"
             _smb_fw_fix
             return 1 ;;
        no)  ok "Firewall: 445 is not open to the home network" ;;
        *)   warn "Firewall: could not read the state (firewalld not running?). Make sure 445 is not open to the LAN." ;;
    esac
    echo ""

    # A previous (uninstalled) setup left its folders and password behind.
    if _smb_load && _smb_cur_login; then
        echo -e "  Saved setup found: ${#_SMB_NAMES[@]} folder(s) ($(printf '%s ' "${_SMB_NAMES[@]}"))."
        printf '  Reuse it, with the same password? [Y/n] '
        read -n 1 -r
        echo ""
        if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then saved=1; fi
    fi
    if (( saved )); then
        _smb_offer_drop
        if (( ${#_SMB_NAMES[@]} == 0 )); then
            saved=0; keep_pw=1
            info "No saved folder left - pick the folders to share (the saved password is kept)."
        fi
    fi
    if (( ! saved )); then
        _SMB_NAMES=(); _SMB_PATHS=()
        echo -e "  ${DIM}Tip: your files folder is $(_smb_files_path)${NC}"
        while true; do
            if (( first )); then printf '  Folder to share (type a path, Enter = cancel): '
            else printf '  Another folder? (path, Enter = done): '; fi
            read -r f || f=""
            if [[ -z "$f" ]]; then
                (( first )) && { info "Cancelled. Nothing changed."; return 0; }
                break
            fi
            if _smb_add_folder "$f"; then first=0; ok "Sharing ${_SMB_NAMES[-1]}"; fi
        done
        if (( ! keep_pw )); then
            _smb_ask_password "Password for $user (Enter = generate, or type one): " || { fail "No password set - nothing installed."; return 1; }
            _SMB_USER=$user
        fi
    fi
    _smb_apply || return 1
    _smb_connect_box "$ip" "$_SMB_USER" "$_SMB_PW"
    echo -e "  ${RED}Save the password${NC} - Manage password shows it again."
    _smb_wait_phone
    ok "File sharing set up: ${#_SMB_NAMES[@]} folders."
}

# ── manage folders ──
_smb_list_folders() {
    local i c
    echo ""
    for i in "${!_SMB_NAMES[@]}"; do
        c=$(_smb_folder_check "${_SMB_PATHS[$i]}")
        if [[ "$c" == ok ]]; then echo -e "    $((i+1))) ${_SMB_NAMES[$i]} -> ${_SMB_PATHS[$i]} ${GREEN}✓${NC}"
        else echo -e "    $((i+1))) ${_SMB_NAMES[$i]} -> ${_SMB_PATHS[$i]} ${RED}✗ $(_smb_folder_reason "$c")${NC}"; fi
    done
    echo ""
}

_smb_manage_folders() {
    local in i r
    if ! _smb_load || ! _smb_cur_login; then fail "Could not read the saved setup under $_SMB_DIR (sudo refused?)."; return 1; fi
    while true; do
        _smb_list_folders
        printf '  Type a path to add, a number to remove, Enter = back: '
        read -r in || in=""
        [[ -z "$in" ]] && return 0
        if [[ "$in" =~ ^[0-9]+$ ]]; then
            i=$((in-1))
            if (( in < 1 || i >= ${#_SMB_NAMES[@]} )); then fail "No folder number $in."; continue; fi
            if (( ${#_SMB_NAMES[@]} == 1 )); then
                fail "That is the last shared folder. To stop sharing everything use Uninstall."
                continue
            fi
            printf '  Stop sharing "%s"? Files are NOT deleted. [y/N] ' "${_SMB_NAMES[$i]}"
            read -n 1 -r r
            echo ""
            [[ "$r" =~ ^[Yy]$ ]] || { info "Kept."; continue; }
            unset '_SMB_NAMES[i]' '_SMB_PATHS[i]'
            _SMB_NAMES=("${_SMB_NAMES[@]}"); _SMB_PATHS=("${_SMB_PATHS[@]}")
            _smb_apply || return 1
            info "Phones that were open on it will lose the share."
        else
            _smb_add_folder "$in" || continue
            _smb_apply || return 1
            ok "Now sharing ${_SMB_NAMES[-1]}. Connected phones must reconnect."
        fi
    done
}

# ── manage password ──
_smb_manage_password() {
    local ip in
    if ! _smb_cur_login; then fail "Could not read $_SMB_DIR/samba.env (sudo refused or file missing)."; return 1; fi
    _smb_load || true
    ip=$(_ts_ipv4)
    _smb_connect_box "${ip:-<server tailscale ip>}" "$_SMB_USER" "$_SMB_PW"
    printf '  New password (Enter = keep, g = generate, or type one): '
    IFS= read -r -s in || in=""
    echo ""
    [[ -z "$in" ]] && { info "Password kept."; return 0; }
    if [[ "$in" == g ]]; then
        _SMB_PW=$(_smb_gen_password) || { fail "Could not generate a password (openssl failed)."; return 1; }
    else
        local why b
        if ! why=$(_smb_pw_check "$in"); then fail "Password $why. Nothing changed."; return 1; fi
        printf '  Type it again to confirm: '
        IFS= read -r -s b || b=""
        echo ""
        if [[ "$in" != "$b" ]]; then fail "The two passwords did not match. Nothing changed."; return 1; fi
        _SMB_PW=$in
    fi
    _smb_apply || return 1
    ok "Password changed. Phones must re-enter it. New password: ${BOLD}$_SMB_PW${NC}"
}

_smb_uninstall() {
    echo ""
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE file sharing (Samba)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} Stop + remove the samba container (phones lose access)"
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} $_SMB_DIR/ (login, password, folder list); your files are never touched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete samba || return 0
    info "Removing samba container..."
    sudo docker rm -f samba > /dev/null 2>&1
    if ! _container_gone samba; then
        fail "Container 'samba' is still present (or docker could not be queried) - not removed."
        return 1
    fi
    ok "File sharing removed."
    echo -e "  ${DIM}Config kept at $_SMB_DIR. To wipe it:${NC} sudo rm -rf $_SMB_DIR"
}

step_samba() {
    info "Opens folders on this server to phones and laptops over Tailscale (SMB)."
    echo ""
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed. Run step 5 first."
        return 1
    fi
    local choice
    if ! _smb_exists; then
        echo -e "  Not set up yet. Set up picks the folders, makes a password and starts sharing."
        echo ""
        echo -e "  ${BOLD}1)${NC} Set up"
        echo -e "  ${BOLD}0)${NC} Back"
        echo ""
        read -p "  Choose: " choice
        case $choice in
            1) _smb_setup ;;
            0|*) return ;;
        esac
        return
    fi
    _smb_status
    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh"
    echo -e "  ${BOLD}2)${NC} Manage folders             ${DIM}<- add or stop sharing folders${NC}"
    echo -e "  ${BOLD}3)${NC} Manage password           ${DIM}<- show it, change it${NC}"
    echo -e "  ${BOLD}4)${NC} Start"
    echo -e "  ${BOLD}5)${NC} Stop"
    echo -e "  ${BOLD}6)${NC} Restart"
    echo -e "  ${BOLD}7)${NC} ${RED}Uninstall${NC}                 ${DIM}<- remove container, keep $_SMB_DIR${NC}"
    echo -e "  ${BOLD}0)${NC} Back"
    echo ""
    read -p "  Choose: " choice
    case $choice in
        1) _smb_status ;;
        2) _smb_manage_folders ;;
        3) _smb_manage_password ;;
        4) info "Starting...";   _svc_power start samba   && ok "Started."   || { fail "Start failed.";   return 1; } ;;
        5) info "Stopping...";   _svc_power stop samba    && ok "Stopped."   || { fail "Stop failed.";    return 1; } ;;
        6) info "Restarting..."; _svc_power restart samba && ok "Restarted." || { fail "Restart failed."; return 1; } ;;
        7) _smb_uninstall ;;
        0|*) return ;;
    esac
}
# ── end SMB file sharing ─────────────────────────────

# ── CLI argument handling (used by SSH routing) ─────
# `setup.sh --run-job <name>`: what a sync-job launcher runs (cron / systemd timer).
# Output goes to the job's log, as before; the exit code is the job's.
if [[ "${1:-}" == "--run-job" && -n "${2:-}" ]]; then
    mkdir -p "$HOME/.local/share/sync-jobs"
    exec >>"$HOME/.local/share/sync-jobs/$2.log" 2>&1
    _sync_job_run "$2"
    exit $?
fi

if [[ "${1:-}" == "--run" && -n "${2:-}" ]]; then
    # Guard against stale checkouts: if the requested function doesn't exist
    # in this copy of setup.sh, auto-pull from main and re-exec. One retry
    # only — if it's still missing after pull, the function genuinely doesn't
    # exist and we bail with an error.
    if ! declare -F "$2" >/dev/null; then
        if [[ "${_SETUP_RETRIED:-}" == "1" ]]; then
            fail "Step '$2' is not defined even after git pull."
            exit 1
        fi
        info "Step '$2' not found — pulling latest from main..."
        git pull --ff-only > /dev/null 2>&1 || true
        export _SETUP_RETRIED=1
        exec "$0" "$@"
    fi
    "$2"
    exit $?
fi

# ── Main loop ────────────────────────────────────────
# Server gets a reduced menu (bootstrap + status + power). Laptop gets
# everything. This enforces "always run from the laptop" at the UI level
# instead of via error messages 2 menus deep.
if _is_server; then
    while true; do
        show_menu
        read -p "  Choose: " choice
        case $choice in
            1)  run_step "[1] Enable SSH + auto-login + hostname" step_ssh ;;
            s)  run_step "[s] Status" step_status ;;
            p)  run_step "[p] Power" step_power ;;
            e)  run_step "[e] Emergency restart" step_emergency ;;
            0)  echo "Bye."; exit 0 ;;
            *)  echo -e "  ${DIM}Run ${BOLD}${YELLOW}\"federver\"${NC} ${DIM}from your laptop for the full menu.${NC}"
                read -p "  Press Enter..." -r ;;
        esac
    done
else
    # Laptop manages a remote server — make sure we know which one before
    # showing the menu (prompts once, then reads from FEDERVER_CONFIG).
    _require_server_config
    _resolve_server_endpoint
    while true; do
        show_menu
        read -p "  Choose: " choice
        case $choice in
            1)  run_step "[1] Enable SSH + auto-login + hostname" step_ssh ;;
            2)  run_step "[2] SSH key auth" step_sshkey ;;
            3)  run_step "[3] System update" "_on_server step_update" ;;
            4)  run_step "[4] Auto-updates" "_on_server step_autoupdates" ;;
            5)  run_step "[5] Install Docker" "_on_server step_docker" ;;
            6)  run_step "[6] Manage firewall" "_on_server step_firewall" ;;
            7)  run_step "[7] Manage services" step_services_wrapper ;;
            8)  run_step "[8] Manage Tailscale" step_tailscale ;;
            9)  run_step "[9] Manage WireGuard" "_on_server step_wireguard" ;;
            10) run_step "[10] Manage AdGuard" "_on_server step_adguard" ;;
            11) run_step "[11] Manage storage" "_on_server step_storage" ;;
            12) run_step "[12] Manage Syncthing" step_syncthing ;;
            13) run_step "[13] Manage remote desktop" "_on_server step_remotedesktop" ;;
            14) run_step "[14] Manage sync and backups" step_manage_sync ;;
            15) run_step "[15] Save to pass" step_save_to_pass ;;
            16) run_step "[16] Connect phone (Files app)" "_on_server step_samba" ;;
            s)  run_step "[s] Status" step_status ;;
            i)  run_step "[i] Immich (privcloud)" step_immich ;;
            p)  run_step "[p] Power" step_power ;;
            r)  run_step "[r] Reset password" "_on_server step_reset_password" ;;
            a)  run_step "Run all (3-7)" "_on_server run_all" ;;
            0)  echo "Bye."; exit 0 ;;
            *)  echo -e "  ${RED}Invalid choice.${NC}" ;;
        esac
    done
fi
