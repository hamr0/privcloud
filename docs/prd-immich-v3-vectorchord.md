# PRD: Immich v3 upgrade — pgvecto.rs → VectorChord database migration

Status: **Shipped (v0.9.21, 2026-07-02).** Live server migrated v2.7.5 → v3.0.0.

## Goal

Move the stack onto **Immich v3.0.0** without data loss, given that v3 **drops the
`pgvecto.rs` database extension** the deployment had used since day one and requires
**VectorChord** instead. The migration must:

- preserve the existing library (metadata in Postgres; the 120 GB of assets on disk are
  untouched by a DB migration),
- be reversible at every step (backups + a clean rollback path), and
- keep the project's `IMMICH_VERSION=release` / Watchtower auto-update model intact.

## Background — the problem

The `database` service ran `docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0` (extension
`vectors 0.2.0`). Immich **v3.0.0** removed pgvecto.rs support entirely — the app now only
speaks to **VectorChord** (`vchord`) + `pgvector`. Because `IMMICH_VERSION` tracks the
floating `:release` tag and Watchtower pulls nightly at 4am, the server would (or already
had the opportunity to) auto-pull the v3 server image on top of a pgvecto.rs database and
fail to start. This is the one class of change the otherwise-fine auto-update model cannot
absorb: a breaking major that needs an **ordered** database migration.

## Options considered

- **A — Manual SQL migration.** Query embedding dimensions, convert vector columns to
  `real[]`, drop pgvecto.rs, install VectorChord, convert back, rebuild indices. Fragile,
  many hand steps against a live DB, superuser-sensitive. Rejected.
- **B — Immich's bundled dual-extension image + automatic migration.** Switch the DB image
  to `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, which ships **both**
  `vchord` and the legacy `pgvectors` binary. A supported Immich server (≥ v1.133) detects
  VectorChord and migrates the data automatically on startup; the bundled pgvectors binary
  lets it read the old data during the one-time conversion. No hand-written SQL. **Chosen.**

## Design — ordered migration

The ordering is the crux: the migration must run under a **v2.x** server (which still knows
how to read pgvecto.rs), *before* the app is bumped to v3 (which cannot).

1. **Back up twice.** Logical: `docker exec immich_postgres pg_dumpall -U postgres | gzip >
   immich-db-pre-v3-<ts>.sql.gz`. Physical: cold-copy the Postgres data dir aside (a
   throwaway root container avoids sudo — the data dir is uid-999-owned:
   `docker run --rm -v <parent>:/d alpine cp -a /d/postgres /d/postgres.bak-pre-v3-<ts>`).
   Record current image digests for rollback.
2. **Freeze the app.** Stop Watchtower; pin `IMMICH_VERSION` to the exact last-good version
   (`v2.7.5`) so no `compose up` can jump to v3 mid-migration.
3. **Swap the DB image** to `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`
   (keep the `:Z` SELinux label; add `shm_size: 128mb`).
4. **`docker compose up -d`.** The v2.7.5 server auto-migrates pgvecto.rs → VectorChord and
   reindexes. Verify: extensions flip from `vectors 0.2.0` to `vchord` + `vector`, all
   containers healthy, API + ping OK, no errors in logs.
5. **Bump to v3.** Set `IMMICH_VERSION` back to `release` (= v3.0.0 upstream),
   `docker compose pull && docker compose up -d`. The v3 server runs its remaining schema
   migrations (album-owner → album_user, duration → ms, drop deviceId, etc.) and comes up
   on the already-VectorChord database.
6. **Resume Watchtower.**

## Rollback

Any failure at step 4/5: `docker compose stop`, restore the cold data-dir copy over the
Postgres directory, revert the image + `IMMICH_VERSION` pin, `docker compose up -d`. Worst
case, reload the logical dump into a fresh database. Assets on disk are never touched.

## Decisions

- **Pin Immich to its major tag `v3`, not the floating `:release` (v0.9.22).** `:v3` and
  `:release` point to the same image today, so auto-updates are unchanged — Watchtower still
  applies every `v3.x.y` patch/minor nightly. The difference is only at the major boundary:
  `:v3` won't auto-jump to v4 (which could again need an ordered migration), so crossing a
  major becomes a deliberate one-line `.env` bump. Simplest "update freely, don't break"
  posture. (v0.9.21 initially kept `:release`; reversed the next day.) Postgres/Redis stay
  exact-pinned so the DB engine never changes on its own.
- **Keep the existing `pg_isready` healthcheck** rather than Immich's `healthcheck: disable:
  false`; it works against the new image and is more informative.

## Outcome

Live server migrated cleanly: v2.7.5 (pgvecto.rs) → VectorChord auto-migration → v3.0.x, all
services healthy, zero errors, now pinned to `:v3` (running v3.0.1). Backups retained on the
SSD: logical dump `~/immich-backups/immich-db-pre-v3-*.sql.gz` and the flattened cold data
dir `~/immich-backups/postgres-pre-3.0` for a safety window.
