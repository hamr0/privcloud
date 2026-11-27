---
title: Sync jobs and drive mounts
slug: sync-jobs-and-drive-mounts
summary: Pieces 0-2 of the single-source spec: shared test harness, one drive-mount verdict, one sync-job generator
sources:
  - docs/archive/spec-single-source.md
---

# Sync jobs and drive mounts

Pieces 0, 1 and 2 of the single-source spec. Each removes duplicated logic: first the test scaffolding, then the "is this drive really mounted" check, then the generated sync-job scripts. All citations point to `docs/archive/spec-single-source.md`.

## Piece 0: shared test harness (`tests/lib.sh`)

Closes D27 and is done first so every later piece is tested the same way (docs/archive/spec-single-source.md:119-119).

**What is duplicated**
- `check()` is redefined in 7 suites (docs/archive/spec-single-source.md:121-121).
- Function extractors are written five different ways; one stops at the next function's name (docs/archive/spec-single-source.md:121-121).
- A `findmnt` stub appears in 3 suites, and some production helpers are re-stubbed. The disk-check suite re-implements `_cron_drop` twice, the second copy ignoring the flag argument that production honours (docs/archive/spec-single-source.md:121-121).
- The differences are drift, not intent, and nothing is failing today. The cost shows up in commit 2cc42a1 ("extractions stop at their own function end") (docs/archive/spec-single-source.md:122-123).

**Design**
- `tests/lib.sh` is sourced by every suite and provides `check`, `extract_fn NAME FILE` (ends at the function's own closing brace) and stub builders `stub_findmnt`, `stub_docker`, `stub_firewall_cmd` (docs/archive/spec-single-source.md:124-124).
- Pure production helpers (`_cron_*`) are extracted for real instead of stubbed. Stubs that deliberately differ per suite stay in the suite; only the mechanism is shared (docs/archive/spec-single-source.md:124-124).

**Tests and risk**
- Migrate one suite at a time, keeping each green with an unchanged check count. Fail-first proof: rename a function inside a fixture and confirm `extract_fn` neither hangs nor swallows the next function (docs/archive/spec-single-source.md:125-125).
- Size S, risk low. The danger is a silently lower check count, so record counts per suite before and after (docs/archive/spec-single-source.md:126-126).
- Acceptance: `tests/run-all.sh` passes with every suite sourcing the lib, no suite defines its own `check` or extractor, and counts match pre-migration (docs/archive/spec-single-source.md:127-130).

## Piece 1: one drive-mount verdict

Closes D8 and supplies the guard that D9, D14 and D16 call. The spec calls for design review with the user before code (docs/archive/spec-single-source.md:136-136).

### Where the check lives today

Nine places answer "is this path really on a mounted drive" (docs/archive/spec-single-source.md:140-148):

| Place | Notable behaviour |
|---|---|
| `_mirror_check_here` | `-e` check, `empty` verdict, `unknown` when findmnt is missing, an `ls -A` that triggers an idle automount (docs/archive/spec-single-source.md:140-140) |
| `_smb_folder_check` | `-d` check, roots without `/media`, no automount trigger, no `unknown` (docs/archive/spec-single-source.md:141-141) |
| `_require_data_mount` | `/mnt/*` only, 3 retries with an `ls` poke (docs/archive/spec-single-source.md:142-142) |
| inline in `_storage_status` | the same as above without retries (docs/archive/spec-single-source.md:143-143) |
| `_storage_mount` | equality with a chosen partition; intentionally different, keep (docs/archive/spec-single-source.md:144-144) |
| generated disk-check | checks the TARGET only, never SOURCE (docs/archive/spec-single-source.md:145-145) |
| `_pick_backup_default` | `mountpoint -q`, which an autofs stub fools (docs/archive/spec-single-source.md:146-146) |

Some writers do no check at all: `_storage_change_music/files/immich` run `sudo mkdir -p` under `/mnt`, and the scheduled backup does `mkdir -p` under `BACKUP_DIR` (docs/archive/spec-single-source.md:147-147). Six different drive-root lists are in use (docs/archive/spec-single-source.md:148-148).

### Drift that matters

- A share under `/media/<user>/USB` is never mount-checked by SMB, and a bare folder left by an unplugged drive reads "ok" (code-proven, unverified live) (docs/archive/spec-single-source.md:152-152).
- Disk-check ignores SOURCE, so an autofs stub passes (docs/archive/spec-single-source.md:153-153).
- The mirror copy says `unknown` where the SMB copy says `unmounted` (docs/archive/spec-single-source.md:154-154).
- Origin: `_require_data_mount` came with 170ba69 after the stub-mount incident; the SMB and mirror checks were written the same day, one copied from the other (docs/archive/spec-single-source.md:156-156).

### Design

- `_drive_verdict <path> [--poke] [--retries N]` prints one of `ok|missing|empty|unmounted|unknown`, uses one `_DRIVE_ROOTS` list and `findmnt -T`, and requires SOURCE under `/dev/` (docs/archive/spec-single-source.md:160-160).
- Callers become thin mappers: SMB maps to its existing reason function, mirror maps to its guard reasons, and the data-mount and storage-status callers use `--retries 3 --poke`. `_pick_backup_default` filters on SOURCE `/dev/*`, and the `mkdir` writers call it first (docs/archive/spec-single-source.md:161-161).
- It ships to the server and job scripts as one bundle entry; until then it joins the existing `declare -f` lists (docs/archive/spec-single-source.md:162-162).
- The generated disk-check keeps a self-contained copy because it must run standalone, with a test that its verdict agrees with `_drive_verdict` (docs/archive/spec-single-source.md:163-163).
- `_storage_mount` is not merged, since equality with a chosen partition is a different question (docs/archive/spec-single-source.md:164-164).

### Tests, risk, acceptance

- Pin current behaviour first with one shared findmnt stub covering ok, missing, empty, bare folder, autofs stub and findmnt absent. Fail-first: break the SOURCE test and confirm every caller's test fails (docs/archive/spec-single-source.md:168-169).
- `_require_data_mount` and `_storage_status` have no test today (docs/archive/spec-single-source.md:170-170).
- CHANGELOG-worthy behaviour changes: SMB now checks `/media`, disk-check agrees with the verdict, and backup defaults stop offering autofs stubs (docs/archive/spec-single-source.md:171-171).
- Size M, risk medium, because this check gates destructive mirror runs and the data-drive start. A live check on the real USB drive is required (docs/archive/spec-single-source.md:172-172).
- Acceptance: one function and one roots list; an unplugged drive under `/media/<user>/<drive>` is refused by SMB; every caller returns the same verdict for the same path (docs/archive/spec-single-source.md:173-176).

## Piece 2: one sync-job generator

Closes D1, D2, D6, D13, D23 and the `-s`/plan part of D12. Also needs design review before code (docs/archive/spec-single-source.md:182-182).

### Problem 1 (D1): a template plus text patchers

- Creation writes the whole script from a heredoc template. Later mode changes patch the text with an awk patcher that knows four rules, and `_sync_change_mode` reads the rsync line back with `grep` (docs/archive/spec-single-source.md:186-189).
- Header comments (`# Key:`) serve as a database, and three inline copies of the Direction parse remain (docs/archive/spec-single-source.md:190-191).
- The append and mirror template branches differ on purpose (docs/archive/spec-single-source.md:192-192).
- On 2026-11-27 the patcher was added, then the template was fixed, then a fourth awk rule was added to repair old scripts: a patch on a patch (docs/archive/spec-single-source.md:193-193).
- Real failures: failed syncs were recorded as `last: ok` (the `(exit $?)` after a `$(date)` substitution always logged 0), and Status cannot detect an outdated script (docs/archive/spec-single-source.md:194-194).
- A proof of concept showed `nice rsync -avh ...` passing through the mode setter with rc=0 and `MODE=mirror`, but the rsync line never got the delete flag. The menu would say "now mirror" while the job stayed append-only. The `declare -f` snapshot also means later fixes never reach already-written scripts (docs/archive/spec-single-source.md:194-194).

### Problem 2 (D2): registry and cron-line codec

- Five functions each parse the cron or timer line themselves, with `#PAUSED#` handled separately in two of them. The last-result text and timer enumeration are duplicated with different wording (docs/archive/spec-single-source.md:198-200).
- The name regex `sync-\K[^.]+(?=\.sh)` breaks on dotted names. Creation only normalizes spaces and case, so `my.photos` becomes `sync-my.photos.sh`, and Edit, Delete and the Status row get an empty name. A default name from a folder like `Photos.2024` hits this (docs/archive/spec-single-source.md:201-202).

### D13: delete exists twice

`_sync_edit_job` option 5 and `_sync_delete_job` do the same work apart from wording. No failure (docs/archive/spec-single-source.md:206-206).

### Problem 3 (D6): endpoint baked into scripts

- Scripts freeze `SERVER_USER=`/`SERVER_IP=`, a literal `user@ip:` in the rsync command, and a `pre_cmd` doing `sudo mkdir -p` (docs/archive/spec-single-source.md:210-210).
- The menu resolves LAN or Tailscale at start, but a job keeps its creation-time value, so a home-made job never falls back to the Tailscale name. Append-mode scripts also lack the `ssh()` wrapper (docs/archive/spec-single-source.md:211-211).
- Code-proven, unverified live: a LAN-address job run by cron while roaming blocks on the connect timeout and exits 255. The unattended `sudo mkdir` needs a TTY and password under cron, and the failure is ignored (docs/archive/spec-single-source.md:213-213).

### Problem 4 (D23): transport bypasses `ssh()`

All 39 `ssh` call sites go through the wrapper, but rsync spawns the real binary: one-time copies, recurring jobs, mirror previews and the job-script guard. `_ts_connected_via_ts` also re-derives the Tailscale state by matching an address range. Unverified live: an unreachable address could hang a minute or more (docs/archive/spec-single-source.md:217-218).

### D12 (part): one-time copy vs Sync-New

- The folder-or-contents computation is written six times and the summary box and confirm prompt four times (docs/archive/spec-single-source.md:222-222).
- Only the recurring path uses `rsync -s` (docs/archive/spec-single-source.md:223-223).
- This piece takes only what the generator needs: `_copy_plan <direction>` returning src, dest, rsync_src, dest_display and flags (one place for `-s`), plus the shared confirm box (docs/archive/spec-single-source.md:224-224).

### Design

| Element | Decision |
|---|---|
| Record | One KEY=VALUE sidecar per job (`umask 077`) holding name, direction, locations, flags, mode, schedule kind and `format`; the script header carries `# format: N` (docs/archive/spec-single-source.md:228-228) |
| Generator | `_sync_job_render` prints the whole script; `_sync_job_write` renders, runs `bash -n`, moves atomically and keeps mode bits. Nothing patches text, and Status shows "outdated" for a low `format` (docs/archive/spec-single-source.md:230-230) |
| Registry | `_sync_registry_load` fills arrays; the name comes from the script basename by parameter expansion; one cron-line builder, one result-text function and one delete function (docs/archive/spec-single-source.md:232-232) |
| Names | Must match `[a-z0-9_-]`; anything else is rejected with a one-line reason, and the default is sanitized (`Photos.2024` becomes `photos-2024`) (docs/archive/spec-single-source.md:234-234) |
| Endpoint | A value-returning `_pick_server_endpoint` is shipped into scripts and resolves from the config file at each run; no literal user or IP is written anywhere (docs/archive/spec-single-source.md:236-236) |
| Transport | `RSYNC_RSH` exported beside `ssh()` with the same timeout and keepalives; append scripts get the same function set as mirror scripts (docs/archive/spec-single-source.md:238-238) |
| Remote mkdir | `--rsync-path='mkdir -p DIR && rsync'` or an unprivileged mkdir, never sudo under cron (docs/archive/spec-single-source.md:240-240) |
| Exit code | `rc=$?` captured on the line right after rsync and logged; exit 24 handling is a single `case` pending an open decision (docs/archive/spec-single-source.md:242-242) |

### Legacy import

`_sync_job_import_legacy` is the only code that parses old script text. For each job script without a record it reads the header keys and `MODE=`, reads the whole rsync and `pre_cmd` lines, re-renders and replaces via `_sync_job_write` (docs/archive/spec-single-source.md:244-247). It refuses with a reason on ambiguity: multiple rsync lines, a wrapper like `nice rsync`, unmapped flags, missing header keys, unknown `pre_cmd` shapes, or a header that disagrees with the rsync line. A refused job is left untouched and marked "outdated (cannot import: ...)" (docs/archive/spec-single-source.md:248-248). The trigger point (first edit or first Status view) is an open decision; first Status view is recommended (docs/archive/spec-single-source.md:249-249).

### Not merged

The append vs mirror template branches, the privileged one-time download tar path, and the schedule picker vs the Immich cadence picker stay separate (docs/archive/spec-single-source.md:253-255).

### Tests, risk, acceptance

- Keep the 71-check `sync-mirror.sh` green and add pins for `_sync_change_schedule`, `_sync_delete_job` and dotted names, which are uncovered today (docs/archive/spec-single-source.md:259-259).
- New tests: golden renders per direction, mode and schedule kind with `bash -n`; hand-edited and legacy fixtures; endpoint resolution (LAN up, LAN down plus Tailscale, both down); a job run with an rsync stub returning 0, 23, 24 and 255; staleness after changing `_mirror_check_here` (docs/archive/spec-single-source.md:260-260).
- Fail-first: drop `$DELFLAG`, the guard or the `rc` capture and confirm a test fails (docs/archive/spec-single-source.md:261-261).
- Live check: a regenerated mirror job run from the menu, plus the away-from-home fallback (docs/archive/spec-single-source.md:263-263).
- Size L, risk high because it rewrites unattended files. Mitigations: dry-render and `bash -n`, atomic move, refuse on ambiguity, and a one-run `.bak` of the old script (docs/archive/spec-single-source.md:264-264).
- Acceptance (docs/archive/spec-single-source.md:265-271):
  - Create and every edit use `_sync_job_render`; no awk/sed patcher remains.
  - `my.photos` is rejected at creation; a legacy dotted job is listed and manageable.
  - A hand-edited `nice rsync` script is refused with a reason.
  - Scripts contain no literal IP or user and resolve LAN then Tailscale at run time.
  - The logged exit code equals rsync's real exit code.
  - Status shows "outdated" below the current format.
