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
| 5 | Shared lib `lib/common.sh`: `.env`, compose and duplicated helpers | D5, D4, D33, D26, D15, D16, D17 | one `lib/common.sh`, sourced by both tools, holds the only `.env` reader and key-updating writer plus each helper both tools duplicate today (moved one at a time, nothing speculative); compose never edited in place; `.env.example` matches what deploy writes; storage path changes refuse an unmounted drive |
| 6 | Uninstall / firewall / confirm helpers | D18, D21, D22, D24 | shared helpers, adopted as each service is next touched |
| 7 | Menu table and doc checks | D29, D31, D32 | menu numbers come from one table; a test fails on a stale `federver -> N` in docs |

Order: QW → 0 → 1 → 2 → 3 → 5 → 4 → 6 → 7. Pieces 1 and 2 get a design review with the
user before any code.

## Work plan

One branch (`refactor/single-source`), one module at a time, one release at the end. The "Also
fixes" column folds in the open review-ledger items, so nothing is fixed twice.

| Step | Module | Also fixes (review ledger) | Size / risk | Gate before the next step | Status |
|---|---|---|---|---|---|
| 1 | QW quick wins | – | S / low | each fix has a fail-first test | ☐ |
| 2 | 0 test harness `tests/lib.sh` | disk-check flake: capture `tmpd` when it fails | S / low | check counts per suite unchanged | ☐ |
| 3 | 1 drive-mount verdict | `_MIRROR_DRIVE_ROOTS` test override in the production guard | M / medium | **design review**, then live check on the USB drive | ☐ |
| 4 | 2 sync-job generator | legacy finish-line patch gap (CRLF), `mktemp` leak in Change copy mode, untested `_mirror_banner` in step_sync, mirror preview not listing empty folders, duplicated `last:` label mapping, exit 24 (decision 1) | L / high | **design review**; atomic write + `.bak`; live mirror run, home and away | ☐ |
| 5 | 3 Immich backup | install-time dry-run runs as the user, not root | M / medium | live scheduled run + one one-time run | ☐ |
| 6 | 5 shared lib `lib/common.sh` | – | M / medium | `.env` stays mode 600; both tools work from the `/usr/local/bin` wrappers | ☐ |
| 7 | 4 service lifecycle and status | inline `samba-poc` container probe; first live run of `federver -> 16` from the laptop | M–L / medium | live Status and Start/Stop | ☐ |
| 8 | 6 uninstall / firewall / confirm helpers | SMB firewall check queries only the default zone | M / low | typed-name confirm and kept `/opt/<service>` config unchanged | ☐ |
| 9 | 7 menu table and doc checks | findings.md rules duplicated in project memory; docs index filing wiki pages under "Product" | S / low | a test fails on a stale `federver -> N` | ☐ |
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
2. Legacy job scripts are re-rendered on the **first Status view**, with a one-line notice: render,
   compare with the file on disk, replace only if different (atomic write, `.bak` kept).
3. **One shared lib, `lib/common.sh`**, sourced by both tools: the `.env` reader/writer and every helper
   both tools duplicate. The former optional piece 8 is folded into piece 5; there is no `lib/env.sh`.
4. `privcloud config` **stays** (privcloud-only installs need it) and writes through `env_set`, updating
   only `UPLOAD_LOCATION` and `DB_DATA_LOCATION`; every other `.env` key is left untouched.

## Non-goals

- New features. Anything user-visible beyond the fixes named above.
- Changing accepted tradeoffs (LAN-HTTP, `:latest` + Watchtower, Tailscale as the access model).

## Verification

- Each piece: its spec section's tests, fail-first proof for every merge, full suite green.
- Pieces 1 and 2 also get one live check on the real laptop + server (mount verdict on the USB drive;
  a regenerated mirror job run from the menu, away-from-home endpoint fallback).
