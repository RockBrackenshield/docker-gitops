# Runbook: host OS and firmware updates

Based on docker-gitops `main` at `9620752`. File references mean that file at 9620752.

## Purpose, scope, when to use

Patch Raspberry Pi OS on the `infrastructure` or `core` node without knocking down Docker, the host firewall, NFS (core) or AdGuard DNS (infrastructure).

Use it for a planned maintenance window only. If the node is already lost, use ["Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node) and `backrest-backup-restore.md` instead.

Out of scope:

- Image bumps for containers: `dockhand-deploy-rollback.md` and Renovate.
- Changing `host/*/user-data` or `host/bootstrap.sh`.
- Enabling unattended upgrades (not documented in this repo). Confirm they are off before you start.
- A firmware or EEPROM procedure (not documented in this repo; **TBD**). Treat `rpi-eeprom`, kernel and firmware packages as high-risk and do not apply them in a routine window.

## What the repository actually specifies

- OS: Raspberry Pi OS Lite, 64-bit, Trixie (`infrastructure/README.md` "Rebuilding a node" step 2; comments in `host/core/user-data` and `host/infrastructure/user-data`).
- Host packages from cloud-init: `git`, `curl`, `ca-certificates`, `gnupg`, `unzip`, `iptables`, and on core `nfs-kernel-server`.
- Docker Engine and the Compose plugin are installed from Docker's Debian repo (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`), with the signing-key fingerprint checked in `host/README.md` Verify item 2.
- `bws` 2.1.0 is a manual install to `/usr/local/bin/bws`, pinned by `BWS_BIN_SHA256` in `host/bootstrap.sh`. It is not an apt package. An OS update must not replace it with a different binary.
- Docker's firewall backend must be `iptables` (`host/bootstrap.sh` preflight; `host/README.md` step 0).
- The early firewall unit is `RequiredBy=docker.service` and `nfs-server.service`. If it fails at boot, Docker (and therefore AdGuard DNS on infrastructure) stays down until it is fixed over SSH. **Never** `systemctl restart homelab-firewall-early`: `Requires=` restarts Docker too. Re-apply with `sudo homelab-firewall.sh --early` (`host/README.md`).

No update cadence, `apt` command, unattended-upgrades setting or EEPROM procedure is in the repo. Those are **TBD** or **UNVERIFIED** below. Do not enable unattended-upgrades unless a later decision says to.

## Prerequisites

- [ ] A confirmed Backrest snapshot for the node (`backrest-backup-restore.md` Part A).
- [ ] A maintenance window, and SSH access as `<ADMIN_USER>` that will still work if Docker is down (firewall failure must be fixable over SSH).
- [ ] The update cadence and the package set (especially whether `docker-ce` and `nfs-kernel-server` are included) agreed in advance. That cadence is **TBD**.
- [ ] Unattended upgrades are off (Part A3).

## Part A: before you change packages

### A1. Confirm a snapshot
Run `backrest-backup-restore.md` Part A on this node.
**Verify:** a successful snapshot exists that you are willing to restore from.

### A2. Record versions
```bash
. /etc/os-release && printf '%s %s\n' "$PRETTY_NAME" "$VERSION_CODENAME"
uname -r
docker version --format '{{.Server.Version}}'
bws --version
sha256sum /usr/local/bin/bws
```
**Verify:** the OS is still the expected Trixie release, `bws --version` is `bws 2.1.0`, and `sha256sum /usr/local/bin/bws` matches `BWS_BIN_SHA256` in `host/bootstrap.sh`. If the bws hash differs, stop (`host/README.md`).

### A3. Confirm unattended upgrades are off, and hold high-risk packages you will not upgrade
Raspberry Pi OS defaults for unattended-upgrades are **UNVERIFIED**. Confirm the service is not enabled before you continue:

```bash
systemctl is-enabled unattended-upgrades || true
```

**Verify:** the output is `disabled` or `not-found`. If it is `enabled`, stop, turn it off, and only then continue. Do not enable it as part of this runbook.

Treat these as high-risk, in addition to Docker and NFS: `rpi-eeprom` (an upgrade can stage an EEPROM image that applies at the next reboot), kernel packages, and firmware packages. `apt-mark hold` every high-risk package that is **not** in this window's agreed set, so an `apt-get upgrade` cannot pull it in:

```bash
sudo apt-mark hold <PACKAGE>
```

Leave a note to `apt-mark unhold` a package only when a later agreed window includes it.
**Verify:** `apt-mark showhold` lists the high-risk packages you are not upgrading this time.

## Part B: apply host updates

### B1. Review, then upgrade a chosen set
The exact `apt-get` invocation is **UNVERIFIED**. A fail-closed approach, pending the cadence in Prerequisites:

1. `sudo apt-get update`
2. Review the pending upgrades before installing anything.
3. Treat `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`, `docker-buildx-plugin`, (on core) `nfs-kernel-server`, `rpi-eeprom`, kernel packages and firmware packages as high-risk. Whether to include Docker or NFS in a routine window is **TBD**. Do not include `rpi-eeprom`, kernel or firmware in a routine window (see B3).
4. Do not run an unattended or unreviewed `dist-upgrade` unless that is the agreed cadence.
5. Do not install a new bws from apt or from the network as part of this runbook.

**Verify:** the upgrade finished without error, `bws --version` is still `bws 2.1.0` with the same `BWS_BIN_SHA256`, and `docker version` still answers if you did not intend to stop Docker. Then run the firewall and iptables-backend checks in B2 immediately, even if you are not rebooting. An apt-driven Docker restart should keep the raw rules and have the Docker unit re-apply `DOCKER-USER`; still confirm they are present.

### B2. Firewall checks after every upgrade, and after a reboot if one is required
Run these after B1, and again after any reboot. Do **not** `systemctl restart homelab-firewall-early`. If the early unit failed, Docker will not start. Fix `/etc/homelab/firewall.env` over SSH, check a copy with `sudo homelab-firewall.sh --check --env <FILE>`, then `sudo homelab-firewall.sh --early`.

Confirm Docker's firewall backend is still `iptables` (the same requirement as `host/bootstrap.sh` preflight and `host/README.md` step 0). Then:

```bash
systemctl is-active homelab-firewall-early homelab-firewall-docker
systemctl show docker -p Requires
# on core only:
systemctl show nfs-server -p Requires
sudo iptables -t raw -S HOMELAB-RAW
sudo ip6tables -t raw -S HOMELAB-RAW
sudo iptables -S HOMELAB-DOCKER
# on core only:
sudo iptables -S HOMELAB-INPUT
```

On infrastructure, from a LAN host and a tailnet device, `:2586`, `:3000`, `:8000`, `:9898` and `:8102` must still time out as in Verify item 7. After a Tailscale or Docker restart, repeat the ntfy `:2586` timeout check (`infrastructure/README.md` ntfy §3).
On core, `sudo exportfs -v` still lists only the laptop export (`host/README.md` Verify item 9). Core `:9898` is an open exposure until a separate repo change; the timeout check in `backrest-backup-restore.md` Prerequisites still applies, but a passing tunnel does not mean the LAN port is closed.

**Verify:** the Docker firewall backend is `iptables`, the early and Docker firewall units are active, `docker` (and on core `nfs-server`) Requires the early unit, each listed rule appears once, and the timeout checks still pass.

If a reboot is required, reboot during the window, then repeat this whole step.

### B3. Firmware and EEPROM
No firmware or EEPROM procedure is in this repository. **TBD.** Do not run `rpi-eeprom` or other EEPROM or firmware tools as part of this runbook until that is written down. Keep those packages on hold (A3) unless a later agreed window includes them.
**Verify:** you did not apply an undocumented firmware or EEPROM change, or you stopped because the step is TBD. `apt-mark showhold` still lists them.

## Rollback

- If a package upgrade misbehaves but SSH and the firewall still work, stopping after B1 and scheduling a rebuild is safer than inventing an `apt` downgrade (**UNVERIFIED** on this image).
- If the early firewall unit failed closed, fix it over SSH with `homelab-firewall.sh --check` and `--early`. Do not `systemctl restart` the early unit.
- If the node is unusable, use ["Rebuilding a node"](../../infrastructure/README.md#rebuilding-a-node) and `backrest-backup-restore.md`.
- `bws` must remain the pinned 2.1.0 binary. If it changed, stop and restore the verified binary from `host/README.md` ("Install bws 2.1.0") rather than continuing.

## References

- `infrastructure/README.md` — "Rebuilding a node" step 2 (Trixie); ntfy §3 (firewall vs Tailscale/Docker restarts)
- `host/README.md` — Firewall, Verify, "Never `systemctl restart homelab-firewall-early`", Docker firewall backend `iptables`
- `host/core/user-data`, `host/infrastructure/user-data` — packages, Docker apt source
- `host/bootstrap.sh` — `BWS_BIN_SHA256`, `bws 2.1.0`, iptables backend preflight
- `backrest-backup-restore.md` — snapshot before the window

## TBDs and UNVERIFIED items

- Update cadence and whether unattended-upgrades should ever be enabled (default for this runbook: leave them off; confirm they are off before starting).
- Raspberry Pi OS default for unattended-upgrades on these nodes.
- The exact `apt-get` command and whether Docker or NFS packages are in a routine window.
- How to downgrade a bad apt upgrade on this image.
- Any firmware or EEPROM procedure, including what an upgraded `rpi-eeprom` would stage for the next reboot.
