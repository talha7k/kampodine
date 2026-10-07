#!/usr/bin/env bash
# deploy.sh — registry-FREE deploy to the Alpine VM (Meridian-style):
#
#   Mac:  podman build (VITE_BUILD_ID=<sha>) -> podman save (docker-archive)
#         streamed over SSH -> podman load on the VM
#   VM:   retag to 127.0.0.1:5000/esellar-api:latest -> rc-service esellar-api
#         restart (the OpenRC supervise-daemon service re-runs the whole
#         `podman run` against :latest — no pull in the run, so restarts are
#         offline-safe) -> exec-fetch health probe with served-sha verify ->
#         kamal-proxy re-point via podman exec -> public smoke -> tolerant
#         old-image cleanup.
#
# There is NO registry, NO reverse tunnel, NO local registry container. The
# image transfers over the same SSH the deploy already uses. Rollback =
# --rollback <sha> (the previous image is still on the VM under its sha tag —
# instant).
#
# Usage:
#   kampodine deploy                      # build+deploy HEAD
#   kampodine deploy --version <sha7>     # stream an existing local build
#   kampodine deploy --rollback [<sha7>]  # default: previous
#   kampodine deploy --host root@<ip> ... # target VM override
#   kampodine deploy --dockerfile apps/api-go/Dockerfile.cutover  # Go api image
#   --skip-smoke      # skip the public smoke (behind a not-yet-switched proxy)
#   --refresh-config  # ansible container-service refresh BEFORE restart
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ESPELLAR_HOST="${ESPELLAR_HOST:-}"
PROXY_HOST="${PROXY_HOST:-app.example.com}"
ENV_FILE_REMOTE="/etc/esellar/env"
DEPLOYED_SHA_FILE="/etc/esellar/deployed-sha"
ENV_CLEAR_KEYS='^(NODE_ENV|PORT|LIBSQL_TENANT_DIR|LIBSQL_API_MOUNT|STATIC_SPA_MOUNT)='
IMAGE="127.0.0.1:5000/esellar-api"

MODE="deploy"
VERSION=""
SKIP_SMOKE=0
REFRESH_CONFIG=0
# SSH key resolution — GENERIC, no hardcoded personal paths:
#   1. --ssh-key flag           (explicit, per-invocation)
#   2. KAMPODINE_SSH_KEY env    (project-level: direnv / .envrc / export)
#   3. ESSELLAR_SSH_KEY env     (legacy alias, kept for existing setups)
#   4. empty → ssh-agent and/or the operator's ~/.ssh/config Host block
#      (the POSIX way: per-host IdentityFile belongs in ssh config, not here)
if [ -n "${KAMPODINE_SSH_KEY:-}" ]; then
    SSH_KEY="$KAMPODINE_SSH_KEY"
else
    SSH_KEY=""
fi
# Default image recipe = the TS api Containerfile. The Go cutover image rides
# --dockerfile apps/api-go/Dockerfile.cutover (build context stays the repo
# root for BOTH — the cutover Dockerfile path-prefixes its COPYs).
DOCKERFILE="${KAMPODINE_DOCKERFILE:-apps/api/Containerfile}"

say() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[deploy] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  kampodine deploy [--host root@<ip>] [--version <sha7>] [--rollback [<sha7>]]
                   [--dockerfile <path>] [--ssh-key <path>] [--skip-smoke] [--refresh-config]

Examples:
EOF
  grep '^#   kampodine deploy' "$0" | sed 's/^#   //'
  cat <<'EOF'

Host/key resolution: --host | ESPELLAR_HOST; --ssh-key | KAMPODINE_SSH_KEY |
ESPELLAR_SSH_KEY | ssh-agent / ~/.ssh/config.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ESPELLAR_HOST="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --version) VERSION="$2"; MODE="version"; shift 2 ;;
    --rollback)
      MODE="rollback"
      if [[ $# -ge 2 && "$2" != --* ]]; then VERSION="$2"; shift 2; else VERSION=""; shift; fi
      ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    --refresh-config) REFRESH_CONFIG=1; shift ;;
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done
[[ "$VERSION" != *..* && "$VERSION" =~ ^[0-9a-f]{4,40}$|^$ ]] || die "--version must be a git sha fragment"
[ -n "$ESPELLAR_HOST" ] || die "set ESPELLAR_HOST=root@<vm-ip> (or a ~/.ssh/config Host alias via --host)"

SSH_ARGS=(-o ConnectTimeout=10 -o BatchMode=yes)
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
# $1 is a composed remote command — client-side expansion is the design.
# shellcheck disable=SC2029
vm() { ssh "${SSH_ARGS[@]}" "$ESPELLAR_HOST" "$1"; }

# --- macOS ssh-agent quirk (first deploy from a fresh machine) ---------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  SSH_AUTH_SOCK="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
  export SSH_AUTH_SOCK
fi

# --- preflight -----------------------------------------------------------------
cd "$REPO_ROOT"
if [[ "$MODE" == "deploy" ]]; then
  [[ -z "$(git status --porcelain)" ]] || die "dirty tree — deploys must ship COMMITTED files (build identity stamps the git sha); commit first"
fi
command -v podman >/dev/null 2>&1 || die "podman not found on the Mac (podman machine must run: podman machine start)"
podman info >/dev/null 2>&1 || die "podman machine not reachable (podman machine start)"
# version mode: stream an EXISTING local build (no rebuild, no clean-tree gate —
# the build already happened when that sha was HEAD)
[[ "$MODE" == "version" ]] && VER="${VERSION:-$(git rev-parse --short HEAD)}"
[[ "$MODE" != "version" ]] && VER="$(git rev-parse --short HEAD)"

# --- build (deploy mode always builds HEAD — cached layers keep it minutes) ----
if [[ "$MODE" == "deploy" ]]; then
  if [[ "$DOCKERFILE" == "apps/api/Containerfile" ]]; then
    say "building linux/arm64 (VITE_BUILD_ID=$VER — build identity, never remove)…"
    BUILD_ARG=("VITE_BUILD_ID=$VER")
  else
    say "building linux/arm64 ($DOCKERFILE, GIT_SHA=$VER)…"
    BUILD_ARG=("GIT_SHA=$VER")
  fi
  podman build --platform linux/arm64 \
    -f "$DOCKERFILE" \
    --build-arg "${BUILD_ARG[0]}" \
    -t "$IMAGE:$VER" \
    . || die "podman build failed"
  # Same-origin contract: VITE_API_URL / VITE_LIBSQL_API_URL stay UNSET —
  # the bundle uses relative bases (docs/libsql-migration/web-deploy.md § 5).
fi

# --- stream the image over SSH (Meridian-style; no registry, no tunnel) --------
say "streaming image over SSH (podman save | ssh podman load)…"
podman save --format docker-archive "$IMAGE:$VER" \
  | vm "podman load" || die "image stream failed"
vm "podman tag $IMAGE:$VER $IMAGE:latest" || die "stream retag failed"

# --- env file from varlock (schema-only from HEAD; secrets from pass) ----------
say "generating $ENV_FILE_REMOTE from varlock (schema-only from HEAD; secrets resolve from pass — no plaintext secret files)…"
ENV_TMP="$(mktemp /tmp/esellar-env.XXXXXX)"
trap 'rm -f "$ENV_TMP"' EXIT
# Schema-only resolution: extract the COMMITTED schema into a scratch dir
# inside the repo (plugin resolution needs node_modules; local
# .env/.env.local never enter the pipeline — varlock sees only the extracted
# schema), resolve pass() refs with the repo varlock, and drop the rc-script
# -e-owned CLEAR keys (one source of truth per key; podman --env-file reads
# the result directly, no shell sourcing). varlock's env format double-quotes
# values — strip them: podman --env-file does NOT unquote.
ENV_SCHEMA_DIR="$REPO_ROOT/.tmp/deploy-env-schema"
rm -rf "$ENV_SCHEMA_DIR" && mkdir -p "$ENV_SCHEMA_DIR/apps/api"
git -C "$REPO_ROOT" archive HEAD apps/api/.env.schema | tar -x -C "$ENV_SCHEMA_DIR"
( cd "$ENV_SCHEMA_DIR" && "$REPO_ROOT/node_modules/.bin/varlock" load --format env --compact -p apps/api ) \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | grep -Ev "$ENV_CLEAR_KEYS" \
  | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)="(.*)"$/\1=\2/' > "$ENV_TMP" \
  || die "varlock env generation failed (pass store unlocked? schema committed?)"
printf 'API_GIT_SHA=%s\n' "$VER" >> "$ENV_TMP"
scp -q "${SSH_ARGS[@]}" "$ENV_TMP" "$ESPELLAR_HOST:/etc/esellar/env.tmp"
vm "mv /etc/esellar/env.tmp $ENV_FILE_REMOTE && chmod 600 $ENV_FILE_REMOTE"
rm -f "$ENV_TMP"
rm -rf "$ENV_SCHEMA_DIR"

if [[ $REFRESH_CONFIG -eq 1 ]]; then
  say "ansible container-service refresh (--tags container-service — rc script/config drift repair)…"
  (cd "$REPO_ROOT/infra/alpine-host/ansible" \
    && ansible-playbook -i "esellar-vm ansible_host=${ESPELLAR_HOST#*@},ansible_user=${ESPELLAR_HOST%%@*}," playbook.yml --tags container-service --private-key "${SSH_KEY:-~/.ssh/id_ed25519}") \
    || die "ansible playbook failed"
fi

say "rc-service esellar-api restart (supervise-daemon: stop-old/start-new podman run on the retagged :latest)…"
vm "rc-service esellar-api restart" || die "esellar-api restart failed (rc-service esellar-api status)"

say "health probe (host-side wget /api/auth/ok + served-sha — works for node AND scratch images)…"
HEALTH_OK=0
for _ in $(seq 1 30); do
  # wget runs on the VM (busybox, -p 8080:8080 publish); the served-sha
  # grep runs LOCALLY — remote grep quoting is fragile (busybox BRE
  # (busybox BRE alternation + nested quotes → permanent false-negative).
  # grep -E keeps the alternation portable across BSD/GNU/busybox.
  if vm "wget -qO- -T 3 http://127.0.0.1:8080/api/auth/ok 2>/dev/null" \
      | grep -qE "\"(git|build)\":\"$VER"; then
    HEALTH_OK=1
    break
  fi
  sleep 3
done
if [[ $HEALTH_OK -ne 1 ]]; then
  vm "podman logs --tail 30 esellar-api 2>&1" || true
  vm "rc-service esellar-api status 2>&1" || true
  PREV_HINT="$(vm "test -f $DEPLOYED_SHA_FILE && cat $DEPLOYED_SHA_FILE" 2>/dev/null || true)"
  die "container never became healthy — rollback: kampodine deploy --rollback${PREV_HINT:+ $PREV_HINT}"
fi
CANARY="$(vm "podman logs esellar-api 2>&1 | grep -c ENV_IMPORT_SUSPECT || true")"
say "container healthy, env-canary hits: $CANARY"

say "kamal-proxy re-point (podman exec — same invocation kamal used)…"
if vm "podman ps --format '{{.Names}}' | grep -qx kamal-proxy"; then
  vm "podman exec kamal-proxy kamal-proxy deploy esellar-api --host=$PROXY_HOST --target=esellar-api:8080 --tls --health-check-path=/api/auth/ok" \
    || die "proxy re-point failed (podman logs kamal-proxy)"
else
  say "  kamal-proxy not running — skipping re-point"
fi

if [[ $SKIP_SMOKE -eq 0 ]]; then
  say "smoke (public, through the proxy)…"
  GOT="$(curl -s --max-time 10 "https://$PROXY_HOST/api/auth/ok")"
  echo "$GOT" | grep -q "\"git\":\"$VER" || die "served git sha mismatch: $GOT (proxy still pointing at the old version?)"
  curl -fsS --max-time 10 "https://$PROXY_HOST/up" >/dev/null || die "/up failed"
  curl -s --max-time 10 "https://$PROXY_HOST/build-id.txt" | grep -q "$VER" || die "build-id.txt stale"
  say "LIVE: git=$VER, /up ok, build-id fresh"
else
  say "--skip-smoke; run the public smoke once the proxy serves this host"
fi

say "cleanup (dangling only + sha tags beyond the 3 newest — tolerant, never fatal)…"
vm "podman image prune -f >/dev/null 2>&1 || true"
# busybox head lacks -n -N — tail -n +4 after a newest-first sort keeps 3 tags.
vm "podman images --format '{{.Tag}} {{.CreatedAt}}' $IMAGE 2>/dev/null | grep -E '^[0-9a-f]{7,40} ' | sort -k2,2r | tail -n +4 | awk '{print \$1}' | while read -r old; do podman rmi \"$IMAGE:\$old\" >/dev/null 2>&1 || true; done" || true
[[ "$MODE" == "rollback" ]] || vm "echo $VER > $DEPLOYED_SHA_FILE" || true
say "done (version: $VER). instant rollback: kampodine deploy --rollback"
