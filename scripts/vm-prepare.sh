#!/usr/bin/env bash
# vm-prepare.sh — first-run bootstrap for a fresh Alpine VM.
#
# The VM goes to production from its first boot: no blue->green flip, no
# cert carry; the first TLS certificate issues during the first deploy.
#
# Alpine ships NO systemd anywhere (verified v3.22 main/community + edge; the
# golden image boots OpenRC) — everything here is OpenRC-native:
#   1. sanity gates (UEFI boot, OpenRC tooling; sshd hardening is
#      ENSURED — drop-in + Include + restart — then gated: a fresh golden
#      image may predate the baked hardening drop-in)
#   2. apk repositories: ensure the v3.22 community repo (podman lives there)
#   3. podman stack: podman podman-docker crun catatonit netavark
#      aardvark-dns fuse-overlayfs
#   4. /etc/esellar/ (kampodine deploy writes /etc/esellar/env here, 0600 root)
#   5. /etc/containers/registries.conf (insecure 127.0.0.1:5000; search docker.io)
#   6. sysctl net.ipv4.ip_unprivileged_port_start=80 (persisted + applied live)
#   7. OpenRC services /etc/init.d/esellar-api + /etc/init.d/kamal-proxy
#      (supervise-daemon around plain `podman run`), rc-update'd into the
#      default runlevel — that IS boot survival (no quadlets, no systemctl)
#   8. esellar-anchor: the blue-green reserved-ip flip's GUEST half — a
#      busybox watcher (no container) that polls /etc/esellar/anchor.conf and
#      `ip addr add`s the anchor address at flip time. Started+enabled on every
#      VM, inert without the conf (flip tooling writes it over ssh).
#   9. kamal-proxy image pulled + service UP — the first deploy execs into it
#      to issue the fresh ACME certificate
#
# The esellar-api container is NOT started here: neither its image (pulled by
# the first deploy over the registry tunnel) nor /etc/esellar/env (written by
# kampodine deploy) exists yet on a fresh VM.
#
# Idempotent: safe to re-run. apk add is a no-op when satisfied; managed files
# are overwritten; rc-update add is guarded; RUNNING services are never bounced
# (if a rewritten unit differs while its service is started, you get a warning,
# not a restart).
#
#   kampodine vm-prepare --host root@<new-ip>
#   ... --pull-images     # + pre-pull the app image over the registry tunnel
#   ... --ssh-key <path>  # ssh identity (default: agent / ESPELLAR_SSH_KEY)
set -euo pipefail

HOST=""
DO_PULL=0
SSH_KEY="${ESPELLAR_SSH_KEY:-}"

say() { printf '\033[1;32m[vm-prepare]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[vm-prepare] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  kampodine vm-prepare --host root@<new-ip> [--pull-images] [--ssh-key <path>]

Examples:
EOF
  grep '^#   kampodine vm-prepare' "$0" | sed 's/^#   //'
  cat <<'EOF'

Host/key resolution: --host | (no env default — explicit flag);
--ssh-key | ESPELLAR_SSH_KEY | ssh-agent / ~/.ssh/config.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --pull-images) DO_PULL=1; shift ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done
[[ -n "$HOST" ]] || die "--host root@<ip> required (--help for usage)"

SSH_ARGS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
# $1 is a composed remote command — client-side expansion is the design.
# shellcheck disable=SC2029
vm() { ssh "${SSH_ARGS[@]}" "$HOST" "$1"; }
# Multi-line POSIX snippet on stdin -> remote busybox sh (avoids quoting hell).
# shellcheck disable=SC2029
vm_sh() { ssh "${SSH_ARGS[@]}" "$HOST" 'sh -s'; }

if [[ "$(uname -s)" == "Darwin" ]]; then
  SSH_AUTH_SOCK="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"
  export SSH_AUTH_SOCK
fi

# --- managed file payloads (built Mac-side, scp'd) ----------------------------
TMPDIR_LOCAL="$(mktemp -d /tmp/esellar-vm-prepare.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

cat > "$TMPDIR_LOCAL/registries.conf" <<'REGISTRIES'
# Managed by packages/kampodine/scripts/vm-prepare.sh — do not hand-edit.
# 127.0.0.1:5000 is the Mac-local registry reached over the ssh reverse
# tunnel (plain HTTP by design — hence insecure); docker.io serves public
# base/proxy images (kamal-proxy).
unqualified-search-registries = ["docker.io"]

[[registry]]
location = "127.0.0.1:5000"
insecure = true
REGISTRIES

cat > "$TMPDIR_LOCAL/60-esellar.conf" <<'SYSCTL'
# Managed by packages/kampodine/scripts/vm-prepare.sh — do not hand-edit.
# OpenRC contract: let unprivileged/container paths bind port 80
# (kamal-proxy publishes 80+443; belt-and-braces for a future rootless move).
net.ipv4.ip_unprivileged_port_start=80
SYSCTL

cat > "$TMPDIR_LOCAL/esellar-api" <<'INITD_API'
#!/sbin/openrc-run
# Managed by packages/kampodine/scripts/vm-prepare.sh — do not hand-edit.
# KEEP IN SYNC with ansible/roles/container-service/templates/esellar-api.initd.j2
# (rendered with role defaults): vm-prepare bootstraps a fresh VM BEFORE the
# first ansible converge; ansible owns the file afterwards (drift repair).
#
# THE app container: one image = web SPA + Hono API, same-origin. Alpine has no
# systemd (no quadlets, no podman restart policies) — supervise-daemon wraps
# the FOREGROUND `podman run`: if the container (or the podman run itself)
# dies, the WHOLE run restarts against the local :latest (no pull inside the
# run — restarts are offline-safe; the registry tunnel is down between deploys).
#
# Env: /etc/esellar/env (0600 root, written by kampodine deploy per deploy) is
# the single SECRETS source (podman --env-file reads KEY=VALUE lines directly).
# The five CLEAR vars (NODE_ENV, PORT, LIBSQL_TENANT_DIR, LIBSQL_API_MOUNT,
# STATIC_SPA_MOUNT) are owned HERE via -e — deploy filters them out of the env
# file; one source of truth per key. /data/tenants is the ONLY host data path
# (tenant sqlite files) — without the bind mount, tenant data would be
# container-ephemeral and lost on every restart.

name="esellar-api"
description="esellar API + SPA container (127.0.0.1:5000/esellar-api:latest on 8080)"

supervisor=supervise-daemon
command="/usr/bin/podman"
command_args="run --rm --name esellar-api --network kamal -p 8080:8080"
command_args="$command_args -v /data/tenants:/data/tenants"
command_args="$command_args -e NODE_ENV=production -e PORT=8080"
command_args="$command_args -e LIBSQL_TENANT_DIR=/data/tenants -e LIBSQL_API_MOUNT=1 -e STATIC_SPA_MOUNT=1"
command_args="$command_args --env-file /etc/esellar/env 127.0.0.1:5000/esellar-api:latest"

# Respawn forever (blue's restart=always precedent): a crash loop self-heals at
# the next deploy's restart; the 10s delay bounds log noise.
respawn_delay=10
respawn_max=0

# podman run's OWN stderr (missing image, name conflicts, netavark failures);
# container stdout/stderr go to `podman logs esellar-api`.
supervise_daemon_args="--stderr /var/log/esellar-api-service.log"

depend() {
	need net
	after esellar-datamount
}

start_pre() {
	# SIGKILLed runs leave the container name holding port 8080 (--rm only
	# cleans CLEAN exits) — sweep any leftover before the supervised run.
	podman container exists esellar-api 2>/dev/null && podman rm -f esellar-api >/dev/null 2>&1
	return 0
}

stop_post() {
	# supervise-daemon killed the podman client; make sure the container goes
	# down too (TERM -> graceful shutdown, then a tolerant sweep).
	podman stop --time 10 esellar-api >/dev/null 2>&1 || true
	podman rm -f --time 0 esellar-api >/dev/null 2>&1 || true
}
INITD_API

cat > "$TMPDIR_LOCAL/kamal-proxy" <<'INITD_PROXY'
#!/sbin/openrc-run
# Managed by packages/kampodine/scripts/vm-prepare.sh — do not hand-edit.
# KEEP IN SYNC with ansible/roles/container-service/templates/kamal-proxy.initd.j2
# (see the esellar-api header for the vm-prepare/ansible split).
#
# TLS edge (kamal-proxy, Let's Encrypt HTTP-01 on :80). Publishes 80+443; the
# LE certs + host->target registrations persist in the kamal-proxy-config named
# volume (mounted at kamal-proxy's config home) — the fresh ACME cert issued on
# the first deploy survives container recreation AND reboots. Start-fresh:
# nothing is carried from the retired blue VM. Target registration happens at
# deploy time (kampodine deploy: podman exec kamal-proxy kamal-proxy deploy
# esellar-api --host=$PROXY_HOST --target=esellar-api:8080 --tls
# --health-check-path=/api/auth/ok).

name="kamal-proxy"
description="kamal-proxy edge container (80/443, persistent cert/config volume)"

supervisor=supervise-daemon
command="/usr/bin/podman"
command_args="run --rm --name kamal-proxy --network kamal -p 80:80 -p 443:443 --cap-add NET_BIND_SERVICE"
command_args="$command_args -v kamal-proxy-config:/home/kamal-proxy/.config docker.io/basecamp/kamal-proxy:latest"

respawn_delay=10
respawn_max=0
supervise_daemon_args="--stderr /var/log/kamal-proxy-service.log"

depend() {
	need net
}

start_pre() {
	podman container exists kamal-proxy 2>/dev/null && podman rm -f kamal-proxy >/dev/null 2>&1
	return 0
}

stop_post() {
	podman stop --time 10 kamal-proxy >/dev/null 2>&1 || true
	podman rm -f --time 0 kamal-proxy >/dev/null 2>&1 || true
}
INITD_PROXY

cat > "$TMPDIR_LOCAL/esellar-anchor.sh" <<'ANCHOR_WATCHER'
#!/bin/sh
# KEEP IN SYNC with ansible/roles/container-service/files/esellar-anchor.sh
# (vm-prepare rendered-content convention: vm-prepare bootstraps a fresh VM
# BEFORE the first ansible converge; ansible owns the file afterwards).
#
# esellar-anchor.sh — guest half of the blue-green reserved-ip flip.
#
# OCI assigns the reserved PUBLIC ip to a SECONDARY private ip ("the anchor")
# on the instance VNIC, but this image has NO oracle-cloud-agent: nothing
# configures that private ip inside the guest, so packets to the reserved ip
# die until the address exists on the interface. `kampodine bluegreen flip` writes
# /etc/esellar/anchor.conf over ssh at flip time; this watcher polls it and
# runs `ip addr add` within one interval. The unit is enabled+started on every
# VM by default and is INERT without the conf — a VM that never flips never
# touches its addresses.
#
# CONF (written by the flip tooling, root-only dir):
#   ANCHOR_ADDR="10.0.0.14/24"   # anchor private ip + subnet prefix (required)
#   ANCHOR_IFACE="eth0"          # optional; empty/unset = default-route iface
#
# ADD-ONLY BY DESIGN: this script NEVER removes or flushes addresses (rollback
# cleanup is the flip tool's explicit ssh job). Idempotent: a present address
# is a no-op. Only state TRANSITIONS are logged (bounded log noise), to
# stdout — supervise-daemon tees it to /var/log/esellar-anchor.log.

CONF="/etc/esellar/anchor.conf"
INTERVAL="${ESPELLAR_ANCHOR_INTERVAL:-5}"
STATE="boot" # last logged transition (boot | idle | added | error)

log() { printf '%s esellar-anchor: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# supervise-daemon SIGTERMs on stop — die cleanly with the current tick.
trap 'exit 0' TERM INT

default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# Dotted-quad/prefix sanity gate before anything touches `ip addr add` — the
# conf is operator-tooling written, but sourcing it must never turn garbage
# into an `ip` invocation.
addr_wellformed() {
  case "$1" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*/*) return 0 ;;
    *) return 1 ;;
  esac
}

while :; do
  ANCHOR_ADDR=""
  ANCHOR_IFACE=""
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
  if [ -n "${ANCHOR_ADDR:-}" ] && addr_wellformed "$ANCHOR_ADDR"; then
    iface="${ANCHOR_IFACE:-$(default_iface)}"
    if [ -n "$iface" ] && ip -4 addr show dev "$iface" 2>/dev/null | grep -qF -- "$ANCHOR_ADDR"; then
      [ "$STATE" = added ] || { log "anchor $ANCHOR_ADDR present on $iface"; STATE=added; }
    elif [ -n "$iface" ] && ip addr add "$ANCHOR_ADDR" dev "$iface" 2>/dev/null; then
      log "anchor ADDED $ANCHOR_ADDR dev $iface"
      STATE=added
    else
      [ "$STATE" = error ] || { log "anchor add FAILED for $ANCHOR_ADDR (iface ${iface:-none})"; STATE=error; }
    fi
  else
    [ "$STATE" = idle ] || { log "no anchor conf (${CONF}) — idling"; STATE=idle; }
  fi
  sleep "$INTERVAL"
done
ANCHOR_WATCHER

cat > "$TMPDIR_LOCAL/esellar-anchor" <<'INITD_ANCHOR'
#!/sbin/openrc-run
# Managed by packages/kampodine/scripts/vm-prepare.sh — do not hand-edit.
# KEEP IN SYNC with ansible/roles/container-service/templates/esellar-anchor.initd.j2
# (rendered with role defaults — see the esellar-api header for the
# vm-prepare/ansible split).
#
# Guest half of the blue-green reserved-ip flip: supervise-daemon runs the
# esellar-anchor.sh watcher, which polls /etc/esellar/anchor.conf (written by
# `kampodine bluegreen flip` over ssh at flip time) and `ip addr add`s the
# anchor address when it appears. Started+enabled on EVERY vm by default and
# INERT without the conf: a VM that never flips never touches its addresses —
# unlike the container units, there is no esellar_start_containers gate.
# Transitions land in /var/log/esellar-anchor.log.

name="esellar-anchor"
description="Blue-green reserved-ip anchor address watcher (guest half of the flip)"

supervisor=supervise-daemon
command="/usr/local/sbin/esellar-anchor.sh"

# Respawn forever: the watcher itself never exits (trap TERM/INT -> exit 0 on
# stop), so a respawn means the script died abnormally — retry gently.
respawn_delay=5
respawn_max=0

supervise_daemon_args="--stdout /var/log/esellar-anchor.log --stderr /var/log/esellar-anchor.log"

depend() {
	need net
}
INITD_ANCHOR

cat > "$TMPDIR_LOCAL/sshd-hardening.conf" <<'SSHD_HARDENING'
# KEEP IN SYNC with ansible/roles/alpine-base/files/sshd-hardening.conf
# (byte-for-byte — ansible owns the file afterwards, rendered-content
# convention). Ensured BEFORE the hardening gate below: a fresh golden image
# may predate the baked drop-in and
# `sshd -T` reports passwordauthentication yes on a fresh VM.
# Keys-only management: this VM's ssh surface is the ONLY management path
# (cloud security lists keep 22 closed to the world; access via temporary
# scoped rule or bastion).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
# Reverse tunnel support for the Mac-local registry pull path
# (ssh -R 5000:... from kampodine deploy) rides the default AllowTcpForwarding.
GatewayPorts no
ClientAliveInterval 30
ClientAliveCountMax 6

# deploy registry tunnel rides a REMOTE forward (ssh -R 5000) — Alpine stock
# sshd_config ships AllowTcpForwarding no; remote-only keeps -L clients off.
AllowTcpForwarding yes
SSHD_HARDENING

# --- 0. connectivity ----------------------------------------------------------
say "waiting for ssh on ${HOST}…"
READY=0
for _ in $(seq 1 60); do
  if vm 'true' >/dev/null 2>&1; then READY=1; break; fi
  sleep 5
done
[[ $READY -eq 1 ]] || die "no ssh after 5 minutes (firewall 22 rule for your IP? baked ops key in the agent?)"

# --- 1. pre gates (fail BEFORE mutating anything) ------------------------------
say "gate: UEFI boot"
vm 'test -d /sys/firmware/efi' || die "not booted via UEFI (golden image is UEFI-only — wrong machine/image?)"

say "gate: OpenRC init + tooling"
vm '! readlink /proc/1/exe 2>/dev/null | grep -q systemd' || die "systemd is PID1 — this is not the Alpine golden image (start-fresh has NO systemd anywhere)"
# shellcheck disable=SC2016
vm 'command -v openrc >/dev/null && command -v rc-service >/dev/null && command -v rc-update >/dev/null && command -v supervise-daemon >/dev/null && rc-status --servicelist >/dev/null' \
  || die "OpenRC tooling missing or not operational (openrc/rc-service/rc-update/supervise-daemon, rc-status)"

say "sshd hardening: ensure drop-in + Include + restart (golden image predates the baked hardening — then the gate below holds)…"
# shellcheck disable=SC2016
vm 'grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config || sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config' \
  || die "could not ensure the sshd_config Include line"
vm 'mkdir -p /etc/ssh/sshd_config.d && chmod 700 /etc/ssh/sshd_config.d'
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/sshd-hardening.conf" "$HOST:/etc/ssh/sshd_config.d/99-esellar-hardening.conf"
vm 'rc-service sshd restart' || die "sshd restart failed after hardening ensure"

say "gate: sshd hardening effective"
vm 'sshd -T 2>/dev/null | grep -qi "^passwordauthentication no"' || die "sshd still allows passwords (hardening ensure failed?)"

# --- 2. apk repositories + podman stack ----------------------------------------
say "ensuring the v3.22 community repo (podman stack lives there)…"
# shellcheck disable=SC2016
vm_sh <<'REPOS' || die "community repo enable / apk update failed"
grep -Eq '^[^#].*/community' /etc/apk/repositories || {
  M=$(grep -E '^[^#].*/main$' /etc/apk/repositories | sed -n '1s#/main$##p')
  [ -n "$M" ] || M="https://dl-cdn.alpinelinux.org/alpine/v3.22"
  echo "$M/community" >> /etc/apk/repositories
}
apk update
REPOS
# shellcheck disable=SC2016
vm 'grep -Eq "^[^#].*/community" /etc/apk/repositories' || die "community repo could not be enabled (/etc/apk/repositories)"

say "installing the podman stack (idempotent)…"
# shellcheck disable=SC2016
vm_sh <<'APK' || die "podman stack install failed (apk output above)"
apk add --no-progress podman podman-docker crun catatonit netavark aardvark-dns fuse-overlayfs iptables
APK
# shellcheck disable=SC2016
vm_sh <<'PODSTACK_GATE' || die "podman stack install failed"
command -v podman >/dev/null
test -x /usr/libexec/podman/aardvark-dns
[ "$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null)" = netavark ]
PODSTACK_GATE

# cgroups: containers need a mounted controller tree (OCI boots without one;
# crun fails with "invalid file system type on /sys/fs/cgroup" otherwise) —
# enable the OpenRC cgroups service (mounts cgroup2) at boot and now.
vm 'rc-update show boot | grep -q cgroups || rc-update add cgroups boot' || die "rc-update cgroups failed"
vm 'rc-service cgroups status >/dev/null 2>&1 || rc-service cgroups start' || die "cgroups start failed"

# --- 3. /etc/esellar + managed config files ------------------------------------
say "creating /etc/esellar (env file lands here via kampodine deploy, 0600 root)…"
vm 'mkdir -p /etc/esellar && chmod 700 /etc/esellar'

say "writing /etc/containers/registries.conf (insecure 127.0.0.1:5000; search docker.io)…"
vm 'mkdir -p /etc/containers'
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/registries.conf" "$HOST:/etc/containers/registries.conf"

say "writing /etc/sysctl.d/60-esellar.conf + applying live…"
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/60-esellar.conf" "$HOST:/etc/sysctl.d/60-esellar.conf"
vm_sh <<'SYSCTL_APPLY' || die "sysctl ensure/apply failed"
rc-update show boot | grep -Eq '^[[:space:]]*sysctl[[:space:]]*\|' || rc-update add sysctl boot
sysctl -w net.ipv4.ip_unprivileged_port_start=80 > /dev/null
SYSCTL_APPLY

# --- 4. OpenRC services (canonical: ansible container-service templates) --------
say "ensuring the 'kamal' podman network (deploy's proxy re-point resolves esellar-api:8080 by network DNS)…"
# shellcheck disable=SC2016
vm 'podman network exists kamal 2>/dev/null || podman network create kamal' \
  || die "podman network create kamal failed"
say "installing OpenRC services esellar-api + kamal-proxy (supervise-daemon around podman run)…"
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/esellar-api" "$HOST:/etc/init.d/esellar-api"
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/kamal-proxy" "$HOST:/etc/init.d/kamal-proxy"
vm 'chmod 755 /etc/init.d/esellar-api /etc/init.d/kamal-proxy'

# --- 4b. esellar-anchor (blue-green flip guest half — watcher, no container) ----
# Ships on EVERY vm: started + enabled now, INERT until a flip writes
# /etc/esellar/anchor.conf over ssh (ansible container-service owns both files
# afterwards — drift repair keeps them in sync).
say "installing the esellar-anchor watcher service (blue-green flip guest half)…"
# /usr/local/sbin does NOT exist on the golden image (fresh Alpine ships no
# /usr/local hierarchy; the alpine-base role creates it — vm-prepare runs
# BEFORE any ansible)
vm 'mkdir -p /usr/local/sbin' || die "mkdir /usr/local/sbin failed"
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/esellar-anchor.sh" "$HOST:/usr/local/sbin/esellar-anchor.sh"
scp -q "${SSH_ARGS[@]}" "$TMPDIR_LOCAL/esellar-anchor" "$HOST:/etc/init.d/esellar-anchor"
vm 'chmod 755 /usr/local/sbin/esellar-anchor.sh /etc/init.d/esellar-anchor' || die "chmod esellar-anchor files failed"
vm 'sh -n /usr/local/sbin/esellar-anchor.sh' || die "esellar-anchor.sh does not parse (busybox sh)"
vm 'sh -n /etc/init.d/esellar-anchor' || die "/etc/init.d/esellar-anchor does not parse"
vm 'rc-update show default | grep -qE "^[[:space:]]*esellar-anchor[[:space:]]*\\|" || rc-update add esellar-anchor default' \
  || die "rc-update add esellar-anchor default failed"
vm 'rc-service esellar-anchor start' || die "rc-service esellar-anchor start failed"

for SVC in esellar-api kamal-proxy; do
  vm "rc-update show default | grep -qE '^[[:space:]]*${SVC}[[:space:]]*\\|' || rc-update add ${SVC} default" \
    || die "rc-update add $SVC default failed"
done

# Warn (never auto-restart) if a rewrite changed a unit of a RUNNING service —
# re-runs after a deploy must not bounce production.
# shellcheck disable=SC2016
vm_sh <<'UNIT_DRIFT' || true
for SVC in esellar-api kamal-proxy esellar-anchor; do
  if rc-service "$SVC" status > /dev/null 2>&1; then
    echo "RUNNING: $SVC (unit file was overwritten — rc-service $SVC restart to apply, on your call)"
  fi
done
UNIT_DRIFT

# --- 5. kamal-proxy up (first deploy execs into it to issue TLS) ----------------
say "pulling kamal-proxy image + starting the service…"
vm 'podman image exists docker.io/basecamp/kamal-proxy:latest || podman pull docker.io/basecamp/kamal-proxy:latest' \
  || die "kamal-proxy image pull failed (docker.io reachable from the VM?)"
vm 'rc-service kamal-proxy start' || die "rc-service kamal-proxy start failed"
PROXY_UP=0
for _ in $(seq 1 20); do
  # shellcheck disable=SC2016
  if vm 'podman ps --format "{{.Names}}" | grep -qx kamal-proxy' >/dev/null 2>&1; then PROXY_UP=1; break; fi
  sleep 3
done
[[ $PROXY_UP -eq 1 ]] || die "kamal-proxy container never came up (podman logs kamal-proxy; rc-service kamal-proxy status)"

# --- 6. optional: pre-pull the app image over the registry tunnel ---------------
if [[ $DO_PULL -eq 1 ]]; then
  say "pre-pulling the app image through the registry tunnel (fail BEFORE the first deploy)…"
  # busybox wget, NOT curl: the golden image ships no curl (ansible
  # installs it later; vm-prepare runs BEFORE any ansible)
  vm 'busybox wget -q -O /dev/null http://127.0.0.1:5000/v2/' || {
    pkill -f "ssh.*-R 5000" 2>/dev/null || true; sleep 1
    nohup ssh -R 5000:127.0.0.1:5000 -N -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes "$HOST" >/tmp/esellar-tunnel.log 2>&1 &
    sleep 3
  }
  vm 'busybox wget -q -O /dev/null http://127.0.0.1:5000/v2/' || die "registry tunnel did not come up (/tmp/esellar-tunnel.log)"
  vm 'podman pull --tls-verify=false 127.0.0.1:5000/esellar-api:latest' || die "app image pull failed"
else
  say "skipping app-image pre-pull (pass --pull-images, or let the first deploy pull)"
fi

# --- 7. converge esellar-api ONLY if a previous deploy left image + env ---------
# On a truly fresh VM neither exists — the FIRST DEPLOY provides both and
# starts the service. Re-runs of this script after a deploy heal drift.
say "esellar-api start check (needs image + /etc/esellar/env — first deploy provides both)…"
# shellcheck disable=SC2016
vm_sh <<'API_CONVERGE' || die "esellar-api start failed (image + env present — investigate: podman logs esellar-api)"
if [ -f /etc/esellar/env ] && podman image exists 127.0.0.1:5000/esellar-api:latest; then
  rc-service esellar-api start
  echo "esellar-api started (image + env present)"
else
  echo "esellar-api deferred: no image and/or /etc/esellar/env yet (normal on a fresh VM — first deploy handles it)"
fi
API_CONVERGE

# --- 8. post gates (readiness, fail-closed) -------------------------------------
say "gate: podman >= 4.9 + netavark backend"
# Remote expressions stay single-quoted deliberately (run on the VM).
# shellcheck disable=SC2016
vm 'V=$(podman --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+"); echo "$V" | awk -F. "{exit !(\$1>4 || (\$1==4 && \$2>=9))}"' \
  || die "podman too old (need >= 4.9 for netavark; got: $(vm 'podman --version' 2>/dev/null || echo '?'))"
vm 'podman info --format "{{.Host.NetworkBackend}}" | grep -qx netavark' || die "network backend is not netavark"

say "gate: sysctl effective"
vm 'sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null | grep -qx 80' || die "net.ipv4.ip_unprivileged_port_start is not 80"

say "gate: registries.conf effective"
vm 'grep -q "127.0.0.1:5000" /etc/containers/registries.conf && grep -q "insecure = true" /etc/containers/registries.conf && grep -q "docker.io" /etc/containers/registries.conf' \
  || die "registries.conf incomplete (127.0.0.1:5000 insecure + docker.io search)"

say "gate: services enabled in the default runlevel"
vm 'rc-update show default | grep -qE "^[[:space:]]*esellar-api[[:space:]]*\\|"' || die "esellar-api not in the default runlevel"
vm 'rc-update show default | grep -qE "^[[:space:]]*kamal-proxy[[:space:]]*\\|"' || die "kamal-proxy not in the default runlevel"
vm 'rc-service kamal-proxy status >/dev/null' || die "kamal-proxy service not started"

say "gate: esellar-anchor watcher running + INERT (no anchor conf on a fresh VM)"
vm 'rc-update show default | grep -qE "^[[:space:]]*esellar-anchor[[:space:]]*\\|"' || die "esellar-anchor not in the default runlevel"
vm 'rc-service esellar-anchor status >/dev/null' || die "esellar-anchor service not started"
vm '! test -e /etc/esellar/anchor.conf' || die "/etc/esellar/anchor.conf already exists on a fresh VM (wrong machine?)"
vm 'grep -q "no anchor conf" /var/log/esellar-anchor.log' \
  || die "esellar-anchor is started but never logged its idle transition (watcher loop not running?)"

# --- summary ---------------------------------------------------------------------
IP="${HOST#*@}"
SUGGESTED_PROXY_HOST="${IP//./-}.sslip.io"
say "PREPARED: $HOST passes all gates (OpenRC, no systemd anywhere)."
say "next — first deploy (fresh ACME TLS issued during it):"
say "  PROXY_HOST=$SUGGESTED_PROXY_HOST kampodine deploy --host $HOST"
say "  (DNS must point at $IP first — <ip-dashes>.sslip.io resolves automatically)"
