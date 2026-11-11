# Infrastructure

This directory contains the configuration, documentation, and automation for the infrastructure **underneath Docker Compose**.

The guiding principle is:

> **Docker Compose defines the Docker environment. Infrastructure defines the host and external environment that Docker depends upon.**

This separation is intentional. The goal is to keep the Docker nodes simple and avoid the abstraction and indirection of a Kubernetes-style setup.

The environment is two Raspberry Pi 4B nodes running Docker:

* `infrastructure`: DNS, reverse proxy, remote access, deployment and backups (`compose/infrastructure/`)
* `core`: applications (`compose/core/`)

---

## Purpose

The `infrastructure/` directory answers questions such as:

* What storage does each Docker node provide?
* Where is persistent application data stored?
* How is the host network arranged?
* What DNS, VLAN, routing, and firewall infrastructure does the environment depend upon?
* How are backups performed?
* How can an underlying node be rebuilt?
* What external infrastructure must exist before the Compose environment can operate?

It **does not** define how individual containers are run.

That responsibility belongs to `/compose`.

---

## Directory Structure

The intended structure is below. Today only `README.md` exists; the rest is added when there is something real to document.

Host setup that runs on the nodes (cloud-init, `bootstrap.sh`, the host firewall) lives in the top-level [`host/`](../host/README.md) directory, not under `infrastructure/`, so the nodes run it straight from their clone at `/srv/homelab/docker-gitops/host/`.

```text
infrastructure/
├── README.md
│
├── networking/
│   ├── dns/
│   ├── addressing.md
│   └── firewall.md
│
├── storage/
│   ├── disks.md
│   ├── mounts.md
│   └── layout.md
│
└── backup/
    ├── backrest.md
    ├── policies.md
    └── restore.md
```

Not every directory needs to contain files immediately. The structure should grow only when there is a real infrastructure concern to document or automate.

---

# Relationship to the Rest of the Repository

The repository has several distinct responsibilities:

```text
docker-gitops/
│
├── compose/
│   └── How Docker runs applications (compose/<node>/<stack>/compose.yaml)
│
├── infrastructure/
│   └── The environment underneath Docker
│
├── .github/workflows/
│   └── CI: compose-validate
│
├── renovate.json
│   └── Image and GitHub Actions updates
│
└── AGENTS.md
    └── Rules for agents working in the repository
```

Secrets are not stored in the repository. Dockhand injects them at deploy time from Bitwarden Secrets Manager, and compose files reference them as `${VAR}`.

The dependency relationship is approximately:

```text
                    Git Repository
                         │
             ┌───────────┴───────────┐
             │                       │
      Infrastructure              Compose
             │                       │
             ▼                       ▼
        Docker Nodes            Containers
             │                  ┌────┴────┐
             │                  │         │
             ▼               Networks   Volumes
      Host Filesystems
             │
             ▼
       /srv/homelab
```

Infrastructure establishes the environment that Compose consumes.

Compose does not need to import infrastructure configuration to function; instead, both are descriptions of different layers of the same system.

---

# What Belongs Here?

## Infrastructure belongs here when it exists independently of Docker

A useful test is:

> **Could this infrastructure exist even if Docker were completely removed from the machine?**

If the answer is yes, it probably belongs under `infrastructure/`.

Examples include:

* Physical disks
* Filesystems
* Mount points
* Host firewall configuration
* Host packages
* VLAN configuration
* IP addressing
* Routing
* DNS infrastructure
* External reverse-proxy dependencies
* Backup repositories
* Backrest repositories and plans
* Host-level system services
* OS configuration
* Hardware-specific considerations

---

# What Does Not Belong Here?

Docker-specific resources should generally remain in `/compose`.

Examples:

* Docker networks
* Docker volumes
* Container definitions
* Container ports
* Container environment variables
* Container health checks
* Container resource limits
* Container restart policies
* Container-to-container dependencies
* Bind mounts from the host into containers

For example, this belongs in Compose:

```yaml
services:
  adguard:
    volumes:
      - /srv/homelab/adguard/work:/opt/adguardhome/work
      - /srv/homelab/adguard/conf:/opt/adguardhome/conf
```

The Compose file is responsible for telling Docker:

> Mount these host directories into this container.

Infrastructure storage documentation is responsible for explaining what those host directories are and where they come from.

---

# Storage

Storage is a good example of the separation between infrastructure and Compose.

Infrastructure might document:

```text
Physical disk
    ↓
Partition
    ↓
Filesystem
    ↓
/srv/homelab
    ↓
Application directories
```

For example:

```text
/srv/homelab/
├── adguard/
├── backrest/
├── romm/
└── ...
```

The infrastructure layer establishes `/srv/homelab`.

Compose consumes it:

```yaml
services:
  <app>:
    volumes:
      - /srv/homelab/<app>/data:/data
```

The actual application data is **not** stored in Git.

Git stores the definition of how that data is mounted; the host filesystem stores the data itself.

Compared with a Kubernetes storage chain:

```text
Kubernetes:

PVC
 ↓
StorageClass
 ↓
Longhorn
 ↓
Volume
 ↓
Node disk
```

this is deliberately simpler:

```text
Docker:

Container
 ↓
Bind mount / Docker volume
 ↓
Host filesystem
 ↓
Physical storage
```

---

# Networking

The same distinction applies to networking.

## Compose owns Docker networking

For example:

```yaml
networks:
  proxy:
    driver: bridge
```

This belongs in Compose because it creates and manages a Docker network.

Likewise:

```yaml
services:
  adguard:
    networks:
      - proxy
```

belongs in Compose.

## Infrastructure owns the external network

Infrastructure networking documentation might describe:

```text
LAN
  <LAN_CIDR>

Docker nodes
  <NODE_IP>

Router
  <ROUTER_IP>

DNS
  AdGuard
  Tailscale
```

It may also document:

* VLANs
* Subnets
* DHCP
* Static reservations
* Routing
* Firewall rules
* DNS architecture
* External load balancers
* External reverse proxies
* Network dependencies

The important distinction is:

> **Compose manages Docker's network. Infrastructure manages the network Docker is connected to.**

---

# External Docker Resources

There may occasionally be Docker resources that are intentionally managed outside an individual Compose application.

For example, a shared network could be created independently:

```bash
docker network create proxy
```

and consumed by Compose:

```yaml
networks:
  proxy:
    external: true
```

This is valid, but it should be used deliberately.

Before creating an external Docker resource, ask:

> **Who is responsible for creating and maintaining this resource?**

If Compose owns it, define it in Compose.

If host-level automation owns it, document or automate it under `infrastructure/`.

Avoid creating an additional abstraction layer solely to allow infrastructure YAML files to be "imported" into Compose.

---

# Host

The top-level [`host/`](../host/README.md) directory contains configuration required by the underlying operating system: the cloud-init `user-data` per node, `bootstrap.sh`, and the host firewall (`host/firewall/`). See [Rebuilding a node](#rebuilding-a-node).

Other host concerns that may be documented there later:

### `host/mounts/`

* `/etc/fstab`
* Mount definitions
* Filesystem mount options
* External disk requirements

### `host/packages/`

* Required host packages
* Docker Engine and the Compose plugin
* Bitwarden Secrets Manager CLI (used by Dockhand)
* Supporting utilities

### `host/firewall/`

* firewalld configuration
* Required inbound ports
* Required outbound connectivity
* Host-level security policy

If host configuration is ever automated, this is also a natural location for that automation.

---

# Backup

Backups are an infrastructure concern because they protect the persistent state beneath the applications.

For example:

```text
infrastructure/backup/
├── backrest.md
├── policies.md
└── restore.md
```

This should describe:

* What is backed up
* What is intentionally excluded
* Where backups are stored
* Retention policies
* Encryption
* Repository configuration
* Restore procedures
* Disaster recovery procedures

Backrest runs as a Compose stack on each node (`compose/infrastructure/backrest`, `compose/core/backrest`) and reads the host data it protects read-only.

The important architectural distinction is:

```text
Git
 ↓
Desired configuration

Backrest
 ↓
Persistent runtime data
```

Neither replaces the other.

A Git repository can reconstruct the application configuration, while Backrest can reconstruct the application's persistent state.

---

# Paperless-ngx host setup (core)

The Paperless stack (`compose/core/paperless`) needs a few things on the `core` host that Compose can't do itself. Everything here is a manual step on the host, the router or the Tailscale admin console. Values in `<angle brackets>` are placeholders; the real values never go in this repository.

## 1. Variables (pre-deploy checklist)

The stack's values live in a **dedicated Bitwarden Secrets Manager project for Paperless**, and the Dockhand machine-account token for this stack has access to that project only. Dockhand injects the whole project into the deploy environment, so nothing unrelated should sit in it.

The compose file uses plain `${VAR}`: an unset variable becomes an empty string rather than stopping the deploy. `CORE_LAN_IP` is the exception, because Compose rejects an empty port `host_ip`. CI validates with placeholder values from `.github/ci.env`, which are never deployed. Before every first deploy (and after editing the project), check:

| Variable | Required | Notes |
|---|---|---|
| `PAPERLESS_SECRET_KEY` | yes | Generate with `python3 -c "import secrets; print(secrets.token_urlsafe(64))"`. Paperless won't start without it. |
| `PAPERLESS_DB_PASSWORD` | yes | Used by the webserver, db and db-backup. Only applied when the database is first created; to change it later, run `ALTER USER paperless WITH PASSWORD '...'` in the db first. |
| `PAPERLESS_URL` | **yes** | The `https://` URL Zoraxy serves, without a trailing slash. **Empty fails open**: allowed hosts become `*` and no CSRF origin is set. |
| `CORE_LAN_IP` | **yes** | Core's LAN address. Ports 8000 and 445 bind to it. **Empty fails closed**: Compose rejects the empty `host_ip` ("invalid ip address") and the stack doesn't deploy. |
| `SMB_HOSTS_ALLOW` | **yes, in practice** | The printer's address(es). Optional for Compose, but **empty fails open**: Samba then allows every host. |
| `SMB_PASSWORD` | yes | Password for the Samba user `scanner`. |
| `PAPERLESS_UID`, `PAPERLESS_GID` | yes | Owner of `/srv/homelab/paperless`. Samba and NFS write as this UID. |
| `PAPERLESS_ADMIN_USER`, `PAPERLESS_ADMIN_PASSWORD` | first start only | Create the first superuser, then clear both (see section 9). |
| `PAPERLESS_TRUSTED_PROXIES` | after section 4 | The Zoraxy node's address. Leave empty until the firewall allowlist is in place. |

After deploying, `docker inspect paperless paperless-samba` should show ports 8000 and 445 bound to `<core-lan-ip>`, not `0.0.0.0` or `::`.

## 2. Old volumes

Paperless starts fresh; there's no old data to migrate. Before the first deploy, run `docker volume ls --filter name=paperless` once. Leave anything it lists alone and don't prune it without reviewing it first.

## 3. Directories and permissions

```bash
sudo mkdir -p /srv/homelab/paperless/{data,media,export,dump,consume/smb,consume/nfs} /srv/paperless/{db,broker}
sudo chown -R <PAPERLESS_UID>:<PAPERLESS_GID> /srv/homelab/paperless
sudo chmod 0750 /srv/homelab/paperless/{data,media,export,dump}
sudo chmod 2770 /srv/homelab/paperless/consume /srv/homelab/paperless/consume/smb /srv/homelab/paperless/consume/nfs
```

- `consume/smb` is the printer's drop folder (Samba) and `consume/nfs` is the laptop's (NFS). Paperless watches `consume` recursively and tags each document with its subfolder name (`smb` or `nfs`). It doesn't delete the subfolders.
- The setgid bit (`2770`) gives new files the Paperless group, whoever writes them.
- `/srv/paperless/db` is chowned by the Postgres container on first start.
- Check that nothing else on core listens on 445: `sudo ss -ltnp 'sport = :445'`.

## 4. Host firewall allowlist

Docker-published ports are DNATed before the host's INPUT rules, so ufw or firewalld zones don't restrict them. Filter them in the `DOCKER-USER` chain, matching the original destination port, for IPv4 and IPv6:

```bash
# 8000 (Paperless) only from the Zoraxy node; 445 (Samba) only from the printer
sudo iptables  -I DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 8000 ! -s <zoraxy-node-ip> -j DROP
sudo iptables  -I DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 445  ! -s <printer-ip>     -j DROP
# IPv6: the same rules with the IPv6 addresses, or drop these ports entirely if IPv6 isn't used for them
sudo ip6tables -I DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 8000 ! -s <zoraxy-node-ipv6> -j DROP
sudo ip6tables -I DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 445  ! -s <printer-ipv6>     -j DROP
```

NFS (2049) is served by the host, not Docker, so it goes in the host's own input rules:

```bash
sudo iptables  -A INPUT -p tcp --dport 2049 ! -s <laptop-ip> -j DROP
sudo ip6tables -A INPUT -p tcp --dport 2049 -j DROP   # unless the laptop uses IPv6 for NFS
```

- `--ctdir ORIGINAL` keeps the replies to allowed clients from being dropped.
- `host/firewall/` applies these rules and keeps them across reboots (see [`host/README.md`](../host/README.md#firewall)): an early unit loads raw `PREROUTING` rules for 8000 and 445 and the `INPUT` rule for 2049 **before** Docker starts and fails closed (`RequiredBy=docker.service`), and a second unit adds the `DOCKER-USER` layer above after Docker starts. Both cover IPv6. The commands above show what the rules do; don't also add them by hand.
- On the router: UPnP **off**, and **no port forwards** for 445, 8000 or 2049.

## 5. Tailnet access

The Tailscale subnet router (on the infrastructure node) translates tailnet traffic so that it arrives on core *from the infrastructure node's address*, which is also Zoraxy's. The firewall in section 4 can't tell the two apart.

In the Tailscale admin console, make sure the tailnet policy **doesn't grant** tailnet sources access to `<core-lan-ip>` on ports 445, 8000 or 2049. Tailscale policies are allow-lists, so if the policy has a broad rule (such as all sources to all destinations), replace it with explicit grants that leave these ports out. Reach Paperless from the tailnet through Zoraxy instead. Changing the subnet router itself is a separate change.

## 6. NFS export for the laptop (NFSv4 only)

On core (Raspberry Pi OS):

```bash
sudo apt install nfs-kernel-server
```

In `/etc/nfs.conf`, turn off NFSv3, which needs rpcbind and extra ports:

```ini
[nfsd]
vers3=n
```

```bash
sudo systemctl mask --now rpcbind.service rpcbind.socket rpc-statd.service
```

Add this to `/etc/exports`:

```text
/srv/homelab/paperless/consume/nfs <laptop-ip>(rw,sync,sec=sys,secure,no_subtree_check,root_squash,all_squash,anonuid=<PAPERLESS_UID>,anongid=<PAPERLESS_GID>)
```

```bash
sudo exportfs -ra && sudo exportfs -v
sudo systemctl restart nfs-server
```

Never export to the infrastructure node's address: tailnet traffic arrives from it.

On the laptop (Fedora):

```bash
sudo dnf install nfs-utils
sudo mkdir -p /mnt/paperless-consume
```

Add this to `/etc/fstab`:

```text
<core-host>:/srv/homelab/paperless/consume/nfs  /mnt/paperless-consume  nfs4  rw,noauto,x-systemd.automount,x-systemd.idle-timeout=600,_netdev  0 0
```

Things to know:

- `sec=sys` trusts the client's address: anyone holding `<laptop-ip>` can write to the drop folder. `all_squash` maps every write to the Paperless UID/GID, so client user IDs don't matter.
- With `no_subtree_check` on a subdirectory export, a client that guesses file handles could reach other files on the same filesystem. Putting `consume` on its own filesystem (a separate partition or subvolume) removes that.
- For tighter isolation, the NFS and Samba writers could squash to a separate ingest UID that has write access only to `consume/*`, with `data`, `media`, `export` and `dump` set to `0700`. That's more moving parts; it isn't the default.

## 7. Printer (scan to folder)

- Share: `\\<core-host>\consume`. User: `scanner`, with the password from `SMB_PASSWORD`.
- The printer must support **SMB 2.1 or newer with signing**. Samba refuses SMB1, guest access and unsigned connections.
- If the printer can't connect for that reason, stop and decide what to do; don't weaken the Samba settings.
- Samba applies its settings once, when the container is created. After changing `SMB_PASSWORD` or `SMB_HOSTS_ALLOW`, recreate the container (`docker compose up -d --force-recreate samba`).
- The compose file drops all Linux capabilities for Samba and adds back a minimal set. If smbd fails to start, check its log and add back only the capability the error names.

## 8. Backups and restore

- Core's Backrest already backs up `/srv/homelab` read-only, which covers `paperless/{data,media,export,dump}`. Exclude `paperless/consume` in the Backrest plan (it's transient), and schedule the snapshot after the daily dump.
- `/srv/paperless/db` (live database files) and `/srv/paperless/broker` (task queue) are deliberately not backed up. `paperless-db-backup` writes a daily custom-format dump to `paperless/dump` and keeps the newest three.

Restore:

```bash
docker compose stop webserver db-backup
# restore /srv/homelab/paperless from Backrest, then:
docker compose up -d db
docker compose exec -T db pg_restore --clean --if-exists --no-owner -U paperless -d paperless < /srv/homelab/paperless/dump/paperless-<timestamp>.dump
docker compose up -d
```

## 9. After the first start

- Clear `PAPERLESS_ADMIN_USER` and `PAPERLESS_ADMIN_PASSWORD` in the Bitwarden project and redeploy. They only create the first superuser.
- Turn on TOTP two-factor authentication for the superuser.
- Use a separate non-superuser account day to day.

## 10. Zoraxy

Zoraxy terminates TLS and proxies `https://<paperless-host>` to `http://<core-lan-ip>:8000`. It must set or overwrite `X-Forwarded-Proto`: Paperless trusts that header (`PAPERLESS_PROXY_SSL_HEADER`), which is only safe because section 4 lets nothing but Zoraxy reach port 8000. Traffic between Zoraxy and core is plain HTTP on the LAN.

---

# Rebuilding a node

The files are in [`host/`](../host/README.md); its README has the details for each step. Values in `<angle brackets>` are placeholders.

1. **Before.** Confirm the node's latest Backrest snapshot. In Bitwarden, create a new access token with a **1-day expiry** on the node's machine account (`bootstrap-infrastructure` or `bootstrap-core`). For infrastructure, make sure `TS_AUTHKEY_INFRASTRUCTURE` in `bootstrap-infrastructure` holds the Tailscale auth key you use today, and remove the old machine from the Tailscale admin console.
2. **Flash.** Raspberry Pi Imager **2.x**, Raspberry Pi OS Lite (64-bit), Trixie. Replace `user-data` on the boot partition with your filled-in copy of `host/<node>/user-data` (username and normal SSH public key only). No password and no Wi-Fi PSK in `user-data` or `network-config`. Never commit the filled-in copy.
3. **First boot.** `cloud-init status --wait`, then set the sudo password and remove `NOPASSWD` ([`host/README.md`](../host/README.md#sudo-after-first-boot)). Optional: `sudo touch /etc/cloud/cloud-init.disabled`.
4. **Install bws** 2.1.0 and check its hash ([`host/README.md`](../host/README.md#install-bws-210-both-nodes-before-bootstrap)).
5. **Restore** from Backrest if needed (restore runbook, separate).
6. **Check the clone with the OS's git**, then run `sudo /srv/homelab/docker-gitops/host/bootstrap.sh` on the node, or `ssh -t <admin-user>@<node> 'sudo /srv/homelab/docker-gitops/host/bootstrap.sh'`.
7. **Revoke the bootstrap access token** right after the run.
8. **Dockhand takes over** (infrastructure). Tunnel to the UI (`ssh -L 3000:127.0.0.1:3000 <admin-user>@infrastructure`), turn on authentication, run `bootstrap.sh --unlock-dockhand`, bind each stack to its Bitwarden project, and deploy in order: AdGuard, Zoraxy, Tailscale (`docker compose -p tailscale down` first, then deploy it from Dockhand), ntfy, Backrest. Core's stacks follow through Hawser once its separate review is done.
9. **Manual steps that stay manual:** the printer (section 7 above), the tailnet policy (section 5), Zoraxy rules and access lists, ntfy users and device tokens, Backrest's ntfy token file, hooks and plans, Paperless first-start cleanup (section 9).
10. **Verify** with the checklist in [`host/README.md`](../host/README.md#verify).

Accepted risk (Rock, Nov 11, 2026: "No, keep the Tailscale setup as it is" and "Leave TS_AUTHKEY in Dockhand's Bitwarden project as it is"): once Dockhand deploys the tailscale stack, its auth key is reused on every container start, is visible in `docker inspect` and the container's command line, and, if untagged, the node's key expires after 180 days unless key expiry is turned off for that machine in the Tailscale admin console.

---

# Infrastructure vs. Configuration

Some files can initially appear ambiguous.

For example, consider DNS.

An AdGuard configuration containing DNS rewrites is application configuration, kept with AdGuard's data on the host:

```text
/srv/homelab/adguard/
```

The overall network's DNS architecture is infrastructure:

```text
infrastructure/networking/dns/
```

Similarly:

| Information               | Location                     |
| ------------------------- | ---------------------------- |
| AdGuard DNS rewrite       | AdGuard's config on the host |
| AdGuard container         | `compose/infrastructure/adguard/` |
| Host IP address           | `infrastructure/networking/` |
| Router DHCP configuration | `infrastructure/networking/` |
| Docker network            | `compose/`                   |
| Host filesystem           | `infrastructure/storage/`    |
| Container bind mount      | `compose/`                   |
| Backrest backup plan      | `infrastructure/backup/`     |
| Application password      | Dockhand (Bitwarden Secrets Manager) |

When something is ambiguous, favor the question:

> **Which system is responsible for this setting?**

That system's configuration should generally be the authoritative representation.

---

# Avoiding Kubernetes-Like Complexity

This repository intentionally avoids reproducing Kubernetes concepts simply because they exist in Kubernetes. The Talos lab in k3s-gitops is the place for those.

We should resist introducing layers such as:

```text
infrastructure/
    definitions/
        networks/
        volumes/
        services/
```

followed by tooling that generates Compose files from those definitions.

That would provide little benefit for two small Docker nodes while introducing another abstraction that must be understood and maintained.

Instead:

```text
Infrastructure
    ↓
Host environment

Compose
    ↓
Docker environment

Host data (bind mounts)
    ↓
Application configuration and state

Dockhand (Bitwarden Secrets Manager)
    ↓
Sensitive configuration
```

Each layer should have a clear owner.

---

# Guiding Principles

## 1. Compose is authoritative for Docker

If a resource is fundamentally a Docker resource, define it in Compose.

## 2. Infrastructure is authoritative for the host

If a resource exists independently of Docker, define or document it under `infrastructure/`.

## 3. Don't duplicate configuration

A setting should have one authoritative location.

Documentation may describe it elsewhere, but it should not be necessary to maintain the same value in multiple configuration files.

## 4. Persistent data does not belong in Git

Git contains configuration and desired state.

Backrest protects persistent runtime data.

## 5. Secrets belong in Bitwarden Secrets Manager

Sensitive values live in Bitwarden Secrets Manager and are injected by Dockhand at deploy time. Compose files reference them only as `${VAR}`.

Secrets are never committed, encrypted or not.

## 6. Prefer explicitness over abstraction

A simple Compose file referencing:

```text
/srv/homelab/<app>
```

is preferable to a custom abstraction that dynamically generates that path.

## 7. Infrastructure should be reproducible where practical

Documentation should eventually evolve into automation for important host configuration.

A future rebuild should ideally look roughly like:

```text
Install Raspberry Pi OS
    ↓
Apply host infrastructure
    ↓
Mount storage
    ↓
Install Docker
    ↓
Deploy Dockhand (connected to Bitwarden Secrets Manager)
    ↓
Deploy the node's stacks from this repository
    ↓
Restore persistent data with Backrest if necessary
```

The repository does not need to implement all of this immediately. The directory structure simply provides a place for those pieces to evolve. The first pieces exist now: see [Rebuilding a node](#rebuilding-a-node).

---

# The Practical Rule

When deciding where something belongs, use this decision tree:

```text
Is it a container/application?
        │
        ├── Yes → compose/
        │
        └── No
             │
             ▼
Is it application configuration?
        │
        ├── Yes → the stack's data on the host (bind mount, backed up by Backrest)
        │
        └── No
             │
             ▼
Is it sensitive configuration?
        │
        ├── Yes → Bitwarden Secrets Manager, injected by Dockhand
        │
        └── No
             │
             ▼
Does it configure/support the host or external environment?
        │
        ├── Yes → infrastructure/
        │
        └── No → README.md or AGENTS.md
```

The overarching goal is **not** to make every aspect of the homelab fit into a rigid directory hierarchy.

The goal is to make it immediately apparent:

1. **What runs?** → `compose/`
2. **How is it configured?** → the stack's `compose.yaml` plus its data on the host
3. **What secrets does it require?** → the `${VAR}`s in its `compose.yaml` (values in Bitwarden Secrets Manager)
4. **What does the host/external environment provide?** → `infrastructure/`
5. **How does it work?** → `README.md` and `AGENTS.md`

Planned, not yet present: a `config/` directory if non-secret application configuration ever needs version control.

If a future change doesn't clearly fit one of those categories, that is a reason to reconsider the architecture before adding another abstraction.
