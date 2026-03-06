# privcloud — Customer Guide

Your photos. Your storage. No cloud required.

---

## Table of Contents

- [Why privcloud](#why-privcloud)
- [What you get](#what-you-get)
- [Getting started](#getting-started)
- [Connecting your phone](#connecting-your-phone)
- [Migrating from Google Photos](#migrating-from-google-photos)
- [Migrating from iCloud](#migrating-from-icloud)
- [Uploading existing photo collections](#uploading-existing-photo-collections)
- [Organizing your photos](#organizing-your-photos)
- [Finding photos](#finding-photos)
- [Face recognition](#face-recognition)
- [Duplicates](#duplicates)
- [Sharing](#sharing)
- [Storage and architecture](#storage-and-architecture)
- [Backup and restore](#backup-and-restore)
- [Moving to a new machine](#moving-to-a-new-machine)
- [Day-to-day usage](#day-to-day-usage)
- [Troubleshooting](#troubleshooting)
- [Privacy and security](#privacy-and-security)

---

## Why privcloud

Apple charges $0.99/month for 50GB of iCloud. Sounds cheap — until your library grows and you're paying $2.99, then $9.99, then $14.99. Every month. Forever. That's $180/year to store files you already own.

Google gives you 15GB free, then strips your photo metadata to save themselves storage costs. Try to export via Google Takeout and you get mangled filenames, missing dates, and JSON sidecar files you have to recombine yourself.

Both companies make it effortless to upload and painful to download. That's not a bug. That's the business model. The friction is intentional — it keeps you paying.

privcloud eliminates all of it. One command runs a full photo server on your own machine. Your photos stay on your drive. No subscription. No cloud. No friction at the exit door.

## What you get

### From privcloud (the CLI)

| Command | What it does |
|---------|-------------|
| `install` | Installs Docker, Docker Compose, pulls images, configures storage |
| `start` | Starts the photo server |
| `stop` | Stops everything (photos stay on disk) |
| `status` | Shows diagnostics — containers, storage usage, URLs |
| `config` | Change where photos are stored |
| `upload` | Bulk upload photos via Immich CLI with API key validation |
| `fix-gp` | Fix Google Photos Takeout metadata (dates + GPS) |

### From Immich (the photo server privcloud runs)

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

## Getting started

### Requirements

- **Linux, macOS, or WSL** — any modern version
- **~4 GB RAM** when running (can be less after initial ML indexing)
- **Storage** — local drive, external HDD, NAS, whatever you have

### Install and start

```bash
# One-liner install
curl -fsSL https://raw.githubusercontent.com/hamr0/privcloud/main/install.sh | bash && privcloud

# Or clone
git clone https://github.com/hamr0/privcloud.git
cd privcloud
./privcloud
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

## Migrating from Google Photos

Google Takeout exports your photos with metadata stripped into separate JSON files. The filenames are truncated and inconsistent. privcloud's `fix-gp` command handles all of it.

### Step 1: Export from Google

1. Go to [Google Takeout](https://takeout.google.com)
2. Deselect everything, then select only **Google Photos**
3. Choose your export format (zip) and size (largest available — fewer files to deal with)
4. Google will email you download links. Download all the zip files into one folder.

### Step 2: Fix metadata

```bash
./privcloud fix-gp
```

Enter the path to the folder containing your takeout zips. The script:

1. Extracts all zips
2. Checks for Python, piexif, and Pillow (installs if missing)
3. Matches each photo to its JSON sidecar — handling every truncated naming pattern Google uses (`.supplemental-metadata.json`, `.suppl.json`, `.su.json`, and everything in between)
4. Writes `DateTimeOriginal`, `DateTimeDigitized`, and GPS coordinates back into JPEG EXIF
5. Sets correct file modification times on all media (HEIC, MOV, MP4, PNG, etc.)

### Step 3: Upload

```bash
./privcloud upload
```

Enter your API key (get it from http://localhost:2283 → Account Settings → API Keys) and the path to the extracted photos folder.

### What gets fixed vs. what doesn't

| File type | EXIF dates | GPS | File timestamp |
|-----------|-----------|-----|----------------|
| JPEG/JPG | Written | Written | Set |
| HEIC/HEIF | — | — | Set |
| MOV/MP4 | — | — | Set |
| PNG/GIF | — | — | Set |

HEIC and video files don't support EXIF writing via piexif, but their file modification times are corrected. Immich uses file timestamps for sorting when EXIF is missing, so your timeline will be correct.

---

## Migrating from iCloud

### Option A: iPhone app (easiest)

If your photos are still on your iPhone (not "Optimize Storage"):

1. Connect your phone to the same WiFi as your computer
2. Open the Immich app, enable auto-backup for your Camera Roll
3. Let it sync — this uploads directly from your phone to privcloud

### Option B: iCloud download + upload

1. Go to [icloud.com/photos](https://icloud.com/photos)
2. Select photos (Cmd+A for all), click the download icon
3. iCloud downloads in batches — this is slow and Apple throttles it intentionally
4. Once downloaded, use `./privcloud upload` to bulk upload the folder

### Option C: Use iCloud for Windows/Mac export

1. On Mac: Photos app → Select All → File → Export Unmodified Originals
2. On Windows: iCloud for Windows syncs to a local folder — point `upload` at that folder

### After migration

Once everything is in privcloud and verified, you can:
- Turn off iCloud Photos on your iPhone (Settings → Photos → iCloud Photos → Off)
- Downgrade your iCloud plan
- Keep the Immich app as your primary photo viewer

---

## Uploading existing photo collections

Have photos scattered across hard drives, USB sticks, old laptops? Upload them all.

```bash
./privcloud upload
```

Point it at any folder. It uploads recursively and skips duplicates automatically (by file hash). You can run it multiple times from different sources — Immich won't create duplicate entries.

### Supported formats

Photos: JPEG, PNG, HEIC, HEIF, GIF, BMP, TIFF, WebP, RAW (CR2, NEF, ARW, DNG, etc.)
Videos: MP4, MOV, AVI, MKV, 3GP, M4V, WebM

---

## Organizing your photos

### Timeline

The main view. All your photos sorted by date, newest first. Scroll to travel back in time. This is your default view and requires no setup — it builds automatically from EXIF dates and file timestamps.

### Albums

- **Create manually** — select photos, click "Add to album"
- **Auto-created** — Immich can suggest albums based on date and location
- **From folders** — when uploading via CLI, folder names can become album names

### Favorites

Star any photo to add it to your Favorites. Quick access from the sidebar.

### Archive

Photos you want to keep but hide from the main timeline. Think of it as a "shoebox in the closet." Archived photos still appear in search, albums, and the map — just not the timeline.

### Trash

Deleted photos go to trash first. Recoverable for 30 days, then permanently removed. This gives you a safety net.

### Tags

Add tags to photos for custom categorization beyond what albums offer.

---

## Finding photos

### Smart search

Type what you're looking for in natural language:

- "beach sunset"
- "birthday cake"
- "dog playing in snow"
- "red car"
- "food"

Immich uses machine learning (CLIP model, runs locally) to understand photo content. No cloud API needed.

### Filters

- **By date** — click any month/year in the timeline
- **By person** — click a face in the People section
- **By location** — use the Map view, zoom to an area
- **By media type** — photos only, videos only
- **By camera** — filter by camera model or lens

### Map view

Every photo with GPS data appears on a world map. Zoom in to see clusters. Click to browse photos from that location. Works especially well after running `fix-gp` on Google Takeout exports — the GPS data gets written back into your photos.

---

## Face recognition

Immich automatically scans every photo for faces. This runs locally on your machine using the ML container.

### How it works

1. After upload, the ML container processes each photo (this takes a while on first import — ~1-2 seconds per photo)
2. Detected faces are grouped by similarity
3. You name each person once — Immich tags all matching faces automatically
4. New photos of that person are tagged going forward

### Tips

- **Merge duplicates** — sometimes the same person gets split into two groups. Select both and merge.
- **Hide faces** — if Immich detects faces in paintings, posters, or TV screens, you can hide those groups
- **Minimum faces** — Immich only shows face groups with multiple photos by default. Check settings to adjust the threshold.

---

## Duplicates

Immich detects duplicates by file hash. When duplicates are found:

1. Go to the Duplicates section in the sidebar
2. Review each group — Immich shows the duplicates side by side
3. Keep the best version, trash the rest
4. Or use "Keep all" if they're not actually duplicates

Run this after migrating from multiple sources. It's common to have the same photo backed up in three different places.

---

## Sharing

### Shared albums

1. Create an album
2. Click Share → add users (they need accounts on your privcloud instance)
3. Shared users can view and optionally add photos

### Shared links

1. Select an album or photos
2. Create a shared link (with optional expiry and password)
3. Anyone with the link can view — no account needed
4. Great for sharing vacation albums with family

### Multi-user

Create accounts for family members. Each person gets their own library, timeline, and face recognition. The admin can see storage usage per user.

---

## Storage and architecture

### What's stored where

privcloud uses two directories, configured in `.env`:

| Directory | What's in it | Default |
|-----------|-------------|---------|
| `UPLOAD_LOCATION` | Original photos, thumbnails, encoded videos, profile pictures | Set during `./privcloud config` |
| `DB_DATA_LOCATION` | PostgreSQL database (face data, search index, albums, user accounts, EXIF index) | Same parent as photos, `/postgres` subfolder |

### How Immich uses PostgreSQL

The database stores everything *about* your photos, but not the photos themselves:

- Face recognition embeddings and person names
- CLIP embeddings for smart search
- Album membership, favorites, archive status
- User accounts, API keys, sharing permissions
- EXIF metadata index (parsed from files for fast filtering)
- Duplicate detection hashes
- Activity history

### Storage growth

Immich stores the original file plus generated assets:

| Asset | Approximate size |
|-------|-----------------|
| Original photo | As-is (not modified) |
| Thumbnail | ~50-100 KB per photo |
| Preview | ~200-500 KB per photo |
| Encoded video | Varies (only if transcoding is enabled) |
| Database | ~1-2 KB per photo |

**Rule of thumb:** expect ~20-30% overhead on top of your original photo library size for thumbnails and previews.

### Docker containers

privcloud runs four containers:

| Container | Purpose | Resource usage |
|-----------|---------|---------------|
| `immich_server` | Web UI, API, photo serving | ~500 MB RAM |
| `immich_machine_learning` | Face recognition, smart search | ~1-2 GB RAM (spikes during processing) |
| `immich_redis` | Job queue and caching | ~50 MB RAM |
| `immich_postgres` | Database | ~200-500 MB RAM |

Total: ~2-4 GB RAM when running. After initial ML processing, usage drops. The ML container is the heaviest — it processes new uploads in the background.

---

## Backup and restore

### What to backup

**Both directories.** Photos without the database = unsorted files. Database without photos = empty references.

| If you lose... | What happens |
|---|---|
| Photos only | Database points to files that don't exist. Everything broken. |
| Database only | Photos are on disk but Immich doesn't know they exist. Face recognition, albums, search — all gone. Re-import works but you lose all organization. |
| Both | Clean slate. Start over. |

### How to backup

```bash
# Always stop first — ensures the database is in a consistent state
./privcloud stop

# Option 1: Copy both directories
cp -a /stuff/privcloud/photos /backup/privcloud-photos
cp -a /stuff/privcloud/postgres /backup/privcloud-postgres

# Option 2: Tar everything
tar czf /backup/privcloud-$(date +%Y%m%d).tar.gz \
  /stuff/privcloud/photos \
  /stuff/privcloud/postgres

# Start again
./privcloud start
```

### How often to backup

- **After a big import** — migrating from Google Photos, uploading an old hard drive
- **Monthly** if you're actively taking photos
- **Before OS upgrades or hardware changes**

### Backup to an external drive

The simplest strategy: plug in an external HDD, copy both directories, unplug. You now have a complete, portable copy of your entire photo library that works on any machine with Docker.

---

## Moving to a new machine

1. Stop privcloud on the old machine: `./privcloud stop`
2. Copy both `photos` and `postgres` directories to the new machine
3. On the new machine:
   ```bash
   git clone https://github.com/hamr0/privcloud.git
   cd privcloud
   ./privcloud install
   ```
4. Run `./privcloud config` — point it at the copied photos directory
5. Edit `.env` — make sure `DB_DATA_LOCATION` points to the copied postgres directory and `DB_PASSWORD` matches the old `.env`
6. `./privcloud start`

Everything comes back — faces, albums, search, sharing, all of it. The database references files by relative path within the upload directory, so as long as the folder structure is preserved, it just works.

---

## Day-to-day usage

### The intended workflow

1. Take photos on your phone like normal
2. Open the Immich app occasionally — photos sync over WiFi
3. When you want to browse, organize, or share: open http://localhost:2283
4. When you're done: `./privcloud stop` (or leave it running — your choice)

### You don't need to keep it running

privcloud is designed for on-demand use:

- `./privcloud start` — spin up when you want to backup or browse
- `./privcloud stop` — shut down when done
- Your photos stay on disk. Nothing is lost when stopped.

The ML container processes new uploads in the background. If you upload 500 photos and stop immediately, face recognition and search indexing will resume where they left off next time you start.

### Keeping Immich updated

privcloud pins to the `release` tag by default. To update:

```bash
./privcloud stop
# Pull latest images
docker compose -f docker-compose.yml pull
./privcloud start
```

Immich handles database migrations automatically on startup.

---

## Troubleshooting

### "privcloud start" hangs or times out

```bash
./privcloud status
```

Check which containers are unhealthy. Common causes:
- **Port 2283 already in use** — another service is on that port
- **Not enough RAM** — the ML container needs ~1-2 GB
- **Docker not running** — `./privcloud start` tries to start it, but check `docker info`

### Photos not showing up after upload

- Give the ML container time to process. Check the Jobs section in the web UI (Administration → Jobs).
- Verify the file format is supported.
- Check that the upload directory permissions are correct: `./privcloud status`

### Face recognition not working

- ML processing happens in the background. Check Administration → Jobs → Face Detection.
- First-time processing is slow (~1-2 seconds per photo).
- After a large import, it may take hours to process everything.

### Wrong dates on photos

- Run `./privcloud fix-gp` on Google Takeout exports before uploading.
- For other sources: check if the files have EXIF data. Immich falls back to file modification time when EXIF is missing.

### Database issues

```bash
./privcloud stop
./privcloud start
```

A restart fixes most database issues. If the postgres container won't start, check disk space — a full disk can corrupt the database.

---

## Privacy and security

### What stays local

- **All your photos** — stored on your drive, never uploaded anywhere
- **Face recognition** — ML models run locally in Docker, no cloud API
- **Smart search** — CLIP model runs locally, no external calls
- **Database** — PostgreSQL on your machine

### What goes over the network

- **Phone ↔ computer** — photos sync over your local WiFi (HTTP on port 2283)
- **Docker image pulls** — downloads container images from GitHub Container Registry during install/update
- **Nothing else** — no telemetry, no analytics, no phoning home

### Security considerations

- The web UI runs on HTTP (not HTTPS) by default. This is fine for local WiFi but **do not expose port 2283 to the internet** without adding a reverse proxy with HTTPS.
- API keys are stored in plaintext in Immich's database. Treat them like passwords.
- The `.env` file contains your database password. Don't commit it to a public repo.
- Each user account has its own library. Users cannot see each other's photos unless explicitly shared.
