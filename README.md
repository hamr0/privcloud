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

1. **Docker** — install it first, the script handles the rest
   - Linux: `sudo dnf install docker docker-compose` (or `apt install docker.io docker-compose`)
   - Mac: `brew install --cask docker`
   - WSL: [Docker Desktop for Windows](https://docker.com/products/docker-desktop) with WSL backend

2. **Immich app** on your iPhone — [App Store link](https://apps.apple.com/app/immich/id1613945652)

That's it. The `install` command handles Docker startup, permissions, SELinux, storage setup, and pulling images.

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

Pick `install`, then `start`. Open http://localhost:2283, create your account, connect the iPhone app.

```
  1) install   Check prerequisites, pull images, set up config
  2) start     Start privcloud
  3) stop      Stop privcloud
  4) status    Show status and diagnostics
  5) config    Change photo storage location
  0) exit
```

Commands also work directly: `./privcloud start`, `./privcloud stop`, etc.

## How It Works

1. `privcloud start` — starts Immich (photo server, face recognition, database)
2. Open Immich app on iPhone — photos sync over WiFi to your storage
3. Browse, search, organize in the web UI
4. `privcloud stop` — stops everything (photos stay on disk)

No always-on server needed. Run it when you want to backup, shut it down when done.

Works on Linux, macOS, and WSL.

## iPhone Setup

1. Server URL: `http://<your-computer-ip>:2283` (shown by `privcloud start`)
2. Login with the account you created in the web UI
3. Enable auto backup in app settings
4. Both devices must be on the same WiFi

## Migrating from Google Photos

1. Export via [Google Takeout](https://takeout.google.com) (select Google Photos)
2. Upload to Immich via web UI (drag and drop) or CLI:
   ```bash
   npm i -g @immich/cli
   immich upload --server http://localhost:2283 --key YOUR_API_KEY /path/to/takeout
   ```

## Features (via Immich)

- Face recognition — auto-groups faces, you name them
- Smart search — "beach", "birthday", "dog"
- Duplicate detection
- Map view, timeline, albums
- EXIF metadata preserved

## License

MIT
