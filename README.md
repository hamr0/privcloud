# privcloud

Self-hosted photo backup. Own your photos, no cloud subscriptions.

## What

A local photo backup solution using [Immich](https://immich.app/) — an open-source Google Photos alternative with face recognition, smart search, and a proper mobile app.

Runs on-demand from your laptop via Docker. No always-on server needed.

## Why

- iPhone keeps pushing iCloud storage upgrades
- Google Photos strips metadata and has storage limits
- Your photos should live on YOUR storage

## How It Works

1. Plug in external HDD
2. `docker compose up -d` — starts Immich
3. Open Immich app on iPhone — photos sync over WiFi
4. Browse, organize, clean up in web UI at `localhost:2283`
5. `docker compose down` when done

## Setup

### Prerequisites

- Docker and Docker Compose installed
- External HDD (or any storage you want photos on)
- iPhone with Immich app from App Store

### Quick Start

```bash
# Clone this repo
git clone <repo-url> && cd privcloud

# Set your storage path in .env
cp .env.example .env
# Edit UPLOAD_LOCATION to point to your external HDD

# Start
docker compose up -d

# Open http://localhost:2283
# Create account, download Immich iOS app, connect to your server
```

### Stopping

```bash
docker compose down
```

Photos and database persist between sessions. Just `docker compose up -d` again next time.

## Features (via Immich)

- **Face recognition** — auto-detects and groups faces
- **Smart search** — search by content ("beach", "birthday")
- **Duplicate detection** — find and clean up duplicates
- **Map view** — see where photos were taken
- **Timeline** — browse by date
- **Albums** — auto-created and manual
- **Metadata preserved** — EXIF data stays intact

## Hardware Tinkering (ESP32)

See [next-project-ideas.md](./next-project-ideas.md) for ESP32 board research, purchase recommendations, and project ideas.

## License

MIT
