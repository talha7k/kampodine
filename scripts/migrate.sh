#!/usr/bin/env bash
# migrate.sh — deploy-time drizzle migration loop over the libSQL db files.
# FINAL MODEL (gcp.md §1, realized on OCI Riyadh): one .db file per tenant under
# /data/tenants (+ root.db).
# Calls scripts/libsql-migrate/migrate-db.ts (one-shot tsx) per file, reusing the
# app's own migration applier (applyMigrationFile) and per-namespace migration
# groups — the SAME code path as local seeding/load, no parallel implementation.
# Order: root.db first (auth/org plane), then tenant_*.db sorted. Per-file failures
# are COLLECTED (files are independent; one bad tenant must not block the others)
# and the script exits 1 if any failed — the deploy's smoke gate catches a red migration.
# Runs ON the VM from the repo checkout (also fine locally against .tmp data):
#   kampodine migrate [--allow-running]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
TENANT_DIR="${TENANT_DIR:-/data/tenants}"
SERVICE="${SERVICE:-esellar-api}"

log() { printf '[migrate-all] %s\n' "$*"; }
fail() { printf '[migrate-all][FAIL] %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  kampodine migrate [--allow-running]

Examples:
  kampodine migrate                    # stop the API first (rc-service esellar-api stop)
  kampodine migrate --allow-running    # deliberate: migrate while the API serves (SQLITE_BUSY risk)

Runs drizzle migrations over the libSQL dbs under TENANT_DIR (default
/data/tenants): root.db first (auth/org plane), then tenant_*.db sorted,
bounded-parallel (MIGRATE_JOBS, default 4). Per-file failures are collected;
exits 1 if any failed.
EOF
  exit 0
}

ALLOW_RUNNING=0
for arg in "$@"; do
  case "$arg" in
    --allow-running) ALLOW_RUNNING=1 ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $arg (--help)" ;;
  esac
done

[[ -f "${REPO_ROOT}/apps/api/scripts/libsql-migrate/migrate-db.ts" ]] \
  || fail "repo root not found at ${REPO_ROOT} (set REPO_ROOT=... if the checkout lives elsewhere)"
command -v pnpm >/dev/null 2>&1 || fail "pnpm not found in PATH"
[[ -d "$TENANT_DIR" ]] || fail "tenant dir ${TENANT_DIR} does not exist"

# Writing schema while the API serves traffic risks SQLITE_BUSY on a single-writer
# engine — the service must be stopped first (rc-service esellar-api stop). Override exists
# for deliberate local use.
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
  if [[ $ALLOW_RUNNING -ne 1 ]]; then
    fail "${SERVICE} is running — stop it first (rc-service esellar-api stop) or pass --allow-running"
  fi
  log "WARNING: migrating while ${SERVICE} is running (--allow-running)"
fi

shopt -s nullglob
db_files=("$TENANT_DIR"/*.db)
shopt -u nullglob
if [[ ${#db_files[@]} -eq 0 && ! -f "${TENANT_DIR}/root/root.db" && ! -f "${TENANT_DIR}/root.db" ]]; then
  log "no .db files under ${TENANT_DIR}; nothing to migrate"
  exit 0
fi

failures=0
migrated=0

RESULTS_DIR="$(mktemp -d /tmp/migrate-results.XXXXXX)"
trap 'rm -rf "$RESULTS_DIR"' EXIT

migrate_one() {
  local db_file="$1" ns="$2"
  local marker
  marker="${RESULTS_DIR}/$(basename "$db_file" .db).status"
  log "migrating ${db_file#"${TENANT_DIR}"/} (ns: ${ns})"
  if (cd "$REPO_ROOT" && pnpm --filter api exec tsx scripts/libsql-migrate/migrate-db.ts --db "file:${db_file}" --ns "$ns"); then
    printf 'ok' > "$marker"
  else
    printf 'FAIL' > "$marker"
    printf '[migrate-all][FAIL] migration failed for %s\n' "$db_file" >&2
  fi
}

tally() {
  failures=0; migrated=0
  local m
  for m in "$RESULTS_DIR"/*.status; do
    [[ -e "$m" ]] || continue
    if [[ "$(cat "$m")" = "ok" ]]; then migrated=$((migrated + 1)); else failures=$((failures + 1)); fi
  done
}

# root.db (auth/org plane) migrates FIRST. App seam (sqld-topology.ts rootDbPath)
# resolves it at /data/tenants/root/root.db; a legacy flat /data/tenants/root.db
# is honored as fallback.
if [[ -f "${TENANT_DIR}/root/root.db" ]]; then
  migrate_one "${TENANT_DIR}/root/root.db" root
elif [[ -f "${TENANT_DIR}/root.db" ]]; then
  migrate_one "${TENANT_DIR}/root.db" root
fi

# then tenant files sorted — bounded-parallel by default (-j 4): per-file
# write locks are independent (one writer per file by the store model), so
# parallelism is safe; the failure gate stays all-or-nothing either way.
JOBS="${MIGRATE_JOBS:-4}"
shopt -s nullglob
tenant_files=("$TENANT_DIR"/tenant_*.db)
shopt -u nullglob
if [[ ${#tenant_files[@]} -gt 0 ]]; then
  sorted_tenants=()
  while IFS= read -r f; do sorted_tenants+=("$f"); done < <(printf '%s\n' "${tenant_files[@]}" | sort)
  if [[ "$JOBS" -le 1 ]]; then
    for db_file in "${sorted_tenants[@]}"; do
      migrate_one "$db_file" "$(basename "$db_file" .db)"
    done
  else
    # migrate_one is marker-file based (no shared shell state) — xargs
    # children report through $RESULTS_DIR; tally() aggregates after.
    export RESULTS_DIR TENANT_DIR REPO_ROOT
    export -f migrate_one log
    printf '%s\n' "${sorted_tenants[@]}" | xargs -P "$JOBS" -I{} bash -c 'migrate_one "$@" "$(basename "$1" .db)"' _ {}
  fi
  tally
fi

if [[ $failures -gt 0 ]]; then
  fail "${failures} db file(s) failed to migrate (migrated: ${migrated}) — do NOT start the API on a half-migrated estate; fix and re-run"
fi
log "all db file(s) migrated cleanly (${migrated} total)"
