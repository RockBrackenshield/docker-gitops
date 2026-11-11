# Welcome

This repository is holding, and will serve as, my homelab repository for Docker configurations, compose stacks, etc.

I started out on Docker, but then moved over to K3s once I found out that, with a single control node, it uses a SQLite database rather than etcd, a boon for my Raspberry Pis that were to run the cluster. Or the single management node at least.

I spent several weeks/months learning K3s, getting a number of utilities set up, but... it was a pain. I loved learning it, I was going into it with possibly using it to look for an SRE or platform engineer job, and orchestration is really useful, but man alive is it overkill for the little homelab I have now. If I had a full rack with server after server, sure, some flavour of Kubernetes would probably be useful, but a couple Pis, its just so much overhead and work to keep it going and I was frequently battling with ArgoCD which was.. whew, those were fights to try to get things resolved. 

So, my day-to-day services run on Docker, while K3s carries on as a Talos lab on the Pi 5 (that lives in my k3s-gitops repo). This repository will take what I've learned from both my previous Docker run and now the past Kuberneted run and try to make a nice, effective homelab. That doesn't need tinkering all the time and preferably does not require 20-30 minutes to boot up every time the power flickers (thank you power company).

Enjoy!

---

## Purpose

Largely as described as above. I want a homelab, K3s hurt my brain, Docker doesn't, let's run that. (The K3s/Talos lab sticks around for learning, in k3s-gitops.)

---

## Structure

The repo is broken into a few pieces.

`/compose` is the workhorse. The stacks live here, one per directory: `compose/<node>/<stack>/compose.yaml`.
`/infrastructure` is mostly notes. How things should be laid out, what's mounted where, various configs, etc. Things outlined and described here support Docker, but nothing about Docker runs out of here.
`/.github/workflows` holds CI: `compose-validate` runs `docker compose config` against every stack on each pull request.
`renovate.json` configures Renovate, which keeps image versions and digests up to date through pull requests.
`AGENTS.md` holds the rules for AI agents working in the repo.

---

## Nodes

Two Raspberry Pi 4Bs, each running Docker:

| Node | Stacks |
|---|---|
| `infrastructure` | AdGuard Home (DNS), Zoraxy (reverse proxy), Tailscale (remote access), Dockhand (deployments), Backrest (backups) |
| `core` | RomM, Shelfmark, FlareSolverr, Paperless-ngx (documents, with SMB and NFS ingest), Backrest (backups) |

---

## How it runs

- **Deployments and secrets:** Dockhand deploys the stacks. Secrets live in Bitwarden Secrets Manager and Dockhand injects them at deploy time; the compose files only reference them as `${VAR}`. Nothing secret is committed.
- **Backups:** Backrest runs on both nodes and backs up the persistent data on the host. App data never goes in Git.
- **Remote access:** Tailscale only.
- **Updates:** Renovate (hosted app) opens pull requests for image updates; nothing automerges.

---

## AI

I know it basically makes me a demon to many, but I did and do use AI as part of helping to manage the lab. This README is hand-written by a not-grass-fed, partially-organically raised, cubically-caged human, but much of the rest has been at least advised on by AI, with much of the overall documentation and layout (architecturally) recommended by ChatGPT, whereas Claude handled a lot of the lifting in terms of the compose stacks, and conversion of existing K3s manifests into a relatively comparable Compose file/stack. I do still review it all, clear out some detritus, but life is busy, and asking the robots to do grunt work is nice. 

---

## License

Don't have one. This is Compose stuff. Do with it as you will. Thank you for coming to my TED Talk.