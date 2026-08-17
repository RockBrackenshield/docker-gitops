# Infrastructure

This directory contains the configuration, documentation, and automation for the infrastructure **underneath Docker Compose**.

The guiding principle is:

> **Docker Compose defines the Docker environment. Infrastructure defines the host and external environment that Docker depends upon.**

This separation is intentional. The goal is to avoid recreating the abstraction and indirection of the Kubernetes environment this repository is replacing.

---

## Purpose

The `infrastructure/` directory answers questions such as:

* What storage does the Docker host provide?
* Where is persistent application data stored?
* How is the host network arranged?
* What DNS, VLAN, routing, and firewall infrastructure does the environment depend upon?
* How are backups performed?
* How can the underlying host be rebuilt?
* What external infrastructure must exist before the Compose environment can operate?

It **does not** define how individual containers are run.

That responsibility belongs to `/compose`.

---

## Directory Structure

The intended structure is:

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
    ├── kopia.md
    ├── policies.md
    └── restore.md
```

Not every directory needs to contain files immediately. The structure should grow only when there is a real infrastructure concern to document or automate.

---

# Relationship to the Rest of the Repository

The repository has several distinct responsibilities:

```text
homelab/
│
├── compose/
│   └── How Docker runs applications
│
├── config/
│   └── Non-secret application configuration
│
├── secrets/
│   └── SOPS/age-encrypted secrets
│
├── infrastructure/
│   └── The environment underneath Docker
│
├── scripts/
│   └── Operational actions
│
└── docs/
    └── General documentation and architectural information
```

The dependency relationship is approximately:

```text
                    Git Repository
                         │
             ┌───────────┴───────────┐
             │                       │
      Infrastructure              Compose
             │                       │
             ▼                       ▼
        Docker Host             Containers
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
* Kopia configuration
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
├── authentik/
├── paperless/
├── postgres/
└── ...
```

The infrastructure layer establishes `/srv/homelab`.

Compose consumes it:

```yaml
services:
  paperless:
    volumes:
      - /srv/homelab/paperless/data:/usr/src/paperless/data
```

The actual application data is **not** stored in Git.

Git stores the definition of how that data is mounted; the host filesystem stores the data itself.

This is an intentional replacement for the Kubernetes storage chain:

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

with a simpler model:

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
  192.168.1.0/24

Docker host
  192.168.1.x

Router
  192.168.1.1

DNS
  AdGuard
  NextDNS
  Tailscale MagicDNS
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
* Docker installation requirements
* SOPS
* age
* Kopia
* Supporting utilities

### `host/firewall/`

* firewalld configuration
* Required inbound ports
* Required outbound connectivity
* Host-level security policy

If host configuration eventually becomes automated with Ansible, this is also a natural location for that automation.

---

# Backup

Backups are an infrastructure concern because they protect the persistent state beneath the applications.

For example:

```text
infrastructure/backup/
├── kopia.md
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

Kopia itself may be installed and configured at the host level.

The important architectural distinction is:

```text
Git
 ↓
Desired configuration

Kopia
 ↓
Persistent runtime data
```

Neither replaces the other.

A Git repository can reconstruct the application configuration, while Kopia can reconstruct the application's persistent state.

---

# Infrastructure vs. Configuration

Some files can initially appear ambiguous.

For example, consider DNS.

An AdGuard configuration containing DNS rewrites is application configuration:

```text
config/adguard/
```

The overall network's DNS architecture is infrastructure:

```text
infrastructure/networking/dns/
```

Similarly:

| Information               | Location                     |
| ------------------------- | ---------------------------- |
| AdGuard DNS rewrite       | `config/adguard/`            |
| AdGuard container         | `compose/services/adguard/`  |
| Host IP address           | `infrastructure/networking/` |
| Router DHCP configuration | `infrastructure/networking/` |
| Docker network            | `compose/`                   |
| Host filesystem           | `infrastructure/storage/`    |
| Container bind mount      | `compose/`                   |
| Kopia backup policy       | `infrastructure/backup/`     |
| Application password      | `secrets/`                   |

When something is ambiguous, favor the question:

> **Which system is responsible for this setting?**

That system's configuration should generally be the authoritative representation.

---

# Avoiding Kubernetes-Like Complexity

This repository intentionally avoids reproducing Kubernetes concepts simply because they existed in the previous environment.

We should resist introducing layers such as:

```text
infrastructure/
    definitions/
        networks/
        volumes/
        services/
```

followed by tooling that generates Compose files from those definitions.

That would provide little benefit for a single Docker host while introducing another abstraction that must be understood and maintained.

Instead:

```text
Infrastructure
    ↓
Host environment

Compose
    ↓
Docker environment

Config
    ↓
Application configuration

Secrets
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

Kopia protects persistent runtime data.

## 5. Secrets belong in SOPS

Sensitive values should be encrypted with SOPS/age and committed if they need to be version controlled.

Plaintext secrets should not be committed.

## 6. Prefer explicitness over abstraction

A simple Compose file referencing:

```text
/srv/homelab/paperless
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
Install Docker/SOPS/age/Kopia
    ↓
Clone repository
    ↓
Decrypt secrets
    ↓
Deploy Compose
    ↓
Restore persistent data if necessary
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
        ├── Yes → config/
        │
        └── No
             │
             ▼
Is it sensitive configuration?
        │
        ├── Yes → secrets/
        │
        └── No
             │
             ▼
Does it configure/support the host or external environment?
        │
        ├── Yes → infrastructure/
        │
        └── No → docs/ or scripts/
```

The overarching goal is **not** to make every aspect of the homelab fit into a rigid directory hierarchy.

The goal is to make it immediately apparent:

1. **What runs?** → `compose/`
2. **How is it configured?** → `config/`
3. **What secrets does it require?** → `secrets/`
4. **What does the host/external environment provide?** → `infrastructure/`
5. **How do I operate it?** → `scripts/`
6. **How does it work?** → `docs/`

If a future change doesn't clearly fit one of those categories, that is a reason to reconsider the architecture before adding another abstraction.
