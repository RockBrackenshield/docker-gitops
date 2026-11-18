# Runbook: Dockhand day-2 deploy and stack rollback

Based on docker-gitops `main` at `9620752`. File references mean that file at 9620752.

## Purpose, scope, when to use

Use this after a change lands on `main` (a Renovate image bump or a compose edit) to deploy the affected stack, check it, and roll back to the previous digest if it is bad. Also use it when Dockhand itself is down and you need the documented recovery for that stack, not an application rollback.

Out of scope:

- First boot, the `:3000` lock, `--unlock-dockhand`, and binding stacks to Bitwarden projects: [`host/README.md`](../../host/README.md) (Dockhand `:3000`) and ["Rebuilding a node" step 8](../../infrastructure/README.md#rebuilding-a-node). Reference those; do not repeat them.
- Resetting Dockhand's data directory (`host/README.md` Rollback) is recovery of Dockhand itself, not rollback of an app stack.
- Core-stack deploys through Hawser. Hawser is not installed or firewalled by this repo yet (`host/README.md` "Not here yet"). Core steps stay **blocked** until that review exists.
- Implementing a new Dockhand feature, or changing `renovate.json` / CI.

Never run `docker compose down -v` or `docker volume prune`. Both delete data. The host rollback commands `docker compose -p tailscale down` and `docker compose -p dockhand down` have no `-v` and must stay that way.

## Prerequisites

- [ ] The change has been merged to `main`. Renovate opens pull requests and nothing automerges (`README.md`, `renovate.json` `automerge: false`). CI `compose-validate` has passed (`AGENTS.md`).
- [ ] Every image in the changed `compose.yaml` is still pinned as `tag@sha256:<DIGEST>` (`AGENTS.md`).
- [ ] Dockhand is running on infrastructure, with authentication on. Reach the UI with:
  ```bash
  ssh -L 3000:127.0.0.1:3000 <ADMIN_USER>@<INFRASTRUCTURE_NODE>
  ```
  After `--unlock-dockhand`, only loopback and Zoraxy reach `:3000`. There is no "open" state.
- [ ] For a first rebuild's deploy order only: AdGuard, Zoraxy, Tailscale (`docker compose -p tailscale down` first, then deploy from Dockhand), ntfy, Backrest (`infrastructure/README.md` step 8). Day-2 deploys are the changed stack, unless a dependency requires more.
- [ ] Core stacks: **blocked** on the Hawser review. Do not invent a Hawser procedure.

## Part A: deploy a change that landed on `main`

### A0. Confirm a snapshot, and a fresh Paperless dump
Before **any** deploy or rollback, confirm a Backrest snapshot of the node that will change (`backrest-backup-restore.md` Part A). If that node is core, or the stack is Paperless, also confirm a fresh Paperless dump in `/srv/homelab/paperless/dump` (the daily `paperless-db-backup` job, or wait for one). The dump should be newer than the data you are willing to lose; the Paperless section says to snapshot after the dump.
**Verify:** a successful snapshot exists with a time you will accept. On core or for a Paperless change, a non-empty `paperless-<TIMESTAMP>.dump` exists that is at least as new as that data.

### A1. Confirm the pin
On a checkout of `main`, open `compose/<NODE>/<STACK>/compose.yaml` and record the `image:` line you intend to run (`<IMAGE>@sha256:<DIGEST>`).
**Verify:** the digest is 64 hex characters, and it matches the merged commit you mean to deploy.

### A2. Deploy from Dockhand
How Dockhand is wired to the git clone, and the exact UI clicks to pull and apply a compose change, are **UNVERIFIED** (not in Git). Do not invent a webhook, a required `git pull`, or a click path.

If you update `/srv/homelab/docker-gitops` on the node by hand, use the same checks as `host/README.md` ("Before every run"):

```bash
sudo git -C /srv/homelab/docker-gitops pull --ff-only
sudo git -C /srv/homelab/docker-gitops rev-parse HEAD      # must equal the merge commit on GitHub
sudo git -C /srv/homelab/docker-gitops status --porcelain --ignored   # must print nothing
```

Whether Dockhand actually deploys from that clone is **UNVERIFIED**. Do not hand-edit a pin on the node to bypass `main`. Do not `docker compose up` to apply the change, and never `docker compose down -v` or `docker volume prune`.
Then apply the change in Dockhand using the operator's usual (undocumented here) deploy action.
**Verify:** `docker inspect --format '{{.Config.Image}}' <CONTAINER>` for the stack's `container_name` equals the `<IMAGE>@sha256:<DIGEST>` recorded in A1. `git status` on the node clone is still clean if you used the checks above.

### A3. Smoke checks
Only checks that already exist in the repo. Skip those that do not apply to the stack you deployed.

- Paperless: `docker inspect paperless paperless-samba` shows ports 8000 and 445 bound to `<CORE_LAN_IP>`, not `0.0.0.0` or `::` (`infrastructure/README.md` §1).
- ntfy: `docker inspect ntfy` shows port 2586 bound to `<INFRA_LAN_IP>` (`infrastructure/README.md` ntfy §1).
- AdGuard: the container healthcheck in `compose/infrastructure/adguard/compose.yaml` is `wget` of `http://127.0.0.1:80/` inside the container. **UNVERIFIED** as a day-2 operator check, but it is the check the compose file defines.
- Backrest version bump: re-check that the Command hook still logs only the rendered script and output, and rerun `infrastructure/README.md` §7.3 step 4 (no token in Backrest logs).
- Tailscale container restart (including after a Renovate bump): from a LAN host and a tailnet device, `http://<INFRA_LAN_IP>:2586` must still time out, including after `docker restart tailscale`. The raw `PREROUTING` rule is the backstop (`infrastructure/README.md` ntfy §3). Do not `systemctl restart homelab-firewall-early` (`host/README.md`).
- Dockhand itself: an anonymous `GET /api/secret-providers` on loopback still returns 403 after unlock (`host/README.md`).

**Verify:** every applicable check above passes. If one fails, go to Part B before deploying anything else.

## Part B: roll back a bad image

Run A0 again before Part B if the snapshot or Paperless dump from the deploy is no longer the one you would restore. Do not skip the dump when rolling back Paperless: a downgrade over migrated data can corrupt it.

### B1. Find the previous pin
From git history of the same `compose.yaml` on `main`, record the previous `<IMAGE>@sha256:<OLD_DIGEST>`.
**Verify:** that line existed on `main` before the bad deploy, and you have not invented a tag.

### B2. Restore pre-deploy data if needed, then redeploy the previous pin
If the stack is stateful (Paperless in particular, and any other stack whose data may have been migrated by the new image), restore the pre-deploy data from the A0 snapshot (and, for Paperless, the pre-deploy dump) with `backrest-backup-restore.md` **before** running the old digest against it.

Whether Dockhand can roll back in the UI, and whether a revert pull request on `main` is required first, are **TBD**. Fail closed: do not leave an uncommitted pin on the node as the source of truth (`AGENTS.md`: deployments are managed through Dockhand; Renovate owns version bumps).

An emergency `docker compose up` from the clone, bypassing Dockhand, is **UNVERIFIED** and is not documented as a day-2 path. The repo does use `docker compose -p tailscale down` and `docker compose -p dockhand down` in host rollback, which stops those stacks; that is not the same as pinning an older app image, and those commands must not gain `-v`. Never `docker volume prune`.

**Verify:** `docker inspect --format '{{.Config.Image}}' <CONTAINER>` equals the `<IMAGE>@sha256:<OLD_DIGEST>` from B1, the smoke checks in A3 pass again, and (for Paperless) the bind check in A3 still shows `<CORE_LAN_IP>`.

## Part C: Dockhand is down

This recovers Dockhand, not an application.

### C1. Check reachability, not the firewall first
Tunnel to `:3000` as in Prerequisites. If the UI is up over the tunnel, Dockhand is running and the problem is elsewhere (auth, or the allowlist).
**Verify:** you can either load the UI over `ssh -L`, or `docker inspect dockhand` shows the container is not running or is restarting.

### C2. If you must recreate Dockhand
Follow `host/README.md` Rollback for Dockhand only: `docker compose -p dockhand down` (no `-v`); for a clean start, move `/srv/homelab/dockhand/data` aside **and** set `DOCKHAND_3000=lock` in `/etc/homelab/firewall.env`, then `sudo homelab-firewall.sh --early`, before the next start. Then redo first-start auth and `--unlock-dockhand` from `host/README.md`.
Moving the data directory is destructive to Dockhand's own state (users, provider config, stack bindings). It does not roll back AdGuard, Zoraxy or any other app. Re-bind stacks to their Bitwarden projects afterwards ("Rebuilding a node" step 8). After a clean start succeeds, delete the aside copy of the old data directory (it can hold the old provider token) and rotate that token with `bws-token-rotation.md` if the copy was untrusted (lost card or suspected leak).
**Verify:** authentication is on, `--unlock-dockhand` has been run if you started from a lock, the anonymous probe returns 403, and `DOCKHAND_3000` is `allowlist` only after that. The aside copy is gone if you deleted it.

## Rollback

- **Part A:** if A3 fails, run Part B (starting with A0 if needed, including a fresh Paperless dump when core or Paperless is involved).
- **Part B:** if the older pin also fails, stop at a last-known-good stack and do not keep experimenting on the node. A further-back pin is the same procedure, including restoring pre-deploy data when the stack is stateful.
- **Part C:** if a clean Dockhand start fails, leave `:3000` locked and use SSH. Do not open the port. Application data is in `/srv/homelab/<STACK>/`, not in Dockhand's data dir.
- Do not treat `host/README.md`'s Dockhand rollback as an app-stack rollback.
- Never `docker compose down -v` or `docker volume prune`.

## References

- `README.md` — How it runs (Dockhand, Renovate, no automerge)
- `AGENTS.md` — images, CI, deploy responsibility
- `renovate.json`
- `host/README.md` — Dockhand `:3000`, Verify item 7, Rollback
- `infrastructure/README.md` — "Rebuilding a node" step 8; ntfy §3 and §7.3
- `compose/infrastructure/dockhand/compose.yaml` — `fnsys/dockhand:v1.0.57`, port 3000, `/srv/homelab/dockhand/data`, `bws` bind-mount
- `backrest-backup-restore.md` — snapshot, dump and restore

## TBDs and UNVERIFIED items

- How Dockhand is connected to git and the exact day-2 deploy clicks.
- Whether Dockhand deploys from `/srv/homelab/docker-gitops`.
- Whether rollback requires a revert on `main` or can be done in the UI.
- Whether an emergency `docker compose` deploy that bypasses Dockhand is ever accepted.
- Core deploys through Hawser (blocked).
- AdGuard's in-container healthcheck as an operator-facing day-2 command.
