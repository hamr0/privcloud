# Changelog

## Unreleased

### Added
- WireGuard **Remove peer** option in `setup.sh` → `11`. Lists current peers by name, pick a number, confirms, deletes the `[Peer]` block from `wg0.conf` and the client `.conf`, then hot-reloads. Closes the gap where revoking a lost device required a full reinstall.
- Storage: separate **Change Immich location** option (`federver` → `12` → `6`). Immich paths are now independent from FileBrowser and Navidrome — changing one never affects the others.
- **Reset password** option (`federver` → `r`). Resets credentials for FileBrowser, Immich, Navidrome, or Uptime Kuma. FileBrowser and Immich reset password only (data kept). Navidrome and Uptime Kuma wipe data and restart fresh.
- New `MUSIC_LOCATION` env var for Navidrome music library path.

### Changed
- Replaced Jellyfin with Navidrome for music streaming. Navidrome is lighter, supports background playback and offline caching via Subsonic-compatible apps (recommended: Amperfy on iOS).
- WireGuard add/remove now hot-reload via `wg syncconf` instead of `systemctl restart wg-quick@wg0`. Other connected peers stay up during config changes (previously every peer dropped for a few seconds on every add). Falls back to restart if `wg syncconf` is unavailable.
- Storage menu split into three path options: music (Navidrome), data (FileBrowser), Immich. Previously "Change media location" controlled both Jellyfin and FileBrowser, and there was no separate Immich option.

### Removed
- Jellyfin media server. Videos can be played by downloading from FileBrowser and opening in VLC.

### Fixed
- Power management (`federver` → `p`) now runs shutdown/reboot over SSH on the server instead of locally. Previously would shut down the laptop if run from there.
- USB drive detection now finds partitions on USB disks, not just the parent device. Fixes status/mount/unmount showing "none detected" when drives were plugged in.

### Security
- FileBrowser admin password is now randomly generated per-deploy (16-char) and saved to `~/.privcloud/filebrowser.pass` (mode 0600). Removes the hardcoded `privcloud` credential that was published in README and customer-guide.
- `dnf-automatic` now applies **security updates only**, with kernel packages explicitly excluded (`kernel`, `kernel-core`, `kernel-modules*`, `kernel-devel`, `kernel-headers`). A headless home server should never auto-reboot into an untested kernel while the owner is away. Update kernels manually with `sudo dnf upgrade kernel` + reboot when you're home.

## v0.2.1 — 2026-04-06

### Added
- Save to pass (option 15) — backs up all server config to `pass` password manager
  - Runs from laptop, SSHes into server to fetch data
  - Saves: hostname, local IP, Tailscale IP, SSH keys, service URLs, .env, docker-compose.yml, WireGuard configs
  - All entries overwritten on each save (idempotent)

### Changed
- Option 12 "Mount USB drive" replaced with "Manage storage" sub-menu:
  - Status: shows drives, mounts, current paths, disk usage
  - Mount USB: auto-detects USB drives (filters by TRAN=usb, no guessing)
  - Unmount USB: safely unmount and remove from fstab
  - Change media location: updates Jellyfin, redeploys
  - Change data location: updates Immich photo/DB paths, redeploys
- FileBrowser mounts `FILES_LOCATION` (base data path) — browse media, files, and immich
- Jellyfin mounts `MEDIA_LOCATION` only — media files only
- Replaced `DATA_ROOT` with `FILES_LOCATION` in .env
- Status display: separated media path from Immich paths
- FileBrowser password auto-set to `privcloud` during deploy (no more random passwords)
- Deploy no longer sets unused `DATA_ROOT`

### Fixed
- Jellyfin `:ro` flag removed from media mount
- FileBrowser upload now works (correct ownership on media dir)
- FileBrowser password no longer lost on container recreate

## v0.2.0 — 2026-04-05

### Added
- `setup.sh` — full server setup menu (`federver` command)
  - SSH, auto-login, hostname setup
  - SSH key auth (copies key, disables password login)
  - System update and auto-updates (dnf5)
  - Docker installation
  - Firewall (local ports + Tailscale trusted)
  - Tailscale remote access with guided setup
  - USB drive mount (permanent via fstab)
  - Service deployment (Immich, Navidrome, FileBrowser, Watchtower, Uptime Kuma)
  - WireGuard VPN (iptables NAT, auto key gen, QR codes, device-specific instructions, add/show peers)
  - Remote desktop via xrdp (disables local display, RDP from any device)
  - Daily Immich DB backup (cron at 3am)
  - Hourly disk space monitoring with Uptime Kuma push alerts (above 85%)
  - Docker log rotation
  - File sync between laptop and server (upload/download)
  - Status dashboard (URLs, IPs, containers, disk)
  - Power management (shutdown/restart)
- `fedvpn` — WireGuard client CLI for laptop (setup/start/stop/status, IPv6 leak fix)
- Jellyfin, FileBrowser, Watchtower, Uptime Kuma v2 in docker-compose.yml
- `privcloud status` now shows container health and recent errors
- Colored output with success/fail banners
- `federver` and `privcloud` commands available globally
- Reorganized menu: Initial setup (1-5), Services (6-9), Extras (10-13), Tools (14)

### Fixed
- WireGuard: use iptables with detected interface instead of firewall-cmd (NAT routing)
- WireGuard: use local IP as endpoint (Tailscale IP creates routing loops)
- fedvpn: disable IPv6 on connect to prevent tunnel bypass
- fedvpn: use sudo for config file checks (root-owned)
- Uptime Kuma: use server IP not localhost in monitors (Docker networking)
- FileBrowser: read generated password from docker logs
- Postgres permissions: document never to chown postgres directory

## v0.1.0 — 2026-03-06

### Added
- Interactive CLI menu (`./privcloud`)
- `install` — checks Docker, Docker Compose, pulls Immich images, sets up storage
- `start` — starts all containers, waits for API, shows connection URLs
- `stop` — stops containers, shuts down Docker daemon if nothing else running
- `status` — full diagnostics (system, docker, storage, containers, network)
- `config` — change photo storage location
- Auto-detect and patch SELinux volume flags (Fedora/RHEL)
- Auto-fix Docker group permissions (Linux)
- Auto-start Docker daemon via sudo/pkexec
- Auto-generate database credentials on first install
- Docker Compose setup for Immich (server, ML, Redis, PostgreSQL)
- Works on Linux, macOS, and WSL
