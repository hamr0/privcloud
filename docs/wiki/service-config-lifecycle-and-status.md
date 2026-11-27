---
title: Service config, lifecycle and status
description: Design for the .env/compose single sources (piece 5) and service lifecycle and status unification (piece 4) in the single-source spec.
sources:
  - docs/archive/spec-single-source.md
---

# Service config, lifecycle and status

This page covers two pieces of the single-source spec: Piece 5 (`.env` and compose files) and Piece 4 (service lifecycle and status). Piece 5 closes D5 (structural part), D4 and D33 (docs/archive/spec-single-source.md:333-335), plus D26, D15, D16 and D17 from the shared lib folded in from the former piece 8. Piece 4 closes D9 (structural part), D10, D11, D19, D25, D28 and D30 (docs/archive/spec-single-source.md:376-378).

## Piece 5: `.env` and compose files

### D5: readers and writers of `.env`

- Several readers exist: `_env_get` in setup.sh (26 call sites, strips quotes), an `envget` inside the generated disk-check (handles inline comments and whitespace), privcloud's `env_get` (11 call sites, no quote strip), and inline unanchored greps in the remote and local status code (docs/archive/spec-single-source.md:339).
- Writers are `_set_env` (a `sed -i` substitution, so `|`, `&` and `\` corrupt a value), privcloud `cmd_config`, and `.env.example`, which still has the stale `DATA_ROOT` key and no `FILES_LOCATION` (docs/archive/spec-single-source.md:340).
- The drift: quote handling differs across the three readers, and unanchored greps match any line containing the key, including a commented-out one (docs/archive/spec-single-source.md:341).
- Design: one reader and one writer in `lib/common.sh` (the shared lib, decided 2026-11-27), namely `env_get KEY` and `env_set KEY VAL`. The writer updates in place with literal awk matching, anchored on `^KEY=`, handles quotes one way, and creates the line if missing. Both setup.sh and privcloud source it (docs/archive/spec-single-source.md:354).
- The generated disk-check keeps its own `envget` because it must be self-contained. A test asserts all three readers agree on one fixture (docs/archive/spec-single-source.md:355).
- `step_status` gets anchored reads, and `_set_env` becomes a call to `env_set` (docs/archive/spec-single-source.md:356).
- `.env.example` should match what `step_deploy` writes, with a test that every key `step_deploy` writes appears in it (docs/archive/spec-single-source.md:357).
- Not merged: the Syncthing mount builder reading `.env` at `docker run` is intentional, since a "Reapply paths" menu exists (docs/archive/spec-single-source.md:360).

### D4: `patch_selinux`

- privcloud's `patch_selinux` edits a tracked file, although the tracked compose file already carries `:Z`, and setup.sh never calls it even though `step_deploy` runs the same compose file (docs/archive/spec-single-source.md:345).
- On a non-Enforcing host, `step_immich_start` (federver → i → Start) removes `:Z` with `sed -i` and leaves the tree dirty. A dirty compose file could make a later `git pull --ff-only` fail silently; this is marked UNVERIFIED and hypothetical (docs/archive/spec-single-source.md:346).
- Design: never edit the tracked compose file. Either keep `:Z` committed and drop `patch_selinux`, or generate a git-ignored `docker-compose.selinux.yml` passed with a second `-f` when SELinux is not Enforcing. The recommendation is to keep `:Z` committed if non-SELinux hosts accept it, otherwise the override file (docs/archive/spec-single-source.md:358).

### D33: defaults

- Fallbacks disagree. `FILES_LOCATION` falls back to `/mnt/data` in one place and `/mnt/data/data` in others, the latter conflicting with `step_deploy`. The immich fallback differs from `.env.example`, and the `FEDERVER_VERSION` fallback (`0.9.5`) differs from package.json (`0.12.0`). They are reachable only when `.env` lacks the key, and nothing fails (docs/archive/spec-single-source.md:350).
- Design: `_data_defaults` returns the default for each data key, used by every fallback and equal to what `step_deploy` writes. The version fallback reads package.json or fails loudly instead of using a literal (docs/archive/spec-single-source.md:359).

### Piece 5 tests and acceptance

- Pin: `_env_get` in smb-share.sh stays green. Add `env_get`/`env_set` fixtures, three-reader agreement, `env_set` with values containing `|`, `&`, `\`, spaces and `=`, and a check that a commented-out key is not matched (docs/archive/spec-single-source.md:364).
- Fail-first: make `env_set` unanchored and confirm the commented-key test fails (docs/archive/spec-single-source.md:365).
- Gaps: nothing covers `step_immich_config` (was `cmd_config`), `patch_selinux` or `.env.example` parity (docs/archive/spec-single-source.md:366).
- Size S to M, risk low to medium. `.env` holds the DB password, so `chmod 600` and `umask 077` behaviour must be kept (docs/archive/spec-single-source.md:367).
- Acceptance (docs/archive/spec-single-source.md:368-372):
  - One `env_get`/`env_set`, used by `step_immich_config` and `_set_env` (done: `_set_env` is the one writer, `_env_get` the one reader).
  - No unanchored `grep KEY .env` remains.
  - `.env.example` has every key `step_deploy` writes and no `DATA_ROOT`.
  - After federver → i → Start the tracked compose file is unmodified (`git status` clean).

## Piece 4: Service lifecycle and status

### D9 structural: one start preflight

- Delete `_services_action` and `step_services`, which have no callers. Add one `_svc_preflight <container|all>` on every start path (the picker, before `_svc_power_remote start`, and before the All compose-up). It maps navidrome, filebrowser and all to their `.env` paths and calls `_drive_verdict` from piece 1. `step_deploy` keeps its call (docs/archive/spec-single-source.md:382).

### D10: container rows and URLs

- Members: `_services_status`, `step_status` and `_show_laptop_services`. The check/cross/warn classification and the cpu/mem suffix loop are verbatim copies (docs/archive/spec-single-source.md:386).
- Drift: `_services_status` hard-codes "not created" rows for adguard and syncthing only and gates the Syncthing URL on `Up`, while `step_status` shows the URL whenever the container exists. The Tailscale block uses `$HOST` in one place and the literal `federver` in the other, and samba is absent from the not-created rows. No wrong output was reported (docs/archive/spec-single-source.md:387).
- Design: `_render_container_rows` and `_render_service_urls <ip> <host> <containers>`, with callers passing data (docs/archive/spec-single-source.md:388).

### D11: Status remote vs local gather

- The remote branch lists every `/dev/*` mount, but the local branch (Status on the server menu) runs `df -h / /home /mnt/data`. The USB backup drive and any non-`/mnt/data` drive therefore vanish from Disk (code-proven). `_storage_status` holds a third df filter equal to the remote one (docs/archive/spec-single-source.md:392).
- Design: one gather function shipped with `declare -f` and run locally on the server, so both branches execute the same text (docs/archive/spec-single-source.md:393).

### D19: container probes

- Many copies of "does this container exist or run" exist, including `_container_gone`, the samba and syncthing probes, inline adguard checks, emergency checks, `_storage_mount_source` (which uses the container name as a regex), and privcloud's own checks (docs/archive/spec-single-source.md:397).
- They differ in `sudo docker`, plain `docker` and `sg docker -c` variants, and only two copies separate a failed query from absent. An earlier fix covered uninstall paths only (docs/archive/spec-single-source.md:398).
- Design: `_ctr_state NAME [docker-cmd]` prints `running|stopped|absent|error`, using exact name filters with no regex use of names. `_container_gone` becomes `[[ $(_ctr_state "$1") == absent ]]`, and callers keep their own docker prefix through the optional argument (docs/archive/spec-single-source.md:399).

### D25: state vocabulary

- Tailscale and Syncthing state words are derived in many places (the unified picker, `_show_laptop_services`, `_ts_running`, `_ts_word`, and several Syncthing sites). Four `Running*` globs remain. They agree today, but the picker says "disconnected" where `_ts_word` says "not installed" (docs/archive/spec-single-source.md:403).
- Design: `_ts_side_label` and `_syncthing_laptop_state` helpers (docs/archive/spec-single-source.md:404).

### D28: URL blocks and ports

- URL blocks appear in `_ts_install`, the status code, `step_deploy`, the Kuma hints, `step_save_to_pass`, `step_reset_password` and privcloud. Ports 2283, 4533, 8080, 3001 (and 8384 for Syncthing) are written 20+ times, and the same numbers sit in docker-compose.yml, `_fw_defaults` and the Kuma push URL. No wrong output today (docs/archive/spec-single-source.md:408).
- Design: one `_SERVICE_PORTS` table feeding the URL renderer, `_fw_defaults` and the Save-to-pass text (docs/archive/spec-single-source.md:409).

### D30: lists of services

- Separate lists exist in Emergency restart (`adguard syncthing samba`), `_svc_power_all_body` (dynamic via `docker ps -a`), the not-created rows (no samba), the picker special cases (no samba), the Save-to-pass FETCH list (no samba, no Kuma/disk-check token), and the Status URLs (docs/archive/spec-single-source.md:413).
- Evidence: samba was added to Emergency only after the SMB feature shipped. Project memory records that Start All/Stop All also once needed explicit standalone-container inclusion. Compose containers get `compose up -d` in Emergency but not the restart-policy repair other paths do (docs/archive/spec-single-source.md:414).
- Failure: a future standalone container is absent from Emergency until someone edits the list. Save-to-pass omits `/opt/samba` (login, password, share list), so a rebuilt server loses them; the gap is code-proven and the consequence UNVERIFIED (docs/archive/spec-single-source.md:415).
- Design: `_STANDALONE=(adguard syncthing samba)` with menu number and install hint, used by Emergency, status rows and the picker. Emergency calls `_svc_power_all start`, and `/opt/samba` is added to Save-to-pass (docs/archive/spec-single-source.md:416).

### Not merged

Tailscale is a native dnf package, not a container, so it keeps its own state path (Watchtower cannot update it, by design). The `_ts_*_both` and `_syncthing_*_both` pair stays parallel because table-like dispatch exists (docs/archive/spec-single-source.md:420).

### Piece 4 tests and acceptance

- Pin: svc-power.sh and smb-share.sh. Add golden rendering tests for rows and URLs fed from fixture data (running, stopped, unhealthy, absent, error), and a `_ctr_state` test with a docker stub returning running, exited, no such container, and a failing daemon (docs/archive/spec-single-source.md:424).
- Fail-first: break the unhealthy classification and the `error` branch (docs/archive/spec-single-source.md:425).
- Gaps: `_unified_service_picker`, `_services_status`, `step_status` (beyond a grep), the probes themselves, and `_require_data_mount` (docs/archive/spec-single-source.md:426).
- Size M to L, risk medium, since Status and Start/Stop are the daily surface. Do it after pieces 1 to 3 so the picker guard is already the shared one (docs/archive/spec-single-source.md:427).
- Acceptance (docs/archive/spec-single-source.md:428-433):
  - `_services_action` and `step_services` are gone.
  - Status on the server and from the laptop list the same drives.
  - One container-state probe; a failed docker query never reads as absent.
  - Adding a standalone container needs one `_STANDALONE` entry and appears in Emergency, Status and the picker.
  - Ports appear once in a table used by URL, firewall and Save-to-pass text.
