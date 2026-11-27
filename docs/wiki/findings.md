# Findings: what we learned building federver and privcloud

Hard-won facts from building, debugging and reviewing this repo. Each one cost a bug, a
false "done" or a review round. Read the relevant section before touching that area.
Product decisions live in `docs/product/`; this page records *why things are the way they are*.

## Engineering process

- **Verify against the live mechanism, not syntax.** `bash -n` and reading the code prove nothing
  about behaviour. Several "all good" claims broke on the first real run (a backup timer that didn't
  exist, a full backup drive, a schedule read back as empty). Run the real thing, or say plainly what
  wasn't run.
- **Tests must be able to fail.** Prove every new test red against the old code or a deliberate
  mutation of a scratch copy (never the repo file). A test that passes on both is a tautology. Tests
  that only grep the source text don't count as behaviour tests.
- **Reuse before new; regenerate, don't patch.** Most drift in this repo came from a new feature
  writing its own helper for a job an existing one did, or from sed/awk-patching a generated file.
  See `docs/product/prd-single-source.md`. When review findings keep coming from the previous fix,
  stop patching and redesign.
- **Design a component end to end.** List its failure modes up front (missing, empty, unmounted,
  unreachable, no sudo, no TTY, old version on disk) instead of discovering them one review round at
  a time.
- **An agent's "by design" can overstate reality.** Check whether a behaviour is intentional or a
  side effect before calling it a feature (e.g. a root-owned backup tree was accidental).
- **Commit messages and reports are claims.** Re-run the check before relaying "tested" or "proven".

## Bash pitfalls

- `func || true` swallows every error inside `func`; `var=$(cmd)` under `set -e` aborts unless
  guarded. Don't assume `set -e` catches either. Verify state actually changed after a step.
- `echo "[$(date)] ... (exit $?)"` logs **0**: the `$(date)` substitution resets `$?` first. Capture
  `rc=$?` on the line right after the command.
- `read -r` without `IFS=` trims leading and trailing blanks, so a rule like "no space at the start"
  can never fire, and `" delete"` matches `delete`. Use `IFS= read -r` where exact input matters.
- `read -p` prints nothing when stdin is a pipe; use `printf` + `read` for prompts that tests capture.
- `systemctl show -p <X> --value` returns empty for unit-file settings such as `OnCalendar`; read
  them with `systemctl cat <unit>`.
- ext4 is case-sensitive: case-variant duplicate paths cause duplicate imports and entries.
- zsh's `echo` differs from bash's; run harnesses under bash.

## Generated files and remote execution

- Functions shipped to the server with `declare -f` must ship every function they call; a missing one
  fails as "command not found" and can degrade silently. `tests/ts-expiry.sh` checks the lists.
- Cron has no federver functions: anything a job script needs (guards, quoting, ssh wrapper) must be
  embedded in the script itself.
- Generated scripts must not freeze values the live code resolves at run time (server endpoint, data
  paths), or they break when roaming or after a storage change.
- Root on the server needs an interactive sudo password, which a tool without a TTY can't give over
  SSH. Use `ssh -t user@host "sudo …"` (never `sudo ssh …`), or hand the user a copy-paste block.
- One ssh session per sudo step means one password prompt per step; batch privileged steps through
  one session (`_server_sudo_run`).

## Storage and mounts

- **A stub or autofs mountpoint looks mounted.** `mountpoint -q` passes on it while the real device is
  missing; Docker then creates empty folders on the system disk that look like data loss. Check the
  real `/dev/*` source with `findmnt`.
- **An unplugged drive looks like "everything was deleted".** Any `rsync --delete` must refuse a
  missing, empty or not-really-mounted source, and fail closed when it can't tell.
- `rsync -n --delete --out-format='%o|%n'` lists deletions as `del.|<name>`, folders with a trailing
  `/`. Count empty folders too, or a preview says "nothing to delete" and then removes folders.
- A stale duplicate `/etc/fstab` entry can shadow the correct device for the same mountpoint.

## Networking, Tailscale, DNS

- Server SSH must work at home and away: probe the LAN address with a short `ConnectTimeout`, fall
  back to the Tailscale address. Never call raw `ssh` for server hops (an unreachable address hangs).
- Docker-published ports bypass firewalld (Docker's iptables rules run first); host-network ports do
  not. True LAN lockdown of a published port means binding it to the tailnet IP.
- Ports opened with `firewall-cmd --permanent` and no `--zone` land in the **default** zone; checks
  must query the same zone.
- A third-party VPN app can block Tailscale's WireGuard/DERP traffic, breaking server access and
  DNS while traveling. Phone apps "not loading" can also be the phone stuck on a DERP relay;
  reconnecting Tailscale fixes it.
- AdGuard's upstream must be plain DNS (e.g. Quad9 with a fallback), not DoH: DoH to Quad9 hit a Go
  HTTP/2 idle-connection bug that silently dropped queries. DNS-level blocking can't stop ads served
  from content hostnames (YouTube).
- Blocking DoH resolver names makes apps fall back to AdGuard, but most bypass uses hard-coded resolver
  IPs, which DNS can't stop. Blocking `mask.icloud.com` turns off iCloud Private Relay on the network.

## SMB (Connect phone)

- Samba `hosts allow` + `hosts deny`: a client in **neither** list is allowed. `hosts deny =
  0.0.0.0/0` only covers IPv4, so non-tailnet IPv6 got through; deny must be `ALL`. Verify with
  `testparm`'s host test.
- Bridge-mode Docker makes every SMB client appear as the Docker gateway, so address filtering can't
  work; host networking also avoids the boot-order race with Tailscale's IP.
- `smbstatus` prints times in UTC; convert to local time before showing them.
- iOS Files drops idle SMB sessions within seconds: "0 devices connected" right after leaving Files is
  correct. "Socket is not connected" on iOS means the phone's Tailscale is off.
- `docker inspect` of the samba container shows the password in its environment: never print it.
  The image's own scripts mangle a backslash or a leading `-` in passwords.

## Services and containers

- "Stop" means stopped **and** autostart disabled (`docker update --restart=no` + `docker stop`).
  Any reconfigure path must keep a stopped service stopped.
- Standalone containers (AdGuard, Syncthing, samba) live outside `docker-compose.yml`; Start All,
  Stop All and Emergency restart must list them explicitly.
- Tailscale is a native dnf package, not a container: Watchtower can't update it, by design.
- Immich v3 uses VectorChord; follow the ordered migration path.

## Navidrome

- `.nsp` smart playlists query the whole library regardless of folder depth and store
  library-relative paths; `.m3u8` lists are explicit flat file lists. Different upkeep.
- Navidrome won't rename an already-synced smart playlist on rule re-import; only deleting its DB
  row picks up a new name.

## Backups

- There is exactly one Immich backup schedule; privcloud and federver menus drive the same job.
- Unattended backups are append-only on purpose: a deletion by mistake must survive in the backup.
- Exclude regenerable caches (thumbnails, encoded video, Immich's own DB dumps) or the backup drive
  fills up.

## Tooling (for agents working on this repo)

- Trust a tool's own authoritative counts; don't re-derive them from raw IDs (a resumed conversation
  can span several files).
- When cross-checking a delegated count, compare against your own recount of every item, not a sample.
- Before treating missing or changed files as an incident, ask: the user may be testing something.
