#!/bin/bash
# Federver — Fedora XFCE server setup & management menu
#
# HOW TO USE:
#   1. On the server (with monitor + keyboard):
#      git clone https://github.com/hamr0/privcloud.git
#      cd privcloud && ./setup.sh
#      Pick option 1 — this enables SSH so you can go remote.
#
#   2. From your laptop (not SSH):
#      cd ~/PycharmProjects/privcloud && ./setup.sh
#      Pick option 2 — copies SSH key and disables password login.
#
#   3. From your laptop (over SSH):
#      ssh ahassan@<ip-from-step-1>
#      cd privcloud && ./setup.sh
#      Run steps 3-11 in order, or 'a' for all.
#
#   4. After step 5 (Docker), log out and SSH back in before continuing.
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
        fail "This step must run from your laptop, not the server."
        echo ""
        info "It needs resources that only exist on the laptop:"
        info "  • Sync files      — laptop's SSH keys to push/pull files"
        info "  • Save to pass    — pass + GPG keyring live on the laptop"
        info "  • SSH key auth    — installs the laptop's public key onto the server"
        echo ""
        info "Exit this SSH session (${BOLD}exit${NC}) and run from your laptop:"
        info "  ${BOLD}cd ~/PycharmProjects/privcloud && ./setup.sh${NC}"
        info "Then pick the same menu option."
        return 1
    else
        "$step"
    fi
}

show_menu() {
    clear
    echo ""
    if [[ "$(hostname)" == "federver" ]]; then
        local location="server"
    else
        local location="laptop"
    fi
    echo -e "${BOLD}========================================"
    echo -e "  Federver — Fedora XFCE Server Manager"
    echo -e "  Running from: ${YELLOW}${location}${NC}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "  ${YELLOW}DRY RUN${NC} ${DIM}— no commands will be executed${NC}"
    fi
    echo -e "${BOLD}========================================${NC}"
    echo ""
    echo -e "  ${YELLOW}-- Initial setup (run once, in order) --${NC}"
    echo -e "  ${BOLD}1)${NC}  Enable SSH + auto-login + hostname  ${YELLOW}← with monitor${NC}"
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
    echo -e "  ${YELLOW}-- Tools (from laptop, exit SSH first) --${NC}"
    echo -e "  ${BOLD}16)${NC} Sync files                          ${DIM}← upload, download, or delete files${NC}"
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

step_tailscale() {
    # Laptop-side: install + auth locally first, then SSH to server for its
    # side. Server-side (via --run from an SSH hop, or user logged in on
    # federver directly): run the existing server flow.
    if ! _is_server; then
        info "Tailscale lets you access this server from anywhere (phone, laptop)"
        info "without port forwarding. Like a private VPN."
        echo ""
        _ts_install_laptop || return 1
        echo -e "  ${BOLD}── Server side ──${NC}"
        _on_server _ts_server_step
        return
    fi

    _ts_server_step
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
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " ts_choice
    case $ts_choice in
        1) _ts_status ;;
        2) _ts_up ;;
        3) _ts_down ;;
        4) _ts_install ;;
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
    sg docker -c "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null | sed 's/^/    /'
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

_services_lifecycle() {
    local action="$1"   # start | stop | restart
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    info "${action^} all privcloud services..."
    cd "$SCRIPT_DIR"
    case "$action" in
        start)   sg docker -c "docker compose up -d" ;;
        stop)    sg docker -c "docker compose stop" ;;
        restart) sg docker -c "docker compose restart" ;;
    esac
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

step_services() {
    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- running containers + URLs${NC}"
    echo -e "  ${BOLD}2)${NC} Start all"
    echo -e "  ${BOLD}3)${NC} Stop all"
    echo -e "  ${BOLD}4)${NC} Restart all"
    echo -e "  ${BOLD}5)${NC} Logs for a container"
    echo -e "  ${BOLD}6)${NC} Deploy / redeploy           ${DIM}<- first install or change data paths${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " svc_choice
    case $svc_choice in
        1) _services_status ;;
        2) _services_lifecycle start ;;
        3) _services_lifecycle stop ;;
        4) _services_lifecycle restart ;;
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

_syncthing_device_id() {
    # First-run Syncthing needs a few seconds to generate its cert and
    # become ready for `docker exec`. Poll for up to 20 seconds, and
    # validate the output looks like a real Device ID (the command can
    # print warnings to stdout when the cert file doesn't exist yet).
    local attempt id
    for attempt in $(seq 1 20); do
        id=$(sudo docker exec syncthing syncthing --device-id 2>/dev/null \
             | grep -E '^[A-Z0-9]{7}(-[A-Z0-9]{7}){6}$' || echo "")
        if [[ -n "$id" ]]; then
            echo "$id"
            return 0
        fi
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
    sudo firewall-cmd --permanent --add-port=8384/tcp > /dev/null
    sudo firewall-cmd --permanent --add-port=22000/tcp > /dev/null
    sudo firewall-cmd --permanent --add-port=22000/udp > /dev/null
    sudo firewall-cmd --permanent --add-port=21027/udp > /dev/null
    sudo firewall-cmd --reload > /dev/null
    ok "Firewall: 8384/tcp, 22000/tcp+udp, 21027/udp open."

    sudo mkdir -p /opt/syncthing/config /opt/syncthing/data

    # STGUIADDRESS forces the web UI onto all interfaces — default is
    # 127.0.0.1:8384 which is useless with --network=host.
    info "Starting Syncthing container..."
    sudo docker run -d \
        --name syncthing \
        --network=host \
        --restart=unless-stopped \
        -e PUID=$(id -u) \
        -e PGID=$(id -g) \
        -e STGUIADDRESS=0.0.0.0:8384 \
        -v /opt/syncthing/config:/var/syncthing/config \
        -v /opt/syncthing/data:/var/syncthing \
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

    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}NEXT: Install Syncthing on your other devices${NC}"
    echo ""
    echo -e "  ${BOLD}Laptop (Fedora):${NC}"
    echo -e "    sudo dnf install -y syncthing"
    echo -e "    systemctl --user enable --now syncthing"
    echo -e "    Open ${BLUE}http://localhost:8384${NC}"
    echo ""
    echo -e "  ${BOLD}Phone:${NC}"
    echo -e "    Android: ${BOLD}Syncthing${NC} (F-Droid or Play Store)"
    echo -e "    iOS:     ${BOLD}Möbius Sync${NC} (App Store — Syncthing-compatible)"
    echo ""
    echo -e "  ${BOLD}Pair each device with the server:${NC}"
    echo -e "    1. On the device, open Syncthing → ${BOLD}Add Remote Device${NC}"
    echo -e "    2. Paste the server's Device ID shown above → Save"
    echo -e "    3. On the server dashboard (${BLUE}http://$IP:8384${NC}),"
    echo -e "       accept the incoming device request"
    echo -e "    4. Create a shared folder on one side → accept on the other"
    echo ""
    echo -e "  ${DIM}Note: first time you open the server dashboard it'll ask you to${NC}"
    echo -e "  ${DIM}set a GUI username + password. Do it — the UI is LAN-reachable.${NC}"
    echo -e "  ${DIM}After that, run 'federver → 17 (Save to pass)' to back up the${NC}"
    echo -e "  ${DIM}device identity — lose cert.pem/key.pem and you re-pair everything.${NC}"
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

    # Wait for Syncthing to generate its cert file before asking for the
    # Device ID. `syncthing --device-id` prints a warning to STDOUT (not
    # stderr) when the cert isn't there yet, which pollutes the output if
    # we read it too early. So: poll for the cert file first, then read
    # the ID, then validate that it looks like a real ID (52 alphanumeric
    # chars in 7-char groups separated by hyphens).
    local cert=~/.local/state/syncthing/cert.pem
    local attempt laptop_id=""
    for attempt in $(seq 1 20); do
        if [[ -f "$cert" ]]; then
            laptop_id=$(syncthing --device-id 2>/dev/null | grep -E '^[A-Z0-9]{7}(-[A-Z0-9]{7}){6}$' || echo "")
            [[ -n "$laptop_id" ]] && break
        fi
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

step_syncthing() {
    info "Syncthing syncs folders between devices in real-time, peer-to-peer."
    info "Continuous bidirectional sync with conflict resolution."
    echo ""

    # Laptop-side: install locally first, then SSH to server for its side.
    # Server-side (we got here via --run from an SSH hop, or user is logged
    # in directly on federver): just do the server half.
    if ! _is_server; then
        _syncthing_install_laptop || return 1
        echo -e "  ${BOLD}── Server side ──${NC}"
        _on_server _syncthing_server_step
        return
    fi

    # ── From here on: we are on the server ──
    _syncthing_server_step
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
    echo -e "  ${BOLD}2)${NC} Show Device ID           ${DIM}<- for pairing new clients${NC}"
    echo -e "  ${BOLD}3)${NC} Start"
    echo -e "  ${BOLD}4)${NC} Stop"
    echo -e "  ${BOLD}5)${NC} Restart"
    echo -e "  ${BOLD}6)${NC} Logs                     ${DIM}<- tail -f syncthing logs${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " st_choice
    case $st_choice in
        1) _syncthing_status ;;
        2) _syncthing_show_device_id ;;
        3) info "Starting..."; sudo docker start syncthing > /dev/null && ok "Started." ;;
        4) info "Stopping..."; sudo docker stop syncthing > /dev/null && ok "Stopped." ;;
        5) info "Restarting..."; sudo docker restart syncthing > /dev/null && ok "Restarted." ;;
        6)
            info "Last 50 lines (Ctrl+C to exit follow mode)..."
            sudo docker logs --tail 50 -f syncthing || true
            ;;
        0|*) return ;;
    esac
}

step_remotedesktop() {
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
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choose [1/2/3/4/5/0]: " wg_action

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

    # ── Idempotent: already running? (skip in dry-run so the flow is visible)
    if [[ "$DRY_RUN" != "1" ]] && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^adguard$'; then
        ok "AdGuard is already running."
        echo -e "  Dashboard: ${BLUE}http://$IP${NC}"
        if [[ -n "$TS_IP" ]]; then
            echo ""
            _adguard_tailscale_guide "$TS_IP"
        fi
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
            echo ""
            read -p "  Start sync? [Y/n] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Nn]$ ]] && info "Cancelled." && return

            ssh -t "$SERVER_USER@$SERVER_IP" "sudo mkdir -p '$dest_display' && sudo chown $SERVER_USER:$SERVER_USER '$dest_display'"
            rsync -avh --progress "$rsync_src" "$SERVER_USER@$SERVER_IP:$server_path/" || { fail "Sync failed."; return 1; }
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
            echo ""
            read -p "  Start sync? [Y/n] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Nn]$ ]] && info "Cancelled." && return

            sudo mkdir -p "$dest_display"
            rsync -avh --progress "$SERVER_USER@$SERVER_IP:$rsync_src" "$local_path/" || { fail "Sync failed."; return 1; }
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

    echo ""
    ok "Sync complete."
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
            docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null
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
        CONTAINERS=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null)
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

    # Containers + per-container CPU/MEM from docker stats
    echo -e "  ${BOLD}Containers${NC}"
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
            if echo "$status" | grep -qi "healthy"; then
                echo -e "    ${GREEN}✓${NC} $(printf '%-24s' "$name")  $status$suffix"
            elif echo "$status" | grep -qi "exit\|restart\|unhealthy"; then
                echo -e "    ${RED}✗${NC} $(printf '%-24s' "$name")  $status$suffix"
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
    # Guard against stale checkouts: when --run gets a step name the local
    # setup.sh doesn't define, assume the remote copy is behind main and
    # print an actionable fix instead of "command not found".
    if ! declare -F "$2" >/dev/null; then
        fail "Step '$2' is not defined in this copy of setup.sh."
        echo ""
        info "The server's checkout is probably behind main. On the server:"
        info "  ${BOLD}cd ~/privcloud && git pull${NC}"
        info "Then re-run the menu option from your laptop."
        exit 1
    fi
    "$2"
    exit $?
fi

# ── Main loop ────────────────────────────────────────
while true; do
    show_menu
    read -p "  Choose: " choice
    case $choice in
        1)  run_step "[1] Enable SSH + auto-login + hostname" step_ssh ;;  # must be on server with monitor and keyboard
        2)  run_step "[2] SSH key auth" "_on_laptop step_sshkey" ;;
        3)  run_step "[3] System update" "_on_server step_update" ;;
        4)  run_step "[4] Auto-updates" "_on_server step_autoupdates" ;;
        5)  run_step "[5] Install Docker" "_on_server step_docker" ;;
        6)  run_step "[6] Manage firewall" "_on_server step_firewall" ;;
        7)  run_step "[7] Manage services" "_on_server step_services" ;;
        8)  run_step "[8] Setup backups + disk monitoring" "_on_server step_backup" ;;
        9)  run_step "[9] Log rotation" "_on_server step_logrotation" ;;
        10) run_step "[10] Manage Tailscale" step_tailscale ;;
        11) run_step "[11] Manage WireGuard" "_on_server step_wireguard" ;;
        12) run_step "[12] Manage AdGuard" "_on_server step_adguard" ;;
        13) run_step "[13] Manage storage" "_on_server step_storage" ;;
        14) run_step "[14] Manage Syncthing" step_syncthing ;;
        15) run_step "[15] Manage remote desktop" "_on_server step_remotedesktop" ;;
        16) run_step "[16] Sync files" "_on_laptop step_sync" ;;
        17) run_step "[17] Save to pass" "_on_laptop step_save_to_pass" ;;
        s)  run_step "[s] Status" step_status ;;
        i)  run_step "[i] Immich (privcloud)" step_immich ;;
        p)  run_step "[p] Power management" "_on_laptop step_power" ;;
        r)  run_step "[r] Reset password" "_on_server step_reset_password" ;;
        a)  run_step "Run all (3-9)" "_on_server run_all" ;;
        0)  echo "Bye."; exit 0 ;;
        *)  echo -e "  ${RED}Invalid choice.${NC}" ;;
    esac
done
