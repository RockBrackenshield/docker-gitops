# Runbook: Secrets Manager token rotation

Based on docker-gitops `main` at `9620752`. File references mean that file at 9620752.

## Purpose, scope, when to use

Rotate the Bitwarden Secrets Manager tokens and the other credentials this repository already documents. This is not a complete inventory of every `${VAR}` in every compose file; only named tokens and the lost-card list in `host/README.md` are in scope.

Use it when:

- A `bootstrap.sh` run has just finished (always revoke the bootstrap access token).
- `DOCKHAND_BWS_ACCESS_TOKEN` is approaching its 90-day expiry (Part B, expiry path).
- That token, or the machine account that holds it, is suspected to have been exposed (Part B, leak path: revoke first).
- An ntfy token leaked, a device was lost, or the yearly ntfy rotation is due.
- A card was lost or imaged (full rotation list in Part D).
- After a Backrest restore that is older than a later rotation (`backrest-backup-restore.md` Part D2).

Out of scope:

- SOPS or age (not used in this repo).
- A first-time bootstrap or first Dockhand unlock: [`host/README.md`](../../host/README.md).
- Implementing the reserved `restore-<NODE>` projects or `--restore-prep`.
- Hawser install and firewall (deferred in `host/README.md`); the lost-card list still names core's Hawser token.

## Prerequisites

- [ ] Access to the Bitwarden project that holds the token you are rotating (`bootstrap-infrastructure`, `bootstrap-core`, or a stack project).
- [ ] For Dockhand's provider token: the Dockhand UI over `ssh -L 3000:127.0.0.1:3000 <ADMIN_USER>@<INFRASTRUCTURE_NODE>`, with authentication on.
- [ ] For ntfy: ability to `docker exec` into the `ntfy` container as in `infrastructure/README.md` §6–§7.
- [ ] Paste tokens from Bitwarden on the workstation into the Dockhand UI. Do not stage a UI paste in a file on the node. Never put a token on a command line, in `docker inspect` output you paste elsewhere, in shell history, or in a hook script. The ntfy Backrest token file on the node is created only with the §7.1 procedure, under `umask 077`.

## Part A: revoke a bootstrap access token

Do this immediately after every `bootstrap.sh` run, including a failed run that prompted for a token (`host/README.md`; the script also reminds on exit).

The rebuild checklist creates that token with a **1-day expiry** on the node's machine account. Revocation is immediate, but a session already issued can live up to an hour.

The token is typed into `bootstrap.sh` from the terminal (input hidden). It must never be passed in argv, a file, or the **caller's** environment. `host/bootstrap.sh` then passes it to the one `bws` process only, as `BWS_ACCESS_TOKEN` in that process's environment (`host/bootstrap.sh` around line 383), and unsets it immediately afterwards.

### A1. Revoke in Bitwarden
Revoke the access token you just used. Do not leave a successful or failed bootstrap token active.
**Verify:**

- The token shows as revoked (or deleted) in Bitwarden, and `host/README.md` Verify item 11 is satisfied.
- `host/README.md` Verify item 10 (no residue): no `/run/homelab-bootstrap.*`, no `/root/.config/bws`; `/var/log/homelab-bootstrap.log` holds step lines only.

## Part B: rotate `DOCKHAND_BWS_ACCESS_TOKEN`

`host/README.md` says to give this token a 90-day expiry and to rotate it in Dockhand before it lapses. It is stored in the `bootstrap-infrastructure` project and is handed to Dockhand on first start; after that, Dockhand uses it to inject stack secrets. Always write the current live value back to `bootstrap-infrastructure` when you rotate, so a later `bootstrap.sh` does not hand Dockhand a revoked token.

Choose one path. Do not follow the expiry path if the token may have leaked.

### B1. Expiry path (no suspected leak): create the new token first
Create a new access token in Bitwarden with a 90-day expiry, still limited to the projects the Dockhand machine account should read. Do **not** revoke the old token yet.
Paste the new value from Bitwarden on the workstation into the Dockhand UI. Do not write it to a file on the node, and do not pass it to `curl` or `docker exec` on a command line. Exact Dockhand UI clicks are **UNVERIFIED**. Then update `DOCKHAND_BWS_ACCESS_TOKEN` in `bootstrap-infrastructure` to the new value.
**Verify:** Dockhand shows the provider as connected (wording **UNVERIFIED**). The token is not in shell history or `ps`. The workstation clipboard is cleared.

### B2. Expiry path: confirm, then revoke the old token
Fail closed: if you revoke the old token before Dockhand accepts the new one, stack deploys cannot inject secrets.
**Verify:** an authenticated Dockhand action that requires Secrets Manager still works (exact check **UNVERIFIED**; the anonymous `GET /api/secret-providers` 403 probe only proves auth is on, not that the new token works). Then revoke the old token in Bitwarden. Confirm `bootstrap-infrastructure` holds only the new value.

### B3. Leak path (suspected exposure): revoke first
If the token, the machine account, or a host that held either might have been exposed, do **not** leave the old token live until a replacement works.

1. Revoke the exposed `DOCKHAND_BWS_ACCESS_TOKEN` in Bitwarden immediately. Accept that Dockhand cannot inject secrets until the rest of this path is done (an outage).
2. Create a new access token with a 90-day expiry, limited to the same projects.
3. Paste it from Bitwarden on the workstation into the Dockhand UI, then update `DOCKHAND_BWS_ACCESS_TOKEN` in `bootstrap-infrastructure` to the new value.
4. Rotate **every** secret that machine account can read. The complete list is not in Git; in Bitwarden, open the projects that account can access and rotate each secret Dockhand injects into the stacks (the `${VAR}`s in those compose files). That includes values such as `TS_AUTHKEY` if they sit in those projects (the accepted Tailscale risk in `host/README.md` still applies after Dockhand redeploys). Then redeploy the affected stacks from Dockhand so containers pick up the new values (`dockhand-deploy-rollback.md`, including its snapshot step).

**Verify:** the old token is revoked, `bootstrap-infrastructure` holds the new `DOCKHAND_BWS_ACCESS_TOKEN`, Dockhand can inject secrets again, and each secret that account could read has been rotated and redeployed. The workstation clipboard is cleared.

## Part C: ntfy users and tokens

Follow `infrastructure/README.md` §6, §7.1 and §7.3. Summarised, not replaced:

- `token list` prints **full** token values; always mask.
- **Publisher leak:** `docker exec ntfy ntfy user del <USER>`, then re-run that user's `user add`, `access` and `token add` lines, and update the consumer. For Backrest, rewrite `/srv/backrest/secrets/ntfy-token` on the affected node with §7.1 (`install -d -m 0700`, `umask 077`, `cat` into the file, expect `root:root` mode `600`, size 33 for a 32-character token plus newline). Then recreate the Backrest container if the file was empty or missing.
- **Lost device:** delete and recreate the admin user (that removes all of its tokens) without typing an old token, then re-issue a token for each remaining device, and **rotate every publisher token** too.
- **Yearly:** rotate publisher tokens, and re-issue device tokens before they expire (`--expires=365d` in the table).
- Never paste a token into the Backrest hook, and never use `set -x`, `curl -v` or `--trace`.

### C1. Rotate and test without printing the token
Use the §7.3 tests: pipe the token to curl on stdin from the root-only file, expect 200 to publish, 403 to read, 403 for anonymous publish. Then confirm `docker exec backrest printenv | grep -c NTFY_BACKREST_TOKEN` prints `0`, and `sudo grep -rl 'tk_' /srv/homelab/backrest/data /srv/homelab/backrest/config` prints **no files** (names only, never a token).
**Verify:** those checks pass, and the masked `token list` count matches the table in §6.

## Part D: lost or imaged card

From `host/README.md` Rollback: treat it as a full rotation of Dockhand's provider token and key, every injected value in container configs, the Tailscale node key and auth key, Backrest's `config.json`, ntfy tokens, the SMB password, SSH host keys, and core's Hawser token.

Also treat the **backup repository and any storage credentials** as exposed, including `BACKREST_REPO_PASSWORD_<NODE>` once the reserved `restore-<NODE>` projects exist. Until those exist, record that they must be rotated as soon as they do (Part E). A snapshot taken with an exposed repository password is not a safe copy of those credentials.

Hawser is not installed by this repo yet; if that token does not exist, skip it and leave a note. After Dockhand redeploys the tailscale stack, `TS_AUTHKEY` is visible in `docker inspect` again (accepted risk recorded in `host/README.md` and `infrastructure/README.md`). Do not try to "fix" that as part of rotation.

If Dockhand was recreated from `dockhand-deploy-rollback.md` C2 (data directory moved aside and `:3000` locked), delete the aside copy of `/srv/homelab/dockhand/data` after the clean start is verified (it can still hold the old provider token), and rotate `DOCKHAND_BWS_ACCESS_TOKEN` with the **leak path** (B3), because the card held that token.

Rotate each other item with the procedure that already owns it (Part B leak path, Part C, Paperless Samba recreate in `infrastructure/README.md` §7 after `SMB_PASSWORD` changes, Tailscale admin console for the node key). Then take a fresh Backrest snapshot (`backrest-backup-restore.md` Part A).
**Verify:** the old card's credentials no longer work, the aside Dockhand data directory is gone, Dockhand still injects secrets with the new token, ntfy publisher tests in C1 pass, and a new snapshot exists.

## Part E: `BACKREST_REPO_PASSWORD_<NODE>`

The `restore-infrastructure` and `restore-core` projects are reserved for this password (`host/README.md`). `--restore-prep` is not implemented. A rotation procedure is **TBD** until those exist. Do not invent a restic key-change command. After a lost card, treat the password as exposed and rotate it as soon as the projects exist.
**Verify:** you did not rotate an undocumented password, or you stopped because this part is TBD, and a lost-card note records that the rotation is still owed.

## Rollback

- **Part A:** a revoked bootstrap token cannot be un-revoked; create a new 1-day token if you must re-run `bootstrap.sh`.
- **Part B, expiry path:** keep the old `DOCKHAND_BWS_ACCESS_TOKEN` active until the new one is confirmed. If the new one fails, Dockhand should still have the old one. Keep `bootstrap-infrastructure` in step with whichever token Dockhand is actually using.
- **Part B, leak path:** the old token is already revoked; there is no fall back to it. Accept the outage until the new token is in Dockhand and in `bootstrap-infrastructure`.
- **Part C:** if a new ntfy token file is wrong, the Backrest hook sends no alert, or the stack refuses to start if the file is missing. Re-issue from Bitwarden with §7.1. Do not leave a second copy of a live token on disk.
- **Every path, including an abort:** clear the workstation clipboard. If any file on the node was used to stage a UI paste, delete it and confirm `ls` fails.

## References

- `host/README.md` — bws projects, 90-day Dockhand token, Verify items 10 and 11, Rollback (lost card), accepted Tailscale risk
- `host/bootstrap.sh` — token is read from the terminal, passed only to the `bws` process environment, then unset
- `infrastructure/README.md` — "Rebuilding a node" step 1 and 7; ntfy §6, §7.1, §7.3
- `backrest-backup-restore.md` — re-revocation after restoring `user.db`
- `dockhand-deploy-rollback.md` — C2 (Dockhand data dir); snapshot before a redeploy

## TBDs and UNVERIFIED items

- Exact Dockhand UI steps to replace the Secrets Manager provider token, and the exact post-rotation check.
- A full inventory and rotation schedule for every stack `${VAR}` not named in `host/README.md` or the Paperless/ntfy sections. The leak path rotates every secret the machine account can read, listed from Bitwarden at the time.
- Rotation of `BACKREST_REPO_PASSWORD_<NODE>` once `restore-<NODE>` and `--restore-prep` exist (still owed after a lost card).
