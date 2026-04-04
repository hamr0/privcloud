```
           _            _                 _
 _ __ _ __(_)_   _____ | | ___  _   _  __| |
| '_ \| '__| \ \ / / __|| |/ _ \| | | |/ _` |
| |_) | |  | |\ V / (__ | | (_) | |_| | (_| |
| .__/|_|  |_| \_/ \___||_|\___/ \__,_|\__,_|
|_|
```

**Your server. Your data. No cloud required.**

Privcloud has two modes. Pick what fits you:

### Option 1 — Immich only (no server needed)

Just want to back up your photos locally? Run `./privcloud` on any machine — laptop, desktop, whatever. No dedicated server, no setup script. Start it when you want to sync, stop it when done.

```bash
git clone https://github.com/hamr0/privcloud.git
cd privcloud
./privcloud install
./privcloud start
```

Open http://localhost:2283, create your account, connect the Immich app on your phone. Done.

**Good for:** backing up phone photos, replacing iCloud/Google Photos, occasional use.
**Needs:** Docker, ~4GB RAM, storage for your photos. Linux, macOS, or WSL.

### Option 2 — Full home server

Dedicated always-on machine running Immich + media streaming + file management + monitoring + remote access. `./setup.sh` handles everything from a fresh Fedora install — SSH, Docker, firewall, Tailscale, all services.

**Good for:** 24/7 photo backup, streaming media to TV/phone, accessing files from anywhere, replacing Google Drive/iCloud/Plex.
**Needs:** a mini PC or similar (see hardware below), Fedora XFCE, a monitor + keyboard for initial setup (then headless).

## What it runs (full server)

### Immich — Photo backup (port 2283)
Back up every photo from your phone automatically over WiFi. Face recognition groups your family and friends. Search by content ("beach", "birthday", "dog"). Map view, timeline, albums, duplicate detection. Replace iCloud and Google Photos completely.

### Jellyfin — Media streaming (port 8096)
Stream your movies, TV shows, and music to any device — phone, laptop, smart TV. Like a personal Netflix/Spotify. Organizes your media library with metadata, artwork, and subtitles. No subscription, no tracking.

### FileBrowser — File management (port 8080)
Access all your files from any browser. Upload, download, rename, move — like a web-based file manager for your server. No need to SSH in just to grab a file.

### Watchtower — Auto-updates
Checks for new container images daily at 4am and updates automatically. Your services stay up to date without you lifting a finger.

### Uptime Kuma — Monitoring (port 3001)
Dashboard showing if each service is up or down. Set up Telegram or email alerts so you know immediately if something breaks at 2am.

### Tailscale — Remote access
Access everything from anywhere — not just when you're on home WiFi. Like a private VPN between your devices. Free, encrypted, no port forwarding needed.

## Hardware (full server)

- HP ProDesk 400 G4 DM (Desktop Mini)
- Intel Core i5-8500T (6 cores, 6 threads)
- 16GB DDR4 (2x8GB SO-DIMM, 2400MHz)
- 256GB NVMe M.2 (OS + Docker)
- 1TB external HDD via USB 3.0 (data/media)

## Two tools

### `./setup.sh` — Server setup & management

```
========================================
  Privcloud Setup
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
  10) Setup backups              ← daily Immich DB backup
  11) Configure log rotation     ← prevent Docker logs eating disk

  -- Immich management --
      Run: ./privcloud [start|stop|status|update|backup]

  -- Exit SSH, run from laptop --
  12) Sync files                 ← exit SSH first

  s) Status                     ← show all service URLs and config
  a) Run all (3-11)
  0) Exit
```

### `./privcloud` — Immich management

```
  1) install   Check prerequisites, pull images, set up config
  2) start     Start privcloud
  3) stop      Stop privcloud
  4) status    Show status and diagnostics
  5) config    Change photo storage location
  6) update    Check for updates and apply
  7) upload    Upload photos to privcloud
  8) fix-gp    Fix Google Photos metadata (Takeout export)
  9) backup    Backup photos + database to external drive
  0) exit
```

Commands also work directly: `./privcloud start`, `./privcloud status`, `./privcloud backup`, etc.

## Setup

### Step 1 — On the server (with monitor + keyboard)

```bash
git clone https://github.com/hamr0/privcloud.git
cd privcloud
./setup.sh
```

Pick **option 1**. This enables SSH, sets the hostname, configures auto-login, and disables sleep. It prints an SSH command at the end. **Unplug the monitor.**

### Step 2 — From your laptop (not SSH)

```bash
cd ~/PycharmProjects/privcloud
./setup.sh
```

Pick **option 2** to copy your SSH key and disable password login.

### Steps 3-11 — From your laptop (over SSH)

```bash
ssh ahassan@<ip-from-step-1>
cd privcloud
./setup.sh
```

| Step | What | Where | Notes |
|------|------|-------|-------|
| 1 | SSH + auto-login + hostname | Server (monitor) | Run first, then unplug monitor |
| 2 | SSH key auth | Laptop (local) | Copies key, disables password login |
| 3 | System update | SSH | |
| 4 | Auto-updates | SSH | Automatic security patches via dnf5 |
| 5 | Docker | SSH | **Log out and SSH back in after this** |
| 6 | Firewall | SSH | Opens ports locally, trusts Tailscale |
| 7 | Tailscale | SSH | Prints a URL — approve on phone/laptop |
| 8 | USB drive mount | SSH | Plug in drive first |
| 9 | Deploy services | SSH | All services: Immich, Jellyfin, FileBrowser, etc. |
| 10 | Setup backups | SSH | Daily Immich DB backup at 3am |
| 11 | Log rotation | SSH | Limits Docker log sizes |
| 12 | Sync files | Laptop (local) | Upload/download between laptop and server |

Press **a** to run all (3-11) at once. Press **s** for status (URLs, IPs, containers, disk).

### Step 12 — Sync files (run from laptop, not SSH)

```bash
./setup.sh
# Pick 12
```

Upload/download between laptop and server. Auto-detects local drives and USB drives.

## First-time service setup

After deploying (step 9), each service needs initial configuration. Run `./setup.sh` → **s** for URLs.

### Immich

1. Open Immich in your browser (port 2283)
2. Create your admin account
3. Install the Immich app on your phone ([iPhone](https://apps.apple.com/app/immich/id1613945652) / [Android](https://play.google.com/store/apps/details?id=app.alextran.immich))
4. In the app: enter the server URL, log in, enable auto-upload

### Jellyfin

1. Open Jellyfin in your browser (port 8096)
2. Follow the setup wizard — create admin account
3. Add media libraries: point to `/media`
4. Install the Jellyfin app on your phone/TV

### FileBrowser

1. Open FileBrowser in your browser (port 8080)
2. Get the generated password: `docker logs filebrowser | grep password`
3. Login: **admin** / the generated password
4. Change the password (Settings → Profile)

### Uptime Kuma

1. Open Uptime Kuma in your browser (port 3001)
2. Create admin account
3. Add monitors:
   - New Monitor → HTTP → `http://localhost:2283` (Immich)
   - New Monitor → HTTP → `http://localhost:8096` (Jellyfin)
   - New Monitor → HTTP → `http://localhost:8080` (FileBrowser)
4. Optional: set up alerts in Settings → Notifications (Telegram, email, etc.)

### Tailscale

Tailscale creates a private network between your devices — access your server from anywhere.

1. Create a free account at [login.tailscale.com](https://login.tailscale.com)
2. On the server: `sudo tailscale up` → open the URL it prints, approve the device
3. Install the Tailscale app on your phone/laptop, log in with the same account
4. All devices on the same account can now reach each other via Tailscale IPs
5. Access all services remotely: `http://<tailscale-ip>:<port>`

Free for up to 100 devices. No port forwarding, no dynamic DNS, encrypted end-to-end.

## Migrating from Google Photos

1. Export via [Google Takeout](https://takeout.google.com) (select Google Photos)
2. Fix metadata: `./privcloud fix-gp` — point it at the folder with your takeout zips
3. Upload: `./privcloud upload` — prompts for your API key and photo folder

The fix restores dates and GPS coordinates that Google strips from Takeout exports.

## Network access

| Location | How to access |
|----------|--------------|
| Home (WiFi) | `http://<local-ip>:<port>` — anyone on the network |
| Away | `http://<tailscale-ip>:<port>` — via Tailscale VPN |
| SSH | `ssh ahassan@<hostname>` (local) or via Tailscale IP (remote) |

## Security

- **SSH:** key-only auth (password login disabled after step 2)
- **Firewall:** only SSH + service ports open on local network
- **Tailscale:** trusted interface for full remote access
- **Everything else:** blocked

Back up your SSH key:
```bash
cat ~/.ssh/id_ed25519 | pass insert -m ssh/privcloud-key
```

## Backups

**Automated (step 10):**
- Immich database dump daily at 3am
- Location: `<data-path>/immich/backups/`
- Keeps last 7 days
- Manual run: `sudo /usr/local/bin/immich-backup.sh`

**Manual:** `./privcloud backup` — full backup of photos + database to external drive

## Config

Step 9 asks for a base data path and creates `.env` with all service paths:

- `/mnt/data` — USB drive (default)
- `/home/ahassan/data` — internal drive (temporary)

The `.env` file is gitignored. See `.env.example` for the template.

## After power outage

1. **BIOS:** F10 → After Power Loss → Power On
2. Server boots → Fedora auto-logs in → Docker restarts all containers

No monitor or keyboard needed.

## Day-to-day management

```bash
ssh ahassan@<hostname>
cd privcloud
```

| Task | Command |
|------|---------|
| Status dashboard | `./setup.sh` → **s** |
| Check all containers | `docker ps` |
| Immich management | `./privcloud` |
| View logs | `docker logs <container_name>` |
| Update Immich | `./privcloud update` |
| Update all containers | `docker compose pull && docker compose up -d` |
| Update system | `sudo dnf upgrade` |
| Re-run any setup step | `./setup.sh` |
| Manual backup | `./privcloud backup` or `sudo /usr/local/bin/immich-backup.sh` |
| Monitoring | Uptime Kuma on port 3001 |

## Files

| File | What |
|------|------|
| `setup.sh` | Server setup & management menu (steps 1-12) |
| `privcloud` | Immich CLI (start/stop/status/update/backup/upload) |
| `docker-compose.yml` | All services (Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma) |
| `.env.example` | Template for all config paths and credentials |
| `.env` | Your config (gitignored, created by step 9) |
| `scripts/` | Google Takeout fix, installer |
| `tools/` | Backup utility |
| `customer-guide.md` | Detailed walkthrough for photo migration and setup |

## License

MIT
