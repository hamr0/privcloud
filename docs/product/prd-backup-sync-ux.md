# PRD: Backup & sync copy UX (intent-first + tree preview)

Status: **Shipped.**

## Goal

Make every rsync-based transfer in the project understandable to a non-technical user
(or a tired developer) — without anyone having to remember rsync's trailing-slash rule.

## Background — the problem

rsync's behaviour hinges on one invisible character:

- `rsync -a source  dest/` copies the **folder** → `dest/source/…`
- `rsync -a source/ dest/` copies the **contents** → `dest/…`

The old menu exposed this as a choice — "Copy folder" vs "Copy contents" — i.e. it asked
the user to map an abstract decision onto what would land on disk, with only a one-line
"Tip" as a guard. This was the single biggest source of confusion and accidental nesting
(e.g. `…/New Backup/New Backup/`). The pain was confirmed in real use: backing up a drive
into `/mnt/data/nbackup`, the user couldn't tell which option avoided double-nesting.

The logic lived in one shared helper (`_pick_copy_mode` in `setup.sh`), used by **six**
flows — so it was both the source of the problem and the single point to fix it.

## Options considered

- **A — Keep both behaviours, show the real result.** Ask intent in plain words, then
  show exactly what the destination will look like. Keeps the useful "auto-append the
  folder name" convenience.
- **B — One rule: the destination is where files go.** No question ever; to nest, type the
  subfolder into the destination path. Simplest model, but loses auto-append and forces
  retyping full paths for the common "back up this folder into that folder" case.
- **C — Keep the two-option picker, just reword it.** Lowest effort; leaves the underlying
  "map two abstract concepts" problem in place.

## Decision

**Option A + a tree preview.** The deciding insight: the question was only confusing
because it was *abstract*. A tree that draws the actual resulting layout removes the
abstraction entirely — so keeping the question costs nothing and buys back the auto-append
convenience that B throws away. With the tree in play, A dominates B.

### The flow

```
How should "New Backup" be copied?
  1) The whole folder    → a "New Backup" folder is created inside the destination
  2) Only its contents   → files land directly in the destination
  0) Back
Select [1/2]: 1

Destination will look like this:
  /mnt/data/nbackup/
  └── New Backup/
      ├── ashry
      ├── Full Backup Dec 23 2025
      └── … and 3 more
```

You confirm by *seeing* the shape, not by decoding slashes.

## Scope / deliverables

- `_pick_copy_mode` rewritten: plain-words intent question + tree preview. New signature
  `(_src_path, is_dir, dst_path, src_loc)`; still sets `copy_mode=folder|contents` so the
  six callsites' downstream rsync logic is unchanged (the helper controls the slash).
- New `_print_tree_entries` helper: top-level listing capped at 6 (`… and N more`); for a
  root-owned `0700` source it can't read without sudo, shows
  `(can't list without sudo — everything will still be copied)` rather than a misleading
  empty tree.
- **Privileged Download (added v0.9.19).** The tree preview always promised "everything will
  still be copied" for a root-owned source, but the Download direction (server → laptop) then
  ran a plain rsync as the user's SSH login and failed with "permission denied" on exactly
  those sources — most visibly an Immich backup, which is root-owned because the backup job
  runs as root. Download now probes the source as the user (`find ! -readable -print -quit`)
  and, only when something is unreadable, reads it on the server under sudo by streaming a
  `tar` through a single SSH exec (`printf | ssh "sudo -S -p '' tar -cf -" | tar -x`),
  prompting once for the server password. One SSH session is required because a primed sudo
  credential does not survive across separate SSH logins (default `timestamp_type=tty` →
  per-parent-process cache when there is no tty), so the auth and the data must share one
  session; rsync's own second login can't be authorised interactively. The password is read
  silently, passed via a `printf` builtin (never in `ps`) into `sudo -S`, and unset
  immediately; files extract owned by the user, the source stays root-owned, and nothing
  privileged persists. This matches the server → server direction, which was already
  privileged via `sudo rsync` over `ssh -t`.
- Fixes all six flows at once: the four one-time backup directions (`federver` → 14 → 5,
  incl. the new **server → server**) and both scheduled upload/download jobs
  (`federver` → 14 → 2) — so saved cron commands match what the tree showed.
- **Immich backup** (`privcloud` → 9), a separate program with no folder-vs-contents
  ambiguity (fixed `privcloud-backup/` layout), gets the same destination tree in its confirm
  for visual consistency. (Its backup model has since grown a one-time/scheduled split and a
  no-downtime path — see [prd-immich-backup](prd-immich-backup.md); the tree-preview UX here is
  unchanged.)

## Non-goals / known limitations

- Trailing-slash *handling* was already correct (pickers strip slashes; the helper controls
  them) — this work changes presentation, not behaviour.
- Single-**file** sources still pass through the callsites' `src/` line, which appends a
  slash to a filename; that path predates this work and is out of scope here.
- `federver` and `privcloud` are separate scripts; the helper is duplicated in spirit (the
  Immich tree is hand-written) rather than shared, since `privcloud`'s layout is fixed.
