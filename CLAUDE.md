## Dev Rules

**POC first.** Always validate logic with a ~15min proof-of-concept before building. Cover happy path + common edges. POC works → design properly → build with tests. Never ship the POC.

**Build incrementally.** Break work into small independent modules. One piece at a time, each must work on its own before integrating.

**Dependency hierarchy — follow strictly:** vanilla language → standard library → external (only when stdlib can't do it in <100 lines). External deps must be maintained, lightweight, and widely adopted. Exception: always use vetted libraries for security-critical code (crypto, auth, sanitization).

**Lightweight over complex.** Fewer moving parts, fewer deps, less config. Simple > clever. Readable > elegant.

**Open-source only.** No vendor lock-in. Every line of code must have a purpose — no speculative code, no premature abstractions.

For full development and testing standards, see `.claude/memory/AGENT_RULES.md`.

## Project: privcloud

Self-hosted home server and photo backup. Two tools in one repo:

- `federver` (setup.sh) — Fedora XFCE server setup and management. Handles SSH, Docker, firewall, Tailscale, service deployment, backups, monitoring, file sync.
- `privcloud` (privcloud) — Immich photo management. Start/stop, status with error checking, updates, backup, upload, Google Photos migration.

**Services:** Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma, Tailscale.

**Stack:** Docker Compose, bash scripts, Fedora XFCE 43.

**Hardware:** HP ProDesk 400 G4 DM, 16GB RAM, 256GB NVMe + 1TB USB HDD.
