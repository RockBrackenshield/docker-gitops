# Welcome

This repository is holding, and will serve as, my homelab repository for Docker configurations, compose stacks, etc.

I started out on Docker, but then moved over to K3s once I found out that, with a single control node, it uses a SQLite database rather than etcd, a boon for my Raspberry Pis that were to run the cluster. Or the single management node at least.

I spent several weeks/months learning K3s, getting a number of utilities set up, but... it was a pain. I loved learning it, I was going into it with possibly using it to look for an SRE or platform engineer job, and orchestration is really useful, but man alive is it overkill for the little homelab I have now. If I had a full rack with server after server, sure, some flavour of Kubernetes would probably be useful, but a couple Pis, its just so much overhead and work to keep it going and I was frequently battling with ArgoCD which was.. whew, those were fights to try to get things resolved. 

So, I'm planning on moving back to Docker. This repository will take what I've learned from both my previous Docker run and now the past Kuberneted run and try to make a nice, effective homelab. That doesn't need tinkering all the time and preferably does not require 20-30 minutes to boot up every time the power flickers (thank you power company).

In terms of infrastructure, we'll be looking at Adguard for DNS, some form of reverse proxy (unsure if I'll run NPM like I did before, Traefik, Caddy, or something else entirely like Zoraxy), along with Authentik and Renovate for auth and update management and possibly Zot as a lightweight registry, all managed through Dockhand. In terms of apps, Metube, Home Assistant, and Jellyfin are on the docket, plus whatever else strikes my fancy.

Enjoy!

---

## Purpose

Largely as described as above. I want a homelab, K3s hurt my brain, Docker doesn't, let's run that.

---

## Structure

The repo is broken into several directories. 

`/compose` which is the workhorse. The stacks live here.
`/config` will be for things like config directories various containers may need, like Adguard's config-dir. The idea is to keep things contained to allow for Kopia to easily back up the data. 
`/secrets` will hold various encrypted config files, managed with SOPS + age. At least for now, we'll see how they fare, but they seem a viable option
`/infrastructure` is going to be mostly notes. How things should be laid out, what's mounted where, various configs, addressing, etc. Things outlined and described here support Docker, but nothing about Docker runs out of here. This is all support for Docker to actually run the workloads once these items are put in place.
`/scripts` are going to be things to help set up the environment, like Ansible scripts, or other operational items to setup, run, launch, or otherwise do things that the nodes may regularly require to keep Docker going.
`/docs` is self explanatory. Infrastructure may actually be folded under here at some point

---

## AI

I know it basically makes me a demon to many, but I did and do use AI as part of helping to manage the lab. This README is hand-written by a not-grass-fed, partially-organically raised, cubically-caged human, but much of the rest has been at least advised on by AI, with much of the overall documentation and layout (architecturally) recommended by ChatGPT, whereas Claude handled a lot of the lifting in terms of the compose stacks, and conversion of existing K3s manifests into a relatively comparable Compose file/stack. I do still review it all, clear out some detritus, but life is busy, and asking the robots to do grunt work is nice. 

---

## License

Don't have one. This is Compose stuff. Do with it as you will. Thank you for coming to my TED Talk.