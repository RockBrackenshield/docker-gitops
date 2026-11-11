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

```text
infrastructure/
├── README.md
│
├── host/
│   ├── mounts/
│   ├── packages/
│   └── firewall/
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

The `host/` directory contains configuration required by the underlying operating system.

Potential responsibilities include:

```text
host/
├── mounts/
├── packages/
└── firewall/
```

Examples:

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
- Make the rules persistent on Raspberry Pi OS, for example with a small systemd unit ordered `After=docker.service` that re-inserts them at boot. Docker creates `DOCKER-USER` but leaves its contents alone.
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

# ntfy host setup (infrastructure)

The ntfy stack (`compose/infrastructure/ntfy`) is the homelab's notification server. Backrest sends failure alerts to it now, and Gatus and Beszel will later. It needs a few things on the `infrastructure` host, in Zoraxy's UI and in the Tailscale admin console that Compose can't do itself. Everything here is a manual step. Values in `<angle brackets>` are placeholders; the real values never go in this repository.

Order for the first rollout:

1. Sections 1–3 (variables, directory, firewall), then deploy the ntfy stack.
2. Sections 4–6 (tailnet policy, Zoraxy, users and tokens).
3. Section 7.1 (the Backrest secret file) on **both** nodes, **before** redeploying either Backrest stack.
4. Section 7.2 (the hook in each Backrest UI) and the tests in 7.3.
5. Sections 8–10 (clients, relay, backups).

## 1. Variables (pre-deploy checklist)

The stack's values live in a **dedicated Bitwarden Secrets Manager project for ntfy**. That project holds **no tokens**: the ntfy server never needs one. The stack is configured only with `NTFY_*` environment variables; there's no `server.yml`.

| Variable | Required | Notes |
|---|---|---|
| `NTFY_BASE_URL` | **yes** | The `https://` URL Zoraxy serves for ntfy, no trailing slash. **Empty fails closed**: ntfy refuses to start, because the attachment cache needs a base URL. Also goes in each Backrest stack's project (section 7). |
| `INFRA_LAN_IP` | **yes** | The infrastructure node's LAN address. Port 2586 binds to it. **Empty fails closed**: Compose rejects the empty `host_ip` ("invalid ip address") and the stack doesn't deploy. CI uses a TEST-NET placeholder from `.github/ci.env`. |
| `NTFY_UID`, `NTFY_GID` | **yes** | The dedicated `ntfy` system user from section 2. Empty values make `user: ":"`, which Docker rejects. |

`NTFY_UPSTREAM_BASE_URL` is committed as an empty value on purpose (section 9). After deploying, `docker inspect ntfy` should show port 2586 bound to `<infra-lan-ip>`, not `0.0.0.0` or `::`.

## 2. Dedicated user and data directory

```bash
# Dedicated system UID/GID for ntfy, not shared with any human group.
sudo groupadd --system ntfy && sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g ntfy ntfy
id ntfy                                   # put these numbers in Bitwarden as NTFY_UID / NTFY_GID
sudo install -d -m 0700 -o ntfy -g ntfy /srv/homelab/ntfy
sudo install -d -m 0700 -o ntfy -g ntfy /srv/homelab/ntfy/attachments
```

`/srv/homelab/ntfy/user.db` holds password hashes (bcrypt) **and access tokens in plaintext**, so the directory is `0700`. Backrest runs as root with `/srv/homelab` mounted read-only, so it can still back it up.

## 3. Host firewall (infrastructure node)

Only Zoraxy should reach `<infra-lan-ip>:2586`. Clients use `https://<ntfy-host>` through Zoraxy.

**Why `DOCKER-USER` alone isn't enough on this node.** Tailscale runs here with `network_mode: host` as the subnet router. In iptables mode it inserts `-j ts-forward` at **position 1** of `filter/FORWARD` whenever that jump is missing, and `ts-forward` **accepts** every packet that arrived on `tailscale0` (`util/linuxfw/iptables_runner.go` in Tailscale v1.104.4). Docker also puts its `-j DOCKER-USER` jump at the top of FORWARD when it starts. So the order depends on which inserted last, and it changes at runtime: a Tailscale container restart (for example after a Renovate bump) re-inserts its jump. When `ts-forward` comes first, tailnet traffic to port 2586 is accepted before `DOCKER-USER` sees it.

**Primary rule (order-independent): `raw PREROUTING`.** This chain runs before conntrack, Docker's DNAT and every FORWARD chain, whatever order the jumps are in. Neither Docker nor Tailscale manages user rules in it. It matches the original destination:

```bash
# Allow 2586 on the LAN address only from Zoraxy's source network; drop everything else,
# including traffic arriving on tailscale0 and from LAN hosts.
sudo iptables -t raw -I PREROUTING -p tcp -d <infra-lan-ip> --dport 2586 ! -s <zoraxy-source-cidr> -j DROP
```

**Second layer, as for Paperless: `DOCKER-USER`.**

```bash
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 2586 ! -s <zoraxy-source-cidr> -j DROP
```

**Finding `<zoraxy-source-cidr>`.** Zoraxy is on two Docker networks, `infra_edge` and `infra_internal`. Its source address toward `<infra-lan-ip>` comes from the network that holds its default route:

```bash
docker exec zoraxy ip route get <infra-lan-ip>            # note the "src" address
docker network inspect <that-network> --format '{{(index .IPAM.Config 0).Subnet}}'
```

Use that subnet. Every other container on that Docker network can also get through, so keep it to containers that need it.

- **Persistence:** a small systemd unit ordered `After=docker.service network-online.target` that inserts both rules only if they're missing (`iptables -C … || iptables -I …`). Neither Docker nor Tailscale flushes `raw PREROUTING`, so a Tailscale restart doesn't undo the primary rule. If the unit fails at boot, port 2586 is open to the LAN and tailnet until it's fixed, so check it after every reboot.
- **Checks:** `sudo iptables -t raw -S PREROUTING` shows the rule; `sudo iptables -S FORWARD | head -5` shows the current jump order (informational only). `http://<infra-lan-ip>:2586` must **time out** from a tailnet device and from a LAN host, including after `docker restart tailscale`.
- **IPv6:** `host_ip` is an IPv4 address, so nothing is published on IPv6.
- **nftables mode:** if Tailscale runs in nftables mode (`TS_DEBUG_FIREWALL_MODE`), the `raw PREROUTING` rule (priority −300) still runs before any forward hook.
- On the router: UPnP **off**, and **no port forwards** for 2586 or for Zoraxy.

## 4. Tailnet access

In the Tailscale admin console, make sure the tailnet policy **doesn't grant** tailnet sources access to `<infra-lan-ip>` on port 2586. Reach ntfy from the tailnet through Zoraxy on 443 instead. This is a backstop; the raw rule in section 3 is what enforces it.

## 5. Zoraxy

Set up in Zoraxy's UI (Zoraxy's config is host data, not Git):

- **Proxy rule:** `https://<ntfy-host>` → `http://<infra-lan-ip>:2586`. The certificate is publicly trusted. `<ntfy-host>` resolves only on the LAN and the tailnet.
- WebSockets **on**, no response buffering and no short timeouts (subscriptions are long-lived).
- `X-Forwarded-For` set. ntfy runs with `NTFY_BEHIND_PROXY=true` and uses it for rate limiting.
- **Access rule:** Zoraxy listens on 80/443 on all interfaces. On the `<ntfy-host>` rule, add an allow-list that admits **only** `<lan-cidr>` and the tailnet range, and denies everything else. Test from outside the network: `curl -H "Host: <ntfy-host>" https://<wan-address>/v1/health` must fail.

## 6. Users, access and tokens

Default access is `deny-all`, login is required and signup is off, so nothing works until these exist.

| User | Role | Access | Tokens (labels) | Used by |
|---|---|---|---|---|
| `<admin-user>` | admin | all topics | `fedora`, `android`, `ios`, each `--expires=365d` | Rock's web app and devices |
| `backrest` | user | `homelab-backrest` write-only | `backrest-infrastructure`, `backrest-core` | Backrest Command hooks (section 7) |
| `gatus` | user | `homelab-gatus` write-only | `gatus` | Gatus (later) |
| `beszel` | user | `homelab-beszel` write-only | `beszel` | Beszel (later) |

`docker exec` inherits the container's environment, so `NTFY_AUTH_FILE` is already set. Passwords are only ever typed at the prompt.

```bash
docker exec -it ntfy ntfy user add --role=admin <admin-user>        # password from Bitwarden

for u in backrest gatus beszel; do docker exec -it ntfy ntfy user add "$u"; done   # long random password, discarded
docker exec ntfy ntfy access backrest homelab-backrest write-only
docker exec ntfy ntfy access gatus    homelab-gatus    write-only
docker exec ntfy ntfy access beszel   homelab-beszel   write-only

# Each prints the full tk_... once: copy it straight into Bitwarden, then clear the terminal/scrollback.
docker exec ntfy ntfy token add --label=backrest-infrastructure backrest
docker exec ntfy ntfy token add --label=backrest-core           backrest
docker exec ntfy ntfy token add --label=gatus                   gatus
docker exec ntfy ntfy token add --label=beszel                  beszel
docker exec ntfy ntfy token add --expires=365d --label=fedora  <admin-user>
docker exec ntfy ntfy token add --expires=365d --label=android <admin-user>
docker exec ntfy ntfy token add --expires=365d --label=ios     <admin-user>

# Review. `token list` prints FULL token values, so always mask:
docker exec ntfy ntfy access
docker exec ntfy ntfy token list | sed -E 's/tk_[A-Za-z0-9_-]+/tk_<masked>/g'
```

**Where the values go (Bitwarden):**

| Value | Where |
|---|---|
| Admin password, device tokens | Password-manager items |
| Backrest tokens | Password-manager items `ntfy backrest-infrastructure` and `ntfy backrest-core`. Not in Secrets Manager: nothing injects them, they're written to a host file by hand (section 7.1). |
| Gatus and Beszel tokens | Each in its consumer's own Secrets Manager project (their own PRs) |

No secret, token, hash, real URL or address goes into Git, commit messages or PR text.

**What a token can do (ntfy v2.37.2).** Tokens are stored **in plaintext** in `user.db`. Any token can **mint more tokens for its own user that never expire** (`POST /v1/account/token`) and delete that user's other tokens. It can't delete the account or change its password; both need the current password.

- **Publisher tokens** can publish to their one topic, mint and delete their own user's tokens, and nothing else.
- **Admin device tokens** are full admin credentials over HTTP: they can publish to and read every topic, list any non-admin user's tokens in plaintext, mint tokens and reset passwords for those users, and add or delete users and access rules. This is an accepted risk (Rock's choice); keep the device tokens per device and at 365 days.

**Revoking.** A leaked token may already have minted more, so remove **every** token of that user:

- Publisher: `docker exec ntfy ntfy user del <user>`, then re-run that user's `user add`, `access` and `token add` lines, and update the consumer (for Backrest, the secret file in section 7.1).
- Lost device: delete and recreate the admin user, which removes **all** of its tokens (including any the lost token minted) without typing a token anywhere: `docker exec -it ntfy ntfy user del <admin-user>`, then `docker exec -it ntfy ntfy user add --role=admin <admin-user>` with a new password from Bitwarden. Re-issue a token for each remaining device (section 6), and **rotate every publisher token** too.
- **Yearly:** rotate the publisher tokens, and re-issue device tokens before they expire.
- **Watch for minted tokens:** compare the masked `token list` count per user with the table above. Any extra means a token was minted.

The declarative `NTFY_AUTH_USERS` / `NTFY_AUTH_TOKENS` settings aren't used, so no secret is ever in the container's configuration.

## 7. Backrest failure alerts (both nodes)

Each node's Backrest runs a **Command hook** that posts to the `homelab-backrest` topic when any operation fails. The Backrest compose files carry only non-secret values (`NTFY_URL`, `NTFY_BACKREST_TOPIC`, `NTFY_BACKREST_NODE`) and a file-sourced Compose secret, `ntfy_backrest_token`, mounted read-only at `/run/secrets/ntfy_backrest_token`. The hook itself lives in each node's Backrest UI (its `config.json`), not in Git, and contains no secret.

Add `NTFY_BASE_URL` (the same value as section 1) to **each Backrest stack's** Secrets Manager project. An empty value makes the hook fail with a message and send nothing.

### 7.1 The secret file (pre-deploy, on each node)

Create it **before** redeploying that node's Backrest stack. If the file is missing, Compose can't create the container, so **the whole Backrest stack won't start and backups stop** until it's fixed.

```bash
sudo install -d -m 0700 -o root -g root /srv/backrest/secrets
sudo sh -c 'umask 077; cat > /srv/backrest/secrets/ntfy-token'
# paste the node's token from the Bitwarden item "ntfy backrest-<node>", press Enter, then Ctrl-D
sudo stat -c '%U:%G %a %s' /srv/backrest/secrets/ntfy-token   # expect: root:root 600 33 (32-char token + newline)
```

- The token never goes on a command line or into shell history. The trailing newline doesn't matter.
- `/srv/backrest/secrets` sits next to `/srv/backrest/{cache,tmp}`, outside `/srv/homelab`, so it's never in a restic snapshot. Bitwarden is its backup.
- The directory is `0700 root:root` and the file `0600 root:root`. Backrest runs as root in its container, so it can read it. Outside Swarm, Compose ignores `uid`/`gid`/`mode` on file secrets, so the host permissions are what count.
- `docker inspect backrest` shows only the source path, never the value. No environment variable holds the token.
- An **empty** file lets the stack start, but the hook fails with a message and sends no alert.

### 7.2 The hook (Backrest UI, identical on both nodes)

In Backrest: **Repo → Hooks → Add → Command**, on each node's **repo** (repo hooks run for every plan on it; don't add a second copy to a plan, or it fires twice).

- **Conditions:** `CONDITION_ANY_ERROR` only. It covers snapshot, prune, check and forget errors and setup failures. `CONDITION_SNAPSHOT_WARNING` stays off, so partial backups don't alert.
- **On error:** `ON_ERROR_IGNORE`.
- **Command:**

```bash
#!/bin/bash
# ntfy failure alert (Backrest Command hook, Malis A3 pattern).
# Token: Compose secret file /run/secrets/ntfy_backrest_token, read at runtime only.
# Never paste a token here; never use set -x, curl -v/--trace, or echo the token.
TOKEN_FILE=/run/secrets/ntfy_backrest_token
if [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_BACKREST_TOPIC:-}" ] || [ ! -s "$TOKEN_FILE" ]; then
  echo "ntfy hook: NTFY_URL/NTFY_BACKREST_TOPIC empty or $TOKEN_FILE missing/empty; no alert sent" >&2
  exit 1
fi
MSG={{ .ShellEscape .Summary }}
MSG="${MSG:0:3800}"
TITLE="Backrest ${NTFY_BACKREST_NODE:-unknown}: "{{ .ShellEscape (.EventName .Event) }}
printf 'Authorization: Bearer %s\n' "$(cat "$TOKEN_FILE")" \
  | curl -fsS -o /dev/null --max-time 20 --retry 2 -H @- \
      -H "Title: ${TITLE}" -H "Priority: high" -H "Tags: warning,backrest" \
      --data-binary "$MSG" "${NTFY_URL}/${NTFY_BACKREST_TOPIC}"
```

Rules for this script: never paste a token into it, never add `set -x`, `curl -v` or `--trace`, and never echo the token.

- Backrest renders the text as a Go template and logs the rendered script and its output. The token isn't a template input: the log shows the literal `"$(cat "$TOKEN_FILE")"`, never the value.
- The token reaches curl on **stdin** (`-H @-`), so it's not in any process's arguments. The URL, title and body that are on curl's arguments are non-secret.
- On success the script prints nothing.
- Message text is inserted with `ShellEscape`, so quotes, `$(…)` and backticks in an error message stay literal.
- On each Backrest version bump, re-check that the Command hook still logs only the rendered script and output, and rerun step 4 below.

### 7.3 Test (each node)

1. **Token access**, on the node itself, reading the token from the root-only secret file (section 7.1). The token is piped to curl on stdin, the same way the hook does it, so it never appears on a command line, in `ps` or in shell history. Never echo it, and don't add `-v` or `--trace`.

   ```bash
   TOKEN_FILE=/srv/backrest/secrets/ntfy-token
   # Publish with the Backrest token: expect 200
   printf 'Authorization: Bearer %s\n' "$(sudo cat "$TOKEN_FILE")" \
     | curl -sS -o /dev/null -w '%{http_code}\n' -H @- \
         -d "test from <node>" "https://<ntfy-host>/homelab-backrest"
   # Read with the Backrest token (write-only user): expect 403
   printf 'Authorization: Bearer %s\n' "$(sudo cat "$TOKEN_FILE")" \
     | curl -sS -o /dev/null -w '%{http_code}\n' -H @- \
         "https://<ntfy-host>/homelab-backrest/json?poll=1"
   # Anonymous publish: expect 403
   curl -sS -o /dev/null -w '%{http_code}\n' -d "anon test" "https://<ntfy-host>/homelab-backrest"
   ```

   `printf` is a bash builtin, so the token is only ever in the shell's memory and curl's stdin.
2. **Secret mounted** (prints metadata only):
   - `docker exec backrest sh -c 'test -s /run/secrets/ntfy_backrest_token && echo present || echo MISSING'`
   - `docker exec backrest printenv | grep -c NTFY_BACKREST_TOKEN` prints `0`.
3. **Forced failure:** add a temporary plan `ntfy-test` on the repo with the single path `/srv/homelab/does-not-exist-ntfy-test` and click **Backup now**. A high-priority "Backrest <node>: …" alert should arrive. Delete the plan afterwards.
4. **Nothing in the log:** the hook operation's `[script]` shows `"$(cat "$TOKEN_FILE")"` and its `[output]` is empty. On the host, `sudo grep -rl 'tk_' /srv/homelab/backrest/data /srv/homelab/backrest/config` prints **no files** (it prints file names only, never a token).
5. **Guard path (optional):** move the secret file aside and run `docker compose up -d --force-recreate backrest`; the stack should refuse to start. Put the file back and redeploy. To test the empty-file guard instead, truncate the file with `: >`, recreate the container, repeat step 3, then restore the file.

## 8. Clients

All clients use the admin account, with one 365-day token per device (section 6).

- **Fedora:** the web app at `https://<ntfy-host>/` (Web Push is off, so an installed PWA gets no background push). For desktop popups, `ntfy subscribe` with `~/.config/ntfy/client.yml` holding `default-host`, `default-token: <fedora-token>` and `command: notify-send "$t" "$m"`, run with `systemctl --user enable --now ntfy-client`. `chmod 600 ~/.config/ntfy/client.yml`, since it holds an admin token.
- **Android:** the ntfy app with **instant delivery** on (self-hosted servers don't use Firebase) and the android token. Keep Tailscale connected.
- **iOS:** the ntfy app with the ios token. Delivery is delayed while the relay is off (section 9), and Tailscale must be connected.
- **Web Push**, if it's ever turned on: the browser vendor sees the endpoint, the VAPID email address, the server's IP and the timing. Use an email alias.

## 9. iOS relay (off)

`NTFY_UPSTREAM_BASE_URL=` is committed empty, so nothing goes to ntfy.sh, Firebase or APNs. Turning it on is a reviewed change. If it's ever on, every message posts `sha256(<base-url>/<topic>)` and a poll ID to ntfy.sh, which reveals the timing and the server's public IP. Because the certificate is publicly trusted, `<ntfy-host>` is in Certificate Transparency logs and the topic names are guessable, so the hash could be reversed and would show *when* backups fail. If the relay is enabled, give the topics random suffixes at the same time.

## 10. Backups and restore

- In the infrastructure node's Backrest plan UI, **exclude `/srv/homelab/ntfy/cache.db*`** (the 24h message cache). `user.db` is the part that matters.
- **Restoring an old `user.db` brings back revoked tokens.** After any restore, redo every revocation made since that snapshot, and check the masked `token list`.
- After restarting ntfy, users, tokens and the last 24 hours of messages should still be there.

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
Install Fedora
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

The repository does not need to implement all of this immediately. The directory structure simply provides a place for those pieces to evolve.

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
