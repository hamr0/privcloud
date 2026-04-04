# Changelog

## v0.2.0 — 2026-04-04

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
  - Remote desktop via xrdp (disables local display, RDP from any device)
  - Daily Immich DB backup (cron at 3am)
  - Docker log rotation
  - File sync between laptop and server (upload/download)
  - Status dashboard (URLs, IPs, containers, disk)
  - Power management (shutdown/restart)
- Jellyfin, FileBrowser, Watchtower, Uptime Kuma in docker-compose.yml
- `privcloud status` now shows container health and recent errors
- Colored output with success/fail banners
- `federver` and `privcloud` commands available globally

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
