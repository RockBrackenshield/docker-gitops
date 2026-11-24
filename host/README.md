# host/: node bootstrap

Everything needed to rebuild the `infrastructure` or `core` node from a blank
SD card, without Ansible: cloud-init for first boot, one re-runnable
`bootstrap.sh`, and the host firewall. The step-by-step rebuild is in
[`infrastructure/README.md`, "Rebuilding a node"](../infrastructure/README.md#rebuilding-a-node).

| File | What it is |
|---|---|
| `infrastructure/user-data`, `core/user-data` | cloud-init `#cloud-config` per node. Placeholders only: `<admin-user>`, `<ssh-public-key>`, and on infrastructure `<infra-lan-ip>` (DNS fallback, below). |
| `bootstrap.sh` | Run once on the node after first boot; safe to re-run. Reads secrets with one `bws secret list -o env`, parsed against each node's name allowlist. |
| `firewall/homelab-firewall.sh` | Validates `/etc/homelab/firewall.env` and applies the node's rules (`--early`, `--docker`, `--check`, `--remove`). |
| `firewall/homelab-firewall-early.service` | Loads the raw/INPUT rules before the network, Docker and host NFS. `RequiredBy=docker.service nfs-server.service`, so it fails closed. |
| `firewall/homelab-firewall-docker.service` | Adds the `DOCKER-USER` second layer after Docker starts. |
| `firewall/homelab-firewall-alert.service` | Not enabled; started by the early unit's `OnFailure=` to print a notice on the console and through `wall`. |

**Never commit a filled-in `user-data`**, and never put a password, `passwd`,
`plain_text_passwd` or a Wi-Fi PSK in `user-data` or `network-config`
(`network-config` is copied to `/etc/netplan` unchanged). Real values (addresses,
UIDs, keys, tokens) come from Bitwarden Secrets Manager at run time and stay
off Git.

## sudo after first boot

cloud-init gives `<admin-user>` passwordless sudo for the first boot only.
Then, over SSH:

1. `sudo passwd <admin-user>` (while `NOPASSWD` still works). The password never goes in user-data, Git or Bitwarden.
2. `sudo visudo -f /etc/sudoers.d/90-cloud-init-users`, change the line to `<admin-user> ALL=(ALL) ALL`, then `sudo visudo -c`.
3. In a **second** SSH session, `sudo -k && sudo true` must ask for the password and succeed. Only then close the first session.

## Install bws 2.1.0 (both nodes, before bootstrap)

`bootstrap.sh` and Dockhand both use `/usr/local/bin/bws`. Dockhand requires
`>=2.1.0 <3.0.0`; 2.1.0 is the latest release. Source:
<https://github.com/bitwarden/sdk-sm/releases/tag/bws-v2.1.0>. Bitwarden
publishes no signature or attestation for the Linux build, so verification is
checksum-only against the values pinned here.

```bash
cd "$(mktemp -d)"
curl -fsSLO https://github.com/bitwarden/sdk-sm/releases/download/bws-v2.1.0/bws-aarch64-unknown-linux-gnu-2.1.0.zip
curl -fsSLO https://github.com/bitwarden/sdk-sm/releases/download/bws-v2.1.0/bws-sha256-checksums-2.1.0.txt
echo "b7a7c8de686fe7f816cab6ed2576688b5922fc0e003c4eed554feca17828184f  bws-sha256-checksums-2.1.0.txt" | sha256sum -c -
echo "18253757286e119d450133a87eb463bf8c1ce418ce24c834f4f250d60cba6f9e  bws-aarch64-unknown-linux-gnu-2.1.0.zip" | sha256sum -c -
grep ' bws-aarch64-unknown-linux-gnu-2.1.0.zip$' bws-sha256-checksums-2.1.0.txt | sha256sum -c -
unzip -o bws-aarch64-unknown-linux-gnu-2.1.0.zip bws
sudo install -m 0755 -o root -g root bws /usr/local/bin/bws
sha256sum /usr/local/bin/bws
bws --version            # expect: bws 2.1.0
```

**`BWS_BIN_SHA256` in `bootstrap.sh` is pinned to Rock's installed bws
2.1.0.** Bitwarden publishes digests for the zip only, so the pin is the
`sha256sum /usr/local/bin/bws` of that verified install. On each node, check
that `sha256sum /usr/local/bin/bws` prints exactly the `BWS_BIN_SHA256` value
before the first run. If it differs, stop: `bootstrap.sh` refuses to run in
preflight (fails closed), and a different bws build needs a new pin through a
reviewed PR.

## Before every run: check the clone with the OS's git

`bootstrap.sh` runs as root from `/srv/homelab/docker-gitops`. A check inside
the script can't prove the script itself is unmodified, so do it first:

```bash
sudo git -C /srv/homelab/docker-gitops pull --ff-only                  # only when updating
sudo git -C /srv/homelab/docker-gitops rev-parse HEAD                  # must equal the merge commit on GitHub
sudo git -C /srv/homelab/docker-gitops status --porcelain --ignored    # must print nothing
```

If either check fails, don't run `bootstrap.sh`: re-clone and check again.

## Running bootstrap.sh

```bash
sudo /srv/homelab/docker-gitops/host/bootstrap.sh
# or from your workstation (needs -t for the prompts):
ssh -t <admin-user>@<node> 'sudo /srv/homelab/docker-gitops/host/bootstrap.sh'
```

`sudo` asks for your password, then the script asks once for the node's
bootstrap access token (input hidden). It only asks if a step still needs
secrets; a re-run on a finished node prints `skipped` for every step.

| # | Step | Node |
|---|---|---|
| 0 | Preflight: root, role from `hostname -s`, aarch64, terminal, cloud-init done, Docker + Compose, Docker firewall backend `iptables`, root-owned clone, prints HEAD (information only), bws hash and version | both |
| 1 | One `bws -p default secret list -o env` on a pipe, parsed by `bootstrap.sh` (strict `NAME="VALUE"` lines, no quotes, backslashes or newlines in values): values go to files in a tmpfs dir under `/run`; no secret becomes an environment variable; fails before writing anything if the account returns any unexpected, duplicate, missing or unparsable secret | both |
| 2 | `ntfy` system user/group with `NTFY_UID/GID`, `/srv/homelab/ntfy` `0700` (infrastructure); Paperless ownership and modes (core) | both |
| 3 | Docker networks `infra_edge`, `infra_internal` with fixed subnets (never recreated on mismatch) | infrastructure |
| 4 | Firewall: validate and write `/etc/homelab/firewall.env`, install the script and the three units, enable the early and Docker units, apply | both |
| 5 | Port 53 free for AdGuard (verify only) | infrastructure |
| 6 | NFS export `/etc/exports.d/paperless.exports` | core |
| 7 | Tailscale join (below) | infrastructure |
| 8 | First Dockhand start behind the `:3000` lock; hand Dockhand its Bitwarden token over its local API | infrastructure |
| 9 | Cleanup (also on any exit): delete the tmpfs dir, unset the token, print next steps | both |

**Revoke the bootstrap access token right after the run.** Revocation is
immediate, but a session already issued can live up to an hour.

### bws projects (names only)

Each machine account is read-only on exactly one project.

| Project (and machine account) | Secrets |
|---|---|
| `bootstrap-infrastructure` | `TS_AUTHKEY_INFRASTRUCTURE`, `DOCKHAND_BWS_ACCESS_TOKEN`, `TS_ROUTES`, `INFRA_LAN_IP`, `ZORAXY_SOURCE_CIDR`, `INFRA_EDGE_SUBNET`, `INFRA_INTERNAL_SUBNET`, `NTFY_UID`, `NTFY_GID` |
| `bootstrap-core` | `INFRA_LAN_IP`, `PRINTER_IP`, `LAPTOP_IP`, `PAPERLESS_UID`, `PAPERLESS_GID`, optional `PRINTER_IPV6`, `LAPTOP_IPV6` |
| `restore-infrastructure`, `restore-core` | `BACKREST_REPO_PASSWORD_<NODE>`: reserved for the restore runbook (`--restore-prep` is not implemented yet) |

Core's project holds no Dockhand token and no Tailscale key. Give
`DOCKHAND_BWS_ACCESS_TOKEN` a 90-day expiry and rotate it in Dockhand before it
lapses.

### Tailscale (step 7)

The tailscale stack is unchanged: it takes `TS_AUTHKEY=${TS_AUTHKEY}` from the
deploy environment and keeps its login in `/srv/homelab/tailscale/state`.
For the first join, bootstrap uses whatever auth key you put in
`TS_AUTHKEY_INFRASTRUCTURE` (any key type). It starts the stack once with a
run-time override on tmpfs that passes the key as `TS_AUTHKEY=file:/run/secrets/ts_authkey`,
so `docker inspect` and the process list show only the path. It then recreates
the container without the override and with an empty key, and checks that
`TS_AUTHKEY` is empty in the container, nothing still mounts the tmpfs
directory, and `docker logs tailscale` contains no `tskey-`.

### Dockhand `:3000` (step 8 and `--unlock-dockhand`)

A fresh Dockhand has authentication off and publishes `3000` on every
interface, so `firewall.env` starts with `DOCKHAND_3000=lock`: only loopback
reaches `:3000`, and the early unit re-applies that at every boot. Reach the UI
with `ssh -L 3000:127.0.0.1:3000 <admin-user>@infrastructure`, turn on
authentication, bind the stacks to their projects, then:

```bash
sudo /srv/homelab/docker-gitops/host/bootstrap.sh --unlock-dockhand
```

It requires an anonymous `GET /api/secret-providers` to return `403`, asks you
to confirm the audit (exactly one user; no API tokens, OIDC providers or
webhooks; no Hawser tokens yet, because core's agent token is created after the
unlock), then switches the marker to `allowlist`: from then on only loopback
and Zoraxy reach `:3000`, permanently. There is no "open" state.

## Firewall

| Node | Port | Allowed from |
|---|---|---|
| infrastructure | 2586 (ntfy, LAN IP only) | Zoraxy |
| infrastructure | 3000 (Dockhand) | loopback (lock), then loopback + Zoraxy (allowlist) |
| infrastructure | 8000 (Zoraxy UI) | loopback only (`ssh -L`) |
| infrastructure | 9898 (Backrest), 8102 (AdGuard admin) | loopback + Zoraxy |
| core | 8000 (Paperless) | the infrastructure node (Zoraxy) |
| core | 445 (Samba) | the printer |
| core | 2049 (NFS) | the laptop |

- Raw `PREROUTING` rules use `-m addrtype --dst-type LOCAL`, so they cover every address of the node and nothing the Tailscale subnet router forwards to other hosts. Each has an `ip6tables` twin; IPv6 sources are dropped unless an `*_IPV6` value is set (core only).
- The `DOCKER-USER` layer (`HOMELAB-DOCKER` chain) matches only DNATed traffic to published ports.
- A broken `firewall.env` fails the early unit, and Docker (including AdGuard DNS) stays down until it's fixed over SSH. Check a copy first with `sudo homelab-firewall.sh --check --env <file>`.
- **Never `systemctl restart homelab-firewall-early`**: `Requires=` restarts Docker too. Re-apply with `sudo homelab-firewall.sh --early`.

## DNS fallback (infrastructure)

UniFi hands the infrastructure node its **own** address as DNS, so without a
fallback the node's own lookups (git, Bitwarden, the Tailscale control plane)
die with its AdGuard container. The node therefore asks its AdGuard first, then
**Quad9**: `9.9.9.9` and `149.112.112.112`, Quad9's "Recommended" service
(malware blocking, DNSSEC validation), from
<https://quad9.net/service/service-addresses-and-features/>. Rock chose Quad9
and approved hardcoding its public addresses as a one-off exception to the
no-IPs rule (Nov 24, 2026: "Yes, hardcode Quad 9. I know it breaks the rule,
but it's for a public, well-documented and known service, so I'm not
concerned"). Every other address stays a placeholder.

New nodes get it from `user-data` (fill in `<infra-lan-ip>` in your local
copy; containers start after it, so they pick it up). It fails loudly, and writes nothing, if the placeholder is left or if
neither resolver stack is active. `FallbackDNS=` isn't used: it only applies
when no other server is known, and DHCP always supplies one.

**The already-provisioned node (by hand):**

```bash
systemctl is-active systemd-resolved NetworkManager    # which one is active?
```

- **systemd-resolved active** (the stub listener is off and `/etc/resolv.conf`
  points at `/run/systemd/resolve/resolv.conf`, as `user-data` sets it up):

  ```bash
  printf '[Resolve]\nDNS=<infra-lan-ip> 9.9.9.9 149.112.112.112\n' \
    | sudo tee /etc/systemd/resolved.conf.d/20-homelab-dns.conf
  printf 'nameserver <infra-lan-ip>\nnameserver 9.9.9.9\nnameserver 149.112.112.112\noptions timeout:2 attempts:2\n' \
    | sudo tee /etc/resolv.conf.homelab
  sudo chmod 0644 /etc/resolv.conf.homelab
  sudo ln -sfn /etc/resolv.conf.homelab /etc/resolv.conf
  sudo systemctl restart systemd-resolved
  cat /etc/resolv.conf     # the three servers in order, then the options line
  ```

- **NetworkManager active (and resolved not):**

  ```bash
  printf '[global-dns]\noptions=timeout:2,attempts:2\n\n[global-dns-domain-*]\nservers=<infra-lan-ip>,9.9.9.9,149.112.112.112\n' \
    | sudo tee /etc/NetworkManager/conf.d/20-homelab-dns.conf
  sudo nmcli general reload
  cat /etc/resolv.conf     # <infra-lan-ip> first, then the two Quad9 addresses, and the options line
  ```

- **Then, either way, restart the containers that need DNS.** Docker reads
  the host's `resolv.conf` only when a container starts, so running containers
  keep the old servers until restarted. Do it on site, or from the LAN, because
  restarting `tailscale` drops remote access for a moment:

  ```bash
  docker restart dockhand zoraxy ntfy backrest tailscale
  ```

  AdGuard itself doesn't need a restart.

Use the node's LAN address, not `127.0.0.1`: Docker drops loopback
nameservers when it builds container DNS from the host's `resolv.conf`, so a
loopback entry could silently send containers straight to Quad9.

**Check (on site, at a quiet time; LAN clients lose DNS for those seconds):**
`docker stop adguard-home; getent ahosts github.com; docker start adguard-home`.
The lookup still resolves.

**How the fallback works.** In both cases `/etc/resolv.conf` lists
`<infra-lan-ip>`, `9.9.9.9`, `149.112.112.112` in that order, with
`options timeout:2 attempts:2`, and glibc (and Docker, which copies that file
into containers) asks them **in order**. If AdGuard isn't listening (container
stopped), the query is refused at once and glibc moves to Quad9 straight away.
If AdGuard is up but doesn't answer, glibc waits 2 s (instead of the 5 s default)
before trying the next server, so a lookup can take a few seconds. glibc reads
at most three `nameserver` lines, which is why only IPv4 Quad9 is used.
systemd-resolved can't do this itself: with the stub listener off, its
`/run/systemd/resolve/resolv.conf` holds only `nameserver` and `search` lines
(no `options`), so the timeout couldn't be set there.

**Trade-offs.** While the node uses Quad9, its own lookups bypass AdGuard's
filtering and internal rewrites. The static file on resolved nodes doesn't
follow DHCP changes (no DHCP search domains either); the node's address is
fixed anyway. If `libnss-resolve` is ever installed and `resolve` is put in
`/etc/nsswitch.conf`, lookups would go through systemd-resolved's own server
handling (the `DNS=` drop-in) instead of this file. LAN clients are
unaffected: UniFi still hands them AdGuard.

**Rollback.** Delete the `20-homelab-dns.conf` drop-in, and on resolved nodes
point `/etc/resolv.conf` back with
`sudo ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf` and delete
`/etc/resolv.conf.homelab`. Then restart systemd-resolved or
`sudo nmcli general reload`, and restart the containers as above.

## Verify

1. `cloud-init status --long` = `done`; `sudo cloud-init schema --system --annotate`.
2. `hostname -s` = role; password SSH is refused; `sudo sshd -T | grep -Ei '^(allowusers|authenticationmethods|allowagentforwarding|x11forwarding|allowtcpforwarding|passwordauthentication|permitrootlogin) '`; `sudo -k && sudo true` asks for the password; `sudo grep -r NOPASSWD /etc/sudoers.d` finds nothing; `gpg --show-keys /etc/apt/keyrings/docker.asc` shows `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`.
3. The repo checks above, and `stat -c '%U %a' /srv/homelab/docker-gitops/host/bootstrap.sh` = `root 755`.
4. `sha256sum /usr/local/bin/bws` = `BWS_BIN_SHA256`; `bws --version` = `bws 2.1.0`.
5. A re-run prints `skipped` for every step and doesn't ask for a token.
6. `systemctl is-active homelab-firewall-early homelab-firewall-docker`; `systemctl show docker -p Requires` (and on core `systemctl show nfs-server -p Requires`) lists the early unit; `sudo iptables -t raw -S HOMELAB-RAW`, `sudo ip6tables -t raw -S HOMELAB-RAW`, `sudo iptables -S HOMELAB-DOCKER` (and on core `sudo iptables -S HOMELAB-INPUT`) show each rule once; the same after `sudo reboot`.
7. infrastructure, from a LAN host and a tailnet device: `:2586`, `:3000`, `:8000`, `:9898` and `:8102` time out; `:3000` stays blocked after a reboot before the unlock and after the unlock; after the unlock the anonymous probe returns `403`; `docker exec zoraxy ip route get <infra-lan-ip>` shows a `src` inside `ZORAXY_SOURCE_CIDR`.
8. infrastructure, Tailscale, right after bootstrap: `docker exec tailscale tailscale status` is logged in; `docker inspect tailscale` shows no `TS_AUTHKEY` value and no `/run/homelab-bootstrap` mount; `docker logs tailscale 2>&1 | grep -c 'tskey-'` = `0`. After Dockhand redeploys the stack, `TS_AUTHKEY` is visible again (accepted risk below).
9. core: `sudo exportfs -v` lists only the laptop export; `rpcinfo -p` fails; the laptop can write and files land as the Paperless UID.
10. No residue: no `/run/homelab-bootstrap.*`, no `/root/.config/bws`; `/var/log/homelab-bootstrap.log` holds step lines only.
11. Bitwarden: the bootstrap access token was revoked right after the run.

## Rollback

- Whole node: reflash; data comes back with Backrest.
- Firewall: `sudo systemctl disable homelab-firewall-early homelab-firewall-docker`, then `sudo homelab-firewall.sh --remove`. That also removes the Dockhand allowlist, so only with Dockhand stopped or auth on.
- NFS: remove `/etc/exports.d/paperless.exports`, `sudo exportfs -ra`.
- Tailscale: `docker compose -p tailscale down`; remove the machine in the admin console; delete `/srv/homelab/tailscale/state` only to re-join from scratch.
- Dockhand: `docker compose -p dockhand down`; for a clean start, move `/srv/homelab/dockhand/data` aside **and** set `DOCKHAND_3000=lock` in `/etc/homelab/firewall.env`, then `sudo homelab-firewall.sh --early`, before the next start.
- sudo: `sudo visudo -f /etc/sudoers.d/90-cloud-init-users` (keep a second session open).
- Secrets: revoke the bootstrap token; rotate `DOCKHAND_BWS_ACCESS_TOKEN`, core's Hawser token and the Tailscale auth key if they might be exposed.
- Lost or imaged card: treat it as a full rotation (Dockhand's provider token and key, every injected value in container configs, the Tailscale node key and auth key, Backrest's `config.json`, ntfy tokens, the SMB password, SSH host keys, core's Hawser token).

## Accepted risks (Rock, Nov 11, 2026)

- **Tailscale setup unchanged.** Rock: "No, keep the Tailscale setup as it is". No `TS_AUTH_ONCE` and no tagged or one-off key requirement. containerboot therefore runs `tailscale up` on every container start, and passes `--authkey=<value>` on that command's argv whenever `TS_AUTHKEY` is set.
- **`TS_AUTHKEY` stays in Dockhand's Bitwarden project.** Rock: "Leave TS_AUTHKEY in Dockhand's Bitwarden project as it is". So the key is reused on every container start, is visible in `docker inspect` and in the container's command line, and, if the key is untagged, the node's key expires after 180 days unless key expiry is turned off for that machine in the Tailscale admin console (which would otherwise drop the subnet routes).

## Not here yet

- **Hawser on core.** Dockhand reaches core through Hawser. Its token is root-equivalent on core and gets a separate security review before anything here installs or firewalls it.
- **`--restore-prep`** and the `restore-<node>` projects come with the restore runbook.
