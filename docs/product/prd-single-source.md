# PRD: Single source of truth — stop copy drift in federver and privcloud

Status: **In progress** on branch `refactor/single-source` (decisions settled 2026-11-27, below).
Details per group and per piece: [spec-single-source.md](spec-single-source.md). This PRD is the contract; the spec holds the details.

## Goal

Every job the scripts do is done by **one** piece of code, every generated file comes from **one**
generator, and every list or rule lives in **one** place — so a fix lands once and reaches every
caller, and a template change reaches every file already on disk.

## Background — the problem

New features kept adding their own helper for a job an existing helper already did, or patching
a generated file in place instead of regenerating it. The copies then drifted:

- A guard fixed in one copy stayed missing in the live one (the data-mount start guard sits only in
  dead code, so the stub-mount incident it was written for is still reachable from `federver -> 7`).
- Sync job scripts were written once and then awk-patched; each template change needed a new
  patcher, and hand-edited scripts silently missed upgrades (three review rounds on
  `feat/smb-share` were findings caused by the previous patch).
- Generated files freeze values the live code resolves at run time (job scripts bake the LAN IP and
  never fall back to Tailscale; the Immich backup script bakes the photo path).
- Two copies of the same check appeared on the same day (`_smb_folder_check`, `_mirror_check_here`).

A read-only audit on 2026-11-27 (at `555820d`) found **33 groups**: **8 P1** (wrong result today or
code-proven), **15 P2** (maintenance drift), **10 P3** (cosmetic / scaffolding). The full list with
`file:line` for every member is in the spec.

## Scope — the contract

| # | Piece | Closes | Must hold after |
|---|---|---|---|
| QW | Quick wins (no redesign) | D9 guard, D5 `privcloud config`, D29 wrong menu numbers | `federver -> 7` Start refuses an unmounted data drive; `privcloud config` never drops `.env` keys; docs point at the right menu |
| 0 | Shared test harness `tests/lib.sh` | D27 | every suite uses one `check` / function-extract / stub set |
| 1 | One drive-mount verdict | D8 (+ guards for D9, D14, D16) | one function and one drive-roots list decide "really mounted"; SMB, mirror, disk-check, start guards and backup defaults all call it |
| 2 | One sync-job generator | D1, D2, D6, D13, D23, part of D12 | create and every edit render the script from one record; legacy scripts are imported (only the fields we generate; a script that doesn't match is left alone and flagged in Status, never guessed) then re-rendered (never patched); names validated; scripts resolve the server endpoint at run time (LAN → Tailscale) and use the `ssh()` rules |
| 3 | One Immich backup | D3, D7, D14, D20 | one implementation for scheduled and one-time; reads `.env` at run time; same excludes, layout and guards |
| 4 | Service lifecycle and status | D9, D10, D11, D19, D25, D28, D30 | dead picker removed; one container-state probe, one service list, one renderer for rows and URLs |
| 5 | Merge privcloud into setup.sh ("Manage Immich") | D26, D15, D17, D5 (second reader/writer) | one script: privcloud's features live in `setup.sh` as the **Manage Immich** submenu, styled like every federver menu; duplicated helpers deleted (federver's kept); no `privcloud` command, no shared lib, no macOS branch; the Immich backup keeps working throughout |
| 5b | `.env` and compose files | D4, D33, D16 | one `.env` reader and one key-updating writer in `setup.sh`; compose never edited in place; `.env.example` matches what deploy writes; storage path changes refuse an unmounted drive |
| 6 | Uninstall / firewall / confirm helpers | D18, D21, D22, D24 | shared helpers, adopted as each service is next touched |
| 7 | Menu table and doc checks | D29, D31, D32 | menu numbers come from one table; a test fails on a stale `federver -> N` in docs |

Order: QW → 0 → 1 → 2 → 5 → 3 → 5b → 4 → 6 → 7. Pieces 1 and 2 get a design review with the
user before any code.

## Work plan

One branch (`refactor/single-source`), one module at a time, one release at the end. The "Also
fixes" column folds in the open review-ledger items, so nothing is fixed twice.

| Step | Module | Also fixes (review ledger) | Size / risk | Gate before the next step | Status |
|---|---|---|---|---|---|
| 1 | QW quick wins | copy-mode question (`_mirror_ask`) not colour-coded: question in yellow, `delete` in red per the colour rules; `federver -> 14 -> 2` (Sync - New) reported stuck around that question (root-cause first) | S / low | each fix has a fail-first test | ☑ code (cf6d270..bf70dde); live check pending |
| 1b | Mirror safety (found live 2026-11-27: a mirror into a shared `docs/` offered to delete 1,354,744 files of an unrelated backup) | the preview streams its full output to a private list file (`${XDG_STATE_HOME:-~/.local/state}/federver/mirror-preview-<date>.txt`, newest 5 kept) and the screen shows deletions **grouped by top-level folder** (top 5 with counts, whole folders marked); **wipe guard**: a whole top-level folder (holding deleted files) or more than `MIRROR_WIPE_MIN` (1000) files replaces the y/N with typing the exact count; **flush buffered keys** before every question (a leftover Enter answered the prompt); Ctrl-C during the preview kills the dry run and removes the partial list; the progress line shows live to-delete / to-copy counts | S–M / medium | fail-first tests; live re-run of the same upload shows the guard | ☑ code (16bd6c6..7e46788); live check pending |
| 1c | Mirror confirm follow-ups (found live 2026-11-27) | **one confirmation**: a mirror copy asked `Delete these N files…? [y/N]` and then `Proceed? [y/N]`; ask once, after the summary box (typed count when the wipe guard applies); **symlinked source size**: `From: <path> (0)` because `du -sh` measured the symlink, not the folder it points to | S / low | fail-first tests | ☑ code (99d9e22 one confirmation; the size fix is the commit that ticks this row); live check pending |
| 2 | 0 test harness `tests/lib.sh` | disk-check flake: capture `tmpd` when it fails | S / low | check counts per suite unchanged | ☑ (7452738..775c81c) |
| 3 | 1 drive-mount verdict | `_MIRROR_DRIVE_ROOTS` test override in the production guard | M / medium | **design review**, then live check on the USB drive | ☑ code (02b6b88..e115d12); live USB check pending |
| 4 | 2 sync-job launcher (design B, replaces the generator) | each job is a private record (`~/.local/share/sync-jobs/<name>.job`, KEY=VALUE, read without `source`) plus a two-line launcher (`exec <setup.sh> --run-job <name>`); `_sync_job_run` is the one place a job runs: endpoint picked at each run (LAN probe, then `SERVER_HOST_TS`; D6), rsync with `-s` and the shared ssh options via `RSYNC_RSH` (D23, the `-s` part of D12), remote destination made with `mkdir -p` (no sudo, no TTY under cron), mirror source guard, then an unattended wipe cap (same `_mirror_scan` count and `MIRROR_WIPE_MIN` rule as the preview; skip and log `SKIPPED <name> - would delete N files (over the mirror limit), nothing deleted`), rsync's real exit code captured at once, 24 = `ok (some files vanished)` (decision 1). One registry (`_sync_registry_load`) for List/Edit/Change schedule/Delete/Status (D2), one `_sync_job_delete` (D13), one `_sync_result_text`; names `[a-z0-9_-]`. The awk patcher and header readers are gone, so the CRLF finish-line gap and the `mktemp` leak of Change copy mode go with them (D1); `_mirror_banner` in `step_sync` summaries is now tested; empty folders in the preview were already listed per top-level folder (step 1b) and stay pinned. Old scripts: `_sync_job_import_legacy` converts them on the first Status view (record + launcher, `.bak` kept) or leaves them untouched with `cannot convert: <reason>` (decision 2) | L / high | **design review** (done: design B approved); `.bak` kept; live mirror run, home and away | ☑ code (20167eb..74a8918); live check pending |
| 5 | 5 merge privcloud into setup.sh as "Manage Immich" | move privcloud's code group by group with tests; restyle with federver's `ok/fail/info/warn` and menu layout; drop macOS branches and the `privcloud` CLI verbs and `/usr/local/bin/privcloud` (scripting uses `federver --run <step>`); delete duplicated helpers (D26: colours, local IP, version reader with its stale `0.9.5` fallback, compose helper, autostart read-back); README/customer-guide/CLAUDE.md describe one tool | M–L / medium | **Immich backup (scheduled + one-time) still runs end to end**; suites for the moved code (privcloud-config, privcloud-autostart) retargeted, counts unchanged | ☑ code (c96af2a..da51f26); live check pending |
| 6 | 3 one Immich backup | one generated script for scheduled and one-time (`--once`); one-time writes `<drive>/immich/` like scheduled (old `<drive>/privcloud-backup/` left for the user to delete); one-time mirror kept, behind the same source guard, preview and typed-count confirm as sync; reads `UPLOAD_LOCATION` from `.env` at run time; install-time dry-run runs as the user, not root | M / medium | live scheduled run + one one-time run | ☑ code (25f8d28..f4e30ba); live check pending |
| 6b | 5b `.env` and compose | storage path changes (`_storage_change_*`) check `_drive_verdict` before `mkdir`; start guard / Status derive the mount point by walking up to the nearest existing parent (not only `/mnt/<x>`) | S–M / low | `.env` stays mode 600 | ☐ |
| 7 | 4 service lifecycle and status | Status glitches seen live 2026-11-27 (14 → 1): the job type leaks into Note (`last: ok timer`); Last runs mixes `✓ ok` and `last: ok` (step 4 regression: one wording everywhere); Schedule/When mix a raw `Sun *-*-* 03:00:00` + `systemd` with `Sat` + `weekly` (one readable format); ~10 inline `sg docker -c "docker compose …"` sites move to `_immich_compose`; inline `samba-poc` container probe; first live run of `federver -> 16` from the laptop; `federver -> 7` Restart has no data-drive guard (Start does since QW) | M–L / medium | live Status and Start/Stop | ☐ |
| 8 | 6 uninstall / firewall / confirm helpers | SMB firewall check queries only the default zone | M / low | typed-name confirm and kept `/opt/<service>` config unchanged | ☐ |
| 9 | 7 menu table and doc checks | drop `federver -> 14 -> 4` Sync - Delete a job (Delete stays under Edit job; 5-7 move up); every submenu follows one layout; findings.md rules duplicated in project memory; docs index filing wiki pages under "Product" | S / low | a test fails on a stale `federver -> N` | ☐ |
| 10 | Release | – | – | `/branch-review`, then `/release` | ☐ |

Each module runs the same loop: ~15 min POC → build with tests that fail first against the old code
→ full suite green → `/self-review` → commit. Tick the Status box in the same commit.

## Rules for every piece

1. **Reuse before new.** Search for the job, not just the name; extend the existing helper. A new
   function must say why nothing existing fits.
2. **Regenerate, don't patch.** A generated file has one generator used for create and update.
   Re-rendering a file already on disk writes atomically (temp file + `mv`) and keeps the old file as
   `<name>.bak`, so a hand-edited script is never lost.
3. **No behaviour change hidden in a refactor.** Pure merges are proven by pinning every caller path
   with a test that fails on a deliberate break first; behaviour changes are listed in the piece's
   CHANGELOG entry.
4. **Members that differ on purpose are not merged**; the difference is documented.
5. One piece per commit (or small commit series), each through `/self-review`; the branch through
   `/branch-review` before merge, and the whole cleanup ships as one release.
6. **Simple > clever.** One plain function every caller uses beats a configurable framework; when
   input is ambiguous (e.g. a hand-edited job script), refuse and say so rather than guess.

## Decisions (2026-11-27)

1. rsync exit 24 ("source files vanished during transfer") in sync jobs counts as **success**, logged
   `last: ok (some files vanished)`.
2. Legacy job scripts are **converted to a launcher** on the first Status view, with a one-line notice
   per job: the generated fields are read into a record, the old script is kept as `<script>.bak`, the
   launcher replaces it (atomic `mv`). A script that does not map cleanly is left untouched and shown
   as `cannot convert: <reason>`; script text is never patched.
3. **One script.** privcloud is merged into `setup.sh` as the **Manage Immich** submenu, styled like
   every federver menu (2026-11-27, replaces the earlier shared-lib decision). macOS support and the
   `privcloud` command are dropped; the repo name stays. There is no `lib/common.sh` or `lib/env.sh`.
4. The Immich config step (formerly `privcloud config`) **stays** and writes through the key-updating
   `env_set`, updating only `UPLOAD_LOCATION` and `DB_DATA_LOCATION`; every other `.env` key is left
   untouched. One exception: it generates `DB_PASSWORD` when that key is missing or still the
   `.env.example` placeholder (never changes a real one), because `.env.example` tells users to run it.
5. One-time Immich backups use the scheduled layout `<drive>/immich/`; the one-time mirror option is
   kept, behind the same guard, preview and typed-count confirm as sync.
6. The Immich backup is the feature that must never regress: every step that touches it ends with a
   live backup run.

## Non-goals

- New features. Anything user-visible beyond the fixes named above.
- Changing accepted tradeoffs (LAN-HTTP, `:latest` + Watchtower, Tailscale as the access model).

## Verification

- Each piece: its spec section's tests, fail-first proof for every merge, full suite green.
- Pieces 1 and 2 also get one live check on the real laptop + server (mount verdict on the USB drive;
  a regenerated mirror job run from the menu, away-from-home endpoint fallback).
