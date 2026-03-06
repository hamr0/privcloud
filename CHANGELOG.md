# Changelog

## v0.1.0 — 2026-03-06

Initial release.

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
