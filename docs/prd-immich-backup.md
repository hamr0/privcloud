# PRD: Immich backup — one-time + scheduled, no downtime (`privcloud` → 9)

Status: **Shipped (v0.9.0).**

## Goal

Give a user one place to protect their Immich library — both an on-demand copy and a
recurring automatic one — with:

- **no downtime** (the stack never has to stop to take a backup),
- a choice of **what** to back up (photos, database, or both), and
- **one** schedule across the whole project, not two competing ones.

## Background — the problem

The old `privcloud` → 9 always did the same thing: it ran `docker compose down`, cold-copied
the Postgres **data directory** plus the photos to an external drive, then restarted. Two
issues:

1. **It took the whole stack offline** for the duration of the copy — minutes to hours for a
   large library — which is unacceptable for a server the household actually uses.
2. **There was no scheduling.** Recurring backups existed only in `federver`
   (`step_immich_backup`), and that timer dumped **only the database** — photos were left to a
   separate sync. So "do I have an automatic backup?" had a confusing, split answer.

Meanwhile the one-time flow always copied *both* photos and DB with no way to grab just one.

## Options considered

- **A — Stop-and-copy, but add a scheduler.** Keep the cold data-dir copy; wrap it in a timer.
  Rejected: bakes the downtime into an *unattended* job — the stack would vanish at 3am.
- **B — No-downtime: live `rsync` + online `pg_dump`.** Photos are write-once originals, safe to
  `rsync` live; `pg_dumpall` is transactionally consistent, so the DB dumps cleanly while
  running. Neither step stops anything. **Chosen.**
- **C — Two separate features** (keep `privcloud` one-time and `federver` scheduled fully apart).
  Rejected: that's the split-brain we're trying to remove; users would configure two schedules.

## Decision

**Option B, with a two-way menu and a single shared schedule.**

```
privcloud → 9  Backup
  1) One time   — copy photos + database to a drive now
  2) Scheduled  — recurring automatic backup (systemd timer, no downtime)
```

### One time

```
What to back up:
  1) Both — photos + database (default)
  2) Photos only
  3) Database only
```

- **Photos** → live `rsync` of `UPLOAD_LOCATION` (Append vs Mirror, with the destination tree
  preview from [prd-backup-sync-ux](prd-backup-sync-ux.md)).
- **Database** → **online** `pg_dumpall | gzip` → `immich-db-<ts>.sql.gz` while the container
  runs. If Immich happens to be **stopped**, it falls back to a cold data-dir copy (safe), and
  refuses to cold-copy while containers are up (would be corrupt).
- The restore hint **adapts** to the DB method used (load the SQL dump via `psql`, or copy the
  `postgres/` dir back).

### Scheduled

The `Scheduled` option **hands off to `federver`'s `step_immich_backup`**
(`bash setup.sh --run step_immich_backup`) rather than re-implementing it. That step owns the
shared artifacts — `immich-backup.timer` / `.service` and `/usr/local/bin/immich-backup.sh` — so
the `privcloud` menu and the `federver` main menu drive **one** schedule (single source of
truth). Each run is **full** (database + photos), no downtime:

- Everything lands under `<dest>/immich/` so the destination can hold other backups too.
- DB → `pg_dumpall | gzip` into `<dest>/immich/db/`, rotated by the retention window
  (7 days daily / 21 days weekly).
- Photos → live `rsync` into `<dest>/immich/photos/`, **append-only** (never `--delete`) so an
  unattended job can't propagate an accidental deletion.
- Robustness inherited from the timer: `Persistent=true` catches up missed runs; 3 retries
  30 min apart on failure; logs to `/var/log/immich-backup.log` (final `Backup complete` line is
  what the `federver` status screen parses).
- **First run is immediate.** `enable --now` only starts the *timer* (it wouldn't fire until the
  next tick, and `Persistent=true` only catches up a tick missed during downtime — never an
  initial run). So after setup it offers to run once now via `systemctl start --no-block` —
  confirming it works and seeding the backup, detached so it survives an SSH disconnect.

### Managing it

Both `privcloud` → 9 → 2 **and** `federver` → 14 → 6 open the same submenu (`step_immich_backup_menu`
in `setup.sh`), not a one-shot: **Set up / change**, **Status** (schedule + next/last run, a clean
recent-runs table — `✓ ran` / `✗ failed` per run, no log dump — and a table of the server's
scheduled jobs so it's clear which is which), **Run now** (background), and **Remove** (deletes timer/service/script via
`_immich_backup_remove`, **leaving backup files intact**). The submenu and its actions all live in
`setup.sh` so both entry points are identical and single-source. The interactive `privcloud` menu
loops, so `0) Back` steps up a level rather than exiting.

### Destination

Defaults to a **real external drive**: `_pick_backup_default` auto-detects the mounted removable
drive (`/run/media/*/*`, `/media/*/*`, `/mnt/*`) with the most free space that isn't on the same
filesystem as the photos. If the chosen destination shares a disk with the source, it warns that
a single failure loses both copies and asks to confirm.

## Key properties (verified)

- **Zero downtime.** No `compose down` in either path; both `pg_dumpall` and the photo `rsync`
  run against the live stack.
- **Single schedule.** Configuring from either menu writes the same units — no double-runs.
- **Append-only scheduled photos.** Deleting a photo on the server does not delete the backup
  copy on the next run.
- **Status unchanged.** The shared script keeps the exact `Backup complete` success phrase, so
  `federver`'s Last-runs table renders without changes.

## Security (v0.9.0, alongside this feature)

- `.env` (holds `DB_PASSWORD`) is written `chmod 600` on install; backup copies of it were
  already owner-only.
- Server-side paths in the sync/backup SSH calls are quoted with `_shq` (`printf %q`) to stop a
  path with spaces/quotes from breaking or injecting into the remote command.

## Out of scope / future

- **Photo retention/rotation.** Photos are kept as a single live mirror; only DB dumps rotate.
  Versioned photo snapshots (e.g. dated hardlink trees) are a possible follow-up.
- **Off-site / cloud targets.** Destinations are local/USB drives only.
- **One-time scheduled photos as Mirror.** The unattended job is deliberately append-only; a
  Mirror schedule (with safeguards) is not offered.
- **Args-not-strings refactor** of the scheduled-sync command builders in `setup.sh` (they run
  through `bash -c` / generated scripts, so they need more than single-parse quoting).
