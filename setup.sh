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

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}========================================"
    echo -e "  Federver — Fedora XFCE Server Manager"
    echo -e "========================================${NC}"
    echo ""
    echo -e "  ${YELLOW}-- Run on server with monitor --${NC}"
    echo -e "  ${BOLD}1)${NC} Enable SSH + auto-login + hostname"
    echo ""
    echo -e "  ${YELLOW}-- Exit SSH, run from laptop --${NC}"
    echo -e "  ${BOLD}2)${NC} SSH key auth                ${YELLOW}← exit SSH first${NC}"
    echo ""
    echo -e "  ${DIM}-- Run over SSH from laptop --${NC}"
    echo -e "  ${BOLD}3)${NC} System update"
    echo -e "  ${BOLD}4)${NC} Enable auto-updates"
    echo -e "  ${BOLD}5)${NC} Install Docker              ${YELLOW}← log out & SSH back in after this${NC}"
    echo -e "  ${BOLD}6)${NC} Configure firewall"
    echo -e "  ${BOLD}7)${NC} Install Tailscale           ${DIM}← opens a URL to approve on phone/laptop${NC}"
    echo -e "  ${BOLD}8)${NC} Mount USB drive             ${DIM}← plug in USB drive first${NC}"
    echo -e "  ${BOLD}9)${NC} Deploy services             ${DIM}← Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma${NC}"
    echo -e "  ${BOLD}10)${NC} Setup backups              ${DIM}← daily Immich DB backup${NC}"
    echo -e "  ${BOLD}11)${NC} Configure log rotation     ${DIM}← prevent Docker logs eating disk${NC}"
    echo ""
    echo -e "  ${DIM}-- Immich photo management --${NC}"
    echo -e "      ${DIM}Run: ${BOLD}privcloud${NC} ${DIM}[start|stop|status|update|backup]${NC}"
    echo ""
    echo -e "  ${YELLOW}-- Exit SSH, run from laptop --${NC}"
    echo -e "  ${BOLD}12)${NC} Sync files                 ${YELLOW}← exit SSH first${NC}"
    echo ""
    echo -e "  ${BOLD}s)${NC} Status                     ${DIM}← show all service URLs and config${NC}"
    echo -e "  ${BOLD}p)${NC} Power                      ${DIM}← shutdown or restart server${NC}"
    echo -e "  ${BOLD}a)${NC} Run all (3-11)"
    echo -e "  ${BOLD}0)${NC} Exit"
    echo ""
}

step_ssh() {
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
    info "Installs automatic security updates so you don't have to."
    echo ""
    sudo dnf install -y dnf5-plugin-automatic
    local conf="/etc/dnf/dnf5-plugins/automatic.conf"
    if [[ ! -f "$conf" ]]; then
        sudo mkdir -p /etc/dnf/dnf5-plugins
        sudo cp /usr/share/dnf5/dnf5-plugins/automatic.conf "$conf"
    fi
    sudo sed -i 's/apply_updates = no/apply_updates = yes/' "$conf"
    sudo systemctl enable --now dnf-automatic.timer
    ok "Auto-updates enabled."
}

step_docker() {
    info "Docker runs all your services (Immich, Jellyfin, FileBrowser, etc)."
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

step_firewall() {
    info "Opens SSH + service ports on local network."
    info "Tailscale trusted for remote access."
    echo ""

    sudo firewall-cmd --permanent --add-service=ssh
    sudo firewall-cmd --permanent --add-port=2283/tcp   # Immich
    sudo firewall-cmd --permanent --add-port=8096/tcp   # Jellyfin
    sudo firewall-cmd --permanent --add-port=8080/tcp   # FileBrowser
    sudo firewall-cmd --permanent --add-port=3001/tcp   # Uptime Kuma

    sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 2>/dev/null || true

    sudo firewall-cmd --reload
    echo ""
    ok "Firewall configured:"
    echo -e "    ${GREEN}Local network:${NC} SSH, Immich (2283), Jellyfin (8096), FileBrowser (8080), Uptime Kuma (3001)"
    echo -e "    ${GREEN}Tailscale:${NC}     full access (remote)"
    echo -e "    ${RED}Everything else:${NC} blocked"
}

step_tailscale() {
    info "Tailscale lets you access this server from anywhere (phone, laptop)"
    info "without port forwarding. Like a private VPN."
    echo ""

    # Install
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo systemctl enable --now tailscaled
    ok "Tailscale installed."

    # Guide: create account
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

    # Authenticate
    echo ""
    info "Authenticating this server with Tailscale..."
    info "A URL will appear below. Open it in your browser and approve."
    echo ""
    sudo tailscale up
    echo ""

    # Verify
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
        echo -e "  3. Now you can access all services from anywhere:"
        echo -e "     Immich:       ${BLUE}http://$ts_ip:2283${NC}"
        echo -e "     Jellyfin:     ${BLUE}http://$ts_ip:8096${NC}"
        echo -e "     FileBrowser:  ${BLUE}http://$ts_ip:8080${NC}"
        echo -e "     Uptime Kuma:  ${BLUE}http://$ts_ip:3001${NC}"
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "  Press Enter when done..." -r
    else
        fail "Tailscale not connected. Run 'sudo tailscale up' manually."
    fi
}

step_usbmount() {
    info "This permanently mounts your USB drive so it auto-connects on reboot."
    info "Make sure the USB drive is plugged into a back USB 3.0 port (blue)."
    echo ""
    echo -e "  ${BOLD}Available drives:${NC}"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL | grep -v loop
    echo ""
    info "Pick the partition for your data drive (ignore nvme — that's the system disk)."
    info "Example: if you see 'sda1', type 'sda1'"
    echo ""
    read -p "  Which partition? (or Enter to skip): " partition
    if [[ -n "$partition" ]]; then
        sudo mkdir -p /mnt/data
        uuid=$(sudo blkid -s UUID -o value /dev/$partition)
        fstype=$(sudo blkid -s TYPE -o value /dev/$partition)
        if grep -q "$uuid" /etc/fstab 2>/dev/null; then
            ok "Already in fstab, skipping."
        else
            echo "UUID=$uuid /mnt/data $fstype defaults,nofail 0 2" | sudo tee -a /etc/fstab
            sudo mount -a
            ok "Mounted /dev/$partition at /mnt/data"
        fi
    else
        info "Skipped. Run this step again when USB drive is plugged in."
    fi
}

step_deploy() {
    info "Deploys all services: Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma."
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ── Helper to set env vars ──
    _set_env() {
        local key="$1" val="$2" file="$3"
        if grep -q "^${key}=" "$file"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$file"
        else
            echo "${key}=${val}" >> "$file"
        fi
    }

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
    _set_env "DATA_ROOT" "${base_path}" "$SCRIPT_DIR/.env"

    source "$SCRIPT_DIR/.env"
    sudo mkdir -p "$UPLOAD_LOCATION" "$DB_DATA_LOCATION" "$MEDIA_LOCATION" 2>/dev/null || true

    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d"

    IP=$(hostname -I | awk '{print $1}')
    echo ""
    ok "Services running!"
    echo ""
    echo -e "  ${BOLD}Access from your browser:${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Jellyfin:     ${BLUE}http://$IP:8096${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"
    echo ""
    info "Watchtower auto-updates all containers daily at 4am."
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}SETUP EACH SERVICE${NC}"
    echo ""
    echo -e "  ${BOLD}Jellyfin${NC} (port 8096)"
    echo -e "    Create admin account, add media libraries from /media"
    echo ""
    echo -e "  ${BOLD}FileBrowser${NC} (port 8080)"
    local fb_pass
    fb_pass=$(docker logs filebrowser 2>&1 | grep "randomly generated password" | awk '{print $NF}')
    if [[ -n "$fb_pass" ]]; then
        echo -e "    Login: ${BOLD}admin${NC} / ${BOLD}$fb_pass${NC} (change it after login)"
    else
        echo -e "    Check password: ${BOLD}docker logs filebrowser | grep password${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}Uptime Kuma${NC} (port 3001)"
    echo -e "    Create admin account, then add monitors:"
    echo -e "    + New Monitor → HTTP → http://localhost:2283 (Immich)"
    echo -e "    + New Monitor → HTTP → http://localhost:8096 (Jellyfin)"
    echo -e "    + New Monitor → HTTP → http://localhost:8080 (FileBrowser)"
    echo -e "    Optional: set up Telegram/email alerts in Settings → Notifications"
    echo ""
    echo -e "  See README or run ${BOLD}s)${NC} for full setup details."
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
    info "Transfer files between this laptop and the server."
    info "Run this from your LAPTOP, not over SSH."
    echo ""
    echo -e "  ${BOLD}1)${NC} Upload:   laptop → server"
    echo -e "  ${BOLD}2)${NC} Download: server → laptop"
    echo ""
    read -p "  Direction [1/2]: " direction

    _list_local_sources() {
        echo ""
        echo -e "  ${BOLD}Local paths:${NC}"
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
        local attempts=0
        while (( attempts < 3 )); do
            _list_local_sources
            read -p "  Choose [number or path]: " choice

            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local_path="${sources[$choice]}"
            else
                local_path="$choice"
            fi

            if [[ -n "$local_path" && -d "$local_path" ]]; then
                break
            fi

            ((attempts++))
            if (( attempts < 3 )); then
                fail "'$local_path' does not exist. Try again. ($((3-attempts)) attempts left)"
            else
                fail "3 invalid attempts. Aborting."
                return 1
            fi
        done

        echo ""
        echo -e "  ${BOLD}Contents of $local_path:${NC}"
        ls "$local_path"
        echo ""
        read -p "  Subfolder (or Enter for all): " subfolder
        if [[ -n "$subfolder" ]]; then
            local_path="$local_path/$subfolder"
        fi
    }

    _pick_server_path() {
        echo ""
        echo -e "  ${BOLD}Server paths:${NC}"
        echo "    1) /home/ahassan/data  (internal drive)"
        echo "    2) /mnt/data           (USB drive)"
        echo ""
        info "Or type a path directly (e.g. /home/ahassan/media)"
        echo ""
        local attempts=0
        while (( attempts < 3 )); do
            read -p "  Choose [number or path]: " choice

            case $choice in
                1) server_path="/home/ahassan/data" ;;
                2) server_path="/mnt/data" ;;
                *) server_path="$choice" ;;
            esac

            if ssh "$SERVER_USER@$SERVER_IP" "test -d '$server_path'" 2>/dev/null; then
                break
            fi

            ((attempts++))
            if (( attempts < 3 )); then
                fail "'$server_path' does not exist on server. Try again. ($((3-attempts)) attempts left)"
            else
                fail "3 invalid attempts. Aborting."
                return 1
            fi
        done

        echo ""
        echo -e "  ${BOLD}Contents of server:$server_path:${NC}"
        ssh "$SERVER_USER@$SERVER_IP" "ls '$server_path' 2>/dev/null || echo '  (empty or does not exist)'"
        echo ""
        read -p "  Subfolder (or Enter for all): " subfolder
        if [[ -n "$subfolder" ]]; then
            server_path="$server_path/$subfolder"
        fi
    }

    case $direction in
        1)
            echo ""
            echo -e "  ${BOLD}-- Source (laptop) --${NC}"
            _pick_local_path
            echo ""
            echo -e "  ${BOLD}-- Destination (server) --${NC}"
            _pick_server_path

            src_size=$(du -sh "$local_path" 2>/dev/null | awk '{print $1}')
            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↑ Upload: laptop → server${NC}"
            echo -e "  From: $local_path ($src_size)"
            echo -e "  To:   $SERVER_USER@$SERVER_IP:$server_path"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            read -p "  Start sync? [Y/n] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Nn]$ ]] && info "Cancelled." && return

            ssh "$SERVER_USER@$SERVER_IP" "sudo mkdir -p '$server_path' && sudo chown -R $SERVER_USER:$SERVER_USER '$server_path'"
            sudo rsync -avh --progress "$local_path/" "$SERVER_USER@$SERVER_IP:$server_path/"
            ;;

        2)
            echo ""
            echo -e "  ${BOLD}-- Source (server) --${NC}"
            _pick_server_path
            echo ""
            echo -e "  ${BOLD}-- Destination (laptop) --${NC}"
            _pick_local_path

            echo ""
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${BOLD}↓ Download: server → laptop${NC}"
            echo -e "  From: $SERVER_USER@$SERVER_IP:$server_path"
            echo -e "  To:   $local_path"
            echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            read -p "  Start sync? [Y/n] " -n 1 -r
            echo ""
            [[ $REPLY =~ ^[Nn]$ ]] && info "Cancelled." && return

            sudo mkdir -p "$local_path"
            sudo rsync -avh --progress "$SERVER_USER@$SERVER_IP:$server_path/" "$local_path/"
            ;;

        *)
            fail "Invalid choice."
            return
            ;;
    esac

    echo ""
    ok "Sync complete."
}

step_status() {
    IP=$(hostname -I | awk '{print $1}')
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_DIR_STATUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo -e "  ${BOLD}Server${NC}"
    echo -e "    Hostname:   $(hostname)"
    echo -e "    Local IP:   $IP"
    echo -e "    Tailscale:  $TAILSCALE_IP"
    echo ""

    echo -e "  ${BOLD}Service URLs (local network)${NC}"
    echo -e "    Immich:       ${BLUE}http://$IP:2283${NC}"
    echo -e "    Jellyfin:     ${BLUE}http://$IP:8096${NC}"
    echo -e "    FileBrowser:  ${BLUE}http://$IP:8080${NC}"
    echo -e "    Uptime Kuma:  ${BLUE}http://$IP:3001${NC}"

    if [[ "$TAILSCALE_IP" != "not connected" ]]; then
        echo ""
        echo -e "  ${BOLD}Service URLs (remote via Tailscale)${NC}"
        echo -e "    Immich:       ${BLUE}http://$TAILSCALE_IP:2283${NC}"
        echo -e "    Jellyfin:     ${BLUE}http://$TAILSCALE_IP:8096${NC}"
        echo -e "    FileBrowser:  ${BLUE}http://$TAILSCALE_IP:8080${NC}"
        echo -e "    Uptime Kuma:  ${BLUE}http://$TAILSCALE_IP:3001${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Data paths${NC}"
    if [[ -f "$SCRIPT_DIR_STATUS/.env" ]]; then
        echo -e "    Immich photos:  $(grep UPLOAD_LOCATION "$SCRIPT_DIR_STATUS/.env" | cut -d= -f2)"
        echo -e "    Immich DB:      $(grep DB_DATA_LOCATION "$SCRIPT_DIR_STATUS/.env" | cut -d= -f2)"
    fi
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        echo -e "    Media:          $(grep MEDIA_LOCATION "$SCRIPT_DIR/.env" | cut -d= -f2)"
        echo -e "    FileBrowser:    $(grep DATA_ROOT "$SCRIPT_DIR/.env" | cut -d= -f2)"
    fi

    echo ""
    echo -e "  ${BOLD}Containers${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qi "healthy"; then
            ok "$line"
        elif echo "$line" | grep -qi "exit\|restart\|unhealthy"; then
            fail "$line"
        elif echo "$line" | grep -q "NAMES"; then
            echo "    $line"
        else
            warn "$line"
        fi
    done

    echo ""
    echo -e "  ${BOLD}Disk${NC}"
    df -h / /home 2>/dev/null | awk 'NR==1{printf "    %-20s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5} NR>1{printf "    %-20s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5}'

    echo ""
    echo -e "  ${BOLD}Management${NC}"
    echo -e "    Immich:   ${BOLD}privcloud${NC} [start|stop|status|update|backup]"
    echo -e "    Server:   ${BOLD}federver${NC}"
    echo -e "    Services: ${BOLD}docker compose [up -d|down|pull]${NC}"
}

step_power() {
    echo -e "  ${BOLD}1)${NC} Shutdown"
    echo -e "  ${BOLD}2)${NC} Restart"
    echo ""
    read -p "  Choose [1/2]: " power_choice
    case $power_choice in
        1)
            echo ""
            warn "Server will shut down. SSH connection will be lost."
            read -p "  Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ok "Shutting down..."
                sudo shutdown now
            else
                info "Cancelled."
            fi
            ;;
        2)
            echo ""
            warn "Server will restart. SSH connection will drop and reconnect in ~1-2 minutes."
            read -p "  Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ok "Restarting..."
                sudo reboot
            else
                info "Cancelled."
            fi
            ;;
        *)
            fail "Invalid choice."
            ;;
    esac
}

run_all() {
    step_update
    step_autoupdates
    step_docker
    step_firewall
    step_tailscale
    step_usbmount
    step_deploy
    step_backup
    step_logrotation
}

# ── Main loop ────────────────────────────────────────
while true; do
    show_menu
    read -p "  Choose: " choice
    case $choice in
        1)  run_step "[1] Enable SSH + auto-login + hostname" step_ssh ;;
        2)  run_step "[2] SSH key auth" step_sshkey ;;
        3)  run_step "[3] System update" step_update ;;
        4)  run_step "[4] Auto-updates" step_autoupdates ;;
        5)  run_step "[5] Install Docker" step_docker ;;
        6)  run_step "[6] Configure firewall" step_firewall ;;
        7)  run_step "[7] Install Tailscale" step_tailscale ;;
        8)  run_step "[8] Mount USB drive" step_usbmount ;;
        9)  run_step "[9] Deploy services" step_deploy ;;
        10) run_step "[10] Setup backups" step_backup ;;
        11) run_step "[11] Log rotation" step_logrotation ;;
        12) run_step "[12] Sync files" step_sync ;;
        s)  run_step "[s] Status" step_status ;;
        p)  run_step "[p] Power management" step_power ;;
        a)  run_step "Run all (3-11)" run_all ;;
        0)  echo "Bye."; exit 0 ;;
        *)  echo -e "  ${RED}Invalid choice.${NC}" ;;
    esac
done
