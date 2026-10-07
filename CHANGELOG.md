# Changelog

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
