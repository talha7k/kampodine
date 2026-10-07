# Changelog

## 0.3.0 — 2026-10-07

Full-lifecycle orchestration with first-class help — the "mini vercel CLI"
release.

- `env` — manage the remote app env file (`/etc/esellar/env`, 0600 root):
  `list` (KEY + value fingerprints only — length + first 2 chars, values
  NEVER printed), `push --file` (0600 temp from creation via umask + atomic
  `mv` + restart hint), `pull` (raw payload to stdout or `--out` 0600, masked
  summary), `fingerprint` (local masking preview). Host/key resolution
  identical to deploy (`--host` | `ESPELLAR_HOST`, `--ssh-key` |
  `KAMPODINE_SSH_KEY` | ssh-agent)
- `dns` — OCI DNS records: `records`, `add`, `rm`. Shells out to the `oci`
  CLI; auth is the OCI config file (`--profile`) or `--instance-principal`
  ONLY — no credential material is ever accepted, stored, or logged. Types
  pinned to A|AAAA|CNAME; name/type/value/ttl validated locally before any
  provider call; `add` merges into the existing RRSet, `rm` filters it
- Help everywhere: `kampodine --help` prints a grouped command index
  (DEPLOY / INFRA / DNS / ENV, vercel-style); every command and every
  bluegreen/env/dns sub-step answers `--help`/`-h` with `Usage:` +
  `Examples:` — pinned by a test that enumerates all of them
- Tests grew from 38 to 114: help coverage for every subcommand, env
  fingerprint masking against fixture ssh shims (a value in output fails the
  suite), dns arg validation, top-level index groups, oci `--profile` gate
  extended to `dns` calls

## 0.2.1 — 2026-10-07

Docs, hygiene, and deploy hardening.

- Global-audience README: rewritten so it reads clean outside the
  original deployment (no service names, timings, or internal history)
- Removed origin-specific defaults that leaked a real host: the deploy
  target and Host-header defaults are now placeholders — set `ESPELLAR_HOST`
  and `PROXY_HOST` / `APP_HOST_HEADER` explicitly (they were env overrides
  before and still are)
- `deploy`: `--dockerfile <path>` for alternative image recipes (e.g. a Go
  cutover image, built with `GIT_SHA` instead of `VITE_BUILD_ID`); the
  health probe now runs on the VM host (busybox wget) so scratch/Go images
  without a shell probe cleanly
- Script/test comments: tightened wording across the shipped scripts,
  keeping the technical rationale
- Fixed standalone-repo test paths (two vm-prepare suites still resolved the
  old monorepo layout); repo gained `.gitignore` + `package-lock.json`

## 0.2.0 — 2026-10-07

- `bluegreen` — reserved-IP blue/green pairs on OCI:
  `status|init|provision|flip|rollback`; zero-DNS flips, ACME-first
  cutover, health-gated with automatic rollback; a guest anchor watcher is
  shipped by `vm-prepare`
- `vm-prepare` — sshd-hardening self-heal for fresh VMs, busybox-wget
  probes (the golden image ships no curl), anchor watcher install
- `image-import` — every `oci` call honors `OCI_PROFILE`

## 0.1.0 — 2026-10-05

- First release: registry-free stream deploy (`podman save | ssh podman
  load`) with sha-verified health gate and instant rollback, kamal-proxy
  TLS/ACME registration, OpenRC golden-image pipeline, `migrate` (sqlite
  migrations over SSH), OCI image-import path
