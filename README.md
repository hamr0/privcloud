```
           _            _                 _
 _ __ _ __(_)_   _____ | | ___  _   _  __| |
| '_ \| '__| \ \ / / __|| |/ _ \| | | |/ _` |
| |_) | |  | |\ V / (__ | | (_) | |_| | (_| |
| .__/|_|  |_| \_/ \___||_|\___/ \__,_|\__,_|
|_|
```

**Your server. Your data. No cloud required.**

Self-hosted home server with photo backup, music streaming, file management, and remote access.

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
federver      # pick 1 with monitor, then run the rest from anywhere
```

One script sets up everything from a fresh Fedora XFCE install. Run from either machine — server commands auto-route via SSH. See [customer guide](customer-guide.md) for full walkthrough.

## Services

| Service | Port | What it does |
|---------|------|-------------|
| **Immich** | 2283 | Photo backup from phone, face detection, smart search |
| **Navidrome** | 4533 | Music streaming — background playback, offline cache via Amperfy app |
| **FileBrowser** | 8080 | Browse/download/upload files from any browser |
| **Uptime Kuma** | 3001 | Monitoring dashboard, alerts if services go down |
| **Watchtower** | — | Auto-updates all containers daily at 4am |
| **Tailscale** | — | Remote access from anywhere — MagicDNS lets you use `federver` as hostname |
| **WireGuard** | 51820 | Full VPN — route all traffic through server |
| **AdGuard Home** | 53, 80 | Network-wide DNS ad & tracker blocker — routed via Tailscale |
| **Remote Desktop** | 3389 | Full XFCE desktop via RDP from any device |

## Commands

### `federver` — Fedora XFCE server manager

```
========================================
  Federver — Fedora XFCE Server Manager
  Running from: laptop
========================================

  -- Initial setup (run once, in order) --
  1)  Enable SSH + auto-login + hostname    ← with monitor
  2)  SSH key auth                          ← from laptop, exit SSH first
  3)  System update
  4)  Enable auto-updates                   ← security only, kernel excluded
  5)  Install Docker                        ← log out & SSH back in after

  -- Services --
  6)  Configure firewall
  7)  Deploy services                       ← Immich, Navidrome, FileBrowser, Watchtower, Uptime Kuma
  8)  Setup backups + disk monitoring
  9)  Configure log rotation

  -- Extras (optional, run anytime) --
  10) Install Tailscale                     ← remote access VPN
  11) Install WireGuard                     ← full VPN, route all traffic
  12) Install AdGuard Home                  ← DNS ad blocker, uses Tailscale
  13) Manage storage                        ← USB drives, media/data/Immich paths
  14) Remote desktop                        ← access XFCE desktop via RDP

  -- Immich photo management --
      Run: privcloud [start|stop|status|update|backup]

  -- Tools (from laptop, exit SSH first) --
  15) Sync files                          ← upload, download, or delete files
  16) Save to pass                        ← from laptop, backup everything to pass

  s)  Status     p)  Power     r)  Reset password     a)  Run all (3-9)     0)  Exit
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

Both commands work from anywhere on the server. Clone the repo on **both laptop and server** — several features (file sync, backups, password reset) run from the laptop and SSH into the server. First run `federver` → step 1 to register the commands.

### `fedvpn` — WireGuard VPN client (runs on laptop)

```
fedvpn — WireGuard VPN

  1) Setup              ← first time: install + paste config
  2) Connect
  3) Disconnect
  4) Status
  0) Exit
```

Also: `fedvpn start` / `fedvpn stop` / `fedvpn status`

## Quick reference

| Task | Command |
|------|---------|
| Server status | `federver` → **s** |
| Immich management | `privcloud` |
| Upload media/files | FileBrowser → `http://federver:8080` (user `admin`, password: `cat ~/.privcloud/filebrowser.pass`) |
| Manage storage | `federver` → **13** (mount USB, change paths) |
| VPN connect/disconnect | `fedvpn start` / `fedvpn stop` (laptop) |
| Show WireGuard peer config | `federver` → **11** → **2** (server) |
| Remove WireGuard peer | `federver` → **11** → **3** (server) |
| AdGuard dashboard | `http://federver` (Query Log tab shows live blocking) |
| Check containers | `docker ps` |
| View logs | `docker logs <container>` |
| Update Immich | `privcloud update` |
| Update all containers | `docker compose pull && docker compose up -d` |
| Update system | `sudo dnf upgrade` |
| Remote desktop | RDP client → server IP port 3389 |
| Backup | `privcloud backup` or `sudo /usr/local/bin/immich-backup.sh` |
| Disk alerts | `cat /var/log/disk-check.log` or Uptime Kuma dashboard |
| Backup to pass | `federver` → **16** (from laptop) |
| Reset password | `federver` → **r** (FileBrowser, Immich, Navidrome, Uptime Kuma) |
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
| `fedvpn` | WireGuard VPN client for laptop |
| `docker-compose.yml` | All service definitions |
| `.env.example` | Config template |
| `scripts/` | Google Takeout fix, installer |
| `tools/` | Backup utility |

## License

MIT
