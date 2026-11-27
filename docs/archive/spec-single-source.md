# Spec: Single source of truth

Contract: [prd-single-source.md](prd-single-source.md). The PRD fixes the pieces, rules and open
decisions; this spec holds the details behind them.

- Audit date: 2026-11-27. Commit: `555820d` (branch `feat/smb-share`).
- Line numbers are as of that commit and will shift. **Anchor by function name.**
- Facts come from the audit report or from the code. UNVERIFIED = proven from code only, not run live.
- Paths below are generalized: `<SERVER_IP>`, `<SERVER_USER>`, `$HOME`. Nothing user-specific is committed.

## All findings by priority

Kinds: 1 = same job in several places, 2 = helper re-implemented, 3 = generated file with patchers,
4 = generated file freezing a runtime value, 5 = list/constant/prose written many times.
Piece "QW/4" means the quick win closes the visible failure and the piece does the structural fix.

### P1 (8): wrong result today or code-proven

| id | kind | group | members | failure in one sentence | piece |
|---|---|---|---|---|---|
| D1 | 3 | Sync job script: one template, many awk patchers | 7 | Failed syncs were logged `last: ok`, and a hand-edited rsync line reports "now mirror" while staying append-only (POC rc=0). | 2 |
| D2 | 3 | Sync job registry: cron-line codec, `#PAUSED#`, name regex, status text | 8 | A job named `my.photos` is invisible to Edit, Delete and Status (regex verified). | 2 |
| D5 | 3 | `.env` readers and writers (incl. `privcloud config` overwrite) | 9 | `privcloud config` rewrites `.env` with 6 keys and drops `MEDIA/MUSIC/FILES_LOCATION`, so the next `up` mounts an empty path (code-proven, not run live). | QW + 5 |
| D6 | 4 | Sync job scripts bake SERVER_USER/IP, plain ssh, sudo pre_cmd | 6 | A job created on the LAN address blocks and exits 255 while roaming, though Tailscale was reachable (UNVERIFIED live); unattended `sudo mkdir` needs a TTY (UNVERIFIED). | 2 |
| D7 | 4 | Other generated artifacts that bake runtime values | 5 | After moving Immich storage the scheduled backup keeps reading the old `UPLOAD_LOCATION` (code-proven, UNVERIFIED live). | 3 |
| D8 | 1 | "Path must sit on a real /dev/* mount" + the drive-roots lists | 9 | Copies disagree (SMB has no `/media` root, disk-check ignores SOURCE, `_pick_backup_default` uses `mountpoint -q`), so a stub or bare folder reads "ok". | 1 |
| D9 | 1 | Start/Stop picker: dead `_services_action` vs live `_unified_service_picker` | 4 | The data-mount start guard sits only in dead code, so the stub-mount incident is still reachable from `federver -> 7 -> Start` (static read). | QW + 4 |
| D14 | 1 | Immich backup: `immich-backup.sh` vs `privcloud cmd_backup_once` | 2 | One-time backup lacks the excludes (full-drive incident recurs), uses a different layout, and runs an unguarded `rsync --delete`. | 3 |

### P2 (15): maintenance drift

| id | kind | group | members | failure in one sentence | piece |
|---|---|---|---|---|---|
| D3 | 3 | immich-backup.sh: heredoc + sed placeholders + sed read-back | 4 | A `BACKUP_DIR` containing `\|`, `&` or `\` is mangled by the sed delimiter (UNVERIFIED hazard). | 3 |
| D4 | 3 | `patch_selinux` sed-edits the tracked docker-compose.yml | 3 | `privcloud start` can leave the tracked file dirty so a later `git pull --ff-only` fails silently (UNVERIFIED, hypothetical). | 5 |
| D10 | 1 | Container rows + URL list: `_services_status` vs `step_status` | 3 | No wrong output; rows and URLs differ in small ways (Syncthing URL gating, samba absent). | 4 |
| D11 | 1 | `step_status` remote vs local gather (+ `_storage_status` df) | 4 | Status run on the server shows only `/`, `/home`, `/mnt/data`, so the USB drive vanishes from Disk (code-proven). | 4 |
| D12 | 1 | One-time copy (4 branches) vs Sync-New (2 branches) | 8 | `-s` exists only on the recurring path; a remote destination with spaces on an older server rsync is UNVERIFIED. | 2 (part) |
| D13 | 1 | Delete a sync job: Edit option 5 vs `_sync_delete_job` | 2 | None seen; identical except success wording. | 2 |
| D16 | 1 | `_storage_change_music/files/immich` | 3 | A new `/mnt/...` path answered while the drive is unmounted is created on the system disk (UNVERIFIED live). | 8 (guard from 1) |
| D18 | 1 | Uninstallers (6) + remote Tailscale removal string | 8 | Each copy had the "printed removed, nothing removed" bug, fixed one at a time (history). | 6 |
| D19 | 2 | Container exists/running probes | 14 | Only two copies tell "query failed" from "absent"; the fix reached uninstall paths only. | 4 |
| D20 | 2 | Raw `crontab -l` vs `_cron_*`; Immich legacy-cron pattern x4 | 8 | A legacy `immich-db` cron line is shown and removed by Status/Remove but left by Set up, so both run (UNVERIFIED). | 3 |
| D21 | 2 | firewall-cmd add/remove (+reload) | 9 | Add paths ignore failure while remove paths verify; ports are written twice per service. | 6 |
| D22 | 2 | Server sudo password flow (download inline vs `_server_sudo_*`) | 3 | A bad password in the download shows one generic message after the pipeline fails. | 6 |
| D23 | 2 | rsync transport bypasses the `ssh()` wrapper; `_ts_connected_via_ts` re-derives the endpoint | 7 | rsync spawns plain `ssh`, so an unreachable address hangs for a minute or more (UNVERIFIED live). | 2 |
| D29 | 5 | Menu numbers and menu text in prose/docs | 38 refs | Stale numbers: the Syncthing runbook points at the Immich backup menu (code-proven). | QW + 7 |
| D30 | 5 | Lists of services (Emergency, Status, picker, Save-to-pass) | 6 | A new standalone container is missing from Emergency until the list is edited (happened with samba); Save-to-pass omits `/opt/samba`. | 4 |

### P3 (10): cosmetic / scaffolding

| id | kind | group | members | failure in one sentence | piece |
|---|---|---|---|---|---|
| D15 | 1 | Path pickers + preset paths | 3 | None; server presets are hard-coded and duplicate the `.env` data root. | 8 |
| D17 | 1 | Syncthing path logic x2; server status x3 | 5 | None; behaviour matches. | 8 |
| D24 | 2 | y/N and typed confirms | 3 + 36 sites | None; three accept patterns and different EOF handling. | 6 |
| D25 | 2 | Tailscale / Syncthing state vocabulary in pickers | 7 | None today; the picker says "disconnected" where `_ts_word` says "not installed". | 4 |
| D26 | 2 | privcloud <-> setup.sh helper copies | 8 | Partly: the two version fallbacks differ and `keep_autostart` has no read-back. | 8 |
| D27 | 2 | Test scaffolding copies | 8 | None; one stub ignores a flag production honours. | 0 |
| D28 | 5 | Service URL blocks | 7 | None; ports written 20+ times. | 4 |
| D31 | 5 | `declare -f` payload lists | 9 | A helper gaining a dependency breaks only the remote call (history). | 7 |
| D32 | 5 | disk-check cadence/threshold constants | 6 | None; no mismatch today. | 7 |
| D33 | 5 | Data-path defaults and version literal | 8 | None; reachable only when `.env` lacks the key. | 5 |

### Looks similar, no evidence of harm (not in scope)

- `_ts_*_both` vs `_syncthing_*_both`: parallel lifecycle, different commands; dispatch is already table-like.
- `step_wireguard`, `step_adguard`, `step_remotedesktop` install flows: similar scaffolding, different content.
- `_sync_pick_schedule` vs the Immich cadence picker: different option sets on purpose (only the OnCalendar strings could share a helper).
- `_sync_install_timer` vs the immich-backup units: user vs system units, different retry policy.
- `sudo -v` guards: different scopes; one is generated text.
- `step_docker` vs privcloud `ensure_docker` / `cmd_install`: dnf-only vs multi-OS.
- `sudo sed -i` of /etc config: system files, each backed up or idempotent.
- `_cron_to_english` leaks a nested `_hour_str` as a global function (cosmetic).

---

## Piece QW: Quick wins (no redesign)

Closes: D9 (guard only), D5 (`privcloud config` only), D29 (the wrong numbers only).
Order: first. Each is its own small commit with its test.

### D9 guard (setup.sh `_services_action`, `_unified_service_picker`, `step_services_wrapper`)

- Members: `_services_action` (3 refs, all inside `step_services`); `step_services` (0 callers, no menu entry, no `--run step_services`); `_unified_service_picker` (3 callers, all in `step_services_wrapper`); `step_services_wrapper` (live path from the main loop). The wrapper's menu text is a verbatim copy of `step_services`.
- Differs: `_services_action` guards Start of navidrome, filebrowser and All with `_require_data_mount` and confirms Stop All. `_unified_service_picker` has no guard on any start path (single container; All via `docker compose up -d` over ssh). Drift, not intent.
- Failure: Docker "no such device" and empty folders created on the system disk (CHANGELOG, stub-mount incident) remain reachable from `federver -> 7 -> Start`. Static read, not reproduced live.
- Evidence: wrapper and picker date from 2026-04-16 (71b9102, 18322b1). The guard arrived 2026-06-04 in 170ba69 inside `_services_action` only; the live menu already routed through the wrapper then.
- QW change: call `_require_data_mount` from the picker before the single-container start of navidrome/filebrowser and before the All compose-up, with the same path mapping `_services_action` used. Removing the dead code is piece 4.

### D5 `privcloud config` (privcloud `cmd_config`)

- Members: `cmd_config` writes `.env` with `cat > "$ENV_FILE"` (UPLOAD_LOCATION, DB_DATA_LOCATION, IMMICH_VERSION, DB_PASSWORD, DB_USERNAME, DB_DATABASE_NAME). On a server it is reachable through federver `i` (`step_immich`) then privcloud 5.
- Failure (code-proven): drops MEDIA_LOCATION, MUSIC_LOCATION and FILES_LOCATION that `step_deploy` wrote; docker-compose.yml consumes `${MUSIC_LOCATION}` and `${FILES_LOCATION}`, so the next `up` mounts an empty path.
- QW change: replace the whole-file write with a key-updating `env_set KEY VAL` in privcloud (literal match, awk, no sed delimiter issues; create `.env` from `.env.example` when absent). Update only the keys the command asks for. Decision: keep on a server (see Decisions log).

### D29 wrong menu numbers

- setup.sh `step_ssh` text "continue with steps 3-11": the menu says "Run all (3-7)".
- setup.sh "Laptop is already installed (option 14 handled it)" in the Syncthing flow: Syncthing is option 12, 14 is Manage sync.
- customer-guide.md (repo root), Syncthing section: "stop the container (`federver -> 14 -> 6`)": 14 -> 6 is the Immich backup menu. CHANGELOG records the Tools menu renumber; this reference was missed.
- setup.sh "cd federver && ./setup.sh": the repo directory is `privcloud`.
- Fix the four strings to the current numbers; piece 7 removes the cause.

### Tests and acceptance (QW)

- Tests: picker with a stubbed `findmnt`/`_require_data_mount` that fails, assert no `docker start`/`compose up` runs for navidrome, filebrowser, All; assert `cmd_config` on a fixture `.env` containing FILES/MEDIA/MUSIC keys keeps them and changes only the asked key. Each test must fail first against the unfixed code.
- Existing coverage: svc-power.sh covers `_svc_power_body` only; smb-share.sh covers `_env_get` only; nothing covers the picker, `_require_data_mount` or `cmd_config`.
- Size: S. Risk: low; the picker guard adds a refusal path only when the drive is not really mounted.
- Acceptance:
  - `federver -> 7` Start (single and All) refuses an unmounted data drive with the guard's message.
  - `privcloud config` leaves every key it did not ask for byte-identical.
  - The four strings above point at existing menu items.

---

## Piece 0: Shared test harness `tests/lib.sh`

Closes: D27. Done first so every later piece is tested the same way.

- Members: `check()` redefined in 7 suites (svc-power.sh, disk-check.sh, privcloud-autostart.sh, smb-share.sh, sync-mirror.sh, syncthing-gate.sh, ts-expiry.sh); function extractors written five ways (sync-mirror.sh `fn`, smb-share.sh, ts-expiry.sh, syncthing-gate.sh, disk-check.sh; svc-power.sh stops at the next function's name); a `findmnt` stub in 3 suites (sync-mirror.sh, smb-share.sh, disk-check.sh); stubs of production helpers (disk-check.sh re-implements `_cron_drop` twice, the second ignoring the flag argument `$2` that production honours; sync-mirror.sh stubs `_server_sudo_run`).
- Differs: drift, not intent.
- Failure: none today; evidence of the cost is 2cc42a1 ("extractions stop at their own function end").
- Design: `tests/lib.sh` sourced by every suite, with `check`, `extract_fn NAME FILE` (ends at the function's own closing brace), and stub builders (`stub_findmnt`, `stub_docker`, `stub_firewall_cmd`). Stubs of production helpers are replaced by extracting the real helper where it is pure (`_cron_*`). Not merged: stubs that are deliberately different per suite (what the stub returns) stay in the suite; only the mechanism is shared.
- Tests: migrate suites one at a time; each stays green and its check count is unchanged before and after. Fail-first proof: rename a function inside a fixture and confirm `extract_fn` does not hang or swallow the next function.
- Size: S. Risk: low; the danger is a silently lower check count, so record counts per suite before and after.
- Acceptance:
  - `tests/run-all.sh` passes with every suite sourcing `tests/lib.sh`.
  - No suite defines its own `check` or extractor.
  - Check counts per suite are equal to the pre-migration counts.

---

## Piece 1: One drive-mount verdict

Closes: D8. Supplies the guard that D9 (done in QW), D14 (piece 3) and D16 (piece 8) call. Design review with the user before code.

### D8 members

1. `_mirror_check_here` (setup.sh:5032; 4 call sites; shipped via `declare -f` at 5056, 5058, 5167): `-e` check, `empty` verdict, roots `${_MIRROR_DRIVE_ROOTS:-/mnt /media /run/media}`, `findmnt -T` TARGET and SOURCE, `unknown` when findmnt is missing, an `ls -A` that triggers an idle automount.
2. `_smb_folder_check` (7566; 6 refs, also shipped at 6886): `-d` check, roots `_SMB_DRIVE_ROOTS="/mnt /run/media"` (no `/media`), same findmnt test, no automount trigger, no `unknown`.
3. `_require_data_mount` (1289; 4 call sites): `/mnt/*` only, mount point = first two path components, `findmnt -frno SOURCE "$mp"` (no `-T`), 3 retries with an `ls` poke.
4. Inline in `_storage_status` (1385-1398): member 3 without retries.
5. `_storage_mount` (1533): equality with a specific `/dev/$partition`. **Intentionally different; keep.**
6. Generated disk-check (4698-4710): `findmnt -T` TARGET only, never SOURCE, plus fstab logic.
7. `_pick_backup_default` (4148): `mountpoint -q`, the check 170ba69 documents as fooled by an autofs stub.
8. Unchecked writers: `_storage_change_music/files/immich` (1697, 1740, 1779) `sudo mkdir -p` under `/mnt` with no check; scheduled `immich-backup.sh` does `mkdir -p` under `BACKUP_DIR`; privcloud:780 uses only `[ ! -d "$dest" ]`.
9. Drive-root lists: `/mnt /media /run/media` (5035), `/mnt /run/media` (7443), `/mnt/*` (1296), `/run/media/*/* /media/*/* /mnt/*` (4146), `/run/media/$USER` + `/media/$USER` (6168), `/mnt/*|/media/*|/run/media/*` (disk-check).

### Differences that matter (drift)

- SMB has no `/media` root: a share under `/media/<user>/USB` is never mount-checked, and a bare folder left by an unplugged drive reads "ok" (code-proven, UNVERIFIED live).
- Disk-check ignores SOURCE, so an autofs stub passes.
- `unknown` (no findmnt) in the mirror copy vs `unmounted` in the SMB copy.

Evidence: `_require_data_mount` came with 170ba69 (2026-06-04) after the stub-mount incident. `_smb_folder_check` (9c6181b) and `_mirror_check_here` (ac96bd7) were written the same day, one copied from the other with additions.

### Design

- `_drive_verdict <path> [--poke] [--retries N]` prints one of `ok|missing|empty|unmounted|unknown`. One `_DRIVE_ROOTS` list. Uses `findmnt -T` and requires SOURCE under `/dev/`.
- Callers map the verdict: `_smb_folder_check` becomes a thin mapper to the existing `_smb_folder_reason`; `_mirror_check_here` maps to `_mirror_guard` reasons; `_require_data_mount` and the inline `_storage_status` block call it with `--retries 3 --poke`; `_pick_backup_default` filters on SOURCE `/dev/*`; `_storage_change_*` and the scheduled backup call it before `mkdir` (the latter two land in pieces 8 and 3).
- Shipping to the server and into job scripts is one entry in the bundle list (D31, piece 7). Until then add it to the existing `declare -f` lists.
- The generated disk-check keeps a self-contained copy (it must run standalone); add a test that its verdict agrees with `_drive_verdict` on a fixture.
- Not merged: `_storage_mount` (equality with a chosen partition is a different question).

### Tests

- Pin current behaviour first: one shared findmnt stub (piece 0) with cases ok / missing / empty / bare folder / autofs stub (SOURCE not `/dev/*`) / findmnt absent, run against `_mirror_check_here`, `_smb_folder_check`, `_require_data_mount` and the `_storage_status` block before the merge.
- Fail-first: break the SOURCE test in the new function and confirm every caller's test fails.
- Existing coverage: smb-share.sh 5e/5g and sync-mirror.sh (findmnt stub) cover members 1-2. disk-check.sh stubs findmnt TARGET only. `_require_data_mount` and `_storage_status` have no test.
- Behaviour changes to list in CHANGELOG: SMB now checks `/media`; disk-check path agreement; `_pick_backup_default` stops offering autofs stubs.
- Size: M. Risk: medium; this check gates destructive mirror runs and the data-drive start. Live check on the real USB drive required.
- Acceptance:
  - One function and one roots list; no other copy of the SOURCE `/dev/*` test outside `_storage_mount` and the generated disk-check.
  - A share under `/media/<user>/<drive>` with the drive unplugged is refused by SMB.
  - Mirror, SMB, start guards, `_storage_status` and backup defaults return the same verdict for the same path in one test.

---

## Piece 2: One sync-job generator

Closes: D1, D2, D6, D13, D23, and the `-s`/plan part of D12. Design review with the user before code.

### D1 members: template + patchers

- `_sync_execute_or_schedule` (setup.sh:5297; 2 callers; heredoc template 5355-5378).
- `_sync_job_set_mode` (5191; 1 caller via `_sync_change_mode`): awk patcher with four rules: swap the `# >>> copy mode` block; insert the block before the `echo "[$(date` line when no markers exist; prefix `$DELFLAG` to lines starting `rsync `; rewrite the legacy `(exit $?)` finish line.
- `_sync_mirror_block` (5163; 2 callers): emits `declare -f ssh _shq _mirror_check_here _mirror_guard` into every mirror script, a snapshot of function bodies.
- `_sync_change_mode` (5278): reads the rsync line back with `grep -m1 '^rsync '` and strips ` $DELFLAG`.
- `_sync_job_field` (5186; 6 refs): treats the `# Key:` header comments as a database. Three inline `grep '^# Direction:' | sed` copies remain (5884, 5894, 5921).
- `_sync_job_mode` (5179; 5 refs): reads the `MODE=` line back.
- Differs: creation writes the whole file; later changes patch it and only know the template shapes of the day. The append and mirror branches of the template differ **on purpose** (guard block only for mirror).
- Evidence (all 2026-11-27): ac96bd7 created the patcher; d57409f fixed the template (`(exit $?)` after a `$(date)` substitution always logged 0; old scripts kept the bug, CHANGELOG says so); 555820d added a fourth awk rule to repair old scripts (a patch on a patch that runs only if the user re-selects a copy mode); d57409f said `_sync_job_field` replaced "6 header parses" while 3 inline parses remain.
- Failures: real, already happened: failed syncs recorded as `last: ok`; Status cannot detect an outdated script (no format version). POC (scratchpad, functions extracted from setup.sh): a hand-edited rsync line `nice rsync -avh ...` through `_sync_job_set_mode job mirror` returned rc=0, the script held `MODE=mirror` and the guard, but the rsync line never got `$DELFLAG`; verification re-reads only `MODE=`, so the menu says "now mirror" while the job is append-only. The `declare -f` snapshot means a later fix to `_mirror_check_here` never reaches already-written scripts.

### D2 members: registry and cron-line codec

- `_sync_list_jobs` (6039; parse 6062-6071); `_sync_edit_job` (5607; parse 5632-5633, pause/resume 5663-5667); `_sync_change_schedule` (5733; parse 5767-5771); `_sync_show_status` (5784; parse 5878-5895, second copy for `#PAUSED#` 5888-5892); `_cron_add_sync` (119, builder) and `_cron_replace_line` (130).
- Last-result text: `_sync_last_note` (5245) vs the inline case at 6024-6030 (different wording: "last: failed" vs "exit", "running?").
- Timer enumeration: OnCalendar awk at 5915 and 6089; is-enabled paused test at 5636, 5917, 6090.
- Differs: same intent, different details (drift). The name regex `grep -oP 'sync-\K[^.]+(?=\.sh)'` is used at 5879, 5891, 6068; creation (5333-5336) only normalizes spaces and case, so `.` is allowed.
- Failure (verified by running the regex): job `my.photos` gives `sync-my.photos.sh`; the regex prints nothing (rc=1) on its cron line, so Edit, Delete and the Status row get an empty name. Default job name is the source basename lowercased, so a folder like `Photos.2024` hits it. `#PAUSED#` is a textual convention four sites re-implement; a site that forgets to strip it treats the job as a comment.

### D13: delete a job x2

- `_sync_edit_job` option 5 (5714-5726) and `_sync_delete_job` (6113; 1 caller `step_manage_sync`): both `_confirm_delete "sync-NAME"`, `_cron_remove_line` or `_sync_remove_timer`, `rm -f` script and log. Identical except wording. No failure.

### D6: endpoint baked into scripts

- Frozen values: header `SERVER_USER=` / `SERVER_IP=` (5364-5365); rsync command with literal `user@ip:` (6790, 6825); `pre_cmd` at 6789 (`ssh -t user@ip 'sudo mkdir -p ... && sudo chown ...'`) and 6824 (`sudo mkdir -p`), pasted via `${pre_cmd:+$pre_cmd}`; `_mirror_guard server` in mirror scripts (5056, shipped via 5167) uses the script's own `$SERVER_IP`.
- Differs from live code: `_resolve_server_endpoint` (458) picks LAN or Tailscale at menu start; the job freezes the value at creation. A job made at home never falls back to `SERVER_HOST_TS`; one created away is pinned to the Tailscale name; config changes do not touch existing jobs. Append-mode scripts lack the `ssh()` wrapper (only mirror scripts get it, 5167).
- Evidence: literal IPs date from 3c10743 (2026-04-16); the fallback came with 5a02503 (v0.8.4, 2026-06-05) and never reached existing jobs; v0.7.4 (5a24bda) removed hardcoded config from the repo but kept the per-job literal.
- Failures: code-proven, UNVERIFIED live: a job made on the LAN address and run by cron while roaming blocks on the TCP connect timeout and exits 255, shown as `last: failed (exit 255)`. UNVERIFIED: the unattended `ssh -t ... sudo mkdir` / local `sudo mkdir` needs a TTY and password under cron; the failure is ignored because the script goes on to rsync.

### D23: transport bypasses `ssh()`

- The 39 `ssh` call sites comply; the only `command ssh` is the wrapper (setup.sh:174-176). rsync spawns the real `ssh` binary: one-time (6424, 6597), recurring (6790, 6825, also pasted into job scripts), `_mirror_preview` dry runs via `bash -c` (5118), `_mirror_guard server` in job scripts (5056). `_ts_connected_via_ts` (1078) re-derives "connected over Tailscale" by matching `SERVER_IP` against 100.64/10 although `_resolve_server_endpoint` is where the switch happens.
- Failure (UNVERIFIED live): an unreachable address hangs a minute or more, the failure the wrapper was written to prevent.

### D12 (part): one-time copy vs Sync-New

- Members: `_sync_one_time_backup` (6360; 4 direction branches; the `rsync_src`/`dest_display` folder-or-contents computation at 6396-6403, 6454-6460, 6609-6616, 6648-6655) and `step_sync` (6729; 6769-6776, 6808-6815): that computation is written six times. Summary box and "Proceed? [y/N]" written four times in the former; direction menus (6365-6372 vs 6735-6740) and the `_pick_*` / `_pick_copy_mode` ladder repeat.
- Differs: only the recurring path uses `rsync -s` (6790, 6825); none of the one-time lines (6408, 6424, 6466, 6597, 6619, 6662) does (0ffee48, v0.9.14 added `-s` to one copy). Mirror is asked via `_mirror_gate` in three branches and via bare `_mirror_ask` plus a separate sudo preview in branch 4 (drift). Only one-time download has the privileged tar path (intentional; not merged). Whether a remote destination with spaces splits on an older server rsync without `-s` is UNVERIFIED (local rsync 3.5.2 protects args by default).
- This piece takes only what the generator needs: `_copy_plan <direction>` returning src, dest, rsync_src, dest_display and flags (one place for `-s`), and the shared confirm box. The one-time branch bodies shrink to plan + execute; unification of menus beyond that is optional.

### Design

**Record.** One parameter record per job in a sidecar `$HOME/.local/share/sync-jobs/<name>.job` (KEY=VALUE, `umask 077`): name, direction, src_loc, src, dest_loc, dest, rsync flags, mode (append|mirror), schedule kind (cron|timer), `format`. The script header carries `# format: N`.

**Generator.** `_sync_job_render <name>` reads the record and prints the whole script. `_sync_job_write <name>` = render, `bash -n`, atomic `mv`, keep mode bits. Create and every edit (mode, endpoint, schedule path) change the record and call `_sync_job_write`; nothing patches text. `_sync_job_set_mode`, `_sync_job_field`, `_sync_job_mode`, the awk patcher and the three inline Direction greps disappear. Status reads the record and shows "outdated" when `format` is below current.

**Registry.** `_sync_registry_load` fills arrays (name, kind cron|timer, sched, paused, script path, raw line). The name is derived from the script basename by parameter expansion, not regex. List, edit, change schedule, delete and Status read those arrays. One `_sync_cron_line` builder next to `_cron_add_sync` handles pause/resume/reschedule. One `_sync_result_text <kind> <style>` for status wording. One `_sync_job_delete <name> <kind> <line>` replaces both delete copies (D13; one success wording).

**Name validation.** Names must match `[a-z0-9_-]`. At creation, lowercase and replace spaces; reject anything else with a one-line reason that names the offending character. Applied to the default (basename) too, so `Photos.2024` is offered as `photos-2024`.

**Run-time endpoint.** Split `_resolve_server_endpoint` into a value-returning `_pick_server_endpoint` (reads the config file, probes the LAN address with `_tcp_open`, falls back to `SERVER_HOST_TS`); the menu sets `SERVER_IP` from it (and `_SERVER_VIA_TS`, which `_ts_connected_via_ts` then reads, closing the D23 re-derivation). The rendered script ships `_pick_server_endpoint` with `declare -f`, sources `${XDG_CONFIG_HOME:-$HOME/.config}/federver/config` for user, LAN address and Tailscale name, and resolves at each run. **No literal user or IP is written into any script or committed file.** Same rule as CLAUDE.md: env var, then config file outside the repo.

**Transport.** Export `RSYNC_RSH` beside the `ssh()` definition with the same `ConnectTimeout` and keepalive options, and ship the same options into job scripts, so rsync and `_mirror_guard server` use the wrapper rules. Append-mode scripts get the same function set as mirror scripts, from one bundle list (D31).

**Remote destination creation.** Replace the unattended `sudo mkdir` pre_cmd with `--rsync-path='mkdir -p DIR && rsync'` or an unprivileged mkdir, never sudo under cron.

**Exit code.** The script runs rsync, captures `rc=$?` on the next line (before any `$(date)` substitution), and logs `rc`. Status text derives from it. rsync exit 24: see the open decision; implement as a single `case` in the template so the choice is one line.

**Legacy import (`_sync_job_import_legacy`).** The only code that ever parses old script text. For each existing job script without a sidecar record:
1. Read the `# Key:` header comments (Direction, source, destination, etc.) and `MODE=`.
2. Read the **whole** rsync line(s) and the whole `pre_cmd` line(s), not a prefix match; extract flags and endpoints by tokenizing the full line.
3. Re-render from the resulting record and replace the script through `_sync_job_write`.
4. **Refuse with a reason** when anything is ambiguous: more than one rsync line, a wrapper such as `nice rsync`, extra flags that do not map to a record field, a missing header key, a `pre_cmd` that is not one of the two known shapes, a header and rsync line that disagree. The job is left untouched, marked "outdated (cannot import: <reason>)" in Status, and its path is shown so the user can recreate it. Never patch a legacy script.
Trigger point: open decision (first edit vs first Status view). Recommended: first Status view with a one-line notice, because old scripts carry the exit-code bug.

### Not merged

- Append vs mirror template branches (guard block only for mirror).
- The one-time download tar path (privileged, append-only by nature).
- `_sync_pick_schedule` vs the Immich cadence picker (different option sets).

### Tests

- Pin before merge: sync-mirror.sh (71 checks) runs a real generated script, `set_mode`, Status, list and edit; keep green. Add pinning tests for `_sync_change_schedule`, `_sync_delete_job` and dotted names (all uncovered today).
- New: render golden files per (direction x mode x schedule kind); `bash -n` on each; hand-edited and legacy fixtures (`nice rsync`, old `(exit $?)` line, old frozen IP) each either imported and re-rendered or refused with a reason; endpoint resolution with a stubbed LAN probe (LAN up, LAN down + TS, both down); a job script run with the rsync stub returning 0, 23, 24, 255 and asserting the logged code; snapshot-staleness: after changing `_mirror_check_here`, a re-rendered script contains the new body.
- Fail-first: for each merge, break the new generator (drop `$DELFLAG`, drop the guard, drop the `rc` capture) and confirm the pinned test fails; revert the break.
- Gaps from the report: hand-edited script, legacy upgrade via re-render, function-snapshot staleness, `_sync_change_schedule`, `_sync_delete_job`, dotted names, endpoint and pre_cmd behaviour, `step_sync`.
- Live check: a regenerated mirror job run from the menu, plus the away-from-home endpoint fallback (PRD Verification).
- Size: L. Risk: high; it rewrites files that run unattended. Mitigations: dry-render and `bash -n` before replace, atomic move, refuse-on-ambiguity, keep a one-run backup of the old script (`.bak`, removed after the first successful run).
- Acceptance:
  - Create and every edit produce the script from `_sync_job_render`; no awk/sed patcher of script text remains.
  - A job named `my.photos` is rejected at creation with a reason; a legacy dotted job is listed and manageable.
  - A hand-edited `nice rsync` script is refused with a reason, never half-patched.
  - Job scripts contain no literal server IP or user; they resolve LAN then Tailscale at run time and use the ssh()/RSYNC_RSH timeout and keepalive options.
  - Logged exit code equals rsync's real exit code.
  - Status shows "outdated" for a script below the current format.

---

## Piece 3: One Immich backup

Closes: D3, D7 (immich-backup.sh row), D14, D20.

### D14: scheduled script vs `cmd_backup_once`

- Members: setup.sh:4249-4313 (script heredoc; `step_immich_backup` 4166) and privcloud:733 `cmd_backup_once` (mirror prompt 808-818, photos rsync 830, db dump 851, datadir copy 869).

| | scheduled script | privcloud one-time |
|---|---|---|
| layout | `$BACKUP_DIR/immich/photos`, `$BACKUP_DIR/immich/db/` | `<dest>/privcloud-backup/photos`, dump `immich-db-*.sql.gz` at the top |
| excludes | `/backups/`, `/thumbs/`, `/encoded-video/` | none |
| mirror | never `--delete` | `rsync --delete` on request, no source guard |
| retention | `find -mtime +N -delete` | none |

- Drift: the differences are accidental. v0.9.12 (56117cb, 2026-06-08) added the excludes to the scheduled script after the shared drive filled ("No space left on device"); `git log -S"--exclude='/thumbs/'"` hits setup.sh only. Mirror in privcloud dates from 63ff51e (2026-03-08) and never received the `_mirror_guard` that ac96bd7 added to the federver copies.
- Failures: real (history): the full-drive incident recurs whenever the one-time backup is used. Code-proven: running both on one drive writes the library twice (`privcloud-backup/photos` and `privcloud-backup/immich/photos`). Mirror with an empty or unmounted `$upload_loc` deletes the destination copy, the hazard `_mirror_guard` was built for.

### D3: template and sed placeholders

- Members: heredoc 4249-4313 plus `sudo sed -i "s|__BACKUP_DIR__|..."` (4315); `_configured_backup_dir` (4162; 1 caller) reads `BACKUP_DIR=` back from the installed script with sed; Status parses the log text the script emits. The right pattern already exists: `_disk_check_script` (4631) is a generator (values through `printf %q`), dry-run before install, regenerated on every reinstall.
- Not like D1: Set up rewrites the whole file each time, so nothing patches an old copy. Hazard (UNVERIFIED): a `BACKUP_DIR` with `|`, `&` or `\` is mangled by the sed delimiter. The installed script doubles as a data store.

### D7: baked values (immich-backup.sh)

- `immich-backup.sh` (setup.sh:4249-4316) bakes BACKUP_DIR, UPLOAD_LOCATION, RETENTION_DAYS. Live source for UPLOAD_LOCATION is `.env`, changed by `_storage_change_immich` (1779-1830, `_set_env` at 1821) and `privcloud config`; neither refreshes the script.
- Other rows in the report's table (wrappers at 638-646, Syncthing mounts with a "Reapply paths" menu, disk-check, sync job scripts) are low or intentional. Job scripts are piece 2.
- Failure (code-proven, UNVERIFIED live): after moving storage, the scheduled backup keeps the old `UPLOAD_LOCATION`. A deleted old path gives a visible rc=1; if the old tree still exists it backs up stale data and reports "Backup complete".

### D20: cron reads and legacy pattern

- Members: `_cron_get/_cron_set/_cron_drop` (setup.sh:80-130); raw reads at 4428 and 4531 (`sudo -n crontab -l`), 4589 (`sudo crontab -l`), 5798 (`_server_sudo_run 'crontab -l ...; echo __CRON_READ_OK__'`, a deliberate marker), 5872 and 6042 (`crontab -l 2>/dev/null || laptop_crons=""`). Pattern: `grep -q immich-backup` (4241) vs `immich-backup\.sh|immich-db|immich-backup\.log` at 4431, 4531, 4578.
- Differs: raw reads cannot tell "read failed" from "empty" (3a85dc9 fixed this in `_cron_get`); set-up teardown uses the narrow pattern, Status and Remove the 3-term one; v0.9.17 (6cd2aae) widened Remove only (drift).
- Failure (UNVERIFIED): a legacy root cron line running `immich-db` without `immich-backup` is shown by Status and removed by Remove, but left when Set up installs the timer, so both run.

### Design

- One implementation: `immich-backup.sh` is generated by `_immich_backup_script` (values via `%q`, dry-run, regenerated on reinstall) and accepts `--once --dest D --scope photos|db|both --mirror`. `cmd_backup_once` asks the questions and calls it via `sudo`; layout, excludes and the mirror guard live in one place. The mirror source guard uses `_drive_verdict` / `_mirror_gate` (piece 1).
- Run-time `.env`: the script reads `UPLOAD_LOCATION` from the repo `.env` at each run (as disk-check does); only BACKUP_DIR and RETENTION live in a small `/etc/immich-backup.conf` (replaces the sed read-back; `_configured_backup_dir` reads it). The repo path comes from the install step, not hardcoded.
- Layout decision (one layout for both modes) is listed in the CHANGELOG as a behaviour change: one-time now writes to `<dest>/immich/...` to match the scheduled layout, so the library is never written twice.
- One `_immich_cron_lines` with a single pattern constant; `_cron_get` everywhere, so Status can show "unknown" on rc=1.
- By design there is exactly ONE Immich backup schedule; Remove/Status never need a chooser (project fact). Not merged: user vs system unit differences between the Immich units and sync-job timers.

### Tests

- Pin first: sync-mirror.sh asserts the scheduled path stays append-only; add pinning for the generated script (excludes, layout, retention, `--once` flags) and for `cmd_backup_once` argument building (none exist today).
- Fail-first: remove an exclude / drop the guard in the new generator and confirm the test fails.
- New: `BACKUP_DIR` containing `|`, `&`, `\` round-trips; `UPLOAD_LOCATION` changed in `.env` is used on the next run without regenerating; one-time mirror with an empty source is refused; legacy `immich-db` cron line is handled identically by Set up, Status, Remove.
- Gaps from the report: no test for `cmd_backup_once`, `cmd_config`, `_storage_change_immich`, the generated `immich-backup.sh`, or the real `_cron_*` (suites stub them; disk-check.sh re-defines them).
- Size: M. Risk: medium (backups; a broken script fails silently until the next run). Live run of the scheduled job and one one-time run before merge.
- Acceptance:
  - One script produces both modes; privcloud one-time has the same excludes and layout.
  - Mirror without a valid source is refused.
  - Changing Immich storage needs no script refresh.
  - Set up, Status and Remove use one legacy-cron pattern and `_cron_get`.

---

## Piece 5: `.env` and compose files

Closes: D5 (structural part; the `config` fix is QW), D4, D33.

### D5 members

- Readers: `_env_get` (setup.sh:2502; 26 call sites; strips quotes); `envget` inside the generated disk-check (4647; handles inline comments and whitespace); privcloud `env_get` (120; 11 call sites; `cut -f2-`, no quote strip); inline unanchored `grep FILES_LOCATION ... | cut -d= -f2` at setup.sh:6892-6895 (remote status) and 6939-6942 (local status); `_configured_backup_dir` (4162, reads the installed script).
- Writers: `_set_env` (1670; 10 call sites; `sed -i "s|^key=.*|key=val|"`, so `|`, `&`, `\` corrupt a value); privcloud `cmd_config`; `.env.example` (stale `DATA_ROOT=/mnt/data` at :23, no `FILES_LOCATION`).
- Differs: quote handling differs across the three readers; unanchored greps match any line containing the key, including a commented-out one. Drift. CHANGELOG records `DATA_ROOT` replaced by `FILES_LOCATION`; `.env.example` still has the old key.

### D4: `patch_selinux`

- privcloud:124 `patch_selinux` (callers privcloud:296, 331); tracked docker-compose.yml:13 and :68 already carry `:Z`; setup.sh never calls it although `step_deploy` runs the same compose file (setup.sh:2426).
- Behaviour: on a non-Enforcing host, `privcloud start` runs `sed -i` to remove `:Z` from a tracked file and leaves the tree dirty. `_on_server` (setup.sh:436) runs `git pull --ff-only -q 2>/dev/null`; a dirty compose file would make later upstream edits a silent failed pull (UNVERIFIED, hypothetical).

### D33: defaults

- FILES_LOCATION fallback `/mnt/data` (setup.sh:1973-1974) vs `/mnt/data/data` (2528, 2558), the latter conflicting with `step_deploy` (2407, `FILES_LOCATION=${base_path}`); MEDIA default (1972, 2529, 2559, .env.example:17); immich fallback `/home/$USER/data/immich` (2533, 2564) vs `.env.example` `/mnt/data/immich/upload`; `FEDERVER_VERSION` fallback `0.9.5` (setup.sh:10) vs package.json 0.12.0. Reachable only when `.env` lacks the key; no failure.

### Design

- One reader and one writer in `lib/env.sh`: `env_get KEY`, `env_set KEY VAL` (update-in-place, literal matching via awk, anchored `^KEY=`, quotes handled one way, creates the line if missing). Sourced by setup.sh and privcloud. This is a small shared file; if piece 8 is declined, keep `lib/env.sh` as the only shared file, or duplicate with a cross-test (see below). Decision recorded in the Decisions log (Piece 8).
- The generated disk-check keeps its own `envget` (it must be self-contained); a test asserts all three readers agree on one fixture (quotes, inline comment, whitespace, commented-out key).
- Anchored reads in `step_status`; `_set_env` becomes a call to `env_set`.
- `.env.example` matches what `step_deploy` writes (`FILES_LOCATION`, no `DATA_ROOT`); add a test that every key `step_deploy` writes appears in `.env.example`.
- D4: never edit the tracked compose file. Either keep `:Z` committed and drop `patch_selinux`, or generate a git-ignored `docker-compose.selinux.yml` passed with a second `-f` when SELinux is not Enforcing. Pick one in the design review (recommended: keep `:Z` committed if non-SELinux hosts accept it; otherwise the override file).
- D33: `_data_defaults` returns the default for each data key, used by every fallback, and equal to what `step_deploy` writes. Version fallback reads package.json or fails loudly instead of a literal.
- Not merged: the Syncthing mount builder reading `.env` at `docker run` is intentional (a "Reapply paths" menu exists).

### Tests

- Pin: `_env_get` (smb-share.sh) stays green; add `env_get`/`env_set` fixtures; three-reader agreement; `env_set` with values containing `|`, `&`, `\`, spaces, `=`; commented-out key not matched.
- Fail-first: make `env_set` unanchored and confirm the commented-key test fails.
- Gaps: nothing covers `cmd_config`, `patch_selinux`, `.env.example` parity.
- Size: S to M. Risk: low to medium; `.env` holds the DB password, keep `chmod 600` and `umask 077` behaviour (project memory).
- Acceptance:
  - One `env_get`/`env_set`; `privcloud config` and `_set_env` use it.
  - No unanchored `grep KEY .env` remains.
  - `.env.example` has every key `step_deploy` writes and no `DATA_ROOT`.
  - After `privcloud start` the tracked compose file is unmodified (`git status` clean).

---

## Piece 4: Service lifecycle and status

Closes: D9 (structural part), D10, D11, D19, D25, D28, D30.

### D9 structural

- Delete `_services_action` and `step_services` (0 callers; the wrapper menu text is a copy). Put one `_svc_preflight <container|all>` where every start path passes (the picker, before `_svc_power_remote start` and before the All compose-up), mapping navidrome/filebrowser/all to their `.env` paths and calling `_drive_verdict` (piece 1). `step_deploy` (2417) keeps its call.

### D10: container rows and URLs

- Members: `_services_status` (setup.sh:1835; 2 callers; rows 1850-1870, URLs 1891-1908); `step_status` (6878; container rows ~7000-7040, URLs 7054-7072); `_show_laptop_services` (2055). The check/cross/warn classification (grep `unhealthy|exit|restart|^stopped` vs `healthy|^Up `) and the cpu/mem suffix loop are verbatim copies.
- Differs (drift): `_services_status` hard-codes "not created" rows for adguard and syncthing only (1875-1880) and gates the Syncthing URL on `Up` (1889); `step_status` shows the URL whenever the container exists; the Tailscale block uses `$HOST` in one and the literal `federver` in the other; samba is absent from the not-created rows. No wrong output reported.
- Design: `_render_container_rows` and `_render_service_urls <ip> <host> <containers>`; callers pass data.

### D11: Status remote vs local gather

- Members: `step_status` remote heredoc (6887-6910), local branch (6930-6950), `_storage_status` df line (1382). Remote lists every `/dev/*` mount (`df -h | awk '$1 ~ /^\/dev\//'`, 6907); the local branch (Status on the server menu `s`) runs `df -h / /home /mnt/data` (6947), so the USB backup drive and any non-`/mnt/data` drive vanish from Disk (code-proven). `.env` greps at 6892-6895 and 6939-6942 are unanchored (D5). `_storage_status` holds a third df filter equal to the remote one.
- Design: one gather function shipped with `declare -f` and run locally on the server, so both branches execute the same text.

### D19: container probes

- Members: `_container_gone` (2577; 4 call sites; the only one that separates "query failed" from "absent"); `_smb_exists` (7447), `_smb_running` (7448); `_syncthing_exists` (2695), `_syncthing_is_running` (2691); `_syncthing_server_probe` (2956-2960, has `docker-error`); REMOTE_STATUS (3005-3010); adguard inline 3806, 3807, 3911; emergency 500 and 506; `_storage_mount_source` (1259, `grep -q "^${container}$"`, the name used as a regex); `_pick_container` 1920/1922; `_services_logs` 2032; samba-poc 7921; privcloud:501 (`^${container}$`) and :796 (`-qx immich_postgres`).
- Differs: `sudo docker`, plain `docker`, `sg docker -c` variants; only two copies separate a failed query from absent. 4d94fff / CHANGELOG ("a failed docker query can no longer read as removed") fixed uninstall paths only. Partly harmful (history).
- Design: `_ctr_state NAME [docker-cmd]` prints `running|stopped|absent|error`, matched with exact name filters (no regex use of names); `_container_gone` becomes `[[ $(_ctr_state "$1") == absent ]]`. Callers keep their own docker prefix via the optional argument.

### D25: state vocabulary

- Members: setup.sh:2078-2087 and 2101-2106 (`Running*` / `NeedsLogin*` maps in `_unified_service_picker`), 2055-2071 `_show_laptop_services` (uses `_ts_word`), 7062 `TS_STATE == Running*`, 2060, `_ts_running` (843), `_ts_word` (850). Laptop Syncthing state derived at 2061, 2084, 2808, 2825, 2979, 2996 with different words. 5deecae replaced most call sites; four `Running*` globs remain. They agree today; the picker says "disconnected" where `_ts_word` says "not installed".
- Design: `_ts_side_label` and `_syncthing_laptop_state` helpers.

### D28: URL blocks and ports

- Members: setup.sh:1004-1007 (`_ts_install`), 1892-1908, 2438-2441 (`step_deploy`), 2484-2486 (Kuma hints), 7055-7072 (`step_status`), 7231-7243 (`step_save_to_pass`), 7378-7424 (`step_reset_password`), and privcloud 326-327, 350-351, 489-490. Ports 2283, 4533, 8080, 3001 (8384 Syncthing) written 20+ times; the same numbers in docker-compose.yml, `_fw_defaults` (748-751) and the Kuma push URL (4800). No wrong output today.
- Design: one `_SERVICE_PORTS` table feeding the URL renderer, `_fw_defaults` and the Save-to-pass text.

### D30: lists of services

- Members: Emergency `for c in adguard syncthing samba` (setup.sh:499); `_svc_power_all_body` (227; dynamic via `docker ps -a`); `_services_status` not-created rows (1875-1880; no samba); picker special cases for tailscale, syncthing, adguard (2108-2122, 2270-2275; no samba); `step_save_to_pass` FETCH list (7155-7190: wg, adguard, syncthing, .env, compose; no samba, no Kuma/disk-check token); Status URLs (D28).
- Evidence: 2cc42a1 ("Emergency restart includes samba") added samba after the SMB feature shipped in 9c6181b. Project memory records that Start All/Stop All needed explicit standalone-container inclusion before `_svc_power_all_body` became dynamic. Compose containers get `compose up -d` in Emergency but not the restart-policy repair the other paths do.
- Failure: a future standalone container is absent from Emergency until someone edits the list (happened with samba). Save-to-pass omits `/opt/samba` (login, password, share list), so a rebuilt server loses them (gap code-proven; consequence UNVERIFIED).
- Design: `_STANDALONE=(adguard syncthing samba)` (with menu number and install hint) used by Emergency, status rows and the picker; Emergency calls `_svc_power_all start`; add `/opt/samba` to Save-to-pass.

### Not merged

Tailscale is a native dnf package, not a container; it keeps its own state path (Watchtower cannot update it, by design). The `_ts_*_both` / `_syncthing_*_both` pair stays parallel (table-like dispatch exists).

### Tests

- Pin: svc-power.sh (`_svc_power_body`), smb-share.sh (Emergency includes samba; `@@SMB@@` appears in Status). Add golden rendering tests for rows and URLs fed from fixture data (running, stopped, unhealthy, absent, error); a `_ctr_state` test with a docker stub returning running, exited, no such container, and a failing daemon.
- Fail-first: break the unhealthy classification and the `error` branch.
- Gaps: `_unified_service_picker`, `_services_status`, `step_status` (beyond a grep), probes themselves, `_require_data_mount`.
- Size: M to L. Risk: medium; Status and Start/Stop are the daily surface. Do it after pieces 1 to 3 so the picker guard is already the shared one.
- Acceptance:
  - `_services_action` and `step_services` are gone.
  - Status on the server and from the laptop list the same drives.
  - One container-state probe; a failed docker query never reads as absent.
  - Adding a standalone container needs one `_STANDALONE` entry and appears in Emergency, Status and the picker.
  - Ports appear once in a table used by URL, firewall and Save-to-pass text.

---

## Piece 6: Uninstall / firewall / confirm helpers

Closes: D18, D21, D22, D24. Adopted as each service is next touched; no big-bang rewrite.

### D18: uninstallers

- Members: `_ts_uninstall` (setup.sh:920), `_ts_uninstall_both` (1084; 2 callers), `_syncthing_uninstall` (2593), `_syncthing_uninstall_both` (2916; 2 callers), `_rdp_uninstall` (3103), `_wg_uninstall` (3375), `_adguard_uninstall` (3984), `_smb_uninstall` (8048); plus the remote Tailscale removal one-liner at 1127, which duplicates `_ts_remove_local` (952; 2 callers) minus `hash -r`.
- Same shape: red banner, "What will happen / Consequences / Kept", `_confirm_delete`, remove, verify end state (`_container_gone` for containers; `rpm -q` / `type -P` for packages).
- Evidence: 4d94fff (2026-10-15) and CHANGELOG: "Server uninstall printed 'Server: removed.' while nothing had been removed", the same false success in the other uninstallers, WireGuard and remote-desktop printing "removed" unconditionally. Each copy had the bug and was fixed separately.
- Not merged: package-based (Tailscale, WireGuard, xrdp) and container-based uninstallers differ on purpose in what "gone" means.
- Design: shared `_uninstall_banner` and `_verify_gone container|pkg|unit NAME`; each uninstaller keeps its own steps. Replace the remote Tailscale one-liner with a shipped `_ts_remove_local`.

### D21: firewall

- Members: `_fw_defaults` (743; 2 callers), `_fw_add` (762), `_fw_remove` (776); Syncthing add 2741-2745 (unchecked) and close 2586-2590 (`_syncthing_fw_close`, checked); xrdp add 3207-3208 (`|| true`) and close 3136; WireGuard add 3629 and again 3721 (`|| true`) and close 3402 (literal 51820 while `wg_port` is a variable); AdGuard add 3884-3887 and close 4016-4019; SMB query 7626-7627.
- Differs (drift): add paths ignore failure; remove paths verify. Port numbers are written twice per service and must match by hand.
- Design: `_fw_open PORT/PROTO...` and `_fw_close PORT/PROTO...` return non-zero on failure and reload once; each service keeps a port-list constant beside its install (shared with `_SERVICE_PORTS`, piece 4).

### D22: server sudo password

- Members: `_server_sudo_pw_prompt` (282; 3 callers) and `_server_sudo_run` (302; 8 callers) vs the inline copy in `_sync_one_time_backup` (6546 `read -rsp "federver sudo password: "`, then `printf | ssh ... sudo -S -p ''` for the size probe and the tar read).
- Differs: the helper verifies first (`sudo -S true`) and separates wrong password (rc 1) from unreachable (rc 2); the download learns of a bad password only after the pipeline fails and prints one generic message (6594).
- Design: the download uses the helper and `_SRV_PW`.

### D24: confirms

- Members: `_confirm_delete` (3968; 10 callers); `_disk_check_remove` (4806; inline typed confirm at 4812-4816, different wording, cancel returns 0); `_immich_backup_remove` (4524; plain y/N at 4559); 36 other `[y/N]` / `[Y/n]` prompts with three accept patterns (`^[Yy]$` after `read -n 1`, the same after a normal read, `^[Yy]([Ee][Ss])?$` in `_mirror_preview`) and different EOF handling (`|| reply=""` at only a few sites). No failure.
- Design: `_ask_yn PROMPT default` and `_confirm_typed WORD VERB`. Low value; adopt per file when touched. The typed `delete` word for mirror stays exact.

### Tests

- Pin: smb-share.sh covers `_confirm_delete` and `_smb_uninstall`. Add per touched uninstaller: a stub that makes removal fail must not print "removed" (this is the bug class); `_fw_open/_fw_close` with a failing `firewall-cmd`; `_server_sudo_run` wrong password (rc 1) vs unreachable (rc 2) in the download path.
- Fail-first: make `_verify_gone` always succeed and confirm the stubbed-failure tests fail.
- Gaps: uninstallers other than SMB, `_fw_*`, the download.
- Size: M. Risk: low per adoption; uninstallers are destructive, so keep the typed-name confirm and "keep `/opt/<service>` config" behaviour unchanged.
- Acceptance:
  - Every uninstaller verifies the end state through `_verify_gone`.
  - Firewall adds report failure; ports are listed once per service.
  - The download uses `_server_sudo_*` and reports a wrong password specifically.

---

## Piece 7: Menu table and doc checks

Closes: D29 (structural), D31, D32.

### D29: menu numbers

- Members: 38 `federver -> N` / `privcloud -> N` references in setup.sh (e.g. 1310, 1560, 1626, 1644, 2023, 4382, 4509, 4592, 4774, 4956, 7705, 7914); `_show_laptop_menu` (559); the main `case` (8160-8185); customer-guide.md menu copy (90-125) and its numbered references; the duplicated wrapper/`step_services` menus (D9).
- References verified correct in the report: 14 -> 1/6/7, 7 -> 3/5, 11 -> 2, 8, 10, 12, 15, 16, and privcloud 9 -> 2/3. The four stale ones are fixed in QW.
- Design: a `_MENU` associative array (`_MENU[services]=7 ...`) used by both the `case` and every message; a test that extracts `federver -> N` references from setup.sh, README.md and customer-guide.md and checks each label exists in `_show_laptop_menu`.

### D31: `declare -f` payloads

- Members: setup.sh:1165, 1176, 2101 (`_ts_ipv4 _ts_state`), 1844 and 2093 (`_ps_autostart`), 2909 (`_syncthing_fw_close`), 5056, 5058, 5167 (mirror functions), 6886 (`_ts_ipv4 _ts_state _ps_autostart _smb_summary _smb_folder_check _smb_sessions _smb_devices _smb_devname`), 7155 (`_ts_ipv4 _ts_state _ts_running`). Each is a hand-maintained dependency closure.
- Evidence: ddfdf5b ("Every declare -f list that ships _ts_state to the server now ships _ts_ipv4"); ts-expiry.sh runs every payload in a clean `bash -s` to catch it.
- Design: named bundles (`_BUNDLE_TS`, `_BUNDLE_SMB`, `_BUNDLE_MIRROR`, plus the endpoint and drive-verdict bundles from pieces 1 and 2) and one `_ship BUNDLE` helper; ts-expiry.sh's clean-shell run covers every bundle.

### D32: disk-check constants

- Members: cron `*/5 * * * *` (setup.sh:4975); staleness `age > 720` at 4857 and 5990 (`_disk_check_last_age` 4832, whose comment says it "mirrors the Status view's calculation"); Kuma "Heartbeat Interval 360" (4897); `THRESHOLD=85` (4638) vs text "alerts above 85%" (4992). No mismatch today.
- Design: `_DC_INTERVAL_MIN`, `_DC_STALE_SEC`, `_DC_THRESHOLD` constants; ship `_disk_check_last_age` to Status.

### Tests

- Pin: ts-expiry.sh payload completeness; disk-check.sh script tests.
- New: the menu-reference test (fail-first: renumber a menu entry and confirm it fails); a bundle test per bundle in a clean shell; constants appear once.
- Gaps: no test of menu references today.
- Size: S. Risk: low; a wrong `_MENU` index is caught by the new test.
- Acceptance:
  - A stale `federver -> N` in setup.sh, README.md or customer-guide.md fails the test suite.
  - Every payload list is a named bundle and runs in a clean shell.
  - The 85 / 5 min / 720 s constants each appear once.

---

## Piece 8: privcloud and setup.sh shared lib (optional)

Closes: D26, D15, D16, D17. Only if a sourced `lib/common.sh` is accepted under the "lightweight" rule (open decision). If declined, the members stay as documented copies and D16's drive guard is still added in piece 1's follow-up.

### D26: helper copies

- Colours: privcloud:40-43 `red/green/yellow/bold` vs setup.sh:56-67 `ok/fail/info/warn` (different escape codes and newline handling).
- Local IP: privcloud:74 `get_ip` (macOS aware) vs 17 inline `hostname -I | awk '{print $1}'` in setup.sh (650, 739, 1884, 2433, 2701, 2737, 3012, 3164, 3211, 3512, 3645, 3767, 4871, 6888, 6934, 7158, 7339).
- Version reader: the same sed at setup.sh:9-12 and privcloud:13-19; fallbacks differ (`0.9.5` vs `unknown`; package.json is 0.12.0). 244c36b set the literal.
- Immich ping: `curl -s http://localhost:2283/api/server/ping | grep -q pong` x4 in privcloud (319, 343, 484, 576).
- Compose: `run_compose` (privcloud:95) vs 9 inline `sg docker -c "docker compose ..."` in setup.sh (495, 1735, 1774, 1828, 1994, 2241, 2426, 7404-7422).
- Autostart rule: privcloud:110 `keep_autostart` vs `_svc_power_body` (setup.sh:204): same `unless-stopped` rule, but no read-back of state or policy (the setup version exits 6 on mismatch).
- `.env` (D5, piece 5) and `elevate` vs `sudo`.
- Differs: partly intentional (privcloud is multi-OS, setup.sh is Fedora-only); `step_docker` vs `ensure_docker` stays separate. Colours and the autostart read-back are drift.

### D15: pickers

- `_pick_local_path` (setup.sh:6188; 7 callers) and `_pick_server_path` (6232; 7 callers): same 3-attempt loop, quote stripping, validation and "Contents of" listing. Presets differ: server presets `/home/$SERVER_USER/data` and `/mnt/data` are hard-coded (6238-6251) and duplicate the data-root choice stored in `.env` (FILES_LOCATION); local presets are Documents etc. plus USB mounts (6168). No failure.
- Design: `_pick_path <loc> <validate> <presets>` with presets read from `.env`.

### D16: `_storage_change_*`

- `_storage_change_music` (1697) and `_storage_change_files` (1740) are verbatim copies except the key, label and an `_install_smart_playlists` line; `_storage_change_immich` (1779) is a variant. Same prompt, `[Y/n]` create (`sudo mkdir -p`, `chown`), `_set_env`, `compose up --force-recreate`. None calls `_require_data_mount`: answering a new `/mnt/...` path with the drive unmounted creates it on the system disk (UNVERIFIED live; same mechanism as 170ba69). `_storage_change_immich` does not refresh immich-backup.sh (fixed by piece 3) or Syncthing.
- Design: `_storage_change <key> <label> <service...>` with a hook list, calling `_drive_verdict` before `mkdir`.

### D17: Syncthing

- `_syncthing_build_mounts` (2519; 2 callers) and `_syncthing_show_paths` (2548; 4 callers) resolve data/media/immich paths with the same defaults. Server status three ways: `_syncthing_status` (2699), the inline REMOTE_STATUS heredoc (3005-3020), `_syncthing_server_probe` (2956). Behaviour matches.
- Design: one `_syncthing_paths` function; ship `_syncthing_status` with `declare -f`.

### Design

- `lib/common.sh` sourced by both tools (colours, `local_ip`, version, `immich_ping`, compose helper); `keep_autostart` reuses the setup-side verification text. The sourced file must be located relative to the script (no absolute paths) and work from the `/usr/local/bin` wrappers. Each item is minor alone; if declined, do only D15/D16/D17 inside setup.sh.
- Not merged: `step_docker` vs `ensure_docker`; the macOS-aware `get_ip` stays privcloud-side unless the lib keeps the macOS branch.

### Tests

- Pin: privcloud-autostart.sh (`keep_autostart`), syncthing-gate.sh (gate only), sync-mirror.sh (pickers stubbed). Add: version reader agreement, `_storage_change` refuses an unmounted `/mnt/...` path (fail-first), sourcing works from the wrapper location.
- Gaps: `_storage_change_*`, `_syncthing_status`, privcloud helpers other than `keep_autostart`.
- Size: S to M. Risk: medium for the lib (both entry points depend on it), low for D15/D16/D17.
- Acceptance:
  - If accepted: one definition each of colours, local IP, version, immich ping, compose; both tools source it and the suites pass.
  - `_storage_change_*` share one function and refuse an unmounted new path.
  - Syncthing paths are resolved in one function.

---

## Decisions log

Copied from the PRD, with options and evidence from the audit. All open until the user decides.

### 1. rsync exit 24 in sync jobs ("source files vanished during transfer")

| Option | Effect |
|---|---|
| A. success with note (recommended) | log `ok (some files vanished)`; status `last: ok (some files vanished)` |
| B. failure | log the exit code; status `last: failed (exit 24)` |

Evidence: the template captured the exit code wrongly before d57409f (every failure logged as 0); piece 2 captures rsync's real code, so 24 becomes visible for the first time. Sources that change during a run (live photo libraries, mail folders) hit 24 routinely; treating it as failure would show red on a run that copied everything that existed at the start. Option B is the safer reading for mirror jobs, since vanished files may mean the source is changing under a `--delete` run; the mirror source guard (D8) already covers missing and unmounted sources. Single `case` line in the template, either choice is cheap to change.

### 2. Legacy job scripts: re-render timing

| Option | Effect |
|---|---|
| A. on first Status view with a one-line notice (recommended) | old scripts stop carrying the exit-code bug without the user touching them |
| B. on first edit only | untouched jobs keep logging `last: ok` for failures |

Evidence: d57409f and the CHANGELOG line "Job scripts already on disk keep the old logging until the job is deleted and created again"; 555820d's fourth awk rule only runs if the user re-selects a copy mode. Import refuses ambiguous scripts with a reason in either option (piece 2); a Status view that triggers writes needs the atomic write and `.bak` described there.

### 3. Piece 8: `lib/common.sh` sourced by both tools

| Option | Effect |
|---|---|
| A. yes | one definition of colours, local IP, version, ping, compose, autostart read-back; adds a sourced file and a path-resolution requirement for the `/usr/local/bin` wrappers |
| B. no | copies stay; `lib/env.sh` (piece 5) is the only shared file or `env_get`/`env_set` is duplicated with a cross-test |

Evidence: D26 lists 8 copies with real drift only in the version fallback (`0.9.5` vs `unknown`) and the autostart read-back; none caused a failure. CLAUDE.md "lightweight over complex" and "fewer moving parts" weigh against a new sourced file; "one source" weighs for it. Piece 5 is affected: it assumes at least `lib/env.sh`.

### 4. `privcloud config` on a federver server

| Option | Effect |
|---|---|
| A. keep, update only its own keys (recommended) | uses `env_set`; fixes D5 with no menu change |
| B. remove in favour of `federver -> 11` | one place edits storage paths; removes a menu item |

Evidence: D5 failure is the whole-file overwrite (drops FILES/MEDIA/MUSIC_LOCATION); `federver -> 11` already edits storage paths through `_storage_change_*`, which also have no drive guard (D16). The report's open question recommends keeping it with UPLOAD_LOCATION and DB_DATA_LOCATION only. QW ships option A either way.
