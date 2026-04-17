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
- [AdGuard Home DNS ad blocker](#adguard-home-dns-ad-blocker)
- [Syncthing real-time folder sync](#syncthing-real-time-folder-sync)
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

Dedicated always-on machine running Immich + music streaming + file management + monitoring + remote access. `federver` handles everything from a fresh Fedora install.

**Good for:** 24/7 photo backup, streaming music to phone, accessing files from anywhere, replacing Google Drive/iCloud.
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
  Running from: server
========================================

  -- Initial setup (run once, in order) --
  1)  Enable SSH + auto-login + hostname    ← with monitor
  2)  SSH key auth                          ← from laptop, exit SSH first
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
  16) Manage sync                          ← transfer, schedule, cron jobs
  17) Save to pass                        ← from laptop, backup everything to pass

  s)  Status   i)  Immich   p)  Power   r)  Reset password   a)  Run all (3-9)   0)  Exit
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
| `FILES_LOCATION` | Base data directory | FileBrowser root |
| `MEDIA_LOCATION` | Videos, files (FileBrowser) | FileBrowser |
| `MUSIC_LOCATION` | Music library | Navidrome |
| `UPLOAD_LOCATION` | Original photos, thumbnails, encoded videos | Immich |
| `DB_DATA_LOCATION` | PostgreSQL database (faces, search, albums, accounts) | Immich |

### Default layout

```
data/                    <- FILES_LOCATION (FileBrowser root)
├── media/               <- MEDIA_LOCATION (FileBrowser)
│   ├── My Music/        <- MUSIC_LOCATION (Navidrome)
│   ├── movies/
│   └── shows/
├── files/               <- your private files (FileBrowser only)
└── immich/              <- UPLOAD_LOCATION + DB (Immich only, leave alone)
    ├── upload/
    └── postgres/
```

### How FileBrowser and Navidrome share media

- **FileBrowser** mounts `FILES_LOCATION` as `/srv` — sees everything (media, files, immich)
- **Navidrome** mounts `MUSIC_LOCATION` as `/music` — sees your music library only

Upload music via FileBrowser into `media/My Music/`, it appears in Navidrome automatically.

Videos are not streamed via a dedicated service. Download them from FileBrowser and play in VLC.

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
- **RAM:** 8GB minimum, 16GB recommended (Immich ML)
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

**Step 2 and everything after:** Always run `federver` from **your laptop**. Clone privcloud on the laptop too (`git clone https://github.com/hamr0/privcloud.git`). Run `federver` → 2 first (copies SSH key, disables password login). Back up the key in `pass`. After that, every step runs from the laptop — server commands auto-SSH to the server, laptop commands run locally. Both machines need the repo.

If you run `federver` on the server by mistake, it shows a reduced menu with only step 1 (bootstrap), Status, Power, and Emergency restart — and a note to run from the laptop for the full menu. No errors, just a redirect.

**Emergency restart (`e` on the server menu):** if DNS breaks because AdGuard stopped (you can't SSH from the laptop because domain names don't resolve), walk to the server, open a terminal, run `federver`, pick `e`. It restores systemd-resolved as a DNS fallback, starts all containers (compose stack + standalone AdGuard/Syncthing), and re-disables the stub once AdGuard is back. One action, everything recovers. Confirms with `[Y/n]` before proceeding.

**Steps 3-9 + Extras:** Go through each step:

- **3-4:** System update + auto-updates (userspace security only — kernel is excluded so the server never auto-reboots into an untested kernel while you're away; update kernels manually with `sudo dnf upgrade kernel` + reboot when you're home)
- **5:** Docker — **log out and SSH back in after this** (docker group)
- **6:** Manage firewall → 4 (Apply defaults) — opens service ports locally, trusts Tailscale
- **7:** Manage services → 6 (Deploy / redeploy) — asks for base data path, starts all services. Shows setup instructions for each service.
- **8:** Backups — daily Immich DB dump at 3am
- **9:** Log rotation — limits Docker logs to 10MB per container
- **10:** Manage Tailscale → install — create account at login.tailscale.com first, then approve the server. Install Tailscale on phone/laptop with same account.
- **13:** Manage storage → 2 (Mount USB drive) — plug in first, pick the partition (ignore nvme). Or skip: data lives on the internal drive.

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

### Navidrome (port 4533)

1. Open `http://<server-ip>:4533` in browser, create admin account
2. Music is automatically scanned from the `MUSIC_LOCATION` folder
3. Install **Amperfy** on iPhone (free, App Store) for mobile playback:
   - Supports background playback and offline caching via Subsonic API
   - Server URL: `http://<server-ip>:4533`
   - Log in with your Navidrome credentials
4. Upload music via FileBrowser into `media/My Music/` — Navidrome picks it up automatically

### FileBrowser (port 8080)

1. Login: user `admin`. The password is randomly generated during deploy and saved to `~/.privcloud/filebrowser.pass` on the server. Retrieve it with `cat ~/.privcloud/filebrowser.pass`. It's also printed once at the end of step 7 (Deploy services).
2. Change the password if you want (Settings → Profile) — then you can delete `~/.privcloud/filebrowser.pass`
3. You'll see:
   - `media/` — videos, music, files (music also visible to Navidrome)
   - `files/` — your private files, docs (create this folder)
   - `immich/` — photo backup data (leave alone, managed by Immich)

### Uptime Kuma (port 3001)

1. Open Uptime Kuma in your browser (port 3001)
2. Create admin account
3. Click **"Add New Monitor"** for each service:

| Name | Type | URL |
|------|------|-----|
| Immich | HTTP(s) | `http://<server-local-ip>:2283/api/server/ping` |
| Navidrome | HTTP(s) | `http://<server-local-ip>:4533` |
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
2. Run `federver` → **10** from your laptop. The step installs and authenticates *both sides* in one shot:
   - **Laptop:** `sudo dnf install tailscale` + `systemctl enable --now tailscaled` + `sudo tailscale up` (prints an auth URL — click, approve)
   - **Server:** SSHes in and does the same flow for the server, printing the server's auth URL too
3. For phones / Mac / Windows (can't automate), install manually:
   - **iPhone/Android:** "Tailscale" from App Store / Play Store, log in with same account
   - **Mac:** [tailscale.com/download](https://tailscale.com/download)
   - **Windows:** [tailscale.com/download](https://tailscale.com/download)

### Access from anywhere

MagicDNS is enabled by default — use `federver` as the hostname instead of an IP:

```
http://federver:2283   Immich
http://federver:4533   Navidrome
http://federver:8080   FileBrowser
http://federver:3001   Uptime Kuma
ssh ahassan@federver   SSH
```

Works from any device with Tailscale installed and logged into the same account. If `federver` doesn't resolve, use the Tailscale IP (`100.x.x.x`) from the Machines tab at [login.tailscale.com](https://login.tailscale.com).

Free for up to 100 devices.

### Family / multi-device access

Each device that needs remote access needs Tailscale installed and logged into the **same account**. For family members:

1. They download Tailscale on their phone
2. Log in with your Tailscale account
3. They can now access all services via `http://federver:<port>`

Tailscale only routes traffic to your server — it does NOT route all their internet through a VPN. Normal browsing, apps, everything else goes through their regular connection.

### Submenu (`federver` → 10 after install)

Re-running option 10 from the laptop once both sides are installed shows a unified status (laptop IP + server IP/hostname) and a both-sides management submenu:

1. **Refresh status** — both sides
2. **Connect both** — `tailscale up` on laptop + server
3. **Disconnect both** — `tailscale down` on both (stays disconnected until you Connect again)
4. **Restart both** — `systemctl restart tailscaled` on both
5. **Re-authenticate server** — SSHes to server and runs `tailscale up` with a new login URL
6. **Uninstall both** — removes Tailscale from laptop + server. Typed-name confirmation. Phones untouched.

When run directly on the server, option 10 opens a server-only submenu instead.

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
3. **Remove peer** — revoke a lost/retired device. Lists current peers, pick a number, confirms, deletes the `[Peer]` block from `wg0.conf` and the client `.conf` file, then hot-reloads without dropping other peers' connections.
4. **Reinstall** — regenerates all keys (existing peers stop working)

Adding and removing peers uses `wg syncconf` for a live reload, so other connected devices stay up.

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

## AdGuard Home DNS ad blocker

Network-wide DNS ad and tracker blocker. Runs in Docker on the server, catches ads before they even download. One install, covers every Tailscale-connected device — phone, laptop, iPad — at home and roaming.

### What it does (and doesn't)

**Blocks at the DNS layer.** When an app or browser asks "what's the IP for `doubleclick.net`?", AdGuard answers "nothing there" and the ad request never leaves your device.

**Good at:** third-party ads, tracker networks, telemetry, smart TV phone-home, app analytics, most open-web ad networks. Typical block rate: 15–30% of all DNS queries.

**Bad at:** first-party ads on Reddit, YouTube, Facebook, Instagram, Buzzfeed, Twitter/X. These are served from the same domain as the content, so DNS can't tell ads apart from real requests. For those, use uBlock Origin in your desktop browser and apps like ReVanced / SmartTube on mobile.

### Install

`federver` → **12**.

The step flow:

1. **Tailscale pre-check.** If Tailscale isn't installed, the step stops and offers to send you to step 10 first (recommended) or continue anyway for manual per-device DNS.
2. **systemd-resolved cleanup.** Fedora binds port 53 to `systemd-resolved`'s stub listener by default. The step explains exactly what it's going to change (`DNSStubListener=no` drop-in, `resolv.conf` symlink, `systemd-resolved` restart) and asks `Disable the stub listener and continue? [Y/n]` before touching anything. Local name resolution keeps working afterward — just not on port 53.
3. **Firewall.** Opens 53/udp, 53/tcp, 80/tcp.
4. **Minimal config pre-seed.** Writes a three-line `/opt/adguard/conf/AdGuardHome.yaml` that sets `http.address: 0.0.0.0:80`. AdGuard's own first-run wizard then runs on port 80 instead of its hardcoded default of port 3000 — so there's no port-3000 detour.
5. **Container start.** Launches `adguard/adguardhome:latest` with `--network=host` and `--restart=unless-stopped`, volumes under `/opt/adguard/{work,conf}`.
6. **Finish AdGuard's wizard in the browser.** The step prints an ACTION NEEDED block pointing at `http://<server-ip>` and waits for you to press Enter. You open the URL, click through AdGuard's native setup wizard (leave everything at defaults → Next → Next → create admin username + password → Finish), come back to the terminal, press Enter.
7. **Tailscale guidance.** Prints the click-by-click steps to point tailnet DNS at AdGuard (see next section).

Total user input: two Enter/Y confirmations in the terminal plus AdGuard's own 4-screen setup wizard in the browser. Admin credentials are set in the wizard, not in the terminal.

### Point devices at AdGuard (via Tailscale)

The install step prints this block when Tailscale is detected. This is the only rollout path we recommend — router-level DHCP DNS overrides are unreliable (many ISP routers reject LAN IPs), and per-device manual DNS leaks around IPv6 settings on Linux and Private Relay on iOS.

1. Open [https://login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns)
2. Under the **DNS** tab → **Nameservers** → **Global nameservers** → **Add nameserver** → **Custom**
3. Enter the server's **tailnet IP** (shown at the end of the install step, or get it with `tailscale ip -4` on the server)
4. **Save**
5. Toggle **Override local DNS** ON

Every tailnet device now uses AdGuard automatically. Roaming too — works from a coffee shop the same way it works at home.

### Dashboard

[http://federver](http://federver) — log in with the admin credentials you entered during the install step.

**Query Log** tab shows every DNS lookup in real time, with blocked entries highlighted red. Good sanity check that it's actually doing something. Browse a news site for a minute, then check — you'll see a stream of blocked tracker domains.

**Dashboard** tab shows totals: queries per hour, block percentage, top blocked domains, top clients.

### Troubleshooting

- **Query log is empty** — your device isn't sending DNS through AdGuard. Check Tailscale admin console has **Override local DNS** on, and that the device is connected to the tailnet.
- **Some sites look broken** — a filter list may be over-blocking. Click the blocked entry in Query Log → **Unblock** to whitelist that domain.
- **Container is restarting** — something else is holding port 53. Run `sudo ss -tulpn | grep ':53 '` to find it. Usually systemd-resolved; the install step should have disabled it.
- **Still seeing ads on Reddit/YouTube** — expected, these are first-party ads. DNS can't block them. Use uBlock / ReVanced / SmartTube.

### Upstream + fallback DNS (resilience)

After install, set AdGuard's upstream and fallback DNS so traffic still resolves if the primary upstream fails. Open [http://federver](http://federver) → **Settings → DNS settings** and paste these:

| Field | Value |
|---|---|
| Upstream DNS servers | `https://cloudflare-dns.com/dns-query` <br> `https://dns.quad9.net/dns-query` |
| Bootstrap DNS servers | `1.1.1.1` <br> `9.9.9.9` |
| Fallback DNS servers | `8.8.8.8` <br> `8.8.4.4` |
| Load balancing | **Parallel requests** |

Click **Apply** at the bottom. Three independent providers (Cloudflare, Quad9, Google) over encrypted DoH — ISP can't snoop DNS, and no single provider failing takes you offline. Same guide is available anytime in `federver → 12 → 2`.

**What each field does and why these values:**

| Field | Purpose | Why these values |
|---|---|---|
| Upstream | Where DNS queries actually go | DoH = encrypted, privacy from ISP. Cloudflare = fast. Quad9 = malware filter. |
| Bootstrap | How to reach the upstream first time (chicken-and-egg: can't resolve `cloudflare-dns.com` by name before DNS works) | Plain IPs of Cloudflare + Quad9, matches upstream providers |
| Fallback | Used if both upstreams are unreachable | Different company (Google) — a single-provider outage doesn't kill DNS |
| Load balancing (Parallel requests) | Queries both upstreams at the same time, uses whichever answers first | Lowest latency + automatic failover |

---

## Syncthing real-time folder sync

Continuous bidirectional file sync between devices. Peer-to-peer — no central cloud, changes propagate in seconds. Good for folders you actively edit on multiple devices (notes, code, documents, obsidian vault). Complements Manage sync (`federver` → 16), which handles one-shot transfers and scheduled jobs; Syncthing is always-on.

### What it's good for

- **Obsidian / notes** — edit on laptop, appear on phone instantly
- **Active work folders** — shared between desktop and laptop
- **Code drafts** — small repos you're hacking on from multiple machines
- **Photos from camera SD** — drop in a folder, server auto-picks them up

Not the tool for: photo backup (use Immich), music library (use Navidrome), or one-shot transfers (use Manage sync, option 16).

### Install

`federver` → **14**. Run from the laptop — the step installs and configures *both sides in one shot*:

**Laptop side (automatic):**
1. `sudo dnf install -y syncthing` if it's not already there
2. `systemctl --user enable --now syncthing`
3. Reads the laptop's Device ID and prints it

**Server side (via SSH):**
1. Opens firewall: 8384/tcp (web UI), 22000/tcp+udp (sync protocol), 21027/udp (LAN discovery)
2. Reads your `.env` and bind-mounts the three semantic privcloud paths into the Syncthing container — `data`, `media`, and `immich` — so the web UI's *Add Folder* dialog can browse to them directly
3. Launches `syncthing/syncthing:latest` with `--network=host`, `--restart=unless-stopped`, `STGUIADDRESS=0.0.0.0:8384`, and state at `/opt/syncthing`
4. Reads the server's Device ID and prints it

You end the step with both Device IDs visible and both dashboards running. The next step is pairing, in the browser.

### Installing on other devices

- **Android:** install **Syncthing** from F-Droid (recommended — official) or Play Store
- **iOS:** install **Möbius Sync** from the App Store (Syncthing-compatible, paid)
- **macOS / Windows / non-Fedora Linux:** download from [syncthing.net](https://syncthing.net/downloads/)

### Pairing

Two-way handshake by Device ID. Each pair only happens once:

1. **On the laptop UI** (`http://localhost:8384`): **Add Remote Device** → paste the **server's** Device ID → Save
2. **On the server UI** (`http://federver:8384` or `http://<server-ip>:8384`): a yellow banner appears saying the laptop wants to connect → **Add Device** → Save

Both sides now know each other. Repeat for every additional device (phone, tablet, second laptop) you want in the sync group.

### Sharing folders

Pairing just establishes identities. To actually sync something, you create a folder share:

1. **On one side** — say the laptop — click **Add Folder**
   - **Folder Label:** display name, e.g. `Notes`
   - **Folder Path:** local path on this device, e.g. `/home/hamr/notes`
   - **Sharing** tab → tick the other device (server)
   - **Advanced** tab → **Folder Type** stays at **Send & Receive** (the default) for normal two-way sync
   - Save
2. **On the other side** — a yellow banner appears saying the laptop wants to share "Notes" → **Add**
   - **Folder Path:** pick where on this device, e.g. `/mnt/data/data/notes`
   - Save

Drop a file into the folder on either side → appears on the other side within seconds. Delete, rename, edit — all sync bidirectionally.

**The path is per-device.** The server holds the folder at `/mnt/data/data/notes`, the laptop at `/home/hamr/notes`. Only the contents are synced, not the paths. You can give the same folder totally different locations on each device.

### Folder encryption (per folder, optional)

Syncthing has an "untrusted device" mode for offsite backups — the remote stores an encrypted blob it can't read. Useful if, say, a friend is hosting a backup for you and you don't want them reading your code.

Set it up from the **trusted** side:

1. Open the folder → **Edit** → **Sharing** tab
2. Next to each remote device, there's an **Encryption Password** field
3. Leave blank → plain sync. Fill in → encrypted-at-rest on that remote.
4. Save

The **untrusted** side must accept the folder with **Folder Type = Receive Encrypted** (in the Advanced tab when accepting the share).

Both sides must agree. Mismatch produces a log error like:
```
remote expects to exchange plain data, but local data is encrypted
(folder-type receive-encrypted)
```

For normal use (your own laptop ↔ your own server), leave the password blank and Folder Type at `Send & Receive` on both sides — that's plain bidirectional sync.

### Sync over the internet

Works automatically. When your laptop is away from home, Syncthing tries in order:

1. **LAN broadcast** (port 21027/udp) — finds peers on the same network
2. **Global discovery** — Syncthing's public discovery servers hand back peer addresses
3. **Public relays** — encrypted end-to-end, bridges traffic when neither side can connect directly

No port forwarding, no DDNS, no VPN required. Device IDs are location-independent.

**Bonus for your setup:** since both your laptop and server are on Tailscale, they'll see each other at stable tailnet IPs (`100.x.x.x`) from anywhere, bypassing relays entirely. Syncthing naturally picks the fastest connection, so you get near-LAN speed even from a coffee shop.

### Dashboard

- **Server:** [http://federver:8384](http://federver:8384) (or `http://<server-ip>:8384`)
- **Laptop:** [http://localhost:8384](http://localhost:8384)

First visit to each dashboard prompts you to set a GUI username and password. Set them — both web UIs are reachable from the LAN (and over Tailscale), so they need credentials. After that, run `federver → 17 (Save to pass)` to back up the server's `device_id`, `config.xml`, `cert.pem`, and `key.pem` into `pass`. The cert/key pair is the node's cryptographic identity — losing it means re-pairing every client.

### Submenu (`federver` → 14 after install)

Re-running option 14 from the laptop once both sides are installed opens a unified submenu that **controls both laptop and server together**:

1. **Refresh status** — both sides: laptop service state + server container state, both dashboard URLs, both Device IDs
2. **Show Device IDs** — laptop + server IDs for pairing new clients
3. **Start both** — laptop `systemctl --user start` + server `docker start` (re-enables autostart on both)
4. **Stop both** — stops on both sides, disables autostart so they stay off across reboots
5. **Restart both** — bounces both without changing autostart policy
6. **Show sync paths** — server-side container bind mounts vs `.env`
7. **Reapply paths from .env** — recreates the server container with fresh mounts (pairings persist)
8. **Logs (server)** — `docker logs -f syncthing` via SSH
9. **Uninstall both** — removes from laptop (`dnf remove`) + server (container + firewall). Typed-name confirm. Config kept on both sides.

When run directly on the server, option 14 opens a server-only submenu instead.

### Troubleshooting

- **Devices don't discover each other on LAN** — port 21027/udp blocked somewhere. Check firewall on both sides.
- **Sync is slow from off-site** — check Syncthing dashboard → peer details. If the connection shows "Relay" it's using Syncthing's public relays (slower, bandwidth-limited). If both peers are on Tailscale, the tailnet connection should be direct — check Tailscale is up on both sides.
- **Device ID unavailable** — container still starting up or Syncthing 2.x CLI couldn't be read. Wait 10 seconds and re-run option 14 → 2. The helper tries several CLI shapes and falls back to reading `config.xml` directly.
- **"Remote expects to exchange plain data, but local data is encrypted"** — Folder Type mismatch. One side set `Receive Encrypted`, the other didn't set an encryption password. Either set a password on the trusted side's Sharing tab, or change the untrusted side's Folder Type to `Send & Receive`.
- **Forgot the GUI password** — stop the container (`federver → 14 → 6`), delete `/opt/syncthing/config/config.xml`, restart. Regenerates clean. Pairings are lost (they lived in config.xml).

---

## Manage sync

`federver` → **16** (from laptop, exit SSH first). One-shot file transfers and scheduled sync jobs between laptop and server via rsync over SSH.

### What it does

- **Transfer files** — upload or download files and directories between laptop and server. Accepts files and directories, strips quotes and trailing slashes, handles folder-vs-contents mode (with a visual preview of the result path + a tip to avoid accidental nesting). Cancel at every step, 3-attempt retry on invalid input. At the end you choose: run now or schedule as a recurring job.
- **Delete files** — remove files on the laptop or server side.
- **Scheduled sync jobs** — set up cron-based rsync jobs that run automatically on a schedule. Pick source and destination, choose from presets (hourly, every 6h, daily at 2am) or enter a custom cron expression with a built-in cheat sheet showing what each field means + English translation + confirmation before saving. Jobs run once immediately after creation to confirm they work. Scripts saved to `~/.local/bin/sync-*.sh`, logs to `~/.local/share/sync-jobs/*.log`.
- **View all scheduled tasks** — unified table showing server cron jobs (immich-backup, disk-check) alongside your laptop sync jobs, with schedule, English translation, type, and status.

### When to use it vs Syncthing

| | Manage sync (option 16) | Syncthing (option 14) |
|---|---|---|
| **Mode** | One-shot or scheduled cron | Always-on real-time |
| **Direction** | One-way per transfer | Bidirectional |
| **Runs from** | Laptop (SSHes to server) | Both sides independently |
| **Good for** | Bulk transfers, scheduled backups, cleanup | Live working folders, notes, code drafts |

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
Install "RD Client" from App Store. Add PC with `federver` (via Tailscale).

### Troubleshooting

- **Session opens then closes:** lightdm is still running. Run `sudo systemctl disable --now lightdm` on the server.
- **Black screen:** XFCE session packages may be missing. Run `sudo dnf install xfce4-session xfwm4 xfce4-panel xfdesktop`.
- **Can't connect:** check firewall port 3389 is open: `sudo firewall-cmd --list-ports`.

---

## Save to pass

Option **17** in `federver` backs up everything to the `pass` password manager. Run from your **laptop** (where pass is installed) — it SSHes into the server to fetch data.

```bash
federver    # pick 17
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
| Disk space | Every-5-min cron + Kuma Push | `cat /var/log/disk-check.log` or Uptime Kuma dashboard |
| Backup status | Check log | `cat /var/log/immich-backup.log` |
| Container errors | `privcloud status` | Shows recent errors per container |

**Uptime Kuma monitors to add:**

| Name | Type | URL/Host |
|------|------|----------|
| Immich | HTTP(s) | `http://<server-ip>:2283/api/server/ping` |
| Navidrome | HTTP(s) | `http://<server-ip>:4533` |
| FileBrowser | HTTP(s) | `http://<server-ip>:8080` |
| Server | Ping | `<server-ip>` |

Use the server's local IP, not `localhost` (Uptime Kuma runs in Docker).

**Disk space alert:** Step 8 in `federver` sets this up automatically. It walks you through creating a Push monitor in Uptime Kuma (Heartbeat Interval `360`, Retry Interval `60`, Max Retries `2`), you paste the URL back into the terminal, and it installs `/usr/local/bin/disk-check.sh` with a 5-minute cron. The script sends `status=up` when all mounts are under 85%, or `status=down` when any mount exceeds 85%. The first heartbeat is sent immediately at install time so the Kuma monitor goes green before you even leave the step. Uptime Kuma then alerts you via Telegram/email if configured.

### Periodic (manual)

| Task | Command | When |
|------|---------|------|
| Check status | `federver` → **s** | Anytime |
| Update Immich | `privcloud update` | Monthly |
| Update other containers | `docker compose pull && docker compose up -d` | Monthly |
| Update Fedora userspace | `sudo dnf upgrade --exclude='kernel*'` | Monthly (or skip — security fixes auto-apply) |
| Update kernel + reboot | see [Kernel updates](#kernel-updates) | Every 1–2 months, when you're home |
| Check disk space | `df -h` | Monthly |
| Check disk alerts | `cat /var/log/disk-check.log` | After alerts |
| Check backup logs | `cat /var/log/immich-backup.log` | After issues |
| Manage sync | `federver` → **16** (from laptop) | As needed |

### Kernel updates

`dnf-automatic` (step 4) applies **userspace security fixes only** and explicitly excludes kernel packages. This is deliberate: a headless home server should never auto-reboot into an untested kernel while you're away. The trade-off is that you update the kernel by hand every month or two, when you're physically near the box (or at least able to walk to it if something goes wrong).

**The workflow, when you're home:**

```bash
# 1. See if there's actually a new kernel waiting
sudo dnf check-upgrade kernel

# 2. Install it (and any related kernel packages)
sudo dnf upgrade kernel kernel-core kernel-modules kernel-modules-core

# 3. Reboot into the new kernel
sudo systemctl reboot

# 4. After it comes back, verify
uname -r                    # should show the new version
privcloud status            # containers back up?
federver                    # → s, for full status
```

**If the new kernel misbehaves** (kernel panic, hardware doesn't work, networking broken, anything weird): reboot and pick the previous kernel from the GRUB menu. Fedora keeps the last 3 kernels installed by default, so you always have a working fallback one arrow-key away.

```bash
# To make the previous kernel the default permanently:
sudo grubby --set-default /boot/vmlinuz-<previous-version>
```

**Why not just run `sudo dnf upgrade` like a normal desktop?** You can — it's fine when you're home. The only reason this guide splits it out is that the kernel is the one package where "apply update" and "finish update" are different events (reboot required), and an unattended reboot into a broken kernel is the main way a home server becomes unreachable while you're traveling. Keeping kernels on a manual, supervised cadence removes that failure mode entirely.

### SSH access

```bash
# From home
ssh ahassan@<hostname>

# From anywhere (via Tailscale)
ssh ahassan@federver
```

---

## Server troubleshooting

### `privcloud` or `federver` command not found / wrong path

The global commands are created by step 1 (Enable SSH). If they point to the wrong path or don't exist:

```bash
# Check where they point
cat /usr/local/bin/privcloud
cat /usr/local/bin/federver

# Fix — update to point to your repo location
REPO_DIR="$(cd ~/privcloud && pwd)"
sudo tee /usr/local/bin/federver > /dev/null <<EOF
#!/bin/bash
exec $REPO_DIR/setup.sh "\$@"
EOF
sudo chmod +x /usr/local/bin/federver

sudo tee /usr/local/bin/privcloud > /dev/null <<EOF
#!/bin/bash
exec $REPO_DIR/privcloud "\$@"
EOF
sudo chmod +x /usr/local/bin/privcloud
```

Or re-run `federver` → step 1 which recreates both wrappers with the correct paths.

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
sudo chown -R $USER:$USER ~/data/immich/upload   # safe
# sudo chown -R $USER:$USER ~/data/immich/        # BREAKS POSTGRES
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

`federver` → **13** opens the storage sub-menu:

```
1) Status                     <- drives, mounts, paths
2) Mount USB drive
3) Unmount USB drive
4) Change music location      <- Navidrome
5) Change data location       <- FileBrowser root
6) Change Immich location     <- Immich photos + database
0) Cancel
```

### Mounting a USB drive

1. Plug in the USB drive
2. `federver` → **13** → **2**
3. Select the USB partition (auto-detected, internal drives filtered out)
4. Choose mount point (default: `/mnt/data`)

The drive is added to `/etc/fstab` so it auto-mounts on reboot.

### Changing music location

If you want to move music to a USB drive:

1. Mount the USB: `federver` → **13** → **2**
2. Move files: `rsync -avh --progress /old/music/path/ /mnt/data/media/My\ Music/`
3. Change location: `federver` → **13** → **4** → enter `/mnt/data/media/My Music`

This updates `.env` and redeploys Navidrome automatically.

### Changing FileBrowser location

1. Move files if needed: `rsync -avh --progress /old/data/ /new/data/`
2. Change location: `federver` → **13** → **5** → enter new path

This updates `.env` and redeploys FileBrowser automatically.

### Changing Immich data location

1. Stop Immich: `privcloud stop`
2. Move files: `sudo rsync -ah --progress /old/immich/ /new/immich/`
3. Change location: `federver` → **13** → **6** → enter `/new/immich`
4. Verify: `privcloud status`

**Important:** the Postgres database password is baked in when first created. If you copy the database directory, keep the same `DB_PASSWORD` in `.env`. Changing it will cause `password authentication failed`.

### Unmounting a USB drive

1. Stop services using the drive first
2. `federver` → **13** → **3**
3. Select the USB to unmount
4. Safe to unplug after confirmation

## Resetting passwords

`federver` → **r** lets you reset credentials for any service:

| Service | What happens | Data lost? |
|---------|-------------|------------|
| **FileBrowser** | Sets new admin password | No |
| **Immich** | Clears admin password, re-enter on next login | No |
| **Navidrome** | Wipes data, re-register via web UI | Music library re-scanned automatically |
| **Uptime Kuma** | Wipes data, starts fresh | Monitors need re-adding |
