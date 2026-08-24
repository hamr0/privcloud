# PRD: Bulk photo upload into Immich (`privcloud` → 7)

Status: **Shipped (v0.8.8–v0.8.9).**

## Goal

Let a user bulk-import an existing photo/video collection that already lives **on the
server** into Immich, from the `privcloud` menu, with:

- no host dependencies to install,
- the assets landing in the **correct user account** (multi-profile setups must not mix), and
- a choice of layout — preserve folder structure as albums, or a flat timeline import.

## Background — the problem

The original `cmd_upload` installed the Immich CLI with `npm i -g @immich/cli`. The server
(Fedora XFCE, headless) has **no Node.js/npm**, so the feature died immediately:

```
Immich CLI not found. Installing...
./privcloud: line 535: npm: command not found
```

Installing a full Node toolchain just to run a CLI also cuts against the project's rules
(lightweight, few deps, Docker-first). And once it ran, every collection imported **flat**
into the timeline — there was no way to keep a folder-per-album layout that mirrors how
people store photos on disk.

## Options considered

- **A — Install Node + npm CLI on the host.** Heavy (~full toolchain) for one CLI; adds a
  language runtime to maintain and update; violates the dependency-hierarchy rule. Rejected.
- **B — Official Immich CLI as a one-shot Docker container.** `ghcr.io/immich-app/immich-cli`
  is the maintainer-published image; the server already runs Docker for the whole stack, so
  there's nothing new to install. Pulled once and cached. **Chosen.**
- **C — Upload via raw REST API + curl.** No CLI at all, but reimplements hashing, dedup,
  retries, album creation, and metadata handling — a large surface to maintain. Rejected.

## Decision

Run the official CLI image as a one-shot container (Option B):

```
docker run --rm [-t] \
  --security-opt label=disable \      # don't relabel the user's photo folder (SELinux)
  --network host \                    # reach Immich at localhost:2283
  -e IMMICH_INSTANCE_URL=http://localhost:2283/api \
  -e IMMICH_API_KEY \                 # forwarded by name from the env (value never on argv);
                                      #   determines the destination user
  -v <photo_path>:/import:ro \        # photos mounted read-only
  ghcr.io/immich-app/immich-cli upload --recursive [--album] /import
```

After the path prompt, ask **Albums vs Flat**:

- **Albums** → add `--album` → one album per source subfolder, named after the folder.
- **Flat** (default) → no flag → straight into the user's timeline.

## Key properties (verified live)

- **Per-user isolation.** Assets go to the account that owns the pasted API key (validated
  against `/api/users/me`). A second profile = a second username with its own API key; they
  never mix. A bad key returns a clean 401.
- **Copy, not move.** Originals on the source drive are untouched (read-only mount, no
  `--delete`). Immich keeps its own copy under `UPLOAD_LOCATION`. Plan for the data to exist
  twice — and note the source and `UPLOAD_LOCATION` may be on **different drives** (e.g. USB
  HDD source → NVMe Immich storage).
- **Idempotent.** The CLI hashes files before upload, so re-running skips assets already on
  the server.
- **Self-updating.** `federver` → i now `git pull`s the server's `privcloud` before launching
  it, so server-side fixes reach the box.

## Out of scope / future

- Uploading photos that live on the **laptop** (this flow assumes server-local files). A
  laptop-side path that streams to the server's Immich is a possible follow-up.
- Per-run tuning of CLI flags (concurrency, ignore patterns, delete-after-upload).
