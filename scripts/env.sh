#!/usr/bin/env bash
# env.sh — manage the remote app env file (/etc/esellar/env, 0600 root).
#
# SECRETS NEVER PRINT. `env list`, `env push`, and the `env pull` summaries
# surface FINGERPRINTS ONLY: KEY + value length + first 2 characters. Raw
# values move exactly twice — push uploads the local file over ssh stdin,
# pull streams the remote file to stdout (payload) or --out (0600). Nothing
# secret ever lands in terminal output, logs, or process args.
#
# Host/key resolution is IDENTICAL to deploy.sh:
#   --host root@<ip> | ESPELLAR_HOST | ~/.ssh/config Host alias
#   --ssh-key <path> | KAMPODINE_SSH_KEY | ESPELLAR_SSH_KEY (legacy) |
#   ssh-agent (the POSIX default; per-host IdentityFile belongs in ssh config)
#
# Usage:
#   kampodine env list [--host <user@ip>]              # KEY + fingerprint table (NEVER values)
#   kampodine env push --file <local-env-file> [...]   # upload: 0600 temp + atomic mv + restart hint
#   kampodine env pull [--out <file>] [...]            # raw payload to stdout/--out (0600); masked summary follows it
#   kampodine env fingerprint [--file <f>]             # preview the masking for a LOCAL file / stdin (never values)
#
# push sends the file VERBATIM (what you push is what lands). deploy's env
# step additionally drops rc-script-owned CLEAR keys — keep those out of the
# file you push unless you mean to own them here.
set -euo pipefail

ENV_FILE_REMOTE="${KAMPODINE_ENV_REMOTE:-/etc/esellar/env}"
ENV_TMP_BASE="$(dirname "$ENV_FILE_REMOTE")"

ESPELLAR_HOST="${ESPELLAR_HOST:-}"
# SSH key resolution — same ladder as deploy.sh:
#   1. --ssh-key flag           (explicit, per-invocation)
#   2. KAMPODINE_SSH_KEY env    (project-level: direnv / .envrc / export)
#   3. ESPELLAR_SSH_KEY env     (legacy alias, kept for existing setups)
#   4. empty → ssh-agent and/or the operator's ~/.ssh/config Host block
if [ -n "${KAMPODINE_SSH_KEY:-}" ]; then
    SSH_KEY="$KAMPODINE_SSH_KEY"
else
    SSH_KEY=""
fi

say() { printf '\033[1;36m[env]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[env] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage:\n'
  grep '^#   kampodine env' "$0" | sed 's/^#   //'
  cat <<'EOF'

Fingerprints NEVER leak values: every line is KEY + value length + first 2 chars.
Raw values move only in push's upload stream and pull's stdout/--out payload.
Host/key resolution matches deploy.sh: --host | ESPELLAR_HOST; --ssh-key |
KAMPODINE_SSH_KEY | ESPELLAR_SSH_KEY | ssh-agent / ~/.ssh/config.

Examples:
  kampodine env list --host root@203.0.113.10
  kampodine env push --file ./ops/env.production --host root@203.0.113.10
  kampodine env pull --out ./env.snapshot --host root@203.0.113.10   # written 0600
  kampodine env pull --host root@203.0.113.10 | wc -l                # raw payload on stdout, summary on stderr
  kampodine env fingerprint --file ./.env.local                      # preview masking, values never leave stdin
EOF
  exit 0
}

SUB="${1:-}"
[[ -n "$SUB" ]] || usage
case "$SUB" in
  list|push|pull|fingerprint) shift ;;
  -h|--help|help) usage ;;
  *) die "unknown env subcommand: $SUB (--help)" ;;
esac

FILE=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) ESPELLAR_HOST="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done

SSH_ARGS=(-o ConnectTimeout=10 -o BatchMode=yes)
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
# $1 is a composed remote command — client-side expansion is the design.
# shellcheck disable=SC2029
vm() { ssh "${SSH_ARGS[@]}" "$ESPELLAR_HOST" "$1"; }

# --- macOS ssh-agent quirk (first run from a fresh machine) -------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  SSH_AUTH_SOCK="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
  export SSH_AUTH_SOCK
fi

require_host() {
  [[ -n "$ESPELLAR_HOST" ]] || die "target required: --host root@<ip> or ESPELLAR_HOST=root@<ip> (resolution matches deploy.sh)"
}

# env_fp_lines — env content on stdin -> fingerprint table on stdout.
# THE masking contract lives here: KEY + value length + first 2 chars.
# $value is never printed; only ${value:0:2} and its length are.
env_fp_lines() {
  local line key value len
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${line#*=}"
    # one pair of matching surrounding quotes is formatting, not content
    # (podman --env-file does not unquote — the deploy pipeline strips them)
    if [[ ${#value} -ge 2 ]]; then
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
    fi
    len="${#value}"
    if [[ "$len" -eq 0 ]]; then
      printf '%-32s len=0      (empty)\n' "$key"
    else
      printf '%-32s len=%-7s %s…\n' "$key" "$len" "${value:0:2}"
    fi
  done
}

fetch_remote_env() {
  vm "cat $ENV_FILE_REMOTE" || die "cannot read $ENV_FILE_REMOTE on $ESPELLAR_HOST (no env file yet? run: kampodine env push --file <env>, or kampodine deploy)"
}

case "$SUB" in
  list)
    require_host
    raw="$(fetch_remote_env)"
    env_fp_lines <<<"$raw"
    ;;

  push)
    [[ -n "$FILE" ]] || die "push requires --file <local-env-file> (--help)"
    [[ -f "$FILE" ]] || die "no such file: $FILE"
    require_host
    count="$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$FILE" || true)"
    [[ "${count:-0}" -gt 0 ]] || die "no KEY=VALUE lines in $FILE — nothing to push"
    say "pushing $FILE -> $ESPELLAR_HOST:$ENV_FILE_REMOTE (fingerprint summary below; values are NEVER printed)"
    env_fp_lines < "$FILE"
    tmp_remote="$ENV_TMP_BASE/env.tmp.$$"
    # 0600 FROM CREATION: umask 077 + ssh stdin pipe — the temp is never
    # world-readable, not even for an instant; `mv` within the same
    # directory is atomic (busybox-safe: umask/cat/mv/chmod only).
    vm "umask 077; cat > $tmp_remote" < "$FILE" || die "upload failed"
    vm "chmod 600 $tmp_remote && mv -f $tmp_remote $ENV_FILE_REMOTE" \
      || die "atomic install failed (remote temp left at: $tmp_remote)"
    say "installed $ENV_FILE_REMOTE (0600) on $ESPELLAR_HOST"
    say "restart to apply: ssh $ESPELLAR_HOST 'rc-service esellar-api restart'   # or: kampodine deploy"
    ;;

  pull)
    require_host
    raw="$(fetch_remote_env)"
    if [[ -n "$OUT" ]]; then
      ( umask 077; printf '%s\n' "$raw" > "$OUT" ) || die "cannot write $OUT"
      chmod 600 "$OUT"
      say "wrote $OUT (0600) — fingerprint summary below (payload went to the file, stdout is free):"
      env_fp_lines <<<"$raw"
    else
      # stdout IS the payload (pipe into whatever needs the values);
      # the human-readable summary goes to stderr, masked.
      printf '%s\n' "$raw"
      say "fingerprint summary for $ENV_FILE_REMOTE on $ESPELLAR_HOST (payload above on stdout):" >&2
      env_fp_lines <<<"$raw" >&2
    fi
    ;;

  fingerprint)
    if [[ -n "$FILE" ]]; then
      [[ -f "$FILE" ]] || die "no such file: $FILE"
      env_fp_lines < "$FILE"
    else
      env_fp_lines
    fi
    ;;
esac
