```
           _            _                 _
 _ __ _ __(_)_   _____ | | ___  _   _  __| |
| '_ \| '__| \ \ / / __|| |/ _ \| | | |/ _` |
| |_) | |  | |\ V / (__ | | (_) | |_| | (_| |
| .__/|_|  |_| \_/ \___||_|\___/ \__,_|\__,_|
|_|
```

**Your server. Your data. No cloud required.**

Self-hosted home server with photo backup, media streaming, file management, and remote access.

## Two modes

### Immich only — no server needed

```bash
git clone https://github.com/hamr0/privcloud.git && cd privcloud
privcloud install
privcloud start
# Open http://localhost:2283
```

Back up phone photos locally on any machine. Start when you need it, stop when done.

### Full home server — always-on

```bash
git clone https://github.com/hamr0/privcloud.git && cd privcloud
federver      # pick 1, then SSH in and run the rest
```

One script sets up everything from a fresh Fedora XFCE install. See [customer guide](customer-guide.md) for full walkthrough.

## Services

| Service | Port | What it does |
|---------|------|-------------|
| **Immich** | 2283 | Photo backup from phone, face detection, smart search |
| **Jellyfin** | 8096 | Stream movies, music, media — personal Netflix |
| **FileBrowser** | 8080 | Browse/download/upload files from any browser |
| **Uptime Kuma** | 3001 | Monitoring dashboard, alerts if services go down |
| **Watchtower** | — | Auto-updates all containers daily at 4am |
| **Tailscale** | — | Remote access from anywhere, no port forwarding |
| **Remote Desktop** | 3389 | Full XFCE desktop via RDP from any device |

## Commands

### `federver` — Fedora XFCE server manager

```
========================================
  Federver — Fedora XFCE Server Manager
========================================

  -- Run on server with monitor --
  1) Enable SSH + auto-login + hostname

  -- Exit SSH, run from laptop --
  2) SSH key auth                ← exit SSH first

  -- Run over SSH from laptop --
  3) System update
  4) Enable auto-updates
  5) Install Docker              ← log out & SSH back in after this
  6) Configure firewall
  7) Install Tailscale           ← opens a URL to approve on phone/laptop
  8) Mount USB drive             ← plug in USB drive first
  9) Deploy services             ← Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma
  10) Remote desktop             ← access XFCE desktop from laptop
  11) Setup backups              ← daily Immich DB backup
  12) Configure log rotation     ← prevent Docker logs eating disk

  -- Immich photo management --
      Run: privcloud [start|stop|status|update|backup]

  -- Exit SSH, run from laptop --
  13) Sync files                 ← exit SSH first

  s) Status                     ← show all service URLs and config
  p) Power                      ← shutdown or restart server
  a) Run all (3-12)
  0) Exit
```

### `privcloud` — Immich photo manager

```
  1) install   Check prerequisites, pull images, set up config
  2) start     Start Immich
  3) stop      Stop Immich
  4) status    Show health, containers, recent errors
  5) config    Change photo storage location
  6) update    Check for updates and apply
  7) upload    Upload photos via Immich CLI
  8) fix-gp    Fix Google Photos metadata (Takeout export)
  9) backup    Backup photos + database to external drive
  0) exit
```

Both commands work from anywhere on the server. First run `federver` → step 1 to register the commands.

## Quick reference

| Task | Command |
|------|---------|
| Server status | `federver` → **s** |
| Immich management | `privcloud` |
| Check containers | `docker ps` |
| View logs | `docker logs <container>` |
| Update Immich | `privcloud update` |
| Update all containers | `docker compose pull && docker compose up -d` |
| Update system | `sudo dnf upgrade` |
| Remote desktop | RDP client → server IP port 3389 |
| Backup | `privcloud backup` or `sudo /usr/local/bin/immich-backup.sh` |
| Shutdown | `federver` → **p** |

## Docs

| Doc | What |
|-----|------|
| [Customer Guide](customer-guide.md) | Full setup walkthrough, service config, troubleshooting, maintenance |
| [Changelog](CHANGELOG.md) | Version history |

## Files

| File | What |
|------|------|
| `setup.sh` | Server manager (runs as `federver`) |
| `privcloud` | Photo manager (runs as `privcloud`) |
| `docker-compose.yml` | All service definitions |
| `.env.example` | Config template |
| `scripts/` | Google Takeout fix, installer |
| `tools/` | Backup utility |

## License

MIT
