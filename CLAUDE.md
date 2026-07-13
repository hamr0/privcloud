## Dev Rules

**POC first.** Always validate logic with a ~15min proof-of-concept before building. Cover happy path + common edges. POC works → design properly → build with tests. Never ship the POC.

**Build incrementally.** Break work into small independent modules. One piece at a time, each must work on its own before integrating.

**Dependency hierarchy — follow strictly:** vanilla language → standard library → external (only when stdlib can't do it in <100 lines). External deps must be maintained, lightweight, and widely adopted. Exception: always use vetted libraries for security-critical code (crypto, auth, sanitization).

**Lightweight over complex.** Fewer moving parts, fewer deps, less config. Simple > clever. Readable > elegant.

**Open-source only.** No vendor lock-in. Every line of code must have a purpose — no speculative code, no premature abstractions.

**Public repo — no hardcoded config.** This repo is public. Never commit user-specific values (SSH usernames, LAN/Tailscale IPs, personal paths like `/home/<user>` or `/run/media/<user>`, secrets). Resolve them at runtime: env var → local config file outside the repo (e.g. `${XDG_CONFIG_HOME:-~/.config}/federver/config`) → interactive prompt that persists (write with `umask 077`). `setup.sh`'s `_require_server_config` is the reference pattern; use `$USER`/`$HOME` in paths.

**Server SSH must work home and away.** The config holds `SERVER_IP` (LAN, fast at home) and optional `SERVER_HOST_TS` (Tailscale name/IP, reachable anywhere). At startup `_resolve_server_endpoint` probes the LAN address and falls back to `SERVER_HOST_TS` when roaming, so all SSH targets one resolved `SERVER_IP`. All laptop→server `ssh` goes through the `ssh()` wrapper (`ConnectTimeout` + keepalives) so an unreachable address fails fast instead of hanging — never call `command ssh` directly for server hops.

For full development and testing standards, see `.claude/memory/AGENT_RULES.md`.

## Project: privcloud

Self-hosted home server and photo backup. Two tools in one repo:

- `federver` (setup.sh) — Fedora XFCE server setup and management. Handles SSH, Docker, firewall, Tailscale, service deployment, backups, monitoring, file sync.
- `privcloud` (privcloud) — Immich photo management. Start/stop, status with error checking, updates, backup, upload, Google Photos migration.

**Services:** Immich, Navidrome (music; auto-installs `.nsp` smart playlists), FileBrowser, Watchtower, Uptime Kuma, Tailscale.

**Stack:** Docker Compose, bash scripts, Fedora XFCE 43.

**Hardware:** HP ProDesk 400 G4 DM, 16GB RAM, 256GB NVMe + 1TB USB HDD.

<!-- MEMORY:START -->
@.claude/remember/MEMORY.md
<!-- MEMORY:END -->

<!-- AGENT_RULES:START -->
Consult when building something new or adding a feature — a standards guide, not hot
context like MEMORY.md above:
@.claude/remember/AGENT_RULES.md
<!-- AGENT_RULES:END -->
