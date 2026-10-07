# kampodine — founding doc

Positioning, architecture, and build-out checklist. Public README covers the
pitch; this doc is the deeper reference.

## Why this exists

- **kamal (the tool) requires Docker engine + systemd on the target host.**
- **Alpine ships no systemd at all** (verified: absent from v3.22
  main/community + edge — OpenRC is the init, full stop).
- **Podman-only fleets exist** — no Docker engine on any machine.
- **kamal-proxy doesn't care about any of that** — it's a container image,
  init-agnostic. It was never the problem; kamal's host assumptions were.

So: keep kamal-proxy as the TLS edge, replace the deploy machinery around it
with Alpine-native pieces — OpenRC `supervise-daemon`, rootful podman, and a
plain SSH stream instead of a registry.

## Positioning

- A **kamal alternative** for podman + Alpine targets.
- **Built ON kamal-proxy** — host routing, ACME TLS, gapless target swaps via
  `kamal-proxy deploy` are all still kamal-proxy's job.
- Same mental model as kamal: **build → ship → health-gate → cutover →
  instant rollback**. No registry in the middle.

## Commands (kamal parity)

| kamal | kampodine |
|---|---|
| `kamal deploy` | `kampodine deploy` — stream deploy (`podman save \| ssh podman load`) |
| `kamal rollback` | `kampodine deploy --rollback [sha]` — instant image-tag rollback |
| `kamal details` | `kampodine bluegreen status` — pair + reserved IP + health |
| `kamal proxy …` | unchanged — kamal-proxy container (OpenRC-supervised) |
| `kamal app exec/logs` | `ssh root@<host>` |
| — | `kampodine bluegreen init/provision/flip` — reserved-IP blue-green pair |
| — | `kampodine image-import` — golden qcow2 → OCI custom image |
| — | `kampodine vm-prepare` — first-run bootstrap of a bare Alpine host |
| — | `kampodine migrate` — sqlite migrations over SSH |

## Deploy pipeline (what `kampodine deploy` does)

```
build (BUILD_ID=<git sha>, committed tree only)
  -> podman save <img>:<sha>  |  ssh vm podman load
  -> podman tag <img>:<sha> <img>:latest
  -> env file generation -> /etc/<app>/env (0600, secret-store resolved)
  -> rc-service <app> restart
  -> health endpoint must report the DEPLOYED sha     # health gate
  -> kamal-proxy deploy <host> -> <target>            # gapless cutover
  -> public smoke: health + build-id endpoints
```

Guarantees: committed-tree-only deploys (sha = build identity, verified at
health time); the previous image stays on the VM (rollback = retag + restart);
no registry, no tunnel, no docker, no systemd — SSH + podman only.

## Checklist

**Done (battle-tested in production):**
- [x] registry-free stream deploy with sha-verified health gate + public smoke
- [x] instant rollback (`--rollback [sha]`)
- [x] secret-store-resolved env file generation (zero plaintext)
- [x] kamal-proxy TLS registration + ACME (per-host)
- [x] OpenRC golden image — packer build + single-convergence ansible roles
- [x] `vm-prepare` start-fresh bootstrap
- [x] blue-green reserved-IP tooling — `status`/`init`/`provision`/`flip`/
      `rollback`; discovery, dormant reserved-IP detection, health checks,
      and flip-guards verified against live OCI; flip E2E runs when a second
      instance exists
- [x] sqlite migration runner (`migrate`)
- [x] OCI image import path (`image-import`)
- [x] npm package — bin `kampodine`, scripts shipped in-package, published on
      npm, with package tests (script contract gates: `bash -n` + shellcheck
      over every script; cli dispatch contract: help/version/exit codes/bin
      integrity)

**In progress:**
- [ ] reference sweep (docs → kampodine invocations)

## Roadmap

- `kampodine status` — live served sha + pair view in one command
- registry-path automation (mirror mode: push to any OCI registry,
  VM-side pull, same health-gate/cutover tail)
- genericized defaults (env schema path, service/container names,
  deploy-host env) driven by config

## Non-goals

- multi-host orchestration, roles, accessory containers — kamal's scale
  problems small fleets don't have
- replacing kamal-proxy (that part is already right)

## Prerequisites (deploy machine)

node ≥ 20, podman, oci CLI (bluegreen/image-import), ssh key to the target,
your secret-resolution tool of choice for the env step.
