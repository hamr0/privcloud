```
           _            _                 _
 _ __ _ __(_)_   _____ | | ___  _   _  __| |
| '_ \| '__| \ \ / / __|| |/ _ \| | | |/ _` |
| |_) | |  | |\ V / (__ | | (_) | |_| | (_| |
| .__/|_|  |_| \_/ \___||_|\___/ \__,_|\__,_|
|_|
```

**Your photos. Your storage. No cloud required.**

Apple wants $3/month for iCloud. Google strips your metadata and caps your storage. privcloud runs a full photo server on your machine with one command. Face recognition, smart search, duplicate detection — all local, all yours. Start it when you need it, stop it when you don't. Your photos never leave your drive.

## Prerequisites

- **Linux, macOS, or WSL** — any modern version
- **~4 GB RAM** when running
- **Storage** for your photos — local drive, external HDD, whatever you have
- **Immich app** on your phone — [iPhone](https://apps.apple.com/app/immich/id1613945652) / [Android](https://play.google.com/store/apps/details?id=app.alextran.immich)

The `install` command handles everything else — Docker, Docker Compose, permissions, SELinux, storage setup, and pulling images. On WSL, install [Docker Desktop for Windows](https://docker.com/products/docker-desktop) first.

## Quick Start

**One-liner:**

```bash
curl -fsSL https://raw.githubusercontent.com/hamr0/privcloud/main/install.sh | bash && privcloud
```

**Or clone:**

```bash
git clone https://github.com/hamr0/privcloud.git
cd privcloud
./privcloud
```

Pick `install`, then `start`. Open http://localhost:2283, create your account, connect the Immich app on your phone.

```
  1) install   Check prerequisites, pull images, set up config
  2) start     Start privcloud
  3) stop      Stop privcloud
  4) status    Show status and diagnostics
  5) config    Change photo storage location
  6) upload    Upload photos to privcloud
  7) fix-gp    Fix Google Photos metadata (Takeout export)
  0) exit
```

Commands also work directly: `./privcloud start`, `./privcloud upload`, `./privcloud fix-gp`, etc.

## How It Works

1. `privcloud start` — starts Immich (photo server, face recognition, database)
2. Open Immich app on your phone — photos sync over WiFi to your storage
3. Browse, search, organize in the web UI
4. `privcloud stop` — stops everything (photos stay on disk)

No always-on server needed. Run it when you want to backup, shut it down when done.

Works on Linux, macOS, and WSL.

## Phone Setup

1. Server URL: `http://<your-computer-ip>:2283` (shown by `privcloud start`)
2. Login with the account you created in the web UI
3. Enable auto backup in app settings
4. Both devices must be on the same WiFi

## Migrating from Google Photos

Google Takeout strips metadata from your photos — dates get separated into JSON sidecar files with inconsistent, truncated names. The `fix-gp` command handles all of it.

1. Export via [Google Takeout](https://takeout.google.com) (select Google Photos)
2. Fix metadata: `./privcloud fix-gp` — point it at the folder with your takeout zips
3. Upload: `./privcloud upload` — prompts for your API key and photo folder

The fix restores `DateTimeOriginal`, `DateTimeDigitized`, and GPS coordinates into JPEG EXIF data, and sets correct file modification times on all media files (HEIC, MOV, MP4, etc.).

For the full walkthrough — migration, organizing, face recognition, backup, troubleshooting — see the **[Customer Guide](customer-guide.md)**.

## Features (via Immich)

- Face recognition — auto-groups faces, you name them
- Smart search — "beach", "birthday", "dog"
- Duplicate detection
- Map view, timeline, albums
- EXIF metadata preserved

## License

MIT
