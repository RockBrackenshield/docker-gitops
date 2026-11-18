# Runbook: Backrest backup and restore

Based on docker-gitops `main` at `9620752`. File references mean that file at 9620752.

## Purpose, scope, when to use

This is the restore runbook named in ["Rebuilding a node" step 5](../../infrastructure/README.md#rebuilding-a-node) (`infrastructure/README.md`) and in `host/README.md` ("Not here yet"). It fills that step.

`--restore-prep` remains reserved. `host/bootstrap.sh` accepts the flag only to print that it is reserved for this runbook and exit 2. Do not pass it. Implementing it is a separate, later change.

Use this runbook:

- **Routinely:** before a node rebuild, a host OS update (`host-os-updates.md`) or another risky change, confirm the node's latest successful Backrest snapshot.
- **For a path or app:** when bind-mount data is lost or corrupt (Paperless and ntfy have documented restore notes; RomM does not).
- **For a rebuild:** when "Rebuilding a node" reaches step 5.

Out of scope:

- Flashing the card, first boot, `bootstrap.sh`, firewall and Dockhand first start: [`host/README.md`](../../host/README.md) and ["Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node).
- Day-2 stack deploy and image rollback: `dockhand-deploy-rollback.md`.
- Token rotation after a restore or a lost card: `bws-token-rotation.md`.
- Implementing `--restore-prep` or the `restore-<NODE>` Bitwarden projects.
- Closing core's published Backrest port 9898 (a separate repo change; see Prerequisites).

> **Teaching point:** a Backrest snapshot can hold application data and, for ntfy, `user.db` (password hashes and access tokens in plaintext). Treat restores like a password vault. The ntfy token file and the restic repository password never belong on a command line.

## Prerequisites

- [ ] SSH to the node as `<ADMIN_USER>`, with a way to reach the Backrest UI on port 9898 (below).
- [ ] On infrastructure, port 9898 is allowed only from loopback and Zoraxy (`host/README.md` Firewall). Reach **either** node's UI with:
  ```bash
  ssh -L 9898:127.0.0.1:9898 <ADMIN_USER>@<NODE>
  ```
  **Open exposure (fixed in a separate repo change, not in this runbook and not by editing compose here):** core's Backrest compose publishes `9898:9898` with no `host_ip`, and `host/firewall/homelab-firewall.sh` has no core rule for 9898, so the port is reachable on every interface. Do not use that exposure. Always use `ssh -L`.
  **Verify (core):** from a LAN host and from a tailnet device, `http://<CORE_LAN_IP>:9898` times out. The UI still loads over the `ssh -L` tunnel.
- [ ] A Bitwarden login that can read the reserved `restore-infrastructure` or `restore-core` project. At 9620752 those projects are reserved for `BACKREST_REPO_PASSWORD_<NODE>` and `--restore-prep` is not implemented, so how that password is supplied on the node today is **TBD**. Paste it from Bitwarden on the workstation into the Backrest UI only; never onto the node.
- [ ] The live Backrest plans (each node's `/srv/homelab/backrest/config/config.json`, edited in the Backrest UI). Repo URL, retention, and the exact include/exclude lists are **not in Git** and are **TBD** until a live read is allowed. Treat `config.json` as secret (it is listed for rotation after a lost card in `host/README.md`).

## What the repository says is backed up

Backrest runs on both nodes (`compose/infrastructure/backrest/compose.yaml`, `compose/core/backrest/compose.yaml`), image `garethgeorge/backrest:v1.14.1`. Both mount `/srv/homelab` read-only. Core also mounts `/srv/romm/dump` read-only. Plans live in the UI, so the live include/exclude lists are **UNVERIFIED**; the table is what the repo says should happen.

| Path | Node | In `/srv/homelab`? | Repo guidance at 9620752 |
|---|---|---|---|
| `/srv/homelab/adguard/` | infrastructure | yes | bind-mounted; expect it in the plan |
| `/srv/homelab/zoraxy/` | infrastructure | yes | config is host data; expect it in the plan |
| `/srv/homelab/dockhand/data` | infrastructure | yes | expect it in the plan |
| `/srv/homelab/tailscale/state` | infrastructure | yes | expect it in the plan |
| `/srv/homelab/ntfy/` | infrastructure | yes | back up `user.db`; **exclude** `cache.db*` in the plan (`infrastructure/README.md` §10) |
| `/srv/homelab/backrest/` | both | yes | Backrest's own data and `config.json` |
| `/srv/homelab/paperless/{data,media,export,dump}` | core | yes | include; schedule the snapshot after the daily dump |
| `/srv/homelab/paperless/consume` | core | yes | **exclude** (transient ingest) |
| `/srv/homelab/romm/`, `/srv/homelab/shelfmark/` | core | yes | bind-mounted; expect them in the plan |
| `/srv/romm/dump` | core | no | mounted into Backrest read-only; daily `mariadb-dump` files |
| `/srv/paperless/db`, `/srv/paperless/broker` | core | no | deliberately not backed up; restore Postgres from `paperless/dump` |
| `/srv/romm/db` | core | no | live MariaDB files; not mounted into Backrest |
| `/srv/backrest/cache`, `/srv/backrest/tmp`, `/srv/backrest/secrets` | both | no | outside `/srv/homelab` on purpose. The ntfy token file is never in a restic snapshot; Bitwarden is its backup |

Daily dump jobs (keep three local files; Backrest versions the directory):

- Paperless: `paperless-db-backup` writes `/srv/homelab/paperless/dump/paperless-<TIMESTAMP>.dump` (custom `pg_dump`, interval 86400s).
- RomM: `romm-db-backup` writes `/srv/romm/dump/romm-<TIMESTAMP>.sql` (`mariadb-dump`, interval 86400s).

## Part A: confirm a snapshot

Do this before a rebuild, an OS update or a restore.

### A1. Open the UI
Start the port-forward in Prerequisites. Do not expose 9898 more widely than `host/README.md` already allows on infrastructure, and do not use core's unfiltered publish.
**Verify:** the Backrest UI loads through the tunnel. From another LAN or tailnet host, infrastructure `:9898` should still time out (`host/README.md` Verify item 7). On core, the Prerequisites Verify (timeout of `http://<CORE_LAN_IP>:9898` from the LAN and from the tailnet) also passes.

### A2. Check the latest snapshot
In the Backrest UI, open the node's repo and confirm a recent successful snapshot. Exact control labels are **UNVERIFIED** (they are not in Git).
If Paperless or RomM data matters, the snapshot should be newer than the last daily dump (the Paperless section says to schedule it that way; whether the live plan does is **UNVERIFIED**).
Do not dump `config.json` or snapshot lists that might include repo credentials to the terminal or a ticket.
**Verify:** a successful snapshot exists, with a time you are willing to restore from.

## Part B: restore a path (general)

Use this when you are not following the Paperless or ntfy sections below. Exact Backrest UI clicks are **UNVERIFIED**. Do not restore in-place onto live data.

Backrest mounts `/srv/homelab` read-only and cannot see host `/dev/shm`. Its `/tmp` is `/srv/backrest/tmp` on the SD card. Do not use `/dev/shm` as a Backrest restore target.

### B1. Enter the repository password in the UI only
Paste `BACKREST_REPO_PASSWORD_<NODE>` from Bitwarden on the workstation into the Backrest UI. Do not stage it in a file on the node, and do not put it on a command line. `--restore-prep` cannot supply it yet. How a newly flashed node obtains the password before Backrest is deployed is **TBD** (see Part E).
**Verify:** the UI accepts the repo. `ps` and shell history on the node do not contain the value. The workstation clipboard is cleared.

### B2. Restore into a staging directory, then copy
```bash
umask 077
sudo install -d -m 0700 -o root -g root /srv/backrest/restore-staging/<RESTORE_ID>
```
In the Backrest UI, restore the path into `/srv/backrest/restore-staging/<RESTORE_ID>`.
**Verify:** `sudo stat -c '%U:%G %a' /srv/backrest/restore-staging/<RESTORE_ID>` prints `root:root 700`. Check ownership and modes of the restored tree before copying anything live:

- ntfy: directory `0700`, owner `<NTFY_UID>:<NTFY_GID>` (the `ntfy` system user).
- Paperless: owner `<PAPERLESS_UID>:<PAPERLESS_GID>`; `data`, `media`, `export` and `dump` are `0750`; `consume` (if present) is `2770`.

restic running as root is expected to restore original owners and modes; that is **UNVERIFIED** until this check passes. If the modes or owners are wrong, stop and do not copy.

Stop the affected containers with `docker stop <CONTAINER>` (do not `docker compose up`, and never `docker compose down -v`). Keep the live data until the copy's Verify passes, by syncing it aside first:

```bash
sudo install -d -m 0700 -o root -g root /srv/backrest/restore-staging/<RESTORE_ID>-old
sudo rsync -aHAX --numeric-ids <LIVE_PATH>/ /srv/backrest/restore-staging/<RESTORE_ID>-old/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/<RESTORED_SUBPATH>/ <LIVE_PATH>/
```

**Verify:** the live path has the expected size, ownership and modes, without printing secret file contents.

### B3. Delete the staging directory
After the copy's Verify passes:

```bash
sudo rm -rf /srv/backrest/restore-staging/<RESTORE_ID>
sudo ls /srv/backrest/restore-staging/<RESTORE_ID>    # must fail: "No such file or directory"
```

`shred` is unreliable on SD cards; the directory mode `0700` is the control until deletion. Keep `<RESTORE_ID>-old` until you accept the restore, then delete it the same way and confirm `ls` fails for that path too.
**Verify:** `ls` reports the staging path is gone. The `-old` copy is either gone, or still present only because you have not accepted the restore yet.

## Part C: Paperless

From `infrastructure/README.md` §8 and `compose/core/paperless/compose.yaml`. Run this on core. Use the container names (`paperless`, `paperless-db`, `paperless-db-backup`, `paperless-samba`). Do **not** use `docker compose up` or `docker compose exec`: those can recreate containers without Dockhand's injected values, and an empty `CORE_LAN_IP`, `SMB_HOSTS_ALLOW` or `PAPERLESS_URL` fails open. The same `docker compose` restore sequence is still in `infrastructure/README.md` (around lines 568–572); leaving that snippet as-is is **TBD** for a later docs PR, not this runbook.

### C1. Confirm the snapshot and a dump
The snapshot should include `paperless/{data,media,export,dump}` and exclude `paperless/consume`. After Part B has restored those trees into staging (and only after the staging permission check), pick a `paperless-<TIMESTAMP>.dump` from the restored `dump/` directory (custom format; the backup job keeps the newest three locally).
**Verify:** the chosen `.dump` file exists in staging, is non-empty, and the staging directory is `root:root` `700`.

### C2. Safety dump, stop, copy, restore, start
While `paperless-db` and `paperless-db-backup` are still running, write a safety dump of the **current** database to a `0700` directory outside `/srv/homelab/paperless`, so `pg_restore --clean` is reversible. `paperless-db-backup` already has `PGPASSWORD` in its environment; do not pass the password on the command line.

```bash
umask 077
sudo install -d -m 0700 -o root -g root /srv/backrest/restore-staging/<RESTORE_ID>-pre
docker exec -i paperless-db-backup pg_dump --format=custom --no-password > /srv/backrest/restore-staging/<RESTORE_ID>-pre/paperless-pre-restore.dump
sudo chown root:root /srv/backrest/restore-staging/<RESTORE_ID>-pre/paperless-pre-restore.dump
sudo chmod 600 /srv/backrest/restore-staging/<RESTORE_ID>-pre/paperless-pre-restore.dump
```

**Verify:** that file is non-empty and mode `600`. Then:

```bash
docker stop paperless paperless-db-backup
# keep live trees, then copy from staging (Part B2), for example:
sudo install -d -m 0700 -o root -g root /srv/backrest/restore-staging/<RESTORE_ID>-old
sudo rsync -aHAX --numeric-ids /srv/homelab/paperless/data/   /srv/backrest/restore-staging/<RESTORE_ID>-old/data/
sudo rsync -aHAX --numeric-ids /srv/homelab/paperless/media/  /srv/backrest/restore-staging/<RESTORE_ID>-old/media/
sudo rsync -aHAX --numeric-ids /srv/homelab/paperless/export/ /srv/backrest/restore-staging/<RESTORE_ID>-old/export/
sudo rsync -aHAX --numeric-ids /srv/homelab/paperless/dump/   /srv/backrest/restore-staging/<RESTORE_ID>-old/dump/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/srv/homelab/paperless/data/   /srv/homelab/paperless/data/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/srv/homelab/paperless/media/  /srv/homelab/paperless/media/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/srv/homelab/paperless/export/ /srv/homelab/paperless/export/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/srv/homelab/paperless/dump/   /srv/homelab/paperless/dump/
docker exec -i paperless-db pg_restore --clean --if-exists --no-owner -U paperless -d paperless < /srv/homelab/paperless/dump/paperless-<TIMESTAMP>.dump
docker start paperless paperless-db-backup
```

The staging subpath under `<RESTORE_ID>` is **UNVERIFIED** (it depends on how the Backrest UI writes the restore). Adjust `<RESTORED_SUBPATH>` to match what you see in staging; do not invent a second copy step. If `pg_restore` asks for a password, do not pass it on the command line. Whether `docker exec` into `paperless-db` needs a password is **UNVERIFIED** (`paperless-db` sets `POSTGRES_PASSWORD` only for first init; `paperless-db-backup` is the service that sets `PGPASSWORD`).

If `pg_restore` fails, leave `paperless` stopped and reload the safety dump the same way (`docker exec -i paperless-db pg_restore ... < /srv/backrest/restore-staging/<RESTORE_ID>-pre/paperless-pre-restore.dump`) before starting it.

**Verify:**

- `pg_restore` exits 0.
- `docker start` has brought `paperless` and `paperless-db-backup` back (the same containers Dockhand created; do not `compose up`).
- `docker inspect paperless paperless-samba` shows ports 8000 and 445 bound to `<CORE_LAN_IP>`, not `0.0.0.0` or `::` (the bind check in `dockhand-deploy-rollback.md` A3).
- The Paperless UI shows documents you expect from that snapshot.

Then delete the staging directory as in B3. Keep `<RESTORE_ID>-old` and the safety dump until that Verify passes, then delete them and confirm they are gone.

## Part D: ntfy

From `infrastructure/README.md` §10 and §7.1.

### D1. Restore `user.db`
Exclude `cache.db*` if you are choosing paths by hand. Restore `/srv/homelab/ntfy` into a `0700` staging directory (Part B), not in-place and not into `/dev/shm`.

```bash
docker stop ntfy
# after the staging permission check (0700, owner <NTFY_UID>:<NTFY_GID>):
sudo install -d -m 0700 -o root -g root /srv/backrest/restore-staging/<RESTORE_ID>-old
sudo rsync -aHAX --numeric-ids /srv/homelab/ntfy/ /srv/backrest/restore-staging/<RESTORE_ID>-old/
sudo rsync -aHAX --numeric-ids /srv/backrest/restore-staging/<RESTORE_ID>/<RESTORED_SUBPATH>/ /srv/homelab/ntfy/
docker start ntfy
```

`/srv/backrest/secrets/ntfy-token` is **not** in the snapshot. If that file is missing, the Backrest stack will not start. Recreate it from Bitwarden with the procedure in `infrastructure/README.md` §7.1 (`umask` / `install -d -m 0700`, write the file with `cat`, expect `root:root` mode `600`) before starting Backrest. Do not `docker compose up` ntfy or Backrest.
**Verify:** `sudo stat -c '%U:%G %a' /srv/homelab/ntfy` matches the ntfy user and mode `700`. `docker inspect ntfy` shows the same container running. After start, users and tokens are present. The last 24 hours of messages are present only if `cache.db*` was included; if it was excluded, an empty cache is expected. Then delete staging as in B3.

### D2. Re-do revocations
**Restoring an old `user.db` brings back revoked tokens.** After any restore, repeat every revocation made since that snapshot, and check the masked `token list` (`infrastructure/README.md` §6; `token list` prints full token values, so always mask). Then follow `bws-token-rotation.md` if tokens need rotating rather than only re-revoking.
**Verify:** the masked `token list` count per user matches the table in `infrastructure/README.md` §6, with no extras.

## Part E: whole-node restore ("Rebuilding a node" step 5)

Follow ["Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node) in order. This runbook is step 5 only.

At step 5 the new card does not yet have Dockhand or the Backrest stack (those are step 8). `--restore-prep` was reserved for this moment and is not implemented. How the restic repository is opened, and how data lands on the new card at step 5, is **TBD**. Do not invent a restic or Backrest CLI.

Until that is decided, do not skip ahead with an undocumented tool. Two options remain open:

- **TBD:** implement `--restore-prep` and the `restore-<NODE>` projects in a separately approved change, then restore at step 5 as the checklist already writes.
- **TBD:** restore after Backrest is deployed in step 8 (that deviates from the written order).

When a restore method exists, restore into a `0700` staging directory and copy with `rsync -aHAX --numeric-ids` as in Part B, and recreate `/srv/backrest/secrets/ntfy-token` on both nodes before the Backrest stack is started (step 9 in the checklist, `infrastructure/README.md` §7.1). Then do Part D2 and the lost-card rotations in `bws-token-rotation.md` for any secret that changed after the snapshot date.

**Verify:** the paths you expected from Part A's snapshot are on the node, staging directories have been deleted (B3), and the repository password is not in a file on the node or in shell history.

## Rollback

- **Part A** changes nothing on the node.
- **Parts B–D:** if the restore is wrong, stop the app again (`docker stop`, not `compose down -v`) and copy back from `<RESTORE_ID>-old`, or repeat from an older snapshot or the safety dump. Leave the app down until a verify passes.
- **Part C:** if `pg_restore` fails, do not `docker start paperless` until you have reloaded the safety dump or otherwise recovered. Never `docker compose up`.
- **Every path, including an abort:** delete `/srv/backrest/restore-staging/<RESTORE_ID>` (and, once accepted, `-old` and `-pre`) and confirm `ls` fails. Clear the workstation clipboard.
- **Part E:** if the rebuild cannot restore data, the rest of ["Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node) can still bring the node up empty; data waits on the TBD in Part E.

## References

- `infrastructure/README.md` — Backup, Paperless §8, ntfy §7.1 and §10, "Rebuilding a node" step 5
- `host/README.md` — Firewall (9898), Rollback, "Not here yet" (`--restore-prep`)
- `host/bootstrap.sh` — `--restore-prep` reserved, exit 2
- `host/firewall/homelab-firewall.sh` — 9898 is an infrastructure port only
- `compose/infrastructure/backrest/compose.yaml`, `compose/core/backrest/compose.yaml`
- `compose/core/paperless/compose.yaml`, `compose/core/romm/compose.yaml`

## TBDs and UNVERIFIED items

- Live Backrest repo URL, retention, and include/exclude lists (`config.json` is not in Git).
- Backrest UI control labels, click path, and the exact subpath it writes under the staging directory.
- How `BACKREST_REPO_PASSWORD_<NODE>` is supplied today; `--restore-prep` is reserved only.
- How step 5 of "Rebuilding a node" runs before Backrest is deployed.
- Closing core's unfiltered `:9898` in a separate repo PR (bind loopback or add core firewall rules). This runbook does not change compose.
- Whether `pg_restore` via `docker exec` into `paperless-db` needs a password.
- A RomM database restore procedure (dumps exist; no restore steps are in the repo).
- Whether `config.json` itself stores the repository password.
- Updating the Paperless restore commands in `infrastructure/README.md` (around lines 568–572) to match Part C (a later docs PR).
