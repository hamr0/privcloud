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
    echo -e "  ${YELLOW}-- Initial setup (run once, in order) --${NC}"
    echo -e "  ${BOLD}1)${NC}  Enable SSH + auto-login + hostname  ${YELLOW}← with monitor${NC}"
    echo -e "  ${BOLD}2)${NC}  SSH key auth                        ${YELLOW}← from laptop, exit SSH first${NC}"
    echo -e "  ${BOLD}3)${NC}  System update"
    echo -e "  ${BOLD}4)${NC}  Enable auto-updates                 ${YELLOW}← security only, kernel excluded${NC}"
    echo -e "  ${BOLD}5)${NC}  Install Docker                      ${YELLOW}← log out & SSH back in after${NC}"
    echo ""
    echo -e "  ${DIM}-- Services --${NC}"
    echo -e "  ${BOLD}6)${NC}  Configure firewall"
    echo -e "  ${BOLD}7)${NC}  Deploy services                     ${DIM}← Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma${NC}"
    echo -e "  ${BOLD}8)${NC}  Setup backups + disk monitoring"
    echo -e "  ${BOLD}9)${NC}  Configure log rotation"
    echo ""
    echo -e "  ${DIM}-- Extras (optional, run anytime) --${NC}"
    echo -e "  ${BOLD}10)${NC} Install Tailscale                   ${DIM}← remote access VPN${NC}"
    echo -e "  ${BOLD}11)${NC} Install WireGuard                   ${DIM}← full VPN, route all traffic${NC}"
    echo -e "  ${BOLD}12)${NC} Manage storage                      ${DIM}← USB drives, media/data paths${NC}"
    echo -e "  ${BOLD}13)${NC} Remote desktop                      ${DIM}← access XFCE desktop via RDP${NC}"
    echo ""
    echo -e "  ${DIM}-- Immich photo management --${NC}"
    echo -e "      ${DIM}Run: ${BOLD}privcloud${NC} ${DIM}[start|stop|status|update|backup]${NC}"
    echo ""
    echo -e "  ${YELLOW}-- Tools (from laptop, exit SSH first) --${NC}"
    echo -e "  ${BOLD}14)${NC} Sync files                          ${DIM}← copy/backup files between laptop & server${NC}"
    echo -e "  ${BOLD}15)${NC} Save to pass                        ${DIM}← from laptop, backup everything to pass${NC}"
    echo ""
    echo -e "  ${BOLD}s)${NC}  Status        ${BOLD}p)${NC}  Power        ${BOLD}a)${NC}  Run all (3-9)        ${BOLD}0)${NC}  Exit"
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

step_storage() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo -e "  ${BOLD}1)${NC} Status                     ${DIM}<- drives, mounts, paths${NC}"
    echo -e "  ${BOLD}2)${NC} Mount USB drive"
    echo -e "  ${BOLD}3)${NC} Unmount USB drive"
    echo -e "  ${BOLD}4)${NC} Change media location      ${DIM}<- Jellyfin + FileBrowser${NC}"
    echo -e "  ${BOLD}5)${NC} Change data location       ${DIM}<- Immich photos + database${NC}"
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    read -p "  Choose: " storage_choice

    case $storage_choice in
        1) _storage_status ;;
        2) _storage_mount ;;
        3) _storage_unmount ;;
        4) _storage_change_media ;;
        5) _storage_change_data ;;
        0|*) return ;;
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

    echo -e "  ${BOLD}Current paths (.env)${NC}"
    echo -e "    Files:      ${FILES_LOCATION:-not set}  ${DIM}(FileBrowser root)${NC}"
    echo -e "    Media:      ${MEDIA_LOCATION:-not set}  ${DIM}(Jellyfin)${NC}"
    echo ""
    echo -e "    ${BOLD}Immich${NC}"
    echo -e "    Photos:     ${UPLOAD_LOCATION:-not set}"
    echo -e "    Database:   ${DB_DATA_LOCATION:-not set}"
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

_storage_change_media() {
    echo ""
    source "$SCRIPT_DIR/.env" 2>/dev/null

    info "Current media location: ${MEDIA_LOCATION:-not set}"
    info "Used by: Jellyfin (streaming) + FileBrowser (upload/manage)"
    echo ""
    read -p "  New media path: " new_path

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

    _set_env "MEDIA_LOCATION" "$new_path" "$SCRIPT_DIR/.env"
    ok "Updated .env: MEDIA_LOCATION=$new_path"

    echo ""
    info "Redeploying Jellyfin + FileBrowser..."
    cd "$SCRIPT_DIR"
    sg docker -c "docker compose up -d --force-recreate jellyfin filebrowser" 2>&1 | grep -v "^$"

    ok "Done. Jellyfin and FileBrowser now use: $new_path"
}

_storage_change_data() {
    echo ""
    source "$SCRIPT_DIR/.env" 2>/dev/null

    info "Current Immich paths:"
    echo -e "    Photos:    ${UPLOAD_LOCATION:-not set}"
    echo -e "    Database:  ${DB_DATA_LOCATION:-not set}"
    echo ""
    warn "Changing this does NOT move existing data."
    warn "Move files manually first, then update the path here."
    echo ""
    read -p "  New base data path (e.g. /mnt/data/immich): " new_base

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

step_deploy() {
    info "Deploys all services: Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma."
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
    _set_env "FILES_LOCATION" "${base_path}" "$SCRIPT_DIR/.env"

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
    echo -e "    + New Monitor → HTTP → http://$IP:8096 (Jellyfin)"
    echo -e "    + New Monitor → HTTP → http://$IP:8080 (FileBrowser)"
    echo -e "    Optional: set up Telegram/email alerts in Settings → Notifications"
    echo ""
    echo -e "  See README or run ${BOLD}s)${NC} for full setup details."
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
    echo -e "    Server: ${BOLD}$IP${NC} (local) or ${BOLD}$ts_ip${NC} (Tailscale)"
    echo -e "    Username: ${BOLD}$USER${NC}"
    echo -e "    Password: your server password"
    echo ""
    echo -e "  ${BOLD}From Mac:${NC}"
    echo -e "    Install 'Microsoft Remote Desktop' from App Store"
    echo -e "    Add PC → same server/username/password"
    echo ""
    echo -e "  ${BOLD}From iPhone/iPad:${NC}"
    echo -e "    Install 'RD Client' from App Store"
    echo -e "    Add PC → server: ${BOLD}$ts_ip${NC} (via Tailscale)"
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

            clear
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

        echo -e "  ${BOLD}1)${NC} Add new peer"
        echo -e "  ${BOLD}2)${NC} Show peer config (to set up a device)"
        echo -e "  ${BOLD}3)${NC} Remove peer"
        echo -e "  ${BOLD}4)${NC} Reinstall (regenerate all keys — existing peers stop working)"
        echo -e "  ${BOLD}0)${NC} Cancel"
        echo ""
        read -p "  Choose [1/2/3/4/0]: " wg_action

        case $wg_action in
            0) return ;;
            3) _wg_remove_peer; return ;;
            4) is_new_install=true ;;
            2)
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
            1)
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
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}ACTION NEEDED — Uptime Kuma disk alert${NC}"
    echo ""
    echo -e "  1. Open Uptime Kuma in your browser (port 3001)"
    echo -e "  2. Add New Monitor → Type: ${BOLD}Push${NC}"
    echo -e "  3. Name: ${BOLD}Disk Space${NC}"
    echo -e "  4. Heartbeat Interval: ${BOLD}3600${NC}"
    echo -e "  5. Copy the ${BOLD}Push URL${NC} it shows you"
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

    # Run hourly
    if ! sudo crontab -l 2>/dev/null | grep -q "disk-check"; then
        (sudo crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/disk-check.sh") | sudo crontab -
    fi

    ok "Disk space check runs hourly (alerts above 85%)."
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
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        echo -e "    Files:       $(grep FILES_LOCATION "$SCRIPT_DIR/.env" | cut -d= -f2)  ${DIM}(FileBrowser root)${NC}"
        echo -e "    Media:       $(grep MEDIA_LOCATION "$SCRIPT_DIR/.env" | cut -d= -f2)  ${DIM}(Jellyfin)${NC}"
    fi
    if [[ -f "$SCRIPT_DIR_STATUS/.env" ]]; then
        echo ""
        echo -e "    ${BOLD}Immich${NC}"
        echo -e "    Photos:      $(grep UPLOAD_LOCATION "$SCRIPT_DIR_STATUS/.env" | cut -d= -f2)"
        echo -e "    Database:    $(grep DB_DATA_LOCATION "$SCRIPT_DIR_STATUS/.env" | cut -d= -f2)"
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
                ssh -t "$SERVER_USER@$SERVER_IP" "sudo shutdown now"
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
                ssh -t "$SERVER_USER@$SERVER_IP" "sudo reboot"
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
Jellyfin:     http://$IP:8096
FileBrowser:  http://$IP:8080
Uptime Kuma:  http://$IP:3001"

    if [[ -n "$TS_IP" ]]; then
        urls="$urls

Remote (Tailscale):
Immich:       http://$TS_IP:2283
Jellyfin:     http://$TS_IP:8096
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
    local wg_peers=$(echo "$server_data" | sed -n '/^---WG_PEERS---$/,/^---END---$/p' | sed '1d;$d')
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

    echo ""
    ok "All saved to pass."
    echo ""
    info "pass show privcloud/                       # list everything"
    info "pass show privcloud/server/local_ip         # server IP"
    info "pass show privcloud/services/urls           # all service URLs"
    info "pass show privcloud/config/env              # .env (DB password, paths)"
    info "pass show privcloud/ssh/private_key         # SSH key"
}

run_all() {
    step_update
    step_autoupdates
    step_docker
    step_firewall
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
        7)  run_step "[7] Deploy services" step_deploy ;;
        8)  run_step "[8] Setup backups + disk monitoring" step_backup ;;
        9)  run_step "[9] Log rotation" step_logrotation ;;
        10) run_step "[10] Install Tailscale" step_tailscale ;;
        11) run_step "[11] Install WireGuard" step_wireguard ;;
        12) run_step "[12] Manage storage" step_storage ;;
        13) run_step "[13] Remote desktop" step_remotedesktop ;;
        14) run_step "[14] Sync files" step_sync ;;
        15) run_step "[15] Save to pass" step_save_to_pass ;;
        s)  run_step "[s] Status" step_status ;;
        p)  run_step "[p] Power management" step_power ;;
        a)  run_step "Run all (3-9)" run_all ;;
        0)  echo "Bye."; exit 0 ;;
        *)  echo -e "  ${RED}Invalid choice.${NC}" ;;
    esac
done
