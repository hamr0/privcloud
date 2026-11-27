---
title: Single-source consolidation plan
slug: spec-single-source
description: Findings inventory by priority, quick wins and the decisions log; the entry page for the plan
sources:
  - docs/archive/spec-single-source.md
---

# Single-source consolidation plan

Entry page for the plan. It lists every finding by priority, the first piece of work (quick wins) and the open decisions. Source: `docs/archive/spec-single-source.md`.

## How findings are classified

Kinds: 1 = same job in several places, 2 = helper re-implemented, 3 = generated file with patchers, 4 = generated file freezing a runtime value, 5 = list/constant/prose written many times (docs/archive/spec-single-source.md:13-14). "QW/4" means the quick win closes the visible failure and piece 4 does the structural fix (docs/archive/spec-single-source.md:15).

## P1: wrong result today or code-proven (8)

(docs/archive/spec-single-source.md:17-28)

- **D1** (kind 3, piece 2): sync job script patchers. Failed syncs were logged `last: ok`, and a hand-edited rsync line reports "now mirror" while staying append-only (docs/archive/spec-single-source.md:21).
- **D2** (kind 3, piece 2): sync job registry. A job named `my.photos` is invisible to Edit, Delete and Status (docs/archive/spec-single-source.md:22).
- **D5** (kind 3, QW + 5): `.env` readers and writers. `privcloud config` rewrites `.env` with 6 keys and drops `MEDIA/MUSIC/FILES_LOCATION`, so the next `up` mounts an empty path; code-proven, not run live (docs/archive/spec-single-source.md:23).
- **D6** (kind 4, piece 2): job scripts bake the server user and IP and use plain ssh. A job created on the LAN address blocks and exits 255 while roaming; unattended `sudo mkdir` needs a TTY. Both UNVERIFIED live (docs/archive/spec-single-source.md:24).
- **D7** (kind 4, piece 3): other generated artifacts bake runtime values. After moving Immich storage the scheduled backup keeps the old `UPLOAD_LOCATION` (docs/archive/spec-single-source.md:25).
- **D8** (kind 1, piece 1): the "path must sit on a real /dev/* mount" check and drive-roots lists disagree between copies, so a stub or bare folder reads "ok" (docs/archive/spec-single-source.md:26).
- **D9** (kind 1, QW + 4): dead `_services_action` vs live `_unified_service_picker`. The data-mount start guard exists only in dead code, so the stub-mount incident is still reachable from `federver -> 7 -> Start` (docs/archive/spec-single-source.md:27).
- **D14** (kind 1, piece 3): `immich-backup.sh` vs `privcloud cmd_backup_once`. The one-time backup lacks the excludes, uses a different layout and runs an unguarded `rsync --delete` (docs/archive/spec-single-source.md:28).

## P2: maintenance drift (15)

(docs/archive/spec-single-source.md:30-48)

| id | kind | topic | piece | source |
|---|---|---|---|---|
| D3 | 3 | `BACKUP_DIR` with `\|`, `&` or `\` mangled by the sed delimiter (UNVERIFIED) | 3 | (docs/archive/spec-single-source.md:34) |
| D4 | 3 | `patch_selinux` can leave tracked docker-compose.yml dirty, so `git pull --ff-only` fails (UNVERIFIED) | 5 | (docs/archive/spec-single-source.md:35) |
| D10 | 1 | container rows and URL list differ slightly; no wrong output | 4 | (docs/archive/spec-single-source.md:36) |
| D11 | 1 | server-side Status shows only `/`, `/home`, `/mnt/data`; USB drive vanishes | 4 | (docs/archive/spec-single-source.md:37) |
| D12 | 1 | `-s` exists only on the recurring copy path | 2 (part) | (docs/archive/spec-single-source.md:38) |
| D13 | 1 | delete-a-job exists twice; only success wording differs | 2 | (docs/archive/spec-single-source.md:39) |
| D16 | 1 | new `/mnt/...` path answered while unmounted is created on the system disk (UNVERIFIED) | 8 (guard from 1) | (docs/archive/spec-single-source.md:40) |
| D18 | 1 | six uninstallers each had the "printed removed, nothing removed" bug | 6 | (docs/archive/spec-single-source.md:41) |
| D19 | 2 | only two of 14 probes tell "query failed" from "absent" | 4 | (docs/archive/spec-single-source.md:42) |
| D20 | 2 | legacy `immich-db` cron line shown and removed by Status/Remove but left by Set up (UNVERIFIED) | 3 | (docs/archive/spec-single-source.md:43) |
| D21 | 2 | firewall add paths ignore failure, remove paths verify | 6 | (docs/archive/spec-single-source.md:44) |
| D22 | 2 | download sudo flow shows one generic message on bad password | 6 | (docs/archive/spec-single-source.md:45) |
| D23 | 2 | rsync bypasses the `ssh()` wrapper, so an unreachable address hangs (UNVERIFIED) | 2 | (docs/archive/spec-single-source.md:46) |
| D29 | 5 | stale menu numbers in prose; Syncthing runbook points at the Immich backup menu | QW + 7 | (docs/archive/spec-single-source.md:47) |
| D30 | 5 | service lists; a new standalone container is missing from Emergency until edited | 4 | (docs/archive/spec-single-source.md:48) |

## P3: cosmetic / scaffolding (10)

(docs/archive/spec-single-source.md:50-63)

- No failure seen: D15 (path pickers, piece 8), D17 (Syncthing path logic, piece 8), D24 (confirm prompts, piece 6), D25 (state vocabulary, piece 4), D27 (test scaffolding, piece 0), D28 (service URL blocks, piece 4), D32 (disk-check constants, piece 7) (docs/archive/spec-single-source.md:54-62).
- D26 (helper copies, piece 8): partly harmful; the two version fallbacks differ and `keep_autostart` has no read-back (docs/archive/spec-single-source.md:58).
- D31 (`declare -f` payload lists, piece 7): a helper gaining a dependency breaks only the remote call (docs/archive/spec-single-source.md:61).
- D33 (data-path defaults, piece 5): reachable only when `.env` lacks the key (docs/archive/spec-single-source.md:63).

## Looks similar, out of scope

No evidence of harm for: the `_ts_*_both` and `_syncthing_*_both` lifecycles, the wireguard/adguard/remotedesktop install flows, the two schedule pickers, the user vs system timer units, `sudo -v` guards, `step_docker` vs `ensure_docker`, and `sudo sed -i` of /etc config (docs/archive/spec-single-source.md:65-75).

## Piece QW: quick wins

Closes the D9 guard, the D5 `privcloud config` write and the D29 wrong numbers. It goes first, and each fix is its own small commit with its test (docs/archive/spec-single-source.md:78-81).

- **D9 guard.** `_services_action` guards Start of navidrome, filebrowser and All with `_require_data_mount`; `_unified_service_picker` has none. This is drift, not intent (docs/archive/spec-single-source.md:85-86). The guard arrived in 170ba69 inside `_services_action` only (docs/archive/spec-single-source.md:88). Change: call `_require_data_mount` from the picker before single-container start and before the All compose-up; removing the dead code is piece 4 (docs/archive/spec-single-source.md:89).
- **D5 config.** `cmd_config` writes `.env` with `cat >`, dropping MEDIA/MUSIC/FILES_LOCATION that docker-compose.yml consumes (docs/archive/spec-single-source.md:93-94). Change: a key-updating `env_set KEY VAL` (literal match, awk, creating `.env` from `.env.example` when absent), updating only the asked keys (docs/archive/spec-single-source.md:95).
- **D29 numbers.** Four strings are wrong: "steps 3-11" vs "Run all (3-7)", "option 14" vs option 12 for Syncthing, `federver -> 14 -> 6` in customer-guide.md, and `cd federver` vs the `privcloud` directory (docs/archive/spec-single-source.md:99-102). Piece 7 removes the cause (docs/archive/spec-single-source.md:103).

Tests: a picker test with a failing stubbed mount check must show no `docker start`/`compose up`; a `cmd_config` test on a fixture `.env` must keep FILES/MEDIA/MUSIC keys. Each must fail first against unfixed code (docs/archive/spec-single-source.md:107). Nothing covers the picker, `_require_data_mount` or `cmd_config` today (docs/archive/spec-single-source.md:108). Size S, risk low (docs/archive/spec-single-source.md:109).

Acceptance (docs/archive/spec-single-source.md:110-113):

- `federver -> 7` Start (single and All) refuses an unmounted data drive.
- `privcloud config` leaves every key it did not ask for byte-identical.
- The four strings point at existing menu items.

## Decisions log

All open until the user decides (docs/archive/spec-single-source.md:560-562).

1. **rsync exit 24 in sync jobs.** Option A (recommended): success with note, `last: ok (some files vanished)`. Option B: failure, `last: failed (exit 24)` (docs/archive/spec-single-source.md:564-569). Before d57409f every failure logged as 0, so 24 becomes visible for the first time; B is safer for mirror jobs; either is a single `case` line (docs/archive/spec-single-source.md:571).
2. **Legacy job scripts re-render.** Option A (recommended): on first Status view with a one-line notice. Option B: on first edit only, so untouched jobs keep logging `last: ok` for failures (docs/archive/spec-single-source.md:573-578). A Status view that writes needs the atomic write and `.bak` (docs/archive/spec-single-source.md:580).
3. **Piece 8, shared `lib/common.sh`.** Option A: yes, one definition, at the cost of a sourced file and wrapper path resolution. Option B: no, copies stay (docs/archive/spec-single-source.md:582-587). Real drift is only the version fallback and autostart read-back; "lightweight" weighs against, "one source" for; piece 5 assumes at least `lib/env.sh` (docs/archive/spec-single-source.md:589).
4. **`privcloud config` on a server.** Option A (recommended): keep, update only its own keys via `env_set`. Option B: remove in favour of `federver -> 11` (docs/archive/spec-single-source.md:591-596). QW ships option A either way (docs/archive/spec-single-source.md:598).
