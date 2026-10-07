#!/usr/bin/env bash
# status.sh — one command: what is LIVE (through the proxy) + the blue/green
# pair view (instances, reserved IP, health).
#
# Env: APP_HOST_HEADER (default: app.example.com), OCI_PROFILE, OCI_COMPARTMENT.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${APP_HOST_HEADER:-app.example.com}"

say() { printf '%s\n' "$*"; }

say "== live (through the proxy: https://$HOST) =="
if body="$(curl -sf -m 8 "https://$HOST/api/auth/ok" 2>/dev/null)"; then
  say "HEALTH OK: $body"
  say "build-id  : $(curl -sf -m 8 "https://$HOST/build-id.txt" 2>/dev/null || echo unreachable)"
else
  say "UNREACHABLE or unhealthy — check the VM (ssh) and kamal-proxy"
fi
say
say "== blue/green pair =="
exec bash "$HERE/bluegreen.sh" status
