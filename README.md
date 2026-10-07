# kampodine

**kam**al + **pod**man + alpi**ne** — Kamal-style deploys for Alpine + Podman hosts, built on [kamal-proxy](https://github.com/basecamp/kamal-proxy).

## Why this exists

[kamal](https://kamal-deploy.org) is a great deploy tool with one hard
requirement pair: **Docker engine and systemd on the target host**. If you run
Alpine Linux — or a strict-podman fleet with no Docker anywhere — kamal cannot
deploy for you:

- **Alpine ships no systemd at all.** Not in main, community, or edge
  (verified on v3.22). OpenRC is the init system, period.
- **Not every fleet runs Docker.** Rootful Podman under OpenRC
  `supervise-daemon` is a perfectly good way to host containers — kamal just
  can't talk to it.
- **kamal-proxy was never the problem.** It's a container image — completely
  init-agnostic. Host routing, ACME TLS, and gapless target swaps via
  `kamal-proxy deploy` work fine on an Alpine + Podman host.

kampodine keeps kamal-proxy as the TLS edge and replaces everything around it
with Alpine-native pieces:

| kamal assumes | kampodine uses |
|---|---|
| Docker engine | Podman (rootful, no Docker anywhere) |
| systemd units | OpenRC `supervise-daemon` services |
| Container registry | `podman save \| ssh podman load` — a plain SSH stream |
| kamal proxy orchestration | kamal-proxy itself, unchanged |

## What it does

Same mental model as kamal: **build → ship → health-gate → cutover → instant
rollback.**

```
kampodine deploy:
  podman build --build-arg BUILD_ID=<git sha>        # committed tree only
  podman save <img>:<sha>  |  ssh <host> podman load
  podman tag <img>:<sha> <img>:latest                # on the VM
  env file generation -> /etc/<app>/env (0600)       # from your secret store
  rc-service <app> restart
  health endpoint must report the DEPLOYED sha       # health gate
  kamal-proxy deploy <host> -> <target>              # gapless cutover
  public smoke: health + build-id endpoints
```

- **`kampodine deploy`** — stream deploy; `--version <sha>` restreams an
  existing build; `--rollback [sha]` is an instant image-tag rollback (the
  previous image stays on the VM for exactly this)
- **`kampodine env`** — manage the remote app env file (`/etc/esellar/env`,
  0600 root) without ever printing a secret: `list` shows KEY + fingerprints
  only (value length + first 2 chars), `push --file <env>` uploads over ssh
  stdin into a 0600 temp + atomic `mv`, `pull` streams the raw payload to
  stdout or `--out` (written 0600). Host/key resolution is identical to
  deploy: `--host root@<ip>` | `ESPELLAR_HOST`, `--ssh-key <path>` |
  `KAMPODINE_SSH_KEY` | ssh-agent. `env fingerprint` previews the masking
  for any local file — values never leave stdin
- **`kampodine dns`** — OCI DNS records for the post-sslip.io era:
  `records`, `add --name <label> --type A|AAAA|CNAME --value <target>
  [--ttl 300]`, `rm`. Shell out to the `oci` CLI; auth is the OCI config
  file (`--profile`) or `--instance-principal` ONLY — kampodine never
  accepts, stores, or logs credential material. `add` merges into the
  existing RRSet (round-robin survives), `rm` filters it; types/ttl/value
  are validated locally before any provider call
- **`kampodine bluegreen status|init|provision|flip|rollback`** — reserved
  public IP management for a two-instance blue/green pair on OCI: zero DNS
  change, health-gated flips with an ACME-first cutover (reserved IP assigned
  → cert issued for its hostname → served sha verified) and automatic
  rollback. A guest **anchor watcher** installed by `vm-prepare` holds the
  flip's IP half — add-only and inert until a flip writes its anchor config.
  Every sub-step has its own `--help` with usage + examples
- **`kampodine vm-prepare`** — first-run bootstrap of a bare Alpine host:
  sshd hardening (fresh VMs pass unattended), busybox-wget health probes (the
  golden image ships no curl), the blue-green anchor watcher, the podman
  stack, and OpenRC `supervise-daemon` units for app + kamal-proxy
- **`kampodine image-import`** — golden qcow2 → OCI custom image. Caveat:
  imported custom images boot BIOS and are rejected by Ampere (A1) shapes —
  use `bluegreen provision` for ARM targets
- **`kampodine migrate`** — sqlite migrations over SSH

**Help everywhere:** `kampodine --help` (or bare `kampodine`) prints a
grouped command index (DEPLOY / INFRA / DNS / ENV, vercel-style); every
command — and every bluegreen/env/dns sub-step — answers `--help` with
usage + examples. No subcommand silently does nothing on `--help`.

## Kamal parity

| kamal | kampodine |
|---|---|
| `kamal deploy` | `kampodine deploy` |
| `kamal rollback` | `kampodine deploy --rollback [sha]` |
| `kamal details` | `kampodine bluegreen status` |
| `kamal proxy …` | kamal-proxy container, unchanged |
| `kamal app exec/logs` | `ssh root@<host>` |
| `kamal reboot / app boot` | `rc-service <app> restart` over SSH |

## Building the expected image

kampodine's target host is a **converged Alpine image** — Alpine (aarch64 or
x86_64) with the podman runtime, OpenRC services, and kernel settings the
deploy flow relies on. The reference build pipeline:

1. **packer + qemu (UEFI)** boots the Alpine `virt` ISO. Boot is driven over
   the **serial console**, not VNC — the ISO's VGA tty has no getty; a serial
   bootstrap helper handles the login prompt and ash's `ESC[6n` cursor query,
   then types one line that brings up DHCP and fetches the bootstrap script.
2. **install** runs `setup-disk` under UEFI (ESP + grub-efi, `--removable`
   fallback for hosts with fresh NVRAM), sanitizes apk repos, installs
   `python3` (ansible runtime) + `openssh`, enables boot-critical OpenRC
   services, bakes your public key, reboots.
3. **ansible converge** installs the podman stack — podman, netavark,
   aardvark-dns, **iptables** (netavark needs it), the **cgroups** service
   (cloud VMs boot without one), `ip_unprivileged_port_start=80` sysctl — and
   lays down `supervise-daemon` templates for app + kamal-proxy. **The same
   playbook converges the golden image and repairs live drift**: one
   convergence path, the image is by construction what the playbook produces.
4. **ship the qcow2** to your cloud. On OCI: import **from a launched
   instance** (or boot-volume seeding) — raw QCOW2 object imports land
   x86-flagged and won't boot on Ampere. `kampodine image-import` +
   `kampodine vm-prepare` handle that path.
5. First deploy issues TLS (ACME) via kamal-proxy — no cert carry.

Verify a build by booting the qcow2 locally (qemu UEFI boot, serial console)
before importing — the image should reach a working sshd with the podman
stack installed.

## Shipping the image: mirror vs no-mirror

Two ways to get the built container image onto the target — kampodine
automates the second; the first is a documented recipe:

**No-mirror (default): the SSH stream.** `podman save | ssh podman load` over
the deploy's own SSH connection. Nothing exists between you and the VM: no
registry, no tunnel, no extra ports, no credentials beyond SSH.

- ✅ zero infrastructure; works air-gapped; nothing to keep alive
- ✅ sha-tagged images land atomically; `podman load` dedupes layers by digest
- ⚠️ each deploy streams the full image tar; no cross-deploy layer cache

**Mirror (optional): any OCI registry.** `podman push` the sha-tagged image to
a registry the VM can reach; the VM `podman pull`s and retags `:latest` — the
health-gate/cutover tail is identical. Works with hosted registries (GHCR,
Docker Hub, cloud registries) or a local one mirrored over an SSH reverse
tunnel (`ssh -R 5000:127.0.0.1:5000`).

- ✅ layer caching (fast repeated deploys), multi-target fan-out, CI-native
- ⚠️ requires registry reachability + credentials on the VM
- ⚠️ macOS note: AirPlay listens on :5000 by default — pick another port for
  a local registry

Rule of thumb: one VM and no existing registry → stream. Multiple targets,
CI-driven deploys, or a registry you already run → mirror. Registry-path
automation is on the roadmap; today the stream is the automated path.

## Prerequisites

Deploy machine: node ≥ 20, podman, ssh key access to the target, `oci` CLI
(for bluegreen / image-import / dns), `jq` (for dns record surgery), and
whatever secret-resolution your env-file step uses (kampodine is agnostic;
the reference setup uses [varlock](https://varlock.dev) + pass).

Target: a converged Alpine + Podman + OpenRC host (see above), reachable over
ssh as root, with kamal-proxy running.

## Status

Proven on production deployments (v0.2.x). Defaults are still opinionated —
service/container names, env-file path, deploy-host env — and genericizing
them is the top roadmap item. Design reference + roadmap:
[`kampodine.md`](./kampodine.md). Release history:
[CHANGELOG.md](./CHANGELOG.md).

## License

Copyright (c) 2026 talha7k — **AGPL-3.0** (see [LICENSE](./LICENSE)).

Copyleft with teeth: anyone who uses, modifies, or hosts kampodine —
including as a network service — must publish their source under AGPL-3.0,
and original attribution must be preserved.
