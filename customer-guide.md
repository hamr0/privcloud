# privcloud — Customer Guide

Your server. Your data. No cloud required.

---

## Table of Contents

- [Why privcloud](#why-privcloud)
- [Two modes](#two-modes)
- [What you get](#what-you-get)
- [Getting started (Immich only)](#getting-started-immich-only)
- [Connecting your phone](#connecting-your-phone)
- [Understanding the phone app](#understanding-the-phone-app)
- [Multiple accounts and family setup](#multiple-accounts-and-family-setup)
- [Migrating from Google Photos](#migrating-from-google-photos)
- [Migrating from iCloud](#migrating-from-icloud)
- [Uploading existing photo collections](#uploading-existing-photo-collections)
- [When is it safe to delete from your phone?](#when-is-it-safe-to-delete-from-your-phone)
- [Organizing your photos](#organizing-your-photos)
- [Finding photos](#finding-photos)
- [Face recognition](#face-recognition)
- [Duplicates](#duplicates)
- [Sharing](#sharing)
- [Background jobs and processing](#background-jobs-and-processing)
- [Video playback issues](#video-playback-issues)
- [Storage and architecture](#storage-and-architecture)
- [Backup and restore](#backup-and-restore)
- [Moving to a new machine](#moving-to-a-new-machine)
- [Day-to-day usage (Immich only)](#day-to-day-usage-immich-only)
- [Troubleshooting (Immich)](#troubleshooting-immich)
- [Privacy and security](#privacy-and-security)
- **[Home server setup](#home-server-setup)**
- [Hardware selection](#hardware-selection)
- [Server setup walkthrough](#server-setup-walkthrough)
- [Service setup](#service-setup)
- [Tailscale remote access](#tailscale-remote-access)
- [WireGuard VPN](#wireguard-vpn)
- [Remote desktop](#remote-desktop)
- [Save to pass](#save-to-pass)
- [Server maintenance](#server-maintenance)
- [Server troubleshooting](#server-troubleshooting)
- [Managing storage](#managing-storage)

---

## Why privcloud

Apple charges $0.99/month for 50GB of iCloud. Sounds cheap — until your library grows and you're paying $2.99, then $9.99, then $14.99. Every month. Forever. That's $180/year to store files you already own.

Google gives you 15GB free, then strips your photo metadata to save themselves storage costs. Try to export via Google Takeout and you get mangled filenames, missing dates, and JSON sidecar files you have to recombine yourself.

Both companies make it effortless to upload and painful to download. That's not a bug. That's the business model. The friction is intentional — it keeps you paying.

privcloud eliminates all of it. One command runs a full photo server on your own machine. Your photos stay on your drive. No subscription. No cloud. No friction at the exit door.

---

## Two modes

### Immich only (no server needed)

Just want photo backup? Run `privcloud` on any machine — laptop, desktop, whatever. No dedicated server, no setup script. Start it when you want to sync, stop it when done.

**Good for:** backing up phone photos, replacing iCloud/Google Photos, occasional use.
**Needs:** Docker, ~4GB RAM, storage. Linux, macOS, or WSL.

### Full home server

Dedicated always-on machine running Immich + media streaming + file management + monitoring + remote access. `federver` handles everything from a fresh Fedora install.

**Good for:** 24/7 photo backup, streaming media to TV/phone, accessing files from anywhere, replacing Google Drive/iCloud/Plex.
**Needs:** a mini PC or similar, Fedora XFCE, a monitor + keyboard for initial setup (then headless).

---

## What you get

### From privcloud (the CLI)

| Command | What it does |
|---------|-------------|
| `install` | Installs Docker, Docker Compose, pulls images, configures storage |
| `start` | Starts the photo server |
| `stop` | Stops everything (photos stay on disk) |
| `status` | Shows diagnostics — containers, health, recent errors |
| `config` | Change where photos are stored |
| `update` | Check for updates and apply |
| `upload` | Bulk upload photos via Immich CLI with API key validation |
| `fix-gp` | Fix Google Photos Takeout metadata (dates + GPS) |
| `backup` | Backup photos + database to external drive with progress |

### From federver (server setup)

```
========================================
  Federver — Fedora XFCE Server Manager
========================================

  -- Initial setup (run once, in order) --
  1)  Enable SSH + auto-login + hostname    ← with monitor
  2)  SSH key auth                          ← from laptop, exit SSH first
  3)  System update
  4)  Enable auto-updates
  5)  Install Docker                        ← log out & SSH back in after

  -- Services --
  6)  Configure firewall
  7)  Deploy services                       ← Immich, Jellyfin, FileBrowser, Watchtower, Uptime Kuma
  8)  Setup backups + disk monitoring
  9)  Configure log rotation

  -- Extras (optional, run anytime) --
  10) Install Tailscale                     ← remote access VPN
  11) Install WireGuard                     ← full VPN, route all traffic
  12) Mount USB drive                       ← plug in drive first
  13) Remote desktop                        ← access XFCE desktop via RDP

  -- Immich photo management --
      Run: privcloud [start|stop|status|update|backup]

  -- Tools (from laptop, exit SSH first) --
  14) Sync files                          ← copy/backup files between laptop & server

  s)  Status        p)  Power        a)  Run all (3-9)        0)  Exit
```

### From Immich (the photo server)

- **Face recognition** — automatically detects and groups faces across your entire library
- **Smart search** — search by content: "beach", "birthday cake", "dog in snow"
- **Map view** — see where every photo was taken on a world map
- **Timeline** — scroll through your entire library by date
- **Albums** — create and organize manually, or let Immich auto-create by date/location
- **Duplicate detection** — finds and flags duplicate photos for cleanup
- **Favorites and archive** — star the best, hide the rest without deleting
- **Sharing** — share albums with family via links
- **EXIF metadata** — preserved and indexed (dates, GPS, camera model, lens, etc.)
- **Video support** — full video playback, thumbnails, and timeline integration
- **Trash bin** — deleted photos are recoverable for 30 days
- **Multi-user** — create accounts for family members, each with their own library
- **Mobile apps** — official iPhone and Android apps with auto-backup

---

## Getting started (Immich only)

### Requirements

- **Linux, macOS, or WSL** — any modern version
- **~4 GB RAM** when running (can be less after initial ML indexing)
- **Storage** — local drive, external HDD, NAS, whatever you have

### Install and start

```bash
# One-liner install
curl -fsSL https://raw.githubusercontent.com/hamr0/privcloud/main/scripts/install.sh | bash && privcloud

# Or clone
git clone https://github.com/hamr0/privcloud.git
cd privcloud
privcloud
```

Pick `install` (handles Docker, images, storage config), then `start`.

Open http://localhost:2283 in your browser. Create your first account — this becomes the admin.

## Connecting your phone

1. Install the Immich app — [iPhone](https://apps.apple.com/app/immich/id1613945652) / [Android](https://play.google.com/store/apps/details?id=app.alextran.immich)
2. Server URL: `http://<your-computer-ip>:2283` (shown when you run `privcloud start`)
3. Login with the account you created in the web UI
4. Go to app settings and enable **auto backup**
5. Both devices must be on the same WiFi network

From now on, every photo you take syncs to your machine whenever the Immich app is open. No cloud involved.

### Auto-backup tips

- **Background backup** works on Android. On iPhone, it syncs when the app is open (iOS limitation).
- **Foreground backup** — open the app occasionally to trigger a sync.
- **Selective backup** — choose which albums to backup in the app settings. You can exclude screenshots, downloads, etc.

---

## Understanding the phone app

The Immich app is a **viewer and uploader**, not a two-way sync. This is the most important thing to understand.

### How it works

| Direction | What happens |
|-----------|-------------|
| **Phone → Server** | Auto-backup uploads your phone photos to the server |
| **Server → Phone** | The app **shows** server photos when you browse, but does NOT download them to your Camera Roll |

Photos you uploaded from Google Takeout or an old hard drive will appear in the app when you scroll the timeline — they stream over WiFi, like browsing Google Photos. But they don't take up phone storage.

If you want to save a specific photo back to your phone, tap the photo → share → **Save to Device**. This is a one-off action, not bulk.

### Cloud icons in the app

| Icon | Meaning |
|------|---------|
| Cloud with checkmark | Photo is on the server AND on your phone (backed up from Camera Roll) |
| Cloud without checkmark | Photo is on the server only (uploaded via CLI or from another device) |
| Cloud with no thumbnail | Photo is on the server but the thumbnail hasn't been generated yet |

After a big import, you'll see many photos with no thumbnail. This is normal — Immich generates thumbnails in the background. Check progress at Administration → Jobs → Generate Thumbnails.

---

## Multiple accounts and family setup

Each Immich account gets its own separate library, timeline, face recognition, and storage. Accounts cannot be merged after creation.

### Recommended setup for families

| Account | What goes in it |
|---------|----------------|
| **You** | Your personal photos |
| **Partner** | Their personal photos |
| **Family** | Shared family photos (kids, trips, events) |

### How to set it up

1. Create all accounts in the web UI (the first account is admin)
2. Each person installs the Immich app and logs into their own account
3. Auto-backup sends each person's phone photos to their own library

### Sharing between accounts

- **Shared albums** — create an album, share it with other accounts
- **Partner sharing** — Account Settings → Partner Sharing. Gives another user read-only access to your entire timeline.

### Uploading to the right account

Each API key is tied to the account that created it. When using `privcloud upload`, use the API key for whichever account should own the photos.

---

## Migrating from Google Photos

Google Takeout exports your photos with metadata stripped into separate JSON files. The filenames are truncated and inconsistent. privcloud's `fix-gp` command handles all of it.

### Step 1: Export from Google

1. Go to [Google Takeout](https://takeout.google.com)
2. Deselect everything, then select only **Google Photos**
3. Choose your export format (zip) and size (largest available)
4. Google will email you download links. Download all the zip files into one folder.

### Step 2: Fix metadata

```bash
privcloud fix-gp
```

The script extracts zips, matches each photo to its JSON sidecar, writes dates and GPS back into EXIF, and sets correct file timestamps.

### Step 3: Upload

```bash
privcloud upload
```

Enter your API key (from http://localhost:2283 → Account Settings → API Keys) and the path to the extracted photos.

### What gets fixed

| File type | EXIF dates | GPS | File timestamp |
|-----------|-----------|-----|----------------|
| JPEG/JPG | Written | Written | Set |
| HEIC/HEIF | — | — | Set |
| MOV/MP4 | — | — | Set |
| PNG/GIF | — | — | Set |

HEIC and video files don't support EXIF writing via piexif, but their file modification times are corrected. Immich uses file timestamps when EXIF is missing, so your timeline will be correct.

---

## Migrating from iCloud

### Option A: iPhone app (easiest)

If your photos are still on your iPhone (not "Optimize Storage"):
1. Connect to the same WiFi as your server
2. Open the Immich app, enable auto-backup
3. Let it sync

### Option B: iCloud download + upload

1. Go to [icloud.com/photos](https://icloud.com/photos)
2. Select all, download
3. Use `privcloud upload` to bulk upload

### Option C: Mac/Windows export

1. On Mac: Photos app → Select All → File → Export Unmodified Originals
2. On Windows: iCloud for Windows syncs to a local folder

---

## Uploading existing photo collections

```bash
privcloud upload
```

Point it at any folder. It uploads recursively and skips duplicates automatically (by file hash). Run it from multiple sources — Immich won't create duplicate entries.

---

## When is it safe to delete from your phone?

**After you verify the photo is on the server.**

| Scenario | Safe? |
|----------|-------|
| Photo shows green checkmark in Immich app | Yes |
| Immich app says "All backed up" | Yes |
| You haven't opened the Immich app recently | **No** |
| You're not on WiFi | **No** |

### Recommended approach

Let auto-backup run for a week or two, verify your timeline in the web UI, then delete in bulk.

---

## Organizing your photos

- **Timeline** — all photos sorted by date, newest first. Builds automatically.
- **Albums** — create manually or let Immich auto-create by date/location.
- **Favorites** — star photos for quick access.
- **Archive** — hide from timeline but keep in search/albums.
- **Trash** — recoverable for 30 days.

---

## Finding photos

- **Smart search** — type "beach sunset", "birthday cake", "dog" etc. ML-powered, runs locally.
- **By date** — click month/year in timeline
- **By person** — click a face in People
- **By location** — Map view
- **By camera** — filter by camera model

---

## Face recognition

Immich scans every photo for faces locally using the ML container.

1. After upload, faces are detected and grouped by similarity
2. You name each person once — Immich tags all matching faces
3. New photos of that person are tagged going forward

**Tips:** merge duplicate groups, hide non-person faces (paintings, TV screens).

---

## Duplicates

Immich detects duplicates by file hash. Go to Duplicates in the sidebar, review groups, keep the best version.

---

## Sharing

- **Shared albums** — share with other Immich users
- **Shared links** — shareable URL with optional expiry and password, no account needed
- **Multi-user** — each family member gets their own library

---

## Background jobs and processing

After uploading, Immich processes photos in the background:

| Job | What | Timeline |
|-----|------|----------|
| Generate Thumbnails | Preview images | Minutes — photos appear as these complete |
| Extract Metadata | EXIF data | Fast |
| Smart Search | ML content indexing | Hours for large imports |
| Face Detection + Recognition | Find and group faces | Hours (~1-2 sec per photo) |
| Video Transcoding | Convert HEVC to H.264 | Depends on video count |

Check progress at Administration → Jobs. All jobs resume where they left off after restart.

---

## Video playback issues

iPhone videos (HEVC/H.265) may not play in browsers on Linux. Fix: Administration → Video Transcoding → enable, set codec to H.264. Transcoded copies are stored separately from originals.

---

## Storage and architecture

### What's stored where

| .env variable | Contents | Used by |
|---------------|---------|---------|
| `FILES_LOCATION` | Base data directory (everything below) | FileBrowser root |
| `MEDIA_LOCATION` | Movies, music, TV shows | Jellyfin + FileBrowser |
| `UPLOAD_LOCATION` | Original photos, thumbnails, encoded videos | Immich |
| `DB_DATA_LOCATION` | PostgreSQL database (faces, search, albums, accounts) | Immich |

### Default layout

```
data/                    <- FILES_LOCATION (FileBrowser root)
├── media/               <- MEDIA_LOCATION (Jellyfin + FileBrowser)
│   ├── movies/
│   ├── shows/
│   └── music/
├── files/               <- your private files (FileBrowser only)
└── immich/              <- UPLOAD_LOCATION + DB (Immich only, leave alone)
    ├── upload/
    └── postgres/
```

### How FileBrowser and Jellyfin share media

- **FileBrowser** mounts `FILES_LOCATION` as `/srv` — sees everything (media, files, immich)
- **Jellyfin** mounts `MEDIA_LOCATION` as `/media` — sees media only

Upload a movie via FileBrowser into `media/movies/`, it appears in Jellyfin immediately.

**Adding a library in Jellyfin:**
1. Dashboard > Libraries > Add Media Library
2. Content type: Movies (or Music, Shows, etc.)
3. Click the **+** next to "Folders"
4. Navigate to `/media` (or a subfolder like `/media/movies`)
5. Click OK

**Recommended folder structure** (create in FileBrowser):
```
media/
├── movies/
├── shows/
└── music/
```

Then add one Jellyfin library per folder (`/media/movies`, `/media/shows`, etc.).

### Storage growth

Expect ~20-30% overhead on top of your original library for thumbnails and previews.

### Docker containers (Immich only)

| Container | Purpose | RAM |
|-----------|---------|-----|
| `immich_server` | Web UI, API | ~500 MB |
| `immich_machine_learning` | Faces, search | ~1-2 GB |
| `immich_redis` | Job queue | ~50 MB |
| `immich_postgres` | Database | ~200-500 MB |

---

## Backup and restore

### What to backup

**Both directories.** Photos without the database = unsorted files. Database without photos = empty references.

### How to backup

```bash
privcloud backup
```

Stops server, copies photos + database + config to destination, restarts. Incremental after first run.

### How often

- After big imports
- Monthly if actively taking photos
- Before OS upgrades

---

## Moving to a new machine

1. `privcloud stop` on old machine
2. Copy `photos` and `postgres` directories to new machine
3. Clone privcloud, run `privcloud install`
4. Point config at the copied directories, make sure `DB_PASSWORD` matches
5. `privcloud start`

Everything comes back — faces, albums, search, sharing.

---

## Day-to-day usage (Immich only)

1. Take photos normally
2. Open Immich app occasionally — photos sync over WiFi
3. Browse/organize at http://localhost:2283
4. `privcloud stop` when done (or leave running)

ML processing resumes where it left off on next start.

---

## Troubleshooting (Immich)

### "privcloud start" hangs or times out

Run `privcloud status` — it now shows container health and recent errors from logs. Common causes:
- Port 2283 in use
- Not enough RAM
- Docker not running

### Password authentication failed

If you see `password authentication failed for user "postgres"` in logs, the `.env` password doesn't match what the database was initialized with. Find the original password (check old `.env` files or backups) and update `.env` to match. You **cannot** change the database password by just editing `.env` — the password is baked into the Postgres data directory when first created.

### Photos not showing up

Check Administration → Jobs → Generate Thumbnails. Photos appear in the timeline only after thumbnails are generated.

### Face recognition not working

Check Administration → Jobs → Face Detection. Large imports take hours to process.

### Videos won't play

Enable transcoding: Administration → Video Transcoding → H.264.

### Wrong dates

Run `privcloud fix-gp` on Google Takeout exports before uploading. For other sources, check if files have EXIF data.

### Container keeps restarting

Run `docker logs <container_name> --tail 20` to see the error. Common causes:
- Wrong password (postgres)
- Disk full
- Docker API version mismatch (Watchtower — set `DOCKER_API_VERSION=1.40`)

---

## Privacy and security

### What stays local

- All photos — on your drive, never uploaded
- Face recognition — ML runs locally
- Smart search — CLIP model runs locally
- Database — PostgreSQL on your machine

### What goes over the network

- Phone ↔ server: photos sync over local WiFi
- Docker image pulls during install/update
- Nothing else — no telemetry, no analytics

---

# Home server setup

Everything below is for the **full server** mode using `federver`.

---

## Hardware selection

### Minimum specs

- **CPU:** Intel i3 6th gen+ or i5 4th gen+ (need 4+ threads for Immich ML)
- **RAM:** 8GB minimum, 16GB recommended (Immich ML + Jellyfin transcoding)
- **Storage:** 128GB+ for OS + Docker, external drive for data
- **Form factor:** Mini PC / USFF ideal (low power, quiet, small)

### Recommended

HP ProDesk 400 G4 DM or similar refurbished mini PC. Available on Refurbed/eBay for ~€100-120. These are enterprise-grade, quiet, low power (~35W), and have USB 3.0 for external drives.

### RAM upgrade

The G4 DM has 2 SO-DIMM slots. Get **2x8GB** (dual channel) rather than 1x16GB — dual channel gives ~20% better memory bandwidth. DDR4 2666MHz is backward compatible with 2400MHz motherboards — it just runs at the lower speed.

### External storage

Use a 2.5" SATA drive in a USB 3.0 enclosure (Orico, ~€10). Format as ext4 (not NTFS — causes permission issues with Docker). USB 3.0 is plenty fast for photo serving and media streaming.

### Intel processor naming

- `i3-8100T` = 8th gen i3, T suffix = low power
- `i5-6500` = 6th gen i5, no suffix = standard
- Generation is the first digit(s) after the dash

---

## Server setup walkthrough

### Before you start

- USB stick (8GB+) for Fedora installer
- Ethernet cable (more reliable than WiFi for server)
- Monitor + keyboard (only for initial setup)
- Download Fedora XFCE Spin (x86_64 ISO)

### Flash and install

```bash
# From your laptop — flash ISO to USB
sudo dd if=Fedora-Xfce-Live-43.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot from USB (F9 on HP for boot menu), install Fedora. Use automatic partitioning — the entire internal drive is for the OS. Data goes on the external USB drive.

### Run setup

```bash
git clone https://github.com/hamr0/privcloud.git
cd privcloud
federver
```

**Step 1 (with monitor):** Pick option 1. Enables SSH, sets hostname, auto-login. Note the IP. Unplug the monitor.

**Step 2 (from laptop, not SSH):** Run `federver` → 2. Copies SSH key, disables password login. Back up the key in `pass`.

**Steps 3-11 (over SSH):** SSH into the server, run `federver`, go through each step:

- **3-4:** System update + auto-updates
- **5:** Docker — **log out and SSH back in after this** (docker group)
- **6:** Firewall — opens service ports locally, trusts Tailscale
- **7:** Tailscale — create account at login.tailscale.com first, then approve the server. Install Tailscale on phone/laptop with same account.
- **8:** Mount USB drive — plug in first, pick the partition (ignore nvme)
- **9:** Deploy — asks for base data path, starts all services. Shows setup instructions for each service.
- **10:** Backups — daily Immich DB dump at 3am
- **11:** Log rotation — limits Docker logs to 10MB per container

### BIOS setup

After setup, enter BIOS (F10 on HP) and set **After Power Loss → Power On**. Now the server auto-starts after power outage.

---

## Service setup

After step 9, configure each service in your browser. Run `federver` → **s** for URLs.

### Immich (port 2283)

1. Open in browser, create admin account
2. Install Immich app on phone:
   - **iPhone:** [App Store](https://apps.apple.com/app/immich/id1613945652)
   - **Android:** [Play Store](https://play.google.com/store/apps/details?id=app.alextran.immich)
3. In the app: enter server URL (`http://<server-ip>:2283`), log in, enable auto-upload
4. If migrating: use `privcloud upload` or `privcloud fix-gp` for Google Takeout

### Jellyfin (port 8096)

1. Open in browser, create admin account via setup wizard
2. Add media libraries pointing to `/media`
3. Install Jellyfin app:
   - **iPhone:** [App Store](https://apps.apple.com/app/jellyfin-mobile/id1480732557)
   - **Android:** [Play Store](https://play.google.com/store/apps/details?id=org.jellyfin.mobile)
   - **Smart TV:** search "Jellyfin" in your TV's app store
   - **Laptop:** open `http://<server-ip>:8096` in browser (no install needed)
4. Media files go in the data path's `media/` directory

### FileBrowser (port 8080)

1. Login: **admin** / **privcloud** (set automatically during deploy)
2. Change the password if you want (Settings → Profile)
3. You'll see:
   - `media/` — movies, music, shows (also visible to Jellyfin)
   - `files/` — your private files, docs (create this folder)
   - `immich/` — photo backup data (leave alone, managed by Immich)

### Uptime Kuma (port 3001)

1. Open Uptime Kuma in your browser (port 3001)
2. Create admin account
3. Click **"Add New Monitor"** for each service:

| Name | Type | URL |
|------|------|-----|
| Immich | HTTP(s) | `http://<server-local-ip>:2283/api/server/ping` |
| Jellyfin | HTTP(s) | `http://<server-local-ip>:8096` |
| FileBrowser | HTTP(s) | `http://<server-local-ip>:8080` |

**Important:** Use the server's local IP (e.g. `192.168.178.180`), not `localhost`. Uptime Kuma runs inside Docker where `localhost` refers to the container itself, not the server.

4. Optional: go to **Settings → Notifications** to add alerts:
   - **Telegram:** create a bot via @BotFather, get the token and chat ID
   - **Email:** enter SMTP settings for your email provider
   - You'll get notified instantly if any service goes down

---

## Tailscale remote access

Tailscale creates a private encrypted network between your devices. No port forwarding, no dynamic DNS.

### How it works

```
Your phone ──── Tailscale network ──── Your server
Your laptop ───┘                       (at home)
```

Every device with Tailscale installed and logged into the same account gets a private IP (100.x.x.x). These work from anywhere — coffee shop, office, mobile data.

### Setup

1. Create free account at [login.tailscale.com](https://login.tailscale.com)
2. Server: `federver` → **10** (handles installation and authentication)
3. Install on your other devices:

**Laptop (Fedora):**
```bash
sudo dnf install tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
# If DNS issues: sudo tailscale up --accept-dns=false
```

**iPhone/Android:** Install "Tailscale" from App Store / Play Store, log in with same account.

**Mac:** Download from [tailscale.com/download](https://tailscale.com/download).

### Access from anywhere

Use the Tailscale IP instead of the local IP:

```
http://<tailscale-ip>:2283   Immich
http://<tailscale-ip>:8096   Jellyfin
http://<tailscale-ip>:8080   FileBrowser
http://<tailscale-ip>:3001   Uptime Kuma
ssh ahassan@<tailscale-ip>   SSH
```

Free for up to 100 devices.

### Family / multi-device access

Each device that needs remote access needs Tailscale installed and logged into the **same account**. For family members:

1. They download Tailscale on their phone
2. Log in with your Tailscale account
3. They can now access all services via the Tailscale IP

Tailscale only routes traffic to your server — it does NOT route all their internet through a VPN. Normal browsing, apps, everything else goes through their regular connection.

---

## WireGuard VPN

WireGuard routes ALL your device traffic through the server. Unlike Tailscale (which only lets you access the server), WireGuard makes your phone/laptop appear to be on your home network from anywhere.

### Tailscale vs WireGuard

| | Tailscale | WireGuard |
|--|-----------|-----------|
| **Purpose** | Access your server remotely | Route all traffic through server |
| **Setup** | Easy (managed service) | Step 11 handles everything |
| **Privacy** | Only server traffic | All internet traffic encrypted |
| **Geo-restrictions** | No help | Bypass (appear to be at home) |
| **Public WiFi** | Server access only | Full protection |
| **Can coexist** | Yes | Yes |

### Setup

Run `federver` → **11**. The script:

1. Installs WireGuard and generates server keys
2. Asks how many devices (phone, laptop, etc.)
3. Generates a config + QR code for each device
4. Configures firewall and IP forwarding

### Connecting devices

**Laptop (Linux):**
1. Get `fedvpn` from the server: `scp <user>@<server-ip>:~/privcloud/fedvpn /tmp/fedvpn && sudo cp /tmp/fedvpn /usr/local/bin/fedvpn && sudo chmod +x /usr/local/bin/fedvpn`
2. Get config: `federver` → **11** → **2** (show peer config) on server, copy it
3. Run `fedvpn` → **1** (setup) → paste config → Ctrl+D
4. Connect: `fedvpn` → **2** or `fedvpn start`
5. Disconnect: `fedvpn` → **3** or `fedvpn stop`

**iPhone/Android:** Install "WireGuard" from App Store / Play Store. Get QR from `federver` → **11** → **2** on server.

**Mac:** Install WireGuard (`brew install wireguard-tools` or App Store). Get config from `federver` → **11** → **2**, save to file, import.

### Managing peers

Run `federver` → **11** again. It detects WireGuard is already installed and offers:

1. **Add new peer** — generates keys, shows device-specific instructions (phone QR, Linux/Mac config)
2. **Show peer config** — retrieve an existing peer's config (to set up a new device or re-paste)
3. **Reinstall** — regenerates all keys (existing peers stop working)

Configs saved in `/etc/wireguard/`. Check status: `sudo wg show`

### fedvpn — laptop VPN client

`fedvpn` is a CLI tool that runs on your laptop to manage the WireGuard connection:

```
fedvpn           # interactive menu
fedvpn start     # connect
fedvpn stop      # disconnect
fedvpn status    # show connection info
```

**First-time setup:** `fedvpn` → 1 (setup) — installs WireGuard, asks you to paste the config from the server.

**How it works:** disables IPv6 on connect (prevents traffic leaking outside the tunnel), re-enables on disconnect.

**Install fedvpn on laptop:** copy from server with `scp <user>@<server-ip>:~/privcloud/fedvpn /tmp/fedvpn && sudo cp /tmp/fedvpn /usr/local/bin/fedvpn && sudo chmod +x /usr/local/bin/fedvpn`

### Important notes

- **WireGuard uses local IP as endpoint** — it only works on your home network by default. For remote WireGuard, set up port forwarding on your router (port 51820/udp → server IP).
- **Tailscale and WireGuard serve different purposes** — Tailscale for accessing the server from anywhere, WireGuard for routing all traffic through the server (privacy, public WiFi).
- **Don't use both simultaneously** — Tailscale IP as WireGuard endpoint creates routing loops.

---

## Remote desktop

Access the full XFCE desktop from any device. Step 10 in `federver` installs xrdp.

### How it works

xrdp replaces the local display (lightdm) since the server is headless. The desktop is only accessible remotely via RDP protocol.

### Connecting

**From Linux (Fedora):**
```
sudo dnf install remmina
```
Open Remmina → New → Protocol: RDP → Server: `<server-ip>` → Username + Password.

**From Mac:**
Install "Microsoft Remote Desktop" from App Store. Add PC with server IP.

**From iPhone/iPad:**
Install "RD Client" from App Store. Add PC with Tailscale IP.

### Troubleshooting

- **Session opens then closes:** lightdm is still running. Run `sudo systemctl disable --now lightdm` on the server.
- **Black screen:** XFCE session packages may be missing. Run `sudo dnf install xfce4-session xfwm4 xfce4-panel xfdesktop`.
- **Can't connect:** check firewall port 3389 is open: `sudo firewall-cmd --list-ports`.

---

## Save to pass

Option **15** in `federver` backs up everything to the `pass` password manager. Run from your **laptop** (where pass is installed) — it SSHes into the server to fetch data.

```bash
federver    # pick 15
```

Saves:

```
privcloud/
├── server/
│   ├── hostname              # Server hostname
│   ├── local_ip              # Local network IP
│   ├── tailscale_ip          # Tailscale IP (if installed)
│   └── user                  # SSH username
├── ssh/
│   ├── private_key           # SSH private key (from laptop)
│   └── public_key            # SSH public key
├── services/
│   └── urls                  # All service URLs (local + Tailscale)
├── config/
│   ├── env                   # .env file (DB password, data paths)
│   └── docker_compose        # docker-compose.yml
└── wireguard/
    ├── server_conf           # Server wg0.conf
    └── peers/
        ├── phone             # Phone peer config
        └── laptop            # Laptop peer config
```

All entries are overwritten on each save. To view:

```bash
pass show privcloud/                       # list everything
pass show privcloud/services/urls          # all service URLs
pass show privcloud/config/env             # .env (DB password, paths)
pass show privcloud/ssh/private_key        # SSH key
```

---

## Server maintenance

### Daily (automated)

- **Hourly** — Disk space check (alerts if any mount exceeds 85%)
- **3:00am** — Immich database backup (cron)
- **4:00am** — Watchtower checks for container updates

### Monitoring

| What | How | Where |
|------|-----|-------|
| Service health | Uptime Kuma monitors | `http://<server-ip>:3001` |
| Server online | Ping monitor in Uptime Kuma | Type: Ping → server IP |
| Disk space | Hourly cron + Kuma Push | `cat /var/log/disk-check.log` or Uptime Kuma dashboard |
| Backup status | Check log | `cat /var/log/immich-backup.log` |
| Container errors | `privcloud status` | Shows recent errors per container |

**Uptime Kuma monitors to add:**

| Name | Type | URL/Host |
|------|------|----------|
| Immich | HTTP(s) | `http://<server-ip>:2283/api/server/ping` |
| Jellyfin | HTTP(s) | `http://<server-ip>:8096` |
| FileBrowser | HTTP(s) | `http://<server-ip>:8080` |
| Server | Ping | `<server-ip>` |

Use the server's local IP, not `localhost` (Uptime Kuma runs in Docker).

**Disk space alert:** Step 11 in `federver` sets this up automatically. It asks you to create a Push monitor in Uptime Kuma, you paste the URL, and it configures a script that sends `status=up` every hour when disk is OK, or `status=down` when any mount exceeds 85%. Uptime Kuma then alerts you via Telegram/email if configured.

### Periodic (manual)

| Task | Command | When |
|------|---------|------|
| Check status | `federver` → **s** | Anytime |
| Update Immich | `privcloud update` | Monthly |
| Update other containers | `docker compose pull && docker compose up -d` | Monthly |
| Update Fedora | `sudo dnf upgrade` | Monthly |
| Check disk space | `df -h` | Monthly |
| Check disk alerts | `cat /var/log/disk-check.log` | After alerts |
| Check backup logs | `cat /var/log/immich-backup.log` | After issues |
| Sync files | `federver` → **13** (from laptop) | As needed |

### SSH access

```bash
# From home
ssh ahassan@<hostname>

# From anywhere (via Tailscale)
ssh ahassan@<tailscale-ip>
```

---

## Server troubleshooting

### Can't SSH into server

- **From home:** check the server is on, check IP with `hostname -I` (need monitor temporarily)
- **From away:** make sure Tailscale is running on both devices
- **"Permission denied":** your SSH key might not be on the server. Need monitor + keyboard to fix.
- **Lost SSH key:** plug in monitor, log in locally, re-enable password auth or add new key

### Container keeps restarting

```bash
docker logs <container_name> --tail 20
```

Common causes:
- **Watchtower:** `client version too old` → set `DOCKER_API_VERSION=1.40` in docker-compose.yml
- **Immich postgres:** `password authentication failed` → `.env` password doesn't match database. Find the original password and update `.env`.
- **Any container:** `no space left on device` → disk full, clean up with `docker system prune`

### Immich 500 error / "Permission denied" on postgres

If Immich shows a 500 error and logs say `could not open file ... Permission denied`, the postgres data directory has wrong ownership. This happens if you run `chown` on the entire data directory.

**Fix:**
```bash
docker compose stop database
sudo chown -R 999:999 ~/data/immich/postgres
docker compose start database
docker restart immich_server
```

**Never run `chown` on the postgres directory.** Postgres uses its own internal user (999). Only chown the upload directory:
```bash
sudo chown -R ahassan:ahassan ~/data/immich/upload   # safe
# sudo chown -R ahassan:ahassan ~/data/immich/        # BREAKS POSTGRES
```

### Immich "Taking longer than expected"

Immich's health check has a 60-second timeout. On first start or after updates, it may take longer. Check:

```bash
curl -s http://localhost:2283/api/server/ping
docker logs immich_server --tail 10
```

If it returns `{"res":"pong"}`, it's fine — the timeout was just too short.

### Display not working on mini PC

- Reseat the DisplayPort cable firmly (DP connectors have a latch)
- Try both DP ports
- Select the correct input on the monitor (not auto-detect)
- Try a different cable
- If refurbished: may be DOA, check return policy

### USB drive not detected or I/O errors

- Try a different USB port (back ports are USB 3.0)
- Check cable/enclosure — flaky adapters cause `Remote I/O error`
- Format to ext4 (not NTFS): `sudo mkfs.ext4 -L data /dev/sda1`
- If the old enclosure is dying, get a new SATA-to-USB 3.0 enclosure (~€10)

### After power outage

If BIOS is set to auto-power-on (F10 → After Power Loss → Power On), the server boots automatically. Fedora auto-logs in, Docker restarts all containers. Nothing to do.

If services aren't running: `cd ~/privcloud && docker compose up -d && privcloud start`

---

## Managing storage

`federver` → **12** opens the storage sub-menu:

```
1) Status                     <- drives, mounts, paths
2) Mount USB drive
3) Unmount USB drive
4) Change media location      <- Jellyfin + FileBrowser
5) Change data location       <- Immich photos + database
0) Cancel
```

### Mounting a USB drive

1. Plug in the USB drive
2. `federver` → **12** → **2**
3. Select the USB partition (auto-detected, internal drives filtered out)
4. Choose mount point (default: `/mnt/data`)

The drive is added to `/etc/fstab` so it auto-mounts on reboot.

### Changing media location

If you want to move media to a USB drive:

1. Mount the USB: `federver` → **12** → **2**
2. Move files: `rsync -avh --progress /old/media/path/ /mnt/data/media/`
3. Change location: `federver` → **12** → **4** → enter `/mnt/data/media`

This updates `.env` and redeploys Jellyfin + FileBrowser automatically.

### Changing Immich data location

1. Stop Immich: `privcloud stop`
2. Move files: `rsync -avh --progress /old/immich/ /mnt/data/immich/`
3. Change location: `federver` → **12** → **5** → enter `/mnt/data/immich`
4. Verify: `privcloud status`

**Important:** the Postgres database password is baked in when first created. If you copy the database directory, keep the same `DB_PASSWORD` in `.env`. Changing it will cause `password authentication failed`.

### Unmounting a USB drive

1. Stop services using the drive first
2. `federver` → **12** → **3**
3. Select the USB to unmount
4. Safe to unplug after confirmation
