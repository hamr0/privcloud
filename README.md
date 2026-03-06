# privcloud

Self-hosted photo backup. Own your photos, no cloud subscriptions.

Uses [Immich](https://immich.app/) — an open-source Google Photos alternative with face recognition, smart search, and a proper iPhone app.

## Quick Start

```bash
git clone https://github.com/hamr0/privcloud.git
cd privcloud
./privcloud
```

That's it. You get a menu:

```
privcloud v0.1.0 — self-hosted photo backup

  1) install   Check prerequisites, pull images, set up config
  2) start     Start privcloud
  3) stop      Stop privcloud
  4) status    Show what's running
  5) config    Change photo storage location
  6) doctor    Diagnose issues
  0) exit

Choose [1-6]:
```

Run `install` first, then `start`. Open http://localhost:2283, create your account, connect the Immich iPhone app.

Commands also work directly: `./privcloud start`, `./privcloud stop`, etc.

## How It Works

1. `privcloud start` — spins up Immich (photo server, face recognition ML, database)
2. Open Immich app on iPhone — photos sync over WiFi to your storage
3. Browse, search, organize in the web UI
4. `privcloud stop` when done — photos stay on disk

No always-on server needed. Run it when you want to backup, shut it down when done.

## Requirements

- Docker + Docker Compose
- ~4 GB RAM when running
- Storage for your photos (local drive, external HDD, whatever)

## Platforms

Works on Linux, macOS, and WSL. The `privcloud` script handles platform differences (SELinux on Fedora, Docker Desktop on Mac, etc).

## iPhone Setup

1. Install **Immich** from the App Store
2. Server URL: `http://<your-computer-ip>:2283` (shown by `privcloud start`)
3. Login with the account you created in the web UI
4. Enable auto backup in app settings
5. Both devices must be on the same WiFi

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
