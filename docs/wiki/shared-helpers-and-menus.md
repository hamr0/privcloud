---
title: Shared helpers and menus
description: Spec pieces 6-8 - consolidating uninstall, firewall, sudo-password and confirm helpers, a menu table with doc checks, and an optional shared lib.
sources:
  - docs/archive/spec-single-source.md
---

# Shared helpers and menus

This page covers pieces 6 to 8 of the single-source spec. Piece 6 consolidates uninstall, firewall and confirm helpers. Piece 7 adds a menu table and doc checks. The shared library (formerly piece 8) was accepted on 2026-11-27 and folded into piece 5. All are adopted incrementally, with no big-bang rewrite (docs/archive/spec-single-source.md:439-439).

## Piece 6: uninstall, firewall and confirm helpers

Closes D18, D21, D22 and D24 (docs/archive/spec-single-source.md:439-439).

### D18: uninstallers

- Eight uninstallers share one shape: `_ts_uninstall`, `_ts_uninstall_both`, `_syncthing_uninstall`, `_syncthing_uninstall_both`, `_rdp_uninstall`, `_wg_uninstall`, `_adguard_uninstall` and `_smb_uninstall`. A remote Tailscale removal one-liner also duplicates `_ts_remove_local` minus `hash -r` (docs/archive/spec-single-source.md:443-443).
- Common shape: red banner, "What will happen / Consequences / Kept", `_confirm_delete`, remove, then verify the end state with `_container_gone` or `rpm -q` / `type -P` (docs/archive/spec-single-source.md:444-444).
- The evidence is a recurring false-success bug. The server uninstall printed "Server: removed." while nothing had been removed. WireGuard and remote-desktop printed "removed" unconditionally. Each copy had the bug and was fixed separately (docs/archive/spec-single-source.md:445-445).
- Package-based and container-based uninstallers are not merged, because "gone" means different things for each (docs/archive/spec-single-source.md:446-446).
- Design: a shared `_uninstall_banner` and `_verify_gone container|pkg|unit NAME`. Each uninstaller keeps its own steps. The remote one-liner is replaced by a shipped `_ts_remove_local` (docs/archive/spec-single-source.md:447-447).

### D21: firewall

- Members: `_fw_defaults`, `_fw_add` and `_fw_remove`, plus per-service open and close code for Syncthing, xrdp, WireGuard, AdGuard and an SMB query (docs/archive/spec-single-source.md:451-451).
- Drift: add paths ignore failure while remove paths verify. Port numbers are written twice per service and must match by hand (docs/archive/spec-single-source.md:452-452).
- Design: `_fw_open PORT/PROTO...` and `_fw_close PORT/PROTO...` return non-zero on failure and reload once. Each service keeps one port-list constant beside its install, shared with `_SERVICE_PORTS` from piece 4 (docs/archive/spec-single-source.md:453-453).

### D22: server sudo password

- `_server_sudo_pw_prompt` and `_server_sudo_run` are the helpers. `_sync_one_time_backup` has an inline copy that reads the password and pipes it to `sudo -S` (docs/archive/spec-single-source.md:457-457).
- The helper verifies first and separates a wrong password (rc 1) from an unreachable server (rc 2). The download only learns of a bad password after the pipeline fails and prints one generic message (docs/archive/spec-single-source.md:458-458).
- Design: the download uses the helper and `_SRV_PW` (docs/archive/spec-single-source.md:459-459).

### D24: confirms

- `_confirm_delete` has 10 callers. `_disk_check_remove` uses an inline typed confirm with different wording, and `_immich_backup_remove` uses a plain y/N. 36 other `[y/N]` / `[Y/n]` prompts use three accept patterns and inconsistent EOF handling. None of this is a failure today (docs/archive/spec-single-source.md:463-463).
- Design: `_ask_yn PROMPT default` and `_confirm_typed WORD VERB`. Value is low, so adopt per file when touched. The typed `delete` word for mirror stays exact (docs/archive/spec-single-source.md:464-464).

### Piece 6 tests and acceptance

- Pin: smb-share.sh already covers `_confirm_delete` and `_smb_uninstall`. For each touched uninstaller, add a stub whose failed removal must not print "removed". Also test `_fw_open/_fw_close` with a failing `firewall-cmd`, and `_server_sudo_run` wrong password versus unreachable in the download path (docs/archive/spec-single-source.md:468-468).
- Fail-first: make `_verify_gone` always succeed and confirm the stubbed-failure tests fail (docs/archive/spec-single-source.md:469-469).
- Gaps: uninstallers other than SMB, `_fw_*`, and the download (docs/archive/spec-single-source.md:470-470).
- Size M, risk low per adoption. Keep the typed-name confirm and the "keep `/opt/<service>` config" behaviour unchanged, because uninstallers are destructive (docs/archive/spec-single-source.md:471-471).
- Acceptance (docs/archive/spec-single-source.md:472-475):
  - Every uninstaller verifies the end state through `_verify_gone`.
  - Firewall adds report failure, and ports are listed once per service.
  - The download uses `_server_sudo_*` and reports a wrong password specifically.

## Piece 7: menu table and doc checks

Closes D29 (structural), D31 and D32 (docs/archive/spec-single-source.md:481-481).

### D29: menu numbers

- Menu numbers are scattered across 38 `federver -> N` / `privcloud -> N` references in setup.sh, `_show_laptop_menu`, the main `case`, the customer guide's menu copy, and the duplicated wrapper/`step_services` menus (docs/archive/spec-single-source.md:485-485).
- The report verified the existing references as correct, apart from four stale ones that are fixed in the quick-wins pass (docs/archive/spec-single-source.md:486-486).
- Design: a `_MENU` associative array (`_MENU[services]=7 ...`) used by both the `case` and every message. A test extracts `federver -> N` references from setup.sh, README.md and customer-guide.md and checks each label exists in `_show_laptop_menu` (docs/archive/spec-single-source.md:487-487).

### D31: `declare -f` payloads

- Several `declare -f` lists ship function sets to the server, for example `_ts_ipv4 _ts_state` and the SMB and mirror function groups. Each is a hand-maintained dependency closure (docs/archive/spec-single-source.md:491-491).
- Evidence: commit ddfdf5b fixed every list that shipped `_ts_state` without `_ts_ipv4`. ts-expiry.sh runs every payload in a clean `bash -s` to catch this (docs/archive/spec-single-source.md:492-492).
- Design: named bundles (`_BUNDLE_TS`, `_BUNDLE_SMB`, `_BUNDLE_MIRROR`, plus the endpoint and drive-verdict bundles from pieces 1 and 2) and one `_ship BUNDLE` helper. The clean-shell run in ts-expiry.sh then covers every bundle (docs/archive/spec-single-source.md:493-493).

### D32: disk-check constants

- The same values appear in several places: cron `*/5 * * * *`, staleness `age > 720` at two sites, Kuma "Heartbeat Interval 360", and `THRESHOLD=85` against text saying "alerts above 85%". They do not mismatch today (docs/archive/spec-single-source.md:497-497).
- Design: `_DC_INTERVAL_MIN`, `_DC_STALE_SEC` and `_DC_THRESHOLD` constants, and ship `_disk_check_last_age` to Status (docs/archive/spec-single-source.md:498-498).

### Piece 7 tests and acceptance

- Pin: ts-expiry.sh payload completeness and the disk-check.sh script tests (docs/archive/spec-single-source.md:502-502).
- New: the menu-reference test, which is fail-first by renumbering a menu entry. Also a bundle test per bundle in a clean shell, and a check that constants appear once (docs/archive/spec-single-source.md:503-503).
- There is no test of menu references today (docs/archive/spec-single-source.md:504-504).
- Size S, risk low. A wrong `_MENU` index is caught by the new test (docs/archive/spec-single-source.md:505-505).
- Acceptance (docs/archive/spec-single-source.md:506-509):
  - A stale `federver -> N` in setup.sh, README.md or customer-guide.md fails the test suite.
  - Every payload list is a named bundle and runs in a clean shell.
  - The 85 / 5 min / 720 s constants each appear once.

## Shared lib (former piece 8, now part of piece 5)

Closes D26, D15, D16 and D17. Decided 2026-11-27: one `lib/common.sh`, sourced by both tools, built in piece 5 together with the `.env` reader/writer (docs/archive/spec-single-source.md:515-515).

### D26: helper copies

- Colours: privcloud uses `red/green/yellow/bold`, while setup.sh uses `ok/fail/info/warn`, with different escape codes and newline handling (docs/archive/spec-single-source.md:519-519).
- Local IP: privcloud has a macOS-aware `get_ip`, while setup.sh repeats an inline `hostname -I | awk` 17 times (docs/archive/spec-single-source.md:520-520).
- Version reader: the same sed appears in both tools, with different fallbacks (docs/archive/spec-single-source.md:521-521).
- Immich ping: the same `curl ... | grep -q pong` appears four times in privcloud (docs/archive/spec-single-source.md:522-522).
- Compose: `run_compose` in privcloud versus 9 inline `sg docker -c "docker compose ..."` calls in setup.sh (docs/archive/spec-single-source.md:523-523).
- Autostart rule: `keep_autostart` and `_svc_power_body` share the `unless-stopped` rule, but only the setup version reads state back and exits 6 on mismatch (docs/archive/spec-single-source.md:524-524).
- The differences are partly intentional, since privcloud is multi-OS and setup.sh is Fedora-only. `step_docker` versus `ensure_docker` stays separate. Colours and the autostart read-back are real drift (docs/archive/spec-single-source.md:526-526).

### D15: pickers

- `_pick_local_path` and `_pick_server_path` (7 callers each) share the same 3-attempt loop, quote stripping, validation and listing. Server presets are hard-coded and duplicate the data-root choice stored in `.env` (FILES_LOCATION). There is no failure today (docs/archive/spec-single-source.md:530-530).
- Design: `_pick_path <loc> <validate> <presets>`, with presets read from `.env` (docs/archive/spec-single-source.md:531-531).

### D16: `_storage_change_*`

- `_storage_change_music` and `_storage_change_files` are verbatim copies except for the key, label and one `_install_smart_playlists` line. `_storage_change_immich` is a variant (docs/archive/spec-single-source.md:535-535).
- None calls `_require_data_mount`. Answering a new `/mnt/...` path with the drive unmounted creates it on the system disk. This is unverified live, but it uses the same mechanism as commit 170ba69 (docs/archive/spec-single-source.md:535-535).
- Design: `_storage_change <key> <label> <service...>` with a hook list, calling `_drive_verdict` before `mkdir` (docs/archive/spec-single-source.md:536-536).

### D17: Syncthing

- `_syncthing_build_mounts` and `_syncthing_show_paths` resolve the same paths with the same defaults. Server status is implemented three ways, though behaviour matches (docs/archive/spec-single-source.md:540-540).
- Design: one `_syncthing_paths` function, and ship `_syncthing_status` with `declare -f` (docs/archive/spec-single-source.md:541-541).

### Design

- `lib/common.sh` is sourced by both tools and holds colours, `local_ip`, version, `immich_ping` and the compose helper. It also holds `env_get`/`env_set` (piece 5). The path to it must be relative to the script and work from the `/usr/local/bin` wrappers (docs/archive/spec-single-source.md:545-545).
- Not merged: `step_docker` versus `ensure_docker`. The macOS-aware `get_ip` stays privcloud-side unless the lib keeps the macOS branch (docs/archive/spec-single-source.md:546-546).

### Shared lib tests and acceptance

- Pin: privcloud-autostart.sh, syncthing-gate.sh and sync-mirror.sh. Add: version reader agreement, a fail-first test that `_storage_change` refuses an unmounted `/mnt/...` path, and sourcing from the wrapper location (docs/archive/spec-single-source.md:550-550).
- Gaps: `_storage_change_*`, `_syncthing_status`, and privcloud helpers other than `keep_autostart` (docs/archive/spec-single-source.md:551-551).
- Size S to M. Risk is medium for the lib, because both entry points depend on it, and low for D15 to D17 (docs/archive/spec-single-source.md:552-552).
- Acceptance (docs/archive/spec-single-source.md:553-556):
  - Each of colours, local IP, version, immich ping and compose has one definition. Both tools source it and the suites pass.
  - `_storage_change_*` share one function and refuse an unmounted new path.
  - Syncthing paths are resolved in one function.
