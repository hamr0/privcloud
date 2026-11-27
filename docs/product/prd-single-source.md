# PRD: Single source of truth — stop copy drift in federver and privcloud

Status: **Planned.** Starts on a fresh branch (`refactor/single-source`) after `feat/smb-share` is released.
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
| 2 | One sync-job generator | D1, D2, D6, D13, D23, part of D12 | create and every edit render the script from one record; legacy scripts are imported then re-rendered (never patched); names validated; scripts resolve the server endpoint at run time (LAN → Tailscale) and use the `ssh()` rules |
| 3 | One Immich backup | D3, D7, D14, D20 | one implementation for scheduled and one-time; reads `.env` at run time; same excludes, layout and guards |
| 4 | Service lifecycle and status | D9, D10, D11, D19, D25, D28, D30 | dead picker removed; one container-state probe, one service list, one renderer for rows and URLs |
| 5 | `.env` and compose files | D5, D4, D33 | one reader and one key-updating writer in `lib/env.sh`, sourced by both tools (needed even if piece 8 is declined); compose never edited in place; `.env.example` matches what deploy writes |
| 6 | Uninstall / firewall / confirm helpers | D18, D21, D22, D24 | shared helpers, adopted as each service is next touched |
| 7 | Menu table and doc checks | D29, D31, D32 | menu numbers come from one table; a test fails on a stale `federver -> N` in docs |
| 8 | privcloud ↔ setup.sh shared lib (optional) | D26, D15, D16, D17 | only if a sourced `lib/common.sh` is accepted under the "lightweight" rule; `lib/env.sh` (piece 5) stays either way |

Order: QW → 0 → 1 → 2 → 3 → 5 → 4 → 6 → 7 → (8). Pieces 1 and 2 get a design review with the
user before any code.

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
   `/branch-review` before merge.

## Open decisions

- rsync exit 24 ("source files vanished during transfer") in sync jobs: success-with-note or failure.
  Recommended: success with `last: ok (some files vanished)`.
- Legacy job scripts: re-render on first edit only, or on first Status view with a one-line notice.
  Recommended: on first Status view (old scripts carry the exit-code bug).
- Piece 8 (`lib/common.sh` sourced by both tools): yes / no. A "no" does not remove piece 5's `lib/env.sh`.
- `privcloud config` on a federver server: keep (key-updating only) or remove in favour of
  `federver -> 11`. Recommended: keep, update only its own keys
  (`UPLOAD_LOCATION`, `DB_DATA_LOCATION`); every other `.env` key is left untouched.

## Non-goals

- New features. Anything user-visible beyond the fixes named above.
- Changing accepted tradeoffs (LAN-HTTP, `:latest` + Watchtower, Tailscale as the access model).

## Verification

- Each piece: its spec section's tests, fail-first proof for every merge, full suite green.
- Pieces 1 and 2 also get one live check on the real laptop + server (mount verdict on the USB drive;
  a regenerated mirror job run from the menu, away-from-home endpoint fallback).
