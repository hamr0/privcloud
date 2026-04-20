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
federver      # step 1 with monitor on server, then everything from laptop
```

One script sets up everything from a fresh Fedora XFCE install. **Always run from the laptop** (except step 1 which needs a monitor). Server commands auto-route via SSH. See [customer guide](customer-guide.md) for full walkthrough.

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
| **Syncthing** | 8384, 22000, 21027 | Real-time bidirectional folder sync between devices |
| **Remote Desktop** | 3389 | Full XFCE desktop via RDP from any device |

## Commands

### `federver` — Fedora XFCE server manager

On the **laptop** (full menu):

```
========================================
  Federver — Fedora XFCE Server Manager
  Running from: laptop
========================================

  -- Initial setup (run once, in order) --
  1)  Enable SSH + auto-login + hostname    ← only step on server with monitor
  2)  SSH key auth
  3)  System update
  4)  Enable auto-updates                   ← security only, kernel excluded
  5)  Install Docker                        ← log out & SSH back in after

  -- Services --
  6)  Manage firewall                       ← status, add/remove ports, defaults
  7)  Manage services                       ← unified laptop + server, start/stop/restart
  8)  Setup backups + disk monitoring
  9)  Configure log rotation

  -- Extras (optional, run anytime) --
  10) Manage Tailscale                      ← install, status, up/down
  11) Manage WireGuard                      ← install, peers, QR, remove
  12) Manage AdGuard                        ← install DNS ad blocker, uses Tailscale
  13) Manage storage                        ← USB drives, media/data/Immich paths
  14) Manage Syncthing                      ← real-time bidirectional file sync
  15) Manage remote desktop                 ← install, access XFCE via RDP

  -- Immich photo management --
  i)  Immich (privcloud)                    ← start/stop/status/update/backup

  -- Tools --
  16) Manage sync                           ← transfer, schedule (cron or systemd timer), edit jobs
  17) Save to pass                          ← backup everything to pass

  s) Status  i) Immich  p) Power  r) Reset password  a) Run all (3-9)  0) Exit
```

On the **server** (reduced — bootstrap, status, power only):

```
========================================
  Federver — Fedora XFCE Server Manager
  Running from: server
  For the full menu, run federver from your laptop.
========================================

  1)  Enable SSH + auto-login + hostname    ← bootstrap (needs monitor)
  s)  Status
  p)  Power (shutdown / restart)
  e)  Emergency: restart all services      ← fixes DNS/container outages
  0)  Exit
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

**Always run `federver` from your laptop.** Step 1 (Enable SSH) is the only step that runs on the server with a physical monitor — after that, everything runs from the laptop. Server commands auto-SSH in; laptop commands run locally. Clone the repo on **both** machines. First run `federver` → step 1 on the server to register the commands and enable SSH.

**Dry run mode:** `./setup.sh --dry-run` walks the menu and prints each state-changing command instead of executing it. Safe way to review the flow of any option without touching the system. Propagates across the laptop→server SSH hop.

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
| Syncthing dashboard | `http://federver:8384` (server) or `http://localhost:8384` (laptop) |
| Show Syncthing Device ID | `federver` → **14** → **2** |
| Check containers | `docker ps` |
| View logs | `docker logs <container>` |
| Update Immich | `privcloud update` |
| Update all containers | `docker compose pull && docker compose up -d` |
| Update system | `sudo dnf upgrade` |
| Remote desktop | RDP client → server IP port 3389 |
| Backup | `privcloud backup` or `sudo /usr/local/bin/immich-backup.sh` |
| Disk alerts | `cat /var/log/disk-check.log` or Uptime Kuma dashboard |
| Backup to pass | `federver` → **17** (from laptop) |
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
