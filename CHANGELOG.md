# Changelog

## Unreleased

### Added

### Changed

### Fixed

## v0.3.0 — 2026-04-16

### Changed
- **Service Stop/Start simplified (`federver` → 7, 14).** Collapsed Stop/Suspend/Resume into two actions: Stop (`docker update --restart=no` + `docker stop` — stays off across reboots) and Start (`docker update --restart=unless-stopped` + `docker start` — stays running across reboots). Restart just bounces the container without changing restart policy. Applies to Manage services submenu and Syncthing submenu. Removes the separate Suspend/Resume menu entries — Stop and Start now handle restart-policy management automatically.
- **Manage sync replaces Sync files (`federver` → 16).** Menu label, README, and customer guide updated to reflect the expanded scope: one-shot transfers, scheduled cron jobs, and file deletion.
- **AdGuard install (`federver` → 12)** three big UX fixes:
  - **No more port-3000 wizard detour.** The install pre-seeds a minimal `/opt/adguard/conf/AdGuardHome.yaml` that sets `http.address: 0.0.0.0:80` and nothing else. AdGuard's native first-run wizard then runs on port 80 directly (instead of its hardcoded 3000 default), so the user opens `http://<server-ip>` in a browser, clicks through AdGuard's own setup wizard there, and is done. No firewall shuffle for port 3000, no credentials collected in the terminal, no `htpasswd` / bcrypt dependency. Keeps all of AdGuard's defaults (DNS upstreams, filter lists, etc.) because AdGuard's wizard sets them itself.
  - **systemd-resolved cleanup now explains itself.** Previously ran silently — scary if you have a custom DNS setup. Now prints a yellow block describing exactly what will change (drop-in file path, `resolv.conf` symlink, `systemd-resolved` restart), notes that local name resolution still works, and asks `Disable the stub listener and continue? [Y/n]` before touching anything. Cancel path is safe — no changes made.
  - **Tailscale is pre-checked, not post-checked.** Previously the "install Tailscale" warning only appeared at the *end* of the install, after the system was already changed. Now the step detects Tailscale up front and, if missing, offers `1) Cancel and install Tailscale first (recommended)`, `2) Continue anyway (manual per-device DNS)`, `0) Cancel`. No wasted work for users who hit the step before installing Tailscale. Re-running the step when AdGuard is already up also prints the Tailscale DNS guide if Tailscale is detected, so you can still get to the admin-console instructions without a fresh install.
  - Tailscale DNS guidance wording corrected to match the actual admin UI (**DNS tab → Nameservers → Global nameservers → Add nameserver → Custom**, then toggle **Override local DNS** after saving).
- **Status screen (`s`)** rewritten for triage-first reading order. Dropped the Management section (boilerplate commands that never change). Added a Server block with uptime and 1/5/15m load average, a Memory block with RAM used/total/available and Swap when non-zero, a Disk block split into **Internal** and **USB** sub-sections (so you can see at a glance which drive is cold-backup-candidate), and per-container CPU% and memory usage next to each container line (from `docker stats --no-stream`). Sections ordered Server → Memory → Disk → Containers → Service URLs → Data paths — identity, resources, processes, endpoints, storage. Service URLs now also include AdGuard and Syncthing when those containers are up. Container-row classification fixed: containers without a Docker `HEALTHCHECK` (AdGuard, Syncthing) used to get a yellow `!!` because the status string didn't contain `healthy`; now a plain `Up X` counts as OK (`✓`), only `unhealthy`/`exit`/`restart` states flag as failure.
- **Auto-routing refinements.** `_on_laptop` failure now prints an actionable message listing the three laptop-only steps (Sync files / Save to pass / SSH key auth) and their reasons, plus the exact `exit` + `cd` + `./setup.sh` commands. `step_power` (`p`) no longer SSH-hops when already on the server — runs `sudo shutdown`/`sudo reboot` locally. `step_ssh` (step 1) gains an `SSH_CLIENT`/`SSH_CONNECTION` guard so running the bootstrap step inside an SSH session fails fast with "SSH already works, skip to step 2", plus a heuristic guard against running it on a known laptop hostname (while still allowing fresh-install defaults like `fedora` / `localhost*`).
- **WireGuard submenu (`federver` → 11)** gains a Status-first option (`1) Status`) that runs `sudo wg show wg0` and prints the interface state, listen port, and per-peer handshake timestamps, endpoints, and rx/tx bytes. Matches the Status-first pattern of the Tailscale, Services, and Storage submenus. Also removed a stray `clear` in the Linux-peer setup flow that was wiping scrollback of the peer config you had just copied.
- **Disk-check monitor (`federver` → 8)** made smoother to set up. Cron cadence dropped from hourly to every 5 minutes so Kuma sees a pulse well before the interval expires. The step now also fires the disk-check script once immediately after installing it, so the Kuma monitor turns green right away instead of waiting for the first cron tick. The wizard tells you the exact values to paste into Kuma's monitor form (Heartbeat Interval 360, Retry Interval 60, Max Retries 2) so a fresh setup no longer needs a "why is this red?" debugging round. Re-running step 8 drops any existing disk-check cron line before re-adding it, so old hourly installs migrate cleanly.
- **Storage status display (`federver` → 13 → 1)** reorganised around the `data / media / immich` mental model. Previously listed four cryptic rows (Files / Music / Immich / Database) and showed red `not set` when a path was unset in `.env` — even though the container might be running fine off a Docker volume. Now it falls back to `docker inspect` and reports the actual mount source — a real host path when bind-mounted, `(Docker volume: <name>)` or `(Docker anonymous volume)` when not. No more alarming "not set" rows on a working system.

### Added
- **Uninstall actions on every Extras submenu** (`federver` → 10 Tailscale, 11 WireGuard, 12 AdGuard, 14 Syncthing, 15 Remote desktop). Each has a red `DELETE <service>` block listing exactly what will happen, what breaks afterwards, and what's kept. Confirmation requires **typing the literal service name** (`adguard`, `syncthing`, `tailscale`, `wireguard`, or `xrdp`) — blank Enter cancels cleanly. Stops + removes the container/service, closes only the firewall ports that service opened, reverts service-specific system changes (AdGuard: re-enables the systemd-resolved stub listener; RDP: re-enables lightdm), and keeps `/opt/<service>` and `/etc/wireguard/` config directories intact so a reinstall picks up where you left off. Core privcloud services are never touched.
- **Manage services (`federver` → 7) lifecycle is now per-container.** Start, Stop, Restart, Suspend, and Resume each show a numbered list of containers with "All" as option 0 — pick one or everything. Suspend = `docker update --restart=no` + stop (stays down across reboots until resumed). Resume = `docker update --restart=unless-stopped` + start. Submenu goes from 6 entries to 9 without losing the old Start/Stop/Restart all behaviour, now accessed via "All" in the picker.
- **Manage Syncthing** option (`federver` → `14`). Real-time bidirectional folder sync between devices, peer-to-peer. When run from the laptop, the step installs + configures *both sides in one shot*: laptop gets `sudo dnf install -y syncthing` + `systemctl --user enable --now syncthing`, then the step SSHes to the server and launches `syncthing/syncthing:latest` as a Docker container with `--network=host`, `--restart=unless-stopped`, `STGUIADDRESS=0.0.0.0:8384` (so the web UI is LAN-reachable — default binds to 127.0.0.1 which is useless with host networking). Firewall opens 8384/tcp, 22000/tcp+udp, 21027/udp. Reads `.env` via a safe parser and bind-mounts the three semantic privcloud paths — `data` (FILES_LOCATION), `media` (MEDIA_LOCATION), `immich` (parent of UPLOAD_LOCATION) — each at the same host path inside the container, so the UI's *Add Folder* dialog shows real disk paths with no mental remapping. Reads both Device IDs (laptop + server) and prints them for pairing. Robust against the Syncthing 2.x CLI restructure (old `--device-id` flag was removed) — the helper tries several command shapes and falls back to reading `config.xml` directly. Re-running once installed opens a submenu: refresh status, show Device ID, show sync paths, reapply paths from .env (rebuilds the container with fresh mounts while keeping pairings + folder shares intact), start, stop, restart, logs. Tools menu renumbered: Sync files 15→16, Save to pass 16→17. Remote desktop 14→15.
- **Save to pass** now also captures the Syncthing identity: device ID (under `privcloud/syncthing/device_id`), `config.xml` (folder shares, peer list, GUI credentials), and the `cert.pem` + `key.pem` pair that IS the node's cryptographic identity. Losing cert/key means re-pairing every client, so these are critical to back up. Status screen and `7 Manage services → Status` now also list Syncthing under Service URLs (local + Tailscale) when the container is running, matching the existing AdGuard conditional.
- **Tailscale laptop auto-install.** `federver → 10` now mirrors the Syncthing two-sided pattern: when run from the laptop, it `sudo dnf install`s Tailscale + enables `tailscaled` locally, runs `sudo tailscale up` (auth URL appears in the terminal, click + approve), then SSHes to the server for the server-side install. Phones and non-Fedora systems still get the existing informational pointers — they can't be automated from here.
- **Stale-checkout guardrail** in the `--run` CLI dispatcher. When the laptop's setup.sh adds a new step function and the server's checkout hasn't been pulled yet, the `_on_server` SSH hop used to fall through to bash's cryptic "command not found" trace. The dispatcher now checks `declare -F` for the requested step name first and, if the function isn't defined, prints an actionable message telling the user to `cd ~/privcloud && git pull` on the server and re-run the menu option.
- **`_env_get` safe reader** for `.env` values. Shell's built-in `source` splits on whitespace and chokes on unquoted values with spaces (e.g. `MUSIC_LOCATION=/mnt/data/media/My Music` → `Music: command not found`). The new reader greps one line, strips optional surrounding quotes, and preserves spaces verbatim. Used by the Syncthing helpers; other `source .env` callsites stay as-is since they only read vars that don't contain spaces in practice.
- **`./setup.sh --dry-run`** mode. Walks the full menu and prints each state-changing command (`sudo ...`, `sg docker ...`, `curl ...`, `rsync ...`, `tailscale up|down`) instead of executing it. Read-only queries (hostname, `tailscale ip`, `docker ps`) still run so the display logic works. The dry-run flag propagates across the `_on_server` SSH hop, so running `./setup.sh --dry-run` from the laptop still gives you a safe walkthrough of any server-side option. Menu header shows a "DRY RUN" banner whenever active.
- **`federver` → 7 → 1 (Services status)** now also shows the Tailscale / MagicDNS URL list alongside the LAN URL list when Tailscale is up. Fixes the missing `http://federver:PORT` addresses that used to only appear in the top-level Status screen.
- **Immich `i` letter shortcut** in the `federver` main menu. Opens the `privcloud` CLI directly (via SSH when run from the laptop). Replaces the static "Run: privcloud ..." note that previously sat under the Immich section — now it's an actual menu action like `s`, `p`, `r`.
- **`federver` → 6 (Manage firewall)** gains list/status/add/remove/defaults submenu. Previously a single "configure firewall" action that re-applied a hard-coded set. Now you can open/close arbitrary ports or services without editing the script.
- **`federver` → 7 (Manage services)** gains status/start/stop/restart/logs/redeploy submenu covering every Docker container (Immich + Navidrome + FileBrowser + Uptime Kuma + Watchtower + AdGuard). Deploy is option 6 in the submenu, still the fresh-install flow.
- **`federver` → 10 (Manage Tailscale)** detects existing installs and opens a status/up/down/re-auth submenu. Fresh installs still run the original guided flow. Shows the current tailnet IP, MagicDNS hostname, and peer list.
- **`save to pass`** now also saves `/opt/adguard/conf/AdGuardHome.yaml` under `privcloud/adguard/config`. Preserves the AdGuard admin user + bcrypt password hash, custom filter lists, and client settings across restores.
- **Install AdGuard Home** option (`federver` → `12`). Network-wide DNS ad/tracker blocker as a standalone Docker container with `--network=host`, `--restart=unless-stopped`, and persistent volumes under `/opt/adguard`. Handles the systemd-resolved stub-listener conflict on port 53 automatically (drops `DNSStubListener=no` into a `resolved.conf.d` override), opens the firewall for 53/udp, 53/tcp, 80/tcp, walks the user through the manual setup wizard on port 3000, then closes 3000 once the admin UI moves to port 80. Detects Tailscale and prints exact click-by-click steps to set the tailnet global nameserver to federver's tailnet IP with "Override local DNS" on — the one routing path that reliably covers laptops + iPhones at home and roaming. (Ziggo Connect Box DHCP DNS overrides, manual per-device DNS on Linux, and iOS Wi-Fi DNS overrides were all evaluated and rejected — Ziggo firmware rejects LAN IPs, Linux leaks via IPv6 router advertisements, iOS bypasses via Private Relay.)
- WireGuard **Remove peer** option in `setup.sh` → `11`. Lists current peers by name, pick a number, confirms, deletes the `[Peer]` block from `wg0.conf` and the client `.conf`, then hot-reloads. Closes the gap where revoking a lost device required a full reinstall.
- Storage: separate **Change Immich location** option (`federver` → `13` → `6`). Immich paths are now independent from FileBrowser and Navidrome — changing one never affects the others.
- **Reset password** option (`federver` → `r`). Resets credentials for FileBrowser, Immich, Navidrome, or Uptime Kuma. FileBrowser and Immich reset password only (data kept). Navidrome and Uptime Kuma wipe data and restart fresh.
- New `MUSIC_LOCATION` env var for Navidrome music library path.

### Changed
- **Menu: existing entries absorbed new capabilities instead of adding top-level options.** Rather than growing the main menu with separate "manage docker", "manage firewall", "manage tailscale" entries, each existing option now opens a submenu when re-run. Follows the same pattern `11 Install WireGuard` and `13 Manage storage` already used. Top menu stays the same size; functionality roughly triples.
- **Location-aware routing.** Every menu option now runs on the right machine automatically. Server commands (3–15, r, a) SSH into the server when run from the laptop. Laptop commands (2, 16, 17, p) warn if run from the server. Status works from both. No more "wrong machine" mistakes.
- Menu header shows **Running from: laptop** or **Running from: server** based on hostname.
- Status fetches server data via SSH when run from the laptop — shows real hostname, IPs, data paths, containers, and disk instead of laptop info.
- Tailscale URLs now use `federver` hostname (MagicDNS) instead of raw IPs everywhere — status, deploy, remote desktop, docs.
- Navidrome music volume no longer mounted read-only — allows playlist management via `.m3u8` files.
- File sync (`federver` → `15`) redesigned: accepts files and directories, strips quotes and trailing slashes, copy folder vs contents mode, delete option for laptop or server, cancel at every step, 3-attempt retry on invalid input. Uses `ssh -t` + `chown` for server permissions instead of `sudo rsync`.
- Replaced Jellyfin with Navidrome for music streaming. Navidrome is lighter, supports background playback and offline caching via Subsonic-compatible apps (recommended: Amperfy on iOS).
- WireGuard add/remove now hot-reload via `wg syncconf` instead of `systemctl restart wg-quick@wg0`. Other connected peers stay up during config changes (previously every peer dropped for a few seconds on every add). Falls back to restart if `wg syncconf` is unavailable.
- Storage menu split into three path options: music (Navidrome), data (FileBrowser), Immich. Previously "Change media location" controlled both Jellyfin and FileBrowser, and there was no separate Immich option.

### Removed
- Jellyfin media server. Videos can be played by downloading from FileBrowser and opening in VLC.

### Fixed
- Power management (`federver` → `p`) now runs shutdown/reboot over SSH on the server instead of locally. Previously would shut down the laptop if run from there.
- USB drive detection now finds partitions on USB disks, not just the parent device. Fixes status/mount/unmount showing "none detected" when drives were plugged in.

### Security
- FileBrowser admin password is now randomly generated per-deploy (16-char) and saved to `~/.privcloud/filebrowser.pass` (mode 0600). Removes the hardcoded `privcloud` credential that was published in README and customer-guide.
- `dnf-automatic` now applies **security updates only**, with kernel packages explicitly excluded (`kernel`, `kernel-core`, `kernel-modules*`, `kernel-devel`, `kernel-headers`). A headless home server should never auto-reboot into an untested kernel while the owner is away. Update kernels manually with `sudo dnf upgrade kernel` + reboot when you're home.

## v0.2.1 — 2026-04-06

### Added
- Save to pass (option 15) — backs up all server config to `pass` password manager
  - Runs from laptop, SSHes into server to fetch data
  - Saves: hostname, local IP, Tailscale IP, SSH keys, service URLs, .env, docker-compose.yml, WireGuard configs
  - All entries overwritten on each save (idempotent)

### Changed
- Option 12 "Mount USB drive" replaced with "Manage storage" sub-menu:
  - Status: shows drives, mounts, current paths, disk usage
  - Mount USB: auto-detects USB drives (filters by TRAN=usb, no guessing)
  - Unmount USB: safely unmount and remove from fstab
  - Change media location: updates Jellyfin, redeploys
  - Change data location: updates Immich photo/DB paths, redeploys
- FileBrowser mounts `FILES_LOCATION` (base data path) — browse media, files, and immich
- Jellyfin mounts `MEDIA_LOCATION` only — media files only
- Replaced `DATA_ROOT` with `FILES_LOCATION` in .env
- Status display: separated media path from Immich paths
- FileBrowser password auto-set to `privcloud` during deploy (no more random passwords)
- Deploy no longer sets unused `DATA_ROOT`

### Fixed
- Jellyfin `:ro` flag removed from media mount
- FileBrowser upload now works (correct ownership on media dir)
- FileBrowser password no longer lost on container recreate

## v0.2.0 — 2026-04-05

### Added
- `setup.sh` — full server setup menu (`federver` command)
  - SSH, auto-login, hostname setup
  - SSH key auth (copies key, disables password login)
  - System update and auto-updates (dnf5)
  - Docker installation
  - Firewall (local ports + Tailscale trusted)
  - Tailscale remote access with guided setup
  - USB drive mount (permanent via fstab)
  - Service deployment (Immich, Navidrome, FileBrowser, Watchtower, Uptime Kuma)
  - WireGuard VPN (iptables NAT, auto key gen, QR codes, device-specific instructions, add/show peers)
  - Remote desktop via xrdp (disables local display, RDP from any device)
  - Daily Immich DB backup (cron at 3am)
  - Hourly disk space monitoring with Uptime Kuma push alerts (above 85%)
  - Docker log rotation
  - File sync between laptop and server (upload/download)
  - Status dashboard (URLs, IPs, containers, disk)
  - Power management (shutdown/restart)
- `fedvpn` — WireGuard client CLI for laptop (setup/start/stop/status, IPv6 leak fix)
- Jellyfin, FileBrowser, Watchtower, Uptime Kuma v2 in docker-compose.yml
- `privcloud status` now shows container health and recent errors
- Colored output with success/fail banners
- `federver` and `privcloud` commands available globally
- Reorganized menu: Initial setup (1-5), Services (6-9), Extras (10-13), Tools (14)

### Fixed
- WireGuard: use iptables with detected interface instead of firewall-cmd (NAT routing)
- WireGuard: use local IP as endpoint (Tailscale IP creates routing loops)
- fedvpn: disable IPv6 on connect to prevent tunnel bypass
- fedvpn: use sudo for config file checks (root-owned)
- Uptime Kuma: use server IP not localhost in monitors (Docker networking)
- FileBrowser: read generated password from docker logs
- Postgres permissions: document never to chown postgres directory

## v0.1.0 — 2026-03-06

### Added
- Interactive CLI menu (`./privcloud`)
- `install` — checks Docker, Docker Compose, pulls Immich images, sets up storage
- `start` — starts all containers, waits for API, shows connection URLs
- `stop` — stops containers, shuts down Docker daemon if nothing else running
- `status` — full diagnostics (system, docker, storage, containers, network)
- `config` — change photo storage location
- Auto-detect and patch SELinux volume flags (Fedora/RHEL)
- Auto-fix Docker group permissions (Linux)
- Auto-start Docker daemon via sudo/pkexec
- Auto-generate database credentials on first install
- Docker Compose setup for Immich (server, ML, Redis, PostgreSQL)
- Works on Linux, macOS, and WSL
