# Runbooks

These are practical procedures for the docker-gitops homelab: two Raspberry Pi 4B nodes running Docker Compose, deployed with Dockhand, with Backrest backing up host bind-mount data. All are based on `main` at `9620752`, and every repo file they cite is cited at that commit.

They are drafts. Review and merge them before use.

| Runbook | Use it when |
|---|---|
| [backrest-backup-restore.md](backrest-backup-restore.md) | Confirm a snapshot, restore a path or an app, or fill step 5 of a node rebuild |
| [dockhand-deploy-rollback.md](dockhand-deploy-rollback.md) | Deploy a change that landed on `main`, or roll back a bad image |
| [host-os-updates.md](host-os-updates.md) | Patch Raspberry Pi OS on a node |
| [bws-token-rotation.md](bws-token-rotation.md) | Revoke a bootstrap token, rotate the Dockhand Secrets Manager token, rotate ntfy tokens, or handle a lost card |

Node bootstrap and a lost-Pi rebuild are already in the repository. Do not duplicate them:

- [`host/README.md`](../../host/README.md) — cloud-init, `bootstrap.sh`, firewall, verify, host-level rollback
- [`infrastructure/README.md`, "Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node) — the ten-step rebuild checklist

[backrest-backup-restore.md](backrest-backup-restore.md) is the restore runbook that checklist names in step 5. `--restore-prep` stays reserved and is not implemented (`host/bootstrap.sh` at 9620752).

There is no Zoraxy operations runbook in this set.

## Suggested order

1. bws-token-rotation, so tokens and revocation are familiar before a restore or rebuild.
2. backrest-backup-restore, including a rehearsal of snapshot confirmation.
3. dockhand-deploy-rollback, for day-2 changes.
4. host-os-updates, once a snapshot and a rollback path exist.

## Conventions

- **Values:** everything that is not already a public, non-secret fact at 9620752 (paths, unit names, ports, image names and tags, documented service names) is an `<UPPER_SNAKE>` placeholder. No addresses, hostnames, tailnet names, tokens, passwords or personal identifiers appear here.
- **Verify checks:** every step ends with one. Don't go to the next step until it passes.
- **Markers:** `TBD` means a decision or a missing procedure. `UNVERIFIED` means it is not in the repo and has not been tested on a live node.
- **Secrets:** never paste tokens, passwords, dumps or `config.json` into a terminal log, a chat or the repo. Work under `umask 077`. Paste UI secrets from Bitwarden on the workstation; do not stage those pastes in a file on the node. Backrest restores go to a named `0700` staging directory (Backrest cannot see host `/dev/shm`). After a restore, delete the staging directory and confirm with `ls` that it is gone. `shred` is unreliable on SD cards. Never put a secret on a command line, in process arguments or in shell history. Do not use `set -x`, `curl -v` or `--trace` around secrets.
- **No k3s steps:** this repo does not use SOPS, age, VolSync, CNPG or Longhorn. Do not follow the k3s-gitops restore or key runbooks here.
