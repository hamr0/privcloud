#!/bin/bash
# Federver — Fedora XFCE server setup & management menu
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
#      cd ~/PycharmProjects/privcloud && ./setup.sh
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

SERVER_USER="ahassan"
SERVER_IP="192.168.178.180"

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

# Run a step with clear screen and success/fail banner
run_step() {
    local step_name="$1"
    local step_func="$2"
    clear
    echo -e "${BOLD}${BLUE}=== $step_name ===${NC}"
    echo ""
    if $step_func; then
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

_on_server() {
    local step="$1"
    if _is_server; then
        "$step"
    else
        info "This step runs on the server. Connecting via SSH..."
        echo ""
        local dry=""
        [[ "$DRY_RUN" == "1" ]] && dry="--dry-run "
        ssh -t "$SERVER_USER@$SERVER_IP" "cd ~/privcloud && ./setup.sh ${dry}--run $step"
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

step_emergency() {
    warn "Emergency restart — this will restart ALL containers and restore DNS."
    echo ""
    info "Actions:"
    info "  1. Re-enable systemd-resolved stub (restores local DNS if AdGuard is broken)"
    info "  2. Start all Docker containers (compose stack + AdGuard + Syncthing)"
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
    for c in adguard syncthing; do
        sudo docker update --restart=unless-stopped "$c" > /dev/null 2>&1 || true
        sudo docker start "$c" > /dev/null 2>&1 || true
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
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  Federver — Fedora XFCE Server Manager"
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
    echo -e "  Running from: ${YELLOW}server${NC}"
    echo -e "  ${DIM}For the full menu, run ${BOLD}${YELLOW}\"federver\"${NC} ${DIM}from your laptop.${NC}"
    echo -e "${BOLD}========================================${NC}"
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
    echo -e "  Running from: ${GREEN}laptop${NC}"
    echo -e "${BOLD}========================================${NC}"
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
    echo -e "  ${BOLD}8)${NC}  Setup backups + disk monitoring"
    echo -e "  ${BOLD}9)${NC}  Configure log rotation"
    echo ""
    echo -e "  ${DIM}-- Extras (optional, run anytime) --${NC}"
    echo -e "  ${BOLD}10)${NC} Manage Tailscale                    ${DIM}← install, status, up/down${NC}"
    echo -e "  ${BOLD}11)${NC} Manage WireGuard                    ${DIM}← install, peers, QR, remove${NC}"
    echo -e "  ${BOLD}12)${NC} Manage AdGuard                      ${DIM}← install DNS ad blocker, uses Tailscale${NC}"
    echo -e "  ${BOLD}13)${NC} Manage storage                      ${DIM}← USB drives, media/data paths${NC}"
    echo -e "  ${BOLD}14)${NC} Manage Syncthing                    ${DIM}← real-time bidirectional file sync${NC}"
    echo -e "  ${BOLD}15)${NC} Manage remote desktop               ${DIM}← install, access XFCE via RDP${NC}"
    echo ""
    echo -e "  ${DIM}-- Immich photo management --${NC}"
    echo -e "  ${BOLD}i)${NC}  Immich (privcloud)                  ${DIM}← start/stop/status/update/backup${NC}"
    echo ""
    echo -e "  ${DIM}-- Tools --${NC}"
    echo -e "  ${BOLD}16)${NC} Manage sync                         ${DIM}← transfer, schedule, cron jobs${NC}"
    echo -e "  ${BOLD}17)${NC} Save to pass                        ${DIM}← from laptop, backup everything to pass${NC}"
    echo ""
    echo -e "  ${BOLD}s)${NC}  Status     ${BOLD}i)${NC}  Immich     ${BOLD}p)${NC}  Power     ${BOLD}r)${NC}  Reset password     ${BOLD}a)${NC}  Run all (3-9)     ${BOLD}0)${NC}  Exit"
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
    echo -e "  Then SSH in and continue with steps 3-11."
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
    echo -e "     ${BOLD}cd federver && ./setup.sh${NC}   (then pick step 6)"
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
    echo -e "  ${BOLD}0)${NC} Cancel"
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

_ts_status() {
    echo ""
    if ! command -v tailscale &>/dev/null; then
        fail "Tailscale not installed."
        return 1
    fi
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    echo -e "  ${BOLD}Tailscale status${NC}"
    if [[ -n "$ts_ip" ]]; then
        echo -e "    State:  ${GREEN}connected${NC}"
        echo -e "    IP:     ${BOLD}$ts_ip${NC}"
        echo -e "    Host:   ${BOLD}$(hostname)${NC} ${DIM}(MagicDNS)${NC}"
    else
        echo -e "    State:  ${RED}not connected${NC}"
    fi
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

    info "Bringing tailnet connection down..."
    sudo tailscale logout > /dev/null 2>&1 || true
    sudo tailscale down > /dev/null 2>&1 || true
    info "Disabling tailscaled..."
    sudo systemctl disable --now tailscaled > /dev/null 2>&1 || true
    info "Removing package..."
    sudo dnf remove -y tailscale > /dev/null 2>&1 || true
    ok "Tailscale removed."
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
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ -n "$ts_ip" ]]; then
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
    if tailscale ip -4 &>/dev/null; then
        local laptop_ts_ip
        laptop_ts_ip=$(tailscale ip -4)
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
    info "Disconnecting Tailscale on both laptop and server..."
    sudo tailscale down 2>/dev/null && ok "Laptop: disconnected." || warn "Laptop: not connected."
    ssh "$SERVER_USER@$SERVER_IP" "sudo tailscale down 2>/dev/null" \
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
    ssh "$SERVER_USER@$SERVER_IP" "sudo systemctl restart tailscaled 2>/dev/null" \
        && ok "Server: restarted." || warn "Server: failed."
}

_ts_uninstall_both() {
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE Tailscale (both laptop and server)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} Laptop: tailscale logout + disable tailscaled + dnf remove"
    echo -e "    ${RED}•${NC} Server: tailscale logout + disable tailscaled + dnf remove"
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
    _confirm_delete tailscale || return 0

    info "Removing from laptop..."
    sudo tailscale logout > /dev/null 2>&1 || true
    sudo tailscale down > /dev/null 2>&1 || true
    sudo systemctl disable --now tailscaled > /dev/null 2>&1 || true
    sudo dnf remove -y tailscale > /dev/null 2>&1 || true
    ok "Laptop: removed."

    info "Removing from server..."
    ssh "$SERVER_USER@$SERVER_IP" bash -s <<'REMOTE_TS_UNINSTALL'
        sudo tailscale logout > /dev/null 2>&1 || true
        sudo tailscale down > /dev/null 2>&1 || true
        sudo systemctl disable --now tailscaled > /dev/null 2>&1 || true
        sudo dnf remove -y tailscale > /dev/null 2>&1 || true
REMOTE_TS_UNINSTALL
    ok "Server: removed."
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

    # Check if both sides have Tailscale
    local laptop_installed=false server_installed=false
    command -v tailscale &>/dev/null && laptop_installed=true
    ssh "$SERVER_USER@$SERVER_IP" "command -v tailscale" &>/dev/null && server_installed=true

    # Fresh install: install both sides
    if [[ "$laptop_installed" == false || "$server_installed" == false ]]; then
        [[ "$laptop_installed" == false ]] && { _ts_install_laptop || return 1; }
        if [[ "$server_installed" == false ]]; then
            echo -e "  ${BOLD}── Server side ──${NC}"
            _on_server _ts_server_step
        fi
        return
    fi

    # Both installed — show status + unified management submenu
    echo -e "  ${BOLD}── Laptop ──${NC}"
    local laptop_ip
    laptop_ip=$(tailscale ip -4 2>/dev/null || echo "not connected")
    echo -e "    State:  $(if tailscale status &>/dev/null; then echo "${GREEN}connected${NC}"; else echo "${RED}disconnected${NC}"; fi)"
    echo -e "    IP:     $laptop_ip"
    echo ""

    echo -e "  ${BOLD}── Server ──${NC}"
    ssh "$SERVER_USER@$SERVER_IP" bash -s <<'REMOTE_TS_STATUS'
        ts_ip=$(tailscale ip -4 2>/dev/null || echo "not connected")
        if tailscale status &>/dev/null; then
            echo "    State:  connected"
        else
            echo "    State:  disconnected"
        fi
        echo "    IP:     $ts_ip"
        echo "    Host:   $(hostname) (MagicDNS)"
REMOTE_TS_STATUS

    echo ""
    echo -e "  ${BOLD}1)${NC} Refresh status"
    echo -e "  ${BOLD}2)${NC} Connect both             ${DIM}<- tailscale up${NC}"
    echo -e "  ${BOLD}3)${NC} Disconnect both          ${DIM}<- tailscale down${NC}"
    echo -e "  ${BOLD}4)${NC} Restart both             ${DIM}<- restart tailscaled service${NC}"
    echo -e "  ${BOLD}5)${NC} Re-authenticate server   ${DIM}<- new login URL${NC}"
    echo -e "  ${BOLD}6)${NC} ${RED}Uninstall both${NC}           ${DIM}<- remove from laptop + server${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
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
    echo -e "  ${BOLD}0)${NC} Cancel"
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
    echo -e "  ${BOLD}0)${NC} Cancel"
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

_storage_status() {
    echo ""
    source "$SCRIPT_DIR/.env" 2>/dev/null

    echo -e "  ${BOLD}Internal drives${NC}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL -n | grep -v loop | while IFS= read -r line; do
        if lsblk -o NAME,TRAN -n 2>/dev/null | grep "$(echo "$line" | awk '{print $1}' | tr -d '├─└─│ ')" | grep -q "usb"; then
            continue
        fi
        echo "    $line"
    done
    echo ""

    # USB drives
    local usb_drives
    local usb_disks
    usb_disks=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}')
    usb_drives=""
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
    df -h / /home /mnt/data 2>/dev/null | awk 'NR==1{printf "    %-25s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5} NR>1{printf "    %-25s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5}'
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

    if grep -q "$uuid" /etc/fstab 2>/dev/null; then
        ok "Already in fstab."
        if mountpoint -q "$mount_point" 2>/dev/null; then
            ok "Already mounted at $mount_point."
        else
            sudo mount -a
            ok "Mounted at $mount_point."
        fi
    else
        echo "UUID=$uuid $mount_point $fstype defaults,nofail 0 2" | sudo tee -a /etc/fstab > /dev/null
        sudo mount -a
        ok "Mounted /dev/$partition at $mount_point (permanent via fstab)."
    fi

    echo ""
    info "Contents:"
    ls "$mount_point" 2>/dev/null || true
}

_storage_unmount() {
    echo ""

    # Find USB-mounted partitions
    local usb_mounts
    local usb_disks
    usb_disks=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}')
    usb_mounts=""
    for d in $usb_disks; do
        usb_mounts+="$(lsblk -rno NAME,MOUNTPOINT,SIZE "/dev/$d" 2>/dev/null | awk '$2!=""')"$'\n'
    done
    usb_mounts=$(echo "$usb_mounts" | sed '/^$/d')

    if [[ -z "$usb_mounts" ]]; then
        fail "No mounted USB drives found."
        return 1
    fi

    echo -e "  ${BOLD}Mounted USB drives:${NC}"
    local idx=1
    declare -a mount_arr
    declare -a name_arr
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local mpoint=$(echo "$line" | awk '{print $2}')
        local size=$(echo "$line" | awk '{print $3}')
        echo -e "    ${BOLD}$idx)${NC} /dev/$name  ${mpoint}  ${size}"
        mount_arr[$idx]="$mpoint"
        name_arr[$idx]="$name"
        idx=$((idx + 1))
    done <<< "$usb_mounts"

    echo ""
    read -p "  Which drive to unmount? " umount_choice
    local mpoint="${mount_arr[$umount_choice]}"
    local devname="${name_arr[$umount_choice]}"

    if [[ -z "$mpoint" ]]; then
        fail "Invalid choice."
        return 1
    fi

    warn "This will unmount $mpoint (/dev/$devname)."
    warn "Make sure no services are using files on this drive."
    read -p "  Continue? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi

    sudo umount "$mpoint" 2>/dev/null || true

    # Remove from fstab
    local uuid=$(sudo blkid -s UUID -o value "/dev/$devname" 2>/dev/null)
    if [[ -n "$uuid" ]]; then
        sudo sed -i "\|UUID=$uuid|d" /etc/fstab
    fi

    ok "Unmounted $mpoint and removed from fstab."
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

_storage_change_music() {
    echo ""
    source "$SCRIPT_DIR/.env" 2>/dev/null

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

    echo ""
    info "Redeploying Navidrome..."
    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d --force-recreate navidrome" 2>&1 | grep -v "^$"

    ok "Done. Navidrome now uses: $new_path"
}

_storage_change_files() {
    echo ""
    source "$SCRIPT_DIR/.env" 2>/dev/null

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
    source "$SCRIPT_DIR/.env" 2>/dev/null

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
    echo -e "  ${BOLD}Running containers${NC}"
    echo ""
    if ! command -v docker &>/dev/null; then
        fail "Docker not installed."
        return 1
    fi
    sg docker -c "docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null | sed 's/^/    /'
    echo ""
    local IP HOST TS_IP has_adguard=0
    IP=$(hostname -I | awk '{print $1}')
    HOST=$(hostname)
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q '^adguard$'; then
        has_adguard=1
    fi

    local has_syncthing=0
    if sg docker -c "docker ps --format '{{.Names}}'" 2>/dev/null | grep -q '^syncthing$'; then
        has_syncthing=1
    fi

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
    while IFS= read -r n; do
        local status
        status=$(sudo docker ps -a --filter "name=^${n}$" --format '{{.Status}}' 2>/dev/null)
        echo -e "  ${BOLD}$idx)${NC} $(printf '%-24s' "$n") ${DIM}${status}${NC}" >&2
        arr[$idx]="$n"
        idx=$((idx + 1))
    done <<< "$names"
    echo -e "  ${BOLD}0)${NC} Cancel" >&2
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
    if [[ "$target" == "all" ]]; then
        # Confirm before stopping everything — easy to hit by accident.
        if [[ "$action" == "stop" ]]; then
            echo ""
            warn "This will stop ALL containers on the server."
            read -p "  Continue? [y/N] " -n 1 -r
            echo ""
            [[ ! "$REPLY" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
        fi
        local SCRIPT_DIR
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        cd "$SCRIPT_DIR"
        case "$action" in
            start)
                for c in $(sudo docker ps -a --format '{{.Names}}'); do
                    sudo docker update --restart=unless-stopped "$c" > /dev/null 2>&1 || true
                done
                sg docker -c "docker compose up -d"
                # Also start standalone containers (not in docker-compose.yml)
                for c in adguard syncthing; do
                    sudo docker start "$c" > /dev/null 2>&1 || true
                done
                ;;
            stop)
                for c in $(sudo docker ps --format '{{.Names}}'); do
                    sudo docker update --restart=no "$c" > /dev/null 2>&1 || true
                done
                sg docker -c "docker compose stop"
                # Also stop standalone containers
                for c in adguard syncthing; do
                    sudo docker stop "$c" > /dev/null 2>&1 || true
                done
                ;;
            restart) sg docker -c "docker compose restart" ;;
        esac
    else
        # Extras with both-sides lifecycle have their own submenus.
        # Redirect so the laptop side is handled too.
        case "$target" in
            syncthing)
                warn "Syncthing has a laptop + server instance."
                info "Use ${BOLD}federver → 14${NC} to ${action} both sides."
                return 0
                ;;
            adguard)
                info "Use ${BOLD}federver → 12${NC} to manage AdGuard."
                return 0
                ;;
        esac
        case "$action" in
            start)
                sudo docker update --restart=unless-stopped "$target" > /dev/null 2>&1 || true
                sudo docker start "$target" > /dev/null
                ;;
            stop)
                sudo docker update --restart=no "$target" > /dev/null 2>&1 || true
                sudo docker stop "$target" > /dev/null
                ;;
            restart) sudo docker restart "$target" > /dev/null ;;
        esac
    fi
    ok "${action^} complete."
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
    local ts_state="${RED}stopped${NC}" st_state="${RED}stopped${NC}"
    if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
        local ip
        ip=$(tailscale ip -4 2>/dev/null || echo "")
        ts_state="${GREEN}connected${NC}  ${DIM}($ip)${NC}"
    fi
    if systemctl --user is-active syncthing &>/dev/null; then
        st_state="${GREEN}running${NC}  ${DIM}(http://localhost:8384)${NC}"
    elif ! command -v syncthing &>/dev/null; then
        st_state="${DIM}not installed${NC}"
    fi
    echo -e "    Tailscale:  $ts_state"
    echo -e "    Syncthing:  $st_state"
    echo ""
}

# Laptop-side wrapper for option 7. Shows the submenu locally, collects
# laptop service info for Status, and SSHes to the server for everything else.
step_services_wrapper() {
    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- running containers + URLs${NC}"
    echo -e "  ${BOLD}2)${NC} Start                      ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}3)${NC} Stop                       ${DIM}<- pick one or All (stays off across reboots)${NC}"
    echo -e "  ${BOLD}4)${NC} Restart                    ${DIM}<- pick one or All${NC}"
    echo -e "  ${BOLD}5)${NC} Logs                       ${DIM}<- tail -f a container${NC}"
    echo -e "  ${BOLD}6)${NC} Deploy / redeploy          ${DIM}<- first install or change data paths${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " svc_choice
    case $svc_choice in
        1)
            # Status: show laptop services locally, then SSH for server status
            _show_laptop_services
            _on_server _services_status
            ;;
        2) _on_server "_services_action start" ;;
        3) _on_server "_services_action stop" ;;
        4) _on_server "_services_action restart" ;;
        5) _on_server _services_logs ;;
        6) _on_server step_deploy ;;
        0|*) return ;;
    esac
}

step_services() {
    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- running containers + URLs${NC}"
    echo -e "  ${BOLD}2)${NC} Start                      ${DIM}<- pick one or All (re-enables autostart)${NC}"
    echo -e "  ${BOLD}3)${NC} Stop                       ${DIM}<- pick one or All (stays off across reboots)${NC}"
    echo -e "  ${BOLD}4)${NC} Restart                    ${DIM}<- pick one or All${NC}"
    echo -e "  ${BOLD}5)${NC} Logs                       ${DIM}<- tail -f a container${NC}"
    echo -e "  ${BOLD}6)${NC} Deploy / redeploy          ${DIM}<- first install or change data paths${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
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
    info "Default: /mnt/data (USB drive)"
    info "Internal drive example: /home/ahassan/data"
    echo ""
    read -p "  Base data path [/mnt/data]: " base_path
    base_path="${base_path:-/mnt/data}"
    base_path="${base_path/#\~/$HOME}"

    # Set up .env
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    fi

    _set_env "UPLOAD_LOCATION" "${base_path}/immich/upload" "$SCRIPT_DIR/.env"
    _set_env "DB_DATA_LOCATION" "${base_path}/immich/postgres" "$SCRIPT_DIR/.env"
    _set_env "MEDIA_LOCATION" "${base_path}/media" "$SCRIPT_DIR/.env"
    _set_env "MUSIC_LOCATION" "${base_path}/media/My Music" "$SCRIPT_DIR/.env"
    _set_env "FILES_LOCATION" "${base_path}" "$SCRIPT_DIR/.env"

    source "$SCRIPT_DIR/.env"
    sudo mkdir -p "$UPLOAD_LOCATION" "$DB_DATA_LOCATION" "$MEDIA_LOCATION" "$MUSIC_LOCATION" 2>/dev/null || true

    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d"

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
    echo -e "    Download ${BOLD}Amperfy${NC} from the App Store for iPhone playback"
    echo -e "    (background playback + offline cache via Subsonic API)."
    echo ""
    echo -e "  ${BOLD}FileBrowser${NC} (port 8080)"
    # Generate a random password, persist it across container recreations,
    # and save it to a root-readable file so the user can retrieve it later.
    local fb_pass
    fb_pass=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
    local fb_pass_file="$HOME/.privcloud/filebrowser.pass"
    mkdir -p "$(dirname "$fb_pass_file")"
    printf '%s\n' "$fb_pass" > "$fb_pass_file"
    chmod 600 "$fb_pass_file"
    sleep 2
    sg docker -c "docker stop filebrowser" > /dev/null 2>&1
    sg docker -c "docker run --rm -v privcloud_filebrowser-db:/database filebrowser/filebrowser:latest users update admin --password '$fb_pass' --database /database/filebrowser.db" > /dev/null 2>&1
    sg docker -c "docker start filebrowser" > /dev/null 2>&1
    echo -e "    Login: ${BOLD}admin${NC} / ${BOLD}$fb_pass${NC}"
    echo -e "    Saved to: ${BLUE}$fb_pass_file${NC} (retrieve with: ${BOLD}cat $fb_pass_file${NC})"
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

    info "Closing firewall ports..."
    sudo firewall-cmd --permanent --remove-port=8384/tcp  > /dev/null 2>&1 || true
    sudo firewall-cmd --permanent --remove-port=22000/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --permanent --remove-port=22000/udp > /dev/null 2>&1 || true
    sudo firewall-cmd --permanent --remove-port=21027/udp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true

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
        echo -e "    State:     ${RED}stopped${NC}"
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
    echo -e "  Laptop is already installed (option 14 handled it)."
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
    echo -e "  ${DIM}run federver → 17 (Save to pass) to back up the device identity${NC}"
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
    info "Stopping Syncthing on both laptop and server..."
    systemctl --user stop syncthing 2>/dev/null && ok "Laptop: stopped." || warn "Laptop: not running."
    ssh "$SERVER_USER@$SERVER_IP" "sudo docker update --restart=no syncthing >/dev/null 2>&1; sudo docker stop syncthing >/dev/null 2>&1" \
        && ok "Server: stopped." || warn "Server: not running."
}

_syncthing_start_both() {
    info "Starting Syncthing on both laptop and server..."
    systemctl --user start syncthing 2>/dev/null && ok "Laptop: started." || warn "Laptop: failed to start."
    ssh "$SERVER_USER@$SERVER_IP" "sudo docker update --restart=unless-stopped syncthing >/dev/null 2>&1; sudo docker start syncthing >/dev/null 2>&1" \
        && ok "Server: started." || warn "Server: failed to start."
}

_syncthing_restart_both() {
    info "Restarting Syncthing on both laptop and server..."
    systemctl --user restart syncthing 2>/dev/null && ok "Laptop: restarted." || warn "Laptop: failed."
    ssh "$SERVER_USER@$SERVER_IP" "sudo docker restart syncthing >/dev/null 2>&1" \
        && ok "Server: restarted." || warn "Server: failed."
}

_syncthing_uninstall_both() {
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${RED}DELETE Syncthing (both laptop and server)${NC}"
    echo ""
    echo -e "  ${BOLD}What will happen:${NC}"
    echo -e "    ${RED}•${NC} Laptop: systemctl --user disable --now syncthing + dnf remove"
    echo -e "    ${RED}•${NC} Server: stop + remove Docker container, close firewall ports"
    echo ""
    echo -e "  ${BOLD}Consequences:${NC}"
    echo -e "    ${YELLOW}•${NC} Real-time file sync between all devices stops"
    echo ""
    echo -e "  ${BOLD}Kept:${NC}"
    echo -e "    ${GREEN}•${NC} Server: /opt/syncthing/ (identity, config, pairings)"
    echo -e "    ${GREEN}•${NC} Laptop: ~/.local/state/syncthing/ (identity, config)"
    echo -e "    ${GREEN}•${NC} Core privcloud services untouched"
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _confirm_delete syncthing || return 0

    info "Removing from laptop..."
    systemctl --user disable --now syncthing 2>/dev/null || true
    sudo dnf remove -y syncthing > /dev/null 2>&1 || true
    ok "Laptop: removed."

    info "Removing from server..."
    ssh "$SERVER_USER@$SERVER_IP" bash -s <<'REMOTE_UNINSTALL'
        sudo docker rm -f syncthing > /dev/null 2>&1 || true
        sudo firewall-cmd --permanent --remove-port=8384/tcp  > /dev/null 2>&1 || true
        sudo firewall-cmd --permanent --remove-port=22000/tcp > /dev/null 2>&1 || true
        sudo firewall-cmd --permanent --remove-port=22000/udp > /dev/null 2>&1 || true
        sudo firewall-cmd --permanent --remove-port=21027/udp > /dev/null 2>&1 || true
        sudo firewall-cmd --reload > /dev/null 2>&1 || true
REMOTE_UNINSTALL
    ok "Server: removed."
    echo ""
    echo -e "  ${DIM}Server config kept at /opt/syncthing${NC}"
    echo -e "  ${DIM}Laptop config kept at ~/.local/state/syncthing${NC}"
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

    # ── Laptop-side: check if both sides are installed ──
    local laptop_installed=false server_installed=false
    command -v syncthing &>/dev/null && laptop_installed=true
    ssh "$SERVER_USER@$SERVER_IP" "sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^syncthing$'" 2>/dev/null && server_installed=true

    # Fresh install: install both sides
    if [[ "$laptop_installed" == false || "$server_installed" == false ]]; then
        [[ "$laptop_installed" == false ]] && { _syncthing_install_laptop || return 1; }
        if [[ "$server_installed" == false ]]; then
            echo -e "  ${BOLD}── Server side ──${NC}"
            _on_server _syncthing_server_step
        fi
        return
    fi

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
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^syncthing$'; then
            uptime=$(sudo docker ps --filter name=syncthing --format '{{.Status}}' 2>/dev/null)
            state="running  ($uptime)"
        fi
        ip=$(hostname -I | awk '{print $1}')
        echo "    State:     $state"
        echo "    Dashboard: http://$ip:8384"
        # Try several CLI shapes for Device ID (Syncthing 1.x vs 2.x)
        id=""
        for cmd in 'syncthing --device-id' 'syncthing show device-id' 'syncthing cli show system' 'cat /var/syncthing/config/config.xml'; do
            id=$(sudo docker exec syncthing sh -c "$cmd" 2>/dev/null | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -1 || echo "")
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
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " st_choice
    case $st_choice in
        1) step_syncthing ;;
        2)
            echo ""
            [[ -n "$laptop_id" ]] && echo -e "  ${BOLD}Laptop:${NC} $laptop_id"
            local server_id
            server_id=$(ssh "$SERVER_USER@$SERVER_IP" 'for cmd in "syncthing --device-id" "syncthing show device-id" "syncthing cli show system" "cat /var/syncthing/config/config.xml"; do id=$(sudo docker exec syncthing sh -c "$cmd" 2>/dev/null | grep -oE "[A-Z0-9]{7}(-[A-Z0-9]{7}){7}" | head -1); [[ -n "$id" ]] && echo "$id" && break; done' 2>/dev/null)
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
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " st_choice
    case $st_choice in
        1) _syncthing_status ;;
        2) _syncthing_show_device_id ;;
        3) _syncthing_show_paths ;;
        4) _syncthing_reapply_paths ;;
        5) info "Starting..."; sudo docker update --restart=unless-stopped syncthing > /dev/null 2>&1 || true; sudo docker start syncthing > /dev/null && ok "Started." ;;
        6) info "Stopping..."; sudo docker update --restart=no syncthing > /dev/null 2>&1 || true; sudo docker stop syncthing > /dev/null && ok "Stopped." ;;
        7) info "Restarting..."; sudo docker restart syncthing > /dev/null && ok "Restarted." ;;
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

    info "Stopping xrdp..."
    sudo systemctl disable --now xrdp > /dev/null 2>&1 || true
    info "Re-enabling lightdm..."
    sudo systemctl enable --now lightdm > /dev/null 2>&1 || true
    info "Closing firewall port 3389/tcp..."
    sudo firewall-cmd --permanent --remove-port=3389/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true
    info "Removing xrdp package..."
    sudo dnf remove -y xrdp > /dev/null 2>&1 || true
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
        echo -e "  ${BOLD}0)${NC} Cancel"
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
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "not connected")

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

    info "Stopping wg0..."
    sudo systemctl disable --now wg-quick@wg0 > /dev/null 2>&1 || true
    info "Closing firewall port 51820/udp..."
    sudo firewall-cmd --permanent --remove-port=51820/udp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true
    info "Removing packages..."
    sudo dnf remove -y wireguard-tools qrencode > /dev/null 2>&1 || true
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
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choose [1/2/3/4/5/6/0]: " wg_action

        case $wg_action in
            0) return ;;
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
        ssh -t "$SERVER_USER@$SERVER_IP" "cd ~/privcloud && ./privcloud"
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

    local IP TS_IP=""
    IP=$(hostname -I | awk '{print $1}')

    # ── Pre-check 1: Tailscale. AdGuard is only useful if something routes
    # traffic through it. Tailscale with "Override local DNS" is the only
    # rollout path we recommend (router DHCP-DNS and per-device manual DNS
    # both have too many footguns — see the install-level docs). If it's
    # missing, surface that BEFORE touching the system, not at the end.
    if command -v tailscale &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    fi
    if [[ -z "$TS_IP" && "$DRY_RUN" != "1" ]]; then
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}Tailscale is not installed (or not connected).${NC}"
        echo ""
        echo -e "  AdGuard needs a way to route devices' DNS lookups to it."
        echo -e "  The recommended path is ${BOLD}Tailscale global DNS${NC} — one setting,"
        echo -e "  every tailnet device uses AdGuard automatically (at home + roaming)."
        echo ""
        echo -e "  Without Tailscale you'd have to manually set DNS on every device,"
        echo -e "  which is fragile on Linux (IPv6 RA leaks) and iOS (Private Relay)."
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Cancel and install Tailscale first (step 10)  ${DIM}← recommended${NC}"
        echo -e "  ${BOLD}2)${NC} Continue anyway (I'll set DNS manually per device)"
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choose [1/2/0]: " ts_choice
        case "$ts_choice" in
            2) info "Continuing without Tailscale — manual per-device DNS on you." ;;
            *) info "Cancelled. Run step 10 to install Tailscale, then come back."; return 0 ;;
        esac
        echo ""
    fi

    # ── Idempotent: already running? Open management submenu.
    if [[ "$DRY_RUN" != "1" ]] && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^adguard$'; then
        ok "AdGuard is already running."
        echo -e "  Dashboard: ${BLUE}http://$IP${NC}"
        echo ""
        echo -e "  ${BOLD}1)${NC} Show Tailscale DNS guide"
        echo -e "  ${BOLD}2)${NC} Restart container"
        echo -e "  ${BOLD}3)${NC} Logs"
        echo -e "  ${BOLD}4)${NC} ${RED}Uninstall${NC}"
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choose: " ag_choice
        case "$ag_choice" in
            1) [[ -n "$TS_IP" ]] && _adguard_tailscale_guide "$TS_IP" || warn "Tailscale not detected." ;;
            2) info "Restarting..."; sudo docker restart adguard > /dev/null && ok "Restarted." ;;
            3) sudo docker logs --tail 50 -f adguard || true ;;
            4) _adguard_uninstall ;;
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
        echo -e "    1. Run ${BOLD}federver → 10${NC} to install Tailscale"
        echo -e "    2. Re-run ${BOLD}federver → 12${NC} — this time it'll detect Tailscale"
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
    printf "  Type ${BOLD}${RED}${name}${NC} to DELETE (blank = cancel): "
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

    info "Removing adguard container..."
    sudo docker rm -f adguard > /dev/null 2>&1 || true

    info "Closing firewall ports 53/udp, 53/tcp, 80/tcp..."
    sudo firewall-cmd --permanent --remove-port=53/udp > /dev/null 2>&1 || true
    sudo firewall-cmd --permanent --remove-port=53/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --permanent --remove-port=80/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true

    info "Re-enabling systemd-resolved stub listener..."
    sudo rm -f /etc/systemd/resolved.conf.d/disable-stub.conf
    sudo systemctl restart systemd-resolved > /dev/null 2>&1 || true

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

step_backup() {
    info "Creates a daily cron job to back up the Immich database."
    info "The DB contains your albums, face data, and metadata — hard to recreate."
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/.env" 2>/dev/null || true

    BACKUP_DIR="${DB_DATA_LOCATION:-/home/ahassan/data/immich/postgres}/../backups"
    BACKUP_DIR=$(realpath -m "$BACKUP_DIR")
    sudo mkdir -p "$BACKUP_DIR"

    sudo tee /usr/local/bin/immich-backup.sh > /dev/null <<'BACKUPEOF'
#!/bin/bash
BACKUP_DIR="__BACKUP_DIR__"
TIMESTAMP=$(date +%Y%m%d-%H%M)
mkdir -p "$BACKUP_DIR"
docker exec immich_postgres pg_dumpall -U postgres | gzip > "$BACKUP_DIR/immich-db-$TIMESTAMP.sql.gz"
find "$BACKUP_DIR" -name "immich-db-*.sql.gz" -mtime +7 -delete
echo "$(date): Backup complete → $BACKUP_DIR/immich-db-$TIMESTAMP.sql.gz"
BACKUPEOF

    sudo sed -i "s|__BACKUP_DIR__|$BACKUP_DIR|g" /usr/local/bin/immich-backup.sh
    sudo chmod +x /usr/local/bin/immich-backup.sh

    (sudo crontab -l 2>/dev/null | grep -v immich-backup; echo "0 3 * * * /usr/local/bin/immich-backup.sh >> /var/log/immich-backup.log 2>&1") | sudo crontab -

    ok "Daily backup configured:"
    echo -e "    Time:     ${BOLD}3am daily${NC}"
    echo -e "    Location: ${BOLD}$BACKUP_DIR${NC}"
    echo -e "    Keeps:    ${BOLD}last 7 days${NC}"
    echo ""
    info "Run manually: sudo /usr/local/bin/immich-backup.sh"

    # ── Disk space monitoring ──
    echo ""
    echo -e "  ${BOLD}Disk space monitor${NC}"
    info "Alerts when disk usage exceeds 85%."
    echo ""

    # ── Uptime Kuma push URL ──
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ACTION NEEDED — Uptime Kuma disk alert${NC}"
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
    read -p "  Paste the Push URL here (or Enter to skip): " push_url

    if [[ -n "$push_url" ]]; then
        sudo tee /usr/local/bin/disk-check.sh > /dev/null <<DISKEOF
#!/bin/bash
THRESHOLD=85
LOG="/var/log/disk-check.log"
PUSH_URL="$push_url"
ALERT=false

for mount in / /home /mnt/data; do
    if mountpoint -q "\$mount" 2>/dev/null || [ "\$mount" = "/" ]; then
        USAGE=\$(df "\$mount" 2>/dev/null | awk 'NR==2 {gsub("%",""); print \$5}')
        if [ -n "\$USAGE" ] && [ "\$USAGE" -gt "\$THRESHOLD" ]; then
            echo "\$(date): WARNING — \$mount is \${USAGE}% full" >> "\$LOG"
            ALERT=true
        fi
    fi
done

if \$ALERT; then
    curl -s "\$PUSH_URL?status=down&msg=Disk+above+85%25" > /dev/null 2>&1
else
    curl -s "\$PUSH_URL?status=up&msg=OK" > /dev/null 2>&1
fi
DISKEOF
        ok "Disk monitor with Uptime Kuma alerts configured."
    else
        sudo tee /usr/local/bin/disk-check.sh > /dev/null <<'DISKEOF'
#!/bin/bash
THRESHOLD=85
LOG="/var/log/disk-check.log"

for mount in / /home /mnt/data; do
    if mountpoint -q "$mount" 2>/dev/null || [ "$mount" = "/" ]; then
        USAGE=$(df "$mount" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
        if [ -n "$USAGE" ] && [ "$USAGE" -gt "$THRESHOLD" ]; then
            echo "$(date): WARNING — $mount is ${USAGE}% full" >> "$LOG"
        fi
    fi
done
DISKEOF
        ok "Disk monitor configured (log only, no Kuma alerts)."
        info "Run step 11 again to add Kuma alerts later."
    fi

    sudo chmod +x /usr/local/bin/disk-check.sh

    # Install (or migrate) the cron job — every 5 minutes. Drops any existing
    # disk-check line so re-running step 8 upgrades old hourly installs.
    (sudo crontab -l 2>/dev/null | grep -v 'disk-check'; echo "*/5 * * * * /usr/local/bin/disk-check.sh") | sudo crontab -

    # Fire it once immediately so the Kuma monitor turns green straight away
    # instead of waiting up to 5 minutes for the first cron tick.
    if [[ -n "$push_url" ]]; then
        info "Sending first heartbeat to Kuma..."
        sudo /usr/local/bin/disk-check.sh && ok "Heartbeat sent — Kuma monitor should be green."
    fi

    ok "Disk space check runs every 5 minutes (alerts above 85%)."
    info "Check log: cat /var/log/disk-check.log"
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

_sync_execute_or_schedule() {
    local sync_direction="$1"
    local src_path="$2"
    local dest_path="$3"
    local rsync_cmd="$4"
    local pre_cmd="$5"

    echo ""
    echo -e "  ${BOLD}1)${NC} Run now"
    echo -e "  ${BOLD}2)${NC} Schedule as recurring job"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choice [1/2/0]: " action
    case $action in
        0)
            info "Cancelled."
            return
            ;;
        1)
            [[ -n "$pre_cmd" ]] && eval "$pre_cmd"
            eval "$rsync_cmd" || { fail "Sync failed."; return 1; }
            echo ""
            ok "Sync complete."
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}Schedule:${NC}"
            echo -e "    ${BOLD}1)${NC} Every hour"
            echo -e "    ${BOLD}2)${NC} Every 6 hours"
            echo -e "    ${BOLD}3)${NC} Daily at 2am"
            echo -e "    ${BOLD}4)${NC} Custom cron expression"
            echo ""
            read -p "  Schedule [1/2/3/4]: " sched_choice
            local schedule
            case $sched_choice in
                1) schedule="0 * * * *" ;;
                2) schedule="0 */6 * * *" ;;
                3) schedule="0 2 * * *" ;;
                4)
                    read -p "  Cron expression (e.g. '*/30 * * * *'): " schedule
                    if [[ -z "$schedule" ]]; then
                        fail "Empty schedule. Aborting."
                        return 1
                    fi
                    ;;
                *) fail "Invalid choice."; return 1 ;;
            esac

            local default_name
            default_name=$(basename "$src_path" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
            read -p "  Name for this job [${default_name}]: " job_name
            job_name="${job_name:-$default_name}"
            job_name=$(echo "$job_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')

            local script_dir="$HOME/.local/bin"
            local log_dir="$HOME/.local/share/sync-jobs"
            mkdir -p "$script_dir" "$log_dir"

            local script_path="$script_dir/sync-${job_name}.sh"
            cat > "$script_path" <<SYNCSCRIPT
#!/bin/bash
# Sync job: ${job_name}
# Direction: ${sync_direction}
# Source: ${src_path}
# Destination: ${dest_path}
# Created: $(date '+%Y-%m-%d %H:%M')

SERVER_USER="$SERVER_USER"
SERVER_IP="$SERVER_IP"

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting sync: ${job_name}"
${pre_cmd:+$pre_cmd}
$rsync_cmd
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Sync finished: ${job_name} (exit \$?)"
SYNCSCRIPT
            chmod +x "$script_path"

            (crontab -l 2>/dev/null | grep -v "sync-${job_name}.sh"; echo "$schedule $script_path >> $log_dir/${job_name}.log 2>&1") | crontab -

            ok "Scheduled sync job '${job_name}'"
            info "Script: $script_path"
            info "Log:    $log_dir/${job_name}.log"
            info "Schedule: $schedule"
            echo ""
            info "Running once now to verify..."
            [[ -n "$pre_cmd" ]] && eval "$pre_cmd"
            eval "$rsync_cmd" || { fail "Sync failed on initial run."; return 1; }
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
    case "$expr" in
        "* * * * *")        echo "every minute" ;;
        "*/5 * * * *")      echo "every 5 min" ;;
        "*/10 * * * *")     echo "every 10 min" ;;
        "*/15 * * * *")     echo "every 15 min" ;;
        "*/30 * * * *")     echo "every 30 min" ;;
        "0 * * * *")        echo "every hour" ;;
        "0 */2 * * *")      echo "every 2 hours" ;;
        "0 */3 * * *")      echo "every 3 hours" ;;
        "0 */6 * * *")      echo "every 6 hours" ;;
        "0 */12 * * *")     echo "every 12 hours" ;;
        0\ [0-9]\ \*\ \*\ \*)   echo "daily at $(echo "$expr" | awk '{print $2}')am" ;;
        0\ [0-1][0-9]\ \*\ \*\ \*) echo "daily at $(echo "$expr" | awk '{print $2}'):00" ;;
        0\ [2][0-3]\ \*\ \*\ \*)   echo "daily at $(echo "$expr" | awk '{print $2}'):00" ;;
        *)                  echo "$expr" ;;
    esac
}

_sync_show_status() {
    # Fetch server-side crons FIRST (may prompt for sudo password) so the
    # password prompt appears before any table rendering.
    local server_crons=""
    info "Fetching server cron jobs..."
    ssh -t "$SERVER_USER@$SERVER_IP" 'sudo -v' 2>/dev/null
    server_crons=$(ssh "$SERVER_USER@$SERVER_IP" 'sudo crontab -l 2>/dev/null' 2>/dev/null) || true
    if [[ -z "$server_crons" ]] || ! echo "$server_crons" | grep -qE "immich-backup|disk-check"; then
        server_crons=$(ssh "$SERVER_USER@$SERVER_IP" '
            [[ -x /usr/local/bin/immich-backup.sh ]] && echo "0 3 * * * /usr/local/bin/immich-backup.sh"
            [[ -x /usr/local/bin/disk-check.sh ]]    && echo "*/5 * * * * /usr/local/bin/disk-check.sh"
        ' 2>/dev/null) || server_crons=""
    fi

    echo ""
    echo -e "  ${BOLD}Scheduled tasks${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  ${BOLD}%-20s %-18s %-16s %-10s %s${NC}\n" "Name" "Schedule" "When" "Type" "Note"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local found_any=false

    if [[ -n "$server_crons" ]]; then
        echo "$server_crons" | while IFS= read -r line; do
            [[ "$line" =~ ^#|^$ ]] && continue
            if echo "$line" | grep -q "immich-backup"; then
                local sched when
                sched=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                when=$(_cron_to_english "$sched")
                printf "  %-20s %-18s %-16s %-10s %s\n" "immich-backup" "$sched" "$when" "backup" "(step 8)"
                found_any=true
            elif echo "$line" | grep -q "disk-check"; then
                local sched when
                sched=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                when=$(_cron_to_english "$sched")
                printf "  %-20s %-18s %-16s %-10s %s\n" "disk-check" "$sched" "$when" "monitor" "(step 8)"
                found_any=true
            fi
        done
    fi

    # Laptop-side sync crons
    local laptop_crons
    laptop_crons=$(crontab -l 2>/dev/null) || laptop_crons=""

    if [[ -n "$laptop_crons" ]]; then
        echo "$laptop_crons" | while IFS= read -r line; do
            if echo "$line" | grep -q "sync-.*\.sh"; then
                local sched name direction status
                sched=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                name=$(echo "$line" | grep -oP 'sync-\K[^.]+')
                local script_path
                script_path=$(echo "$line" | grep -oP '/[^ ]*sync-[^ ]*\.sh')
                direction="sync"
                if [[ -f "$script_path" ]]; then
                    direction=$(grep '^# Direction:' "$script_path" 2>/dev/null | sed 's/# Direction: //')
                    [[ -z "$direction" ]] && direction="sync"
                fi
                status=""
                if echo "$line" | grep -q "^#PAUSED#"; then
                    status="${YELLOW}(paused)${NC}"
                    sched=$(echo "$line" | sed 's/^#PAUSED#//' | awk '{print $1,$2,$3,$4,$5}')
                    name=$(echo "$line" | sed 's/^#PAUSED#//' | grep -oP 'sync-\K[^.]+')
                    script_path=$(echo "$line" | sed 's/^#PAUSED#//' | grep -oP '/[^ ]*sync-[^ ]*\.sh')
                    if [[ -f "$script_path" ]]; then
                        direction=$(grep '^# Direction:' "$script_path" 2>/dev/null | sed 's/# Direction: //')
                        [[ -z "$direction" ]] && direction="sync"
                    fi
                fi
                local when
                when=$(_cron_to_english "$sched")
                printf "  %-20s %-18s %-16s %-10s " "$name" "$sched" "$when" "$direction"
                [[ -n "$status" ]] && echo -e "$status" || echo ""
                found_any=true
            fi
        done
    fi

    if [[ "$found_any" == "false" ]]; then
        # Check again outside subshells
        local has_server=false has_laptop=false
        [[ -n "$server_crons" ]] && echo "$server_crons" | grep -qE "immich-backup|disk-check" && has_server=true
        [[ -n "$laptop_crons" ]] && echo "$laptop_crons" | grep -q "sync-.*\.sh" && has_laptop=true
        if [[ "$has_server" == "false" && "$has_laptop" == "false" ]]; then
            echo ""
            info "No scheduled tasks found."
        fi
    fi

    echo ""
}

_sync_list_jobs() {
    local filter="$1"  # "active", "paused", or "all"
    local laptop_crons
    laptop_crons=$(crontab -l 2>/dev/null) || laptop_crons=""

    _sync_jobs=()
    _sync_job_lines=()
    local i=1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$filter" in
            active)
                echo "$line" | grep -q "^#PAUSED#" && continue
                echo "$line" | grep -q "sync-.*\.sh" || continue
                ;;
            paused)
                echo "$line" | grep -q "^#PAUSED#" || continue
                echo "$line" | grep -q "sync-.*\.sh" || continue
                ;;
            all)
                echo "$line" | grep -q "sync-.*\.sh" || continue
                # Also match paused lines
                if ! echo "$line" | grep -q "sync-.*\.sh"; then
                    echo "$line" | sed 's/^#PAUSED#//' | grep -q "sync-.*\.sh" || continue
                fi
                ;;
        esac

        local clean_line name sched status_tag
        clean_line=$(echo "$line" | sed 's/^#PAUSED#//')
        name=$(echo "$clean_line" | grep -oP 'sync-\K[^.]+')
        sched=$(echo "$clean_line" | awk '{print $1,$2,$3,$4,$5}')
        status_tag=""
        echo "$line" | grep -q "^#PAUSED#" && status_tag=" ${YELLOW}(paused)${NC}"

        echo -e "    ${BOLD}${i})${NC} ${name}  [${sched}]${status_tag}"
        _sync_jobs+=("$name")
        _sync_job_lines+=("$line")
        ((i++))
    done <<< "$laptop_crons"

    if [[ ${#_sync_jobs[@]} -eq 0 ]]; then
        return 1
    fi
    return 0
}

_sync_pause_job() {
    echo ""
    echo -e "  ${BOLD}Pause a sync job${NC}"
    echo ""

    if ! _sync_list_jobs "active"; then
        info "No active sync jobs to pause."
        return
    fi

    echo ""
    read -p "  Pick a job [number]: " pick
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi

    local job_name="${_sync_jobs[$((pick-1))]}"
    local old_line="${_sync_job_lines[$((pick-1))]}"
    local new_line="#PAUSED#${old_line}"

    (crontab -l 2>/dev/null | sed "s|^$(printf '%s' "$old_line" | sed 's/[.[\*^$()+?{|]/\\&/g')\$|${new_line}|") | crontab -
    ok "Paused sync job '${job_name}'"
}

_sync_resume_job() {
    echo ""
    echo -e "  ${BOLD}Resume a sync job${NC}"
    echo ""

    if ! _sync_list_jobs "paused"; then
        info "No paused sync jobs to resume."
        return
    fi

    echo ""
    read -p "  Pick a job [number]: " pick
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi

    local job_name="${_sync_jobs[$((pick-1))]}"
    local old_line="${_sync_job_lines[$((pick-1))]}"
    local new_line
    new_line=$(echo "$old_line" | sed 's/^#PAUSED#//')

    (crontab -l 2>/dev/null | sed "s|^$(printf '%s' "$old_line" | sed 's/[.[\*^$()+?{|]/\\&/g')\$|${new_line}|") | crontab -
    ok "Resumed sync job '${job_name}'"
}

_sync_delete_job() {
    echo ""
    echo -e "  ${BOLD}Delete a sync job${NC}"
    echo ""

    if ! _sync_list_jobs "all"; then
        info "No sync jobs to delete."
        return
    fi

    echo ""
    read -p "  Pick a job [number]: " pick
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi

    local job_name="${_sync_jobs[$((pick-1))]}"
    echo ""
    _confirm_delete "sync-${job_name}" || return 0

    # Remove cron line
    local old_line="${_sync_job_lines[$((pick-1))]}"
    (crontab -l 2>/dev/null | grep -vF "$old_line") | crontab -

    # Remove script and log
    local script_path="$HOME/.local/bin/sync-${job_name}.sh"
    local log_path="$HOME/.local/share/sync-jobs/${job_name}.log"
    rm -f "$script_path" "$log_path"

    ok "Deleted sync job '${job_name}'"
    [[ -f "$script_path" ]] || info "Removed $script_path"
    [[ -f "$log_path" ]] || info "Removed $log_path"
}

_sync_run_now() {
    echo ""
    echo -e "  ${BOLD}Run a sync job now${NC}"
    echo ""

    if ! _sync_list_jobs "active"; then
        info "No active sync jobs to run."
        return
    fi

    echo ""
    read -p "  Pick a job [number]: " pick
    if [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#_sync_jobs[@]} )); then
        fail "Invalid choice."
        return
    fi

    local job_name="${_sync_jobs[$((pick-1))]}"
    local script_path="$HOME/.local/bin/sync-${job_name}.sh"

    if [[ ! -x "$script_path" ]]; then
        fail "Script not found or not executable: $script_path"
        return 1
    fi

    info "Running sync-${job_name}..."
    echo ""
    bash "$script_path" || { fail "Sync job failed."; return 1; }
    echo ""
    ok "Sync job '${job_name}' completed."
}

step_manage_sync() {
    echo ""
    echo -e "  ${BOLD}1)${NC} Status                    ${DIM}← all scheduled tasks${NC}"
    echo -e "  ${BOLD}2)${NC} New sync                  ${DIM}← transfer files, run now or schedule${NC}"
    echo -e "  ${BOLD}3)${NC} Pause a sync job"
    echo -e "  ${BOLD}4)${NC} Resume a sync job"
    echo -e "  ${BOLD}5)${NC} Delete a sync job"
    echo -e "  ${BOLD}6)${NC} Run a sync job now"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choice [0-6]: " sync_choice
    case $sync_choice in
        1) _sync_show_status ;;
        2) step_sync ;;
        3) _sync_pause_job ;;
        4) _sync_resume_job ;;
        5) _sync_delete_job ;;
        6) _sync_run_now ;;
        0) return ;;
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
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choice [1/2/3/0]: " direction
        [[ "$direction" == "0" ]] && return
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

    _list_local_sources() {
        echo ""
        echo -e "  ${BOLD}Laptop paths:${NC}"
        echo ""
        local i=1
        sources=()

        for mnt in /home/hamr/Documents /home/hamr/PycharmProjects /stuff; do
            if [[ -d "$mnt" ]]; then
                echo "    $i) $mnt"
                sources[$i]="$mnt"
                i=$((i + 1))
            fi
        done

        local usb_mounts=$(ls -d /run/media/hamr/*/ 2>/dev/null || true)
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
                read -p "  Choose [number or path]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local_path="${sources[$choice]}"
                else
                    local_path="$choice"
                fi
            else
                read -p "  Absolute path: " choice
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
            echo "    1) /home/ahassan/data  (internal drive)"
            echo "    2) /mnt/data           (USB drive)"
            echo ""
            info "Or type a path directly (e.g. /mnt/data/media/My Music)"
            echo ""
        fi
        local attempts=0
        while (( attempts < 3 )); do
            if [[ "$show_presets" == "true" ]]; then
                read -p "  Choose [number or path]: " choice
                case $choice in
                    1) server_path="/home/ahassan/data" ;;
                    2) server_path="/mnt/data" ;;
                    *) server_path="$choice" ;;
                esac
            else
                read -p "  Absolute path: " choice
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
                if ssh "$SERVER_USER@$SERVER_IP" "test -e '$server_path'" 2>/dev/null; then
                    echo ""
                    echo -e "  ${BOLD}Contents of server:$server_path:${NC}"
                    ssh "$SERVER_USER@$SERVER_IP" "if [ -d '$server_path' ]; then ls '$server_path'; else basename '$server_path'; fi"
                    break
                fi
                ((attempts++))
                (( attempts < 3 )) && fail "'$server_path' does not exist on server. Try again. ($((3-attempts)) attempts left)" || { fail "3 invalid attempts. Aborting."; return 1; }
            else
                break
            fi
        done
    }

    _pick_copy_mode() {
        local src_path="$1"
        local is_dir="$2"
        local src_name=$(basename "$src_path")
        copy_mode="contents"
        if [[ "$is_dir" == "true" ]]; then
            echo ""
            echo -e "  ${BOLD}Copy mode for ${src_name}/:${NC}"
            echo -e "    ${BOLD}1)${NC} Copy folder     (creates ${src_name}/ inside destination)"
            echo -e "    ${BOLD}2)${NC} Copy contents   (files go directly into destination)"
            echo ""
            read -p "  Mode [1/2]: " mode
            [[ "$mode" == "2" ]] && copy_mode="contents" || copy_mode="folder"
        fi
    }

    case $direction in
        1)
            echo ""
            echo -e "  ${BOLD}-- Source (laptop) --${NC}"
            _pick_local_path true
            echo ""
            echo -e "  ${BOLD}-- Destination (server) --${NC}"
            _pick_server_path false

            [[ -d "$local_path" ]] && local is_dir="true" || local is_dir="false"
            _pick_copy_mode "$local_path" "$is_dir"
            local rsync_src="$local_path/"
            local dest_display="$server_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$local_path"
                dest_display="$server_path/$(basename "$local_path")"
            fi

            src_size=$(du -sh "$local_path" 2>/dev/null | awk '{print $1}')
            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↑ Upload: laptop → server${NC}"
            echo -e "  From: $local_path ($src_size)"
            echo -e "  To:   $SERVER_USER@$SERVER_IP:$dest_display"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            local pre_cmd="ssh -t $SERVER_USER@$SERVER_IP \"sudo mkdir -p '$dest_display' && sudo chown $SERVER_USER:$SERVER_USER '$dest_display'\""
            local rsync_cmd="rsync -avh --progress \"$rsync_src\" \"$SERVER_USER@$SERVER_IP:$server_path/\""
            _sync_execute_or_schedule "upload" "$local_path" "$dest_display" "$rsync_cmd" "$pre_cmd"
            ;;

        2)
            echo ""
            echo -e "  ${BOLD}-- Source (server) --${NC}"
            _pick_server_path true
            echo ""
            echo -e "  ${BOLD}-- Destination (laptop) --${NC}"
            _pick_local_path false

            local is_dir="false"
            ssh "$SERVER_USER@$SERVER_IP" "test -d '$server_path'" 2>/dev/null && is_dir="true"
            _pick_copy_mode "$server_path" "$is_dir"
            local rsync_src="$server_path/"
            local dest_display="$local_path"
            if [[ "$copy_mode" == "folder" ]]; then
                rsync_src="$server_path"
                dest_display="$local_path/$(basename "$server_path")"
            fi

            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↓ Download: server → laptop${NC}"
            echo -e "  From: $SERVER_USER@$SERVER_IP:$server_path"
            echo -e "  To:   $dest_display"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            local pre_cmd="sudo mkdir -p \"$dest_display\""
            local rsync_cmd="rsync -avh --progress \"$SERVER_USER@$SERVER_IP:$rsync_src\" \"$local_path/\""
            _sync_execute_or_schedule "download" "$server_path" "$dest_display" "$rsync_cmd" "$pre_cmd"
            ;;

        3)
            echo ""
            echo -e "  ${BOLD}Delete from:${NC}"
            echo -e "    ${BOLD}1)${NC} Laptop"
            echo -e "    ${BOLD}2)${NC} Server"
            echo ""
            read -p "  Where [1/2]: " del_where

            case $del_where in
                1)
                    echo ""
                    _pick_local_path true false
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
                    _pick_server_path true false
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
        server_info=$(ssh "$SERVER_USER@$SERVER_IP" bash -s <<'REMOTE_STATUS'
            echo "@@HOSTNAME@@$(hostname)"
            echo "@@IP@@$(hostname -I | awk '{print $1}')"
            echo "@@TS_IP@@$(tailscale ip -4 2>/dev/null || echo 'not connected')"
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
            docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null
            echo "@@CONTAINERS_END@@"
            echo "@@DSTATS_START@@"
            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null
            echo "@@DSTATS_END@@"
            echo "@@USB_DISKS@@$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}' | paste -sd'|' -)"
            echo "@@DISK_START@@"
            df -h / /home /mnt/data 2>/dev/null | tail -n +2 | awk '!seen[$1]++'
            echo "@@DISK_END@@"
REMOTE_STATUS
        ) || { fail "Cannot reach server at $SERVER_IP."; return 1; }

        HOSTNAME=$(echo "$server_info" | grep '@@HOSTNAME@@' | sed 's/@@HOSTNAME@@//')
        IP=$(echo "$server_info" | grep '@@IP@@' | sed 's/@@IP@@//')
        TS_IP=$(echo "$server_info" | grep '@@TS_IP@@' | sed 's/@@TS_IP@@//')
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
    else
        HOSTNAME=$(hostname)
        IP=$(hostname -I | awk '{print $1}')
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
        UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
        LOAD=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
        local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        FILES=$(grep FILES_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        MUSIC=$(grep MUSIC_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        UPLOAD=$(grep UPLOAD_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        DB=$(grep DB_DATA_LOCATION "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2)
        MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print "mem|"$2"|"$3"|"$7} /^Swap:/{print "swap|"$2"|"$3}')
        CONTAINERS=$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null)
        DSTATS=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null)
        USB_DISKS=$(lsblk -rno NAME,TRAN 2>/dev/null | awk '$2=="usb"{print $1}' | paste -sd'|' -)
        DISK=$(df -h / /home /mnt/data 2>/dev/null | tail -n +2 | awk '!seen[$1]++')
    fi

    echo -e "  ${BOLD}Server${NC}"
    echo -e "    Hostname:   $HOSTNAME"
    echo -e "    Local IP:   $IP"
    echo -e "    Tailscale:  $TS_IP"
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
        echo -n "$internal_rows" | awk '{printf "      %-20s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6}'
    fi
    if [[ -n "$usb_rows" ]]; then
        echo -e "    ${DIM}USB${NC}"
        echo -n "$usb_rows" | awk '{printf "      %-20s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6}'
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
            if echo "$status" | grep -qi "unhealthy\|exit\|restart"; then
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
    echo -e "  ${BOLD}Service URLs (local network)${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Navidrome:    ${BLUE}http://$IP:4533${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"
    echo "$CONTAINERS" | grep -q '^adguard|' && echo -e "    AdGuard:      ${BLUE}http://$IP${NC}"
    echo "$CONTAINERS" | grep -q '^syncthing|' && echo -e "    Syncthing:    ${BLUE}http://$IP:8384${NC}"

    if [[ "$TS_IP" != "not connected" ]]; then
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
    local server_data
    server_data=$(ssh "$SERVER_USER@$SERVER_IP" bash -s <<'FETCH'
echo "HOSTNAME=$(hostname)"
echo "LOCAL_IP=$(hostname -I | awk '{print $1}')"
echo "TS_IP=$(tailscale ip -4 2>/dev/null || echo '')"
echo "---ENV---"
cat ~/privcloud/.env 2>/dev/null || cat ~/data/.env 2>/dev/null || true
echo "---DOCKER_COMPOSE---"
cat ~/privcloud/docker-compose.yml 2>/dev/null || true
echo "---WG_SERVER---"
sudo cat /etc/wireguard/wg0.conf 2>/dev/null || true
echo "---WG_PEERS---"
for f in $(sudo find /etc/wireguard -name '*.conf' ! -name 'wg0.conf' 2>/dev/null); do
    echo "PEER_FILE=$(basename "$f" .conf)"
    sudo cat "$f"
    echo "END_PEER_FILE"
done
echo "---ADGUARD---"
sudo cat /opt/adguard/conf/AdGuardHome.yaml 2>/dev/null || true
echo "---SYNCTHING_ID---"
sudo docker exec syncthing syncthing --device-id 2>/dev/null || true
echo "---SYNCTHING_CONFIG---"
sudo cat /opt/syncthing/config/config.xml 2>/dev/null || true
echo "---SYNCTHING_CERT---"
sudo cat /opt/syncthing/config/cert.pem 2>/dev/null || true
echo "---SYNCTHING_KEY---"
sudo cat /opt/syncthing/config/key.pem 2>/dev/null || true
echo "---END---"
FETCH
)

    if [[ -z "$server_data" ]]; then
        fail "Could not connect to server."
        return 1
    fi

    # Parse server details
    local HOSTNAME=$(echo "$server_data" | grep "^HOSTNAME=" | cut -d= -f2)
    local IP=$(echo "$server_data" | grep "^LOCAL_IP=" | cut -d= -f2)
    local TS_IP=$(echo "$server_data" | grep "^TS_IP=" | cut -d= -f2)

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
    step_deploy
    step_backup
    step_logrotation
}

step_reset_password() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local IP
    IP=$(hostname -I | awk '{print $1}')

    echo -e "  ${BOLD}1)${NC} FileBrowser     ${DIM}(port 8080)${NC}"
    echo -e "  ${BOLD}2)${NC} Immich          ${DIM}(port 2283)${NC}"
    echo -e "  ${BOLD}3)${NC} Navidrome       ${DIM}(port 4533)${NC}"
    echo -e "  ${BOLD}4)${NC} Uptime Kuma     ${DIM}(port 3001)${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Which service? " reset_choice

    case $reset_choice in
        1)
            echo ""
            warn "This will reset the FileBrowser admin password."
            read -p "  New password: " new_pass
            if [[ -z "$new_pass" ]]; then
                fail "Password is required."
                return 1
            fi
            sg docker -c "docker stop filebrowser" > /dev/null 2>&1
            sg docker -c "docker run --rm -v privcloud_filebrowser-db:/database filebrowser/filebrowser:latest users update admin --password '$new_pass' --database /database/filebrowser.db" > /dev/null 2>&1
            sg docker -c "docker start filebrowser" > /dev/null 2>&1

            local fb_pass_file="$HOME/.privcloud/filebrowser.pass"
            mkdir -p "$(dirname "$fb_pass_file")"
            printf '%s\n' "$new_pass" > "$fb_pass_file"
            chmod 600 "$fb_pass_file"

            ok "Password reset. Login: admin / $new_pass"
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

# ── CLI argument handling (used by SSH routing) ─────
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
            8)  run_step "[8] Setup backups + disk monitoring" "_on_server step_backup" ;;
            9)  run_step "[9] Log rotation" "_on_server step_logrotation" ;;
            10) run_step "[10] Manage Tailscale" step_tailscale ;;
            11) run_step "[11] Manage WireGuard" "_on_server step_wireguard" ;;
            12) run_step "[12] Manage AdGuard" "_on_server step_adguard" ;;
            13) run_step "[13] Manage storage" "_on_server step_storage" ;;
            14) run_step "[14] Manage Syncthing" step_syncthing ;;
            15) run_step "[15] Manage remote desktop" "_on_server step_remotedesktop" ;;
            16) run_step "[16] Manage sync" step_manage_sync ;;
            17) run_step "[17] Save to pass" step_save_to_pass ;;
            s)  run_step "[s] Status" step_status ;;
            i)  run_step "[i] Immich (privcloud)" step_immich ;;
            p)  run_step "[p] Power" step_power ;;
            r)  run_step "[r] Reset password" "_on_server step_reset_password" ;;
            a)  run_step "Run all (3-9)" "_on_server run_all" ;;
            0)  echo "Bye."; exit 0 ;;
            *)  echo -e "  ${RED}Invalid choice.${NC}" ;;
        esac
    done
fi
