# PRD: Opt-in mirror mode for sync jobs and one-time backups (`federver` → 14)

Status: **Built on `feat/smb-share`, not yet merged.**

## Goal

Let a copy follow the source exactly — files deleted at the source are deleted at the
destination — for people who curate at the source and expect every copy to match, without
ever making that destructive behaviour the default or a surprise.

## Background — the problem

Every rsync transfer in `federver → 14` ran `rsync -avh` without `--delete`: add and
overwrite only. A file removed at the source stayed at the destination forever, so a
"backup" of a curated folder slowly diverged from it (old mixes, renamed albums, junk the
user had already cleaned up). The user's workflow is "update at the source, copies follow",
and they had been working around it by hand.

`--delete` is the opposite risk: one mistake (wrong source, unplugged drive, empty folder)
and the destination is wiped. So the feature is mostly about the guard rails.

## Scope

| Flow | Mirror offered? |
|---|---|
| `14 → 5` Backup - One-time | Yes, asked every run |
| `14 → 2` Sync - New (run now or scheduled) | Yes; a scheduled job asks once, at creation |
| `14 → 3` Sync - Edit job | Yes, new `6) Change copy mode` |
| `14 → 1` Status | Shows each job's mode |
| `14 → 6` Immich backup | **No** — stays append-only by design (see the "Append only (never --delete)" comment in `setup.sh`): an accidental photo deletion must survive in the backup |

## Decisions

1. **Safe default, typed word to opt in.** After source, destination and the
   folder/contents choice:
   ```
   Deleted at source → also delete at destination?
   Enter = no, append only · type "delete" = mirror:
   ```
   Only the exact word `delete` selects mirror; anything else (Enter, typos, `y`) is append
   and says `✓ Append only - nothing at the destination will be deleted.`
2. **Always a second confirmation with a preview.** Choosing mirror runs a dry run
   (`rsync -n --delete`) and shows `⚠ N files would be deleted at <dest>:`, the first five
   names, `... and M more`, then `Delete these N files at the destination? [y/N]`. Enter or
   `n` → `Cancelled - nothing changed.` Nothing to delete → says so and copies. A one-time
   mirror then still shows the existing summary box (with a red `Mode: mirror` line) and its
   `Proceed? [y/N]` — two confirmations is intended.
3. **Source guard — never mirror from nothing.** A missing source, an empty directory, or a
   path under `/mnt`, `/media`, `/run/media` that is not on a real `/dev/*` mount (findmnt;
   a stub/autofs mountpoint or a bare folder left by an unplugged drive) is refused in red.
   An unmounted drive looks exactly like "everything was deleted", so this is the main
   safety rule. The guard fails closed: if it can't decide (tool missing, server
   unreachable), it refuses.
4. **Sudo is probed before the question.** The one-time Download that needs sudo
   (root-owned source or unwritable local destination) streams a tar, which cannot delete.
   Since the probe already knows this, the question is not shown; one dim line says
   `ℹ Needs sudo (tar copy) — append only; mirror isn't possible for this copy.`
   Server → server copies run rsync as root on the server, so mirror works there; guard,
   preview and copy share one sudo password prompt.
5. **Scheduled jobs approve once.** At creation: `⚠ Every scheduled run will delete
   destination files that are gone from the source`, the same preview, then
   `Save this job as mirror? [y/N]`; `n` cancels creating the job (nothing saved). The job
   script stores the mode (`MODE=mirror` / `DELFLAG`) and embeds the guard (cron has no
   federver functions), so **every run re-checks the source**; a failed guard skips the run,
   deletes nothing and logs `SKIPPED <job> - <reason>`. Jobs created before this feature have
   no stored mode and are append-only.
6. **The mode is always visible.** Status (`14 → 1`) has a `Copy` column on every row —
   `mirror` in red, `append` plain, the Immich row `append` — plus a `last:` result per sync
   job (`ok`, `failed (exit N)`, `skipped (<reason>)` in yellow). The user called this
   "very important": a destructive job must never be invisible.

## Non-goals

- Mirror for the Immich backup.
- Mirror through the sudo tar route (would need a separate delete pass under sudo).
- Migrating existing jobs to mirror automatically.
- Versioned/trash-style deletion (`--backup-dir`) — possible later.

## Verification

- `tests/sync-mirror.sh` runs real `rsync` on temp directories: append keeps extras,
  mirror + `y` removes them, Enter cancels, empty/missing/stub-mounted sources are refused,
  the tar route shows no question, job scripts store the mode and re-run the guard, Status
  shows the mode, Change copy mode rewrites legacy scripts safely.
- Not exercised automatically: a real laptop → server ssh hop, a real cron/systemd run on
  the box, a real autofs mount. First live check after merge: one mirror job between two
  throwaway folders, run once from the menu, then Status.
