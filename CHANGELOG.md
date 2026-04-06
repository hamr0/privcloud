# Changelog

## v0.2.1 — 2026-04-06

### Added
- Save to pass (option 15) — backs up all server config to `pass` password manager
  - Runs from laptop, SSHes into server to fetch data
  - Saves: hostname, local IP, Tailscale IP, SSH keys, service URLs, .env, docker-compose.yml, WireGuard configs
  - All entries overwritten on each save (idempotent)
  - Updated README, customer guide, and changelog

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
  - Service deployment (Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma)
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
