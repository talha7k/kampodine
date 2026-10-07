#!/usr/bin/env bash
# bluegreen.sh — reserved-public-IP blue/green pair management for OCI VMs.
#
# A deployment can start as ONE instance; this tool is the DORMANT future
# capability: when a second instance is warranted (zero-downtime upgrades,
# risky migrations), it becomes a two-instance pair sharing one RESERVED
# public IP — the internet-facing address never changes, the flip is one OCI
# API call, rollback is the same call reversed.
#
# Colors are instance display names: <app>-blue / <app>-green (defaults:
# esellar-blue / esellar-green).
# The reserved IP is derived from live OCI state — no local state file.
#
# Usage:
#   kampodine bluegreen status                  # pair view: instances, IP holder, health
#   kampodine bluegreen init                    # create the reserved public IP (dormant, unassigned)
#   kampodine bluegreen provision <color>       # launch the second instance (golden image; see below)
#   kampodine bluegreen flip --to <color>       # ACME-first health-gated flip (see below)
#   kampodine bluegreen rollback                # unassign to DORMANT + holder guest cleanup
#
# FLIP = ACME-FIRST:
#   1. health gate on the target's own IP
#   2. anchor.conf written on the TARGET guest over ssh — the esellar-anchor
#      watcher service (shipped by vm-prepare) configures the anchor private
#      address within one interval; flip waits for `ip addr` to show it
#   3. OCI assigns the reserved IP to the target's anchor (secondary private
#      ip — the primary holds the launch-time ephemeral and rejects a second public ip)
#   4. ACME on the TARGET's kamal-proxy for the reserved-IP sslip hostname
#      (`podman exec kamal-proxy kamal-proxy deploy --host=<raddr-dashes>
#      .sslip.io --tls`): HTTP-01 needs the hostname to already resolve to
#      the reserved ip AND route to the target — hence AFTER the assign, and
#      hence NOT a deploy-time cert (a deploy before the flip cannot issue
#      for the reserved hostname, and issuing on every deploy would burn LE
#      rate limits for VMs that never flip). kamal-proxy has no standalone
#      issue verb — `deploy` IS its registration+ACME path, the same
#      invocation `kampodine deploy` uses; certs persist in the
#      kamal-proxy-config volume. sslip.io sits on the public suffix list, so
#      the reserved-hostname quota is per-hostname.
#   5. verify https through the reserved ip (curl --resolve, valid cert for
#      the sslip name + /up 200) and the served sha — only then: FLIPPED.
#   Any post-assign failure auto-rolls back: the reserved ip goes to the
#   other color's EXISTING anchor (lookup-ONLY — rollback never creates target-side
#   artifacts) or, when none exists, back to UNASSIGNED/dormant; the failed
#   target's anchor.conf is removed and its anchor address deleted.
#
# ROLLBACK = back to dormant: holder cleanup (anchor.conf removal + address
# delete over ssh) then the OCI unassign (`--private-ip-id ""`). For a real
# pair where traffic must move to the other color, use `flip --to <other>`
# instead — it runs the same ACME-first sequence there.
#
# provision has TWO routes:
#   1. NATIVE  — a UEFI_64 esellar-alpine* custom image exists in the
#      compartment: launch it directly (the golden image boots as-is).
#   2. INJECT (provision-via-migrate) — OCI pins imported custom images to
#      firmware=BIOS and A1/Ampere is UEFI-only, but the template instance
#      itself runs Alpine on a boot volume
#      whose image metadata is the Ubuntu PLATFORM image: it was built by
#      platform-image launch + disk injection. With no UEFI custom image,
#      provision queries the template instance's LIVE image-id (never
#      hardcoded — proven A1-launchable, since the template runs on it),
#      launches from it with the ops ssh key, then streams the golden qcow2
#      onto the new instance's boot disk (qemu-img convert -> gzip | ssh
#      'gunzip | sudo dd', reboot, verify /etc/alpine-release). The instance
#      record keeps the platform image metadata — exactly like the template.
#
# Env: OCI_PROFILE (default esellar-api), OCI_COMPARTMENT (default esellar).
# Injection extras: ALPINE_QCOW2 (golden disk path), OPS_SSH_PUBKEY (ops
# public key for the platform-image launch), PLATFORM_SSH_USER (default
# ubuntu), INJECT_PROBE_SLEEP / INJECT_PROBE_TRIES (ssh wait tuning).
# Health checks SSH to each instance's OWN ephemeral IP (the app is checked on
# loopback; the reserved IP is checked over :80 with the prod Host header).
set -euo pipefail

PROFILE="${OCI_PROFILE:-esellar-api}"
COMPARTMENT_NAME="${OCI_COMPARTMENT:-esellar}"
APP_HOST_HEADER="${APP_HOST_HEADER:-app.example.com}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

say()  { printf '%s\n' "$*"; }
die()  { printf '✋ %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'Usage:\n'
  grep '^#   kampodine bluegreen' "$0" | sed 's/^#   //'
  cat <<'EOF'

Each sub-step has its own --help: status | init | provision | flip | rollback.
Env: OCI_PROFILE (default esellar-api), OCI_COMPARTMENT (default esellar).

Examples:
  kampodine bluegreen status
  kampodine bluegreen init
  kampodine bluegreen provision green
  kampodine bluegreen flip --to green
  kampodine bluegreen rollback
EOF
  exit 0
}

step_usage() {
  case "$1" in
    status)
      cat <<'EOF'
Usage:
  kampodine bluegreen status

Pair view: reserved IP + holder, both instances (ocid, ip, AD), per-color app
health. Read-only.

Examples:
  kampodine bluegreen status
EOF
      ;;
    init)
      cat <<'EOF'
Usage:
  kampodine bluegreen init

Create the DORMANT reserved public IP (unassigned — no instance attached).
Idempotent: exits 0 when the reserved IP already exists.

Examples:
  kampodine bluegreen init
EOF
      ;;
    provision)
      cat <<'EOF'
Usage:
  kampodine bluegreen provision <blue|green>

Launch the second instance from the golden image (native UEFI custom image,
or the INJECT route when none exists), then vm-prepare it.

Examples:
  kampodine bluegreen provision green
  kampodine vm-prepare --host root@<new-ip>   # after provision hands you the IP
EOF
      ;;
    flip)
      cat <<'EOF'
Usage:
  kampodine bluegreen flip --to <blue|green> [--force]

ACME-first health-gated cutover: health gate on the target, the guest anchor
watcher claims the reserved-IP half, OCI assigns, the cert issues on the
target, verify through the reserved IP — any post-assign failure auto-rolls
back.

Examples:
  kampodine bluegreen flip --to green
  kampodine bluegreen flip --to green --force
EOF
      ;;
    rollback)
      cat <<'EOF'
Usage:
  kampodine bluegreen rollback

Unassign the reserved IP back to DORMANT: holder guest cleanup (anchor.conf
removal + address delete) then the OCI unassign. To move traffic to the other
color of a real pair instead, use flip --to <other>.

Examples:
  kampodine bluegreen rollback
EOF
      ;;
  esac
  exit 0
}

compartment_ocid() {
  local ocid
  ocid="$(oci iam compartment list --all --profile "$PROFILE" \
    --query "data[?name=='$COMPARTMENT_NAME'].id | [0]" --raw-output 2>/dev/null || true)"
  [[ "$ocid" == ocid1.compartment* ]] || die "compartment '$COMPARTMENT_NAME' not found (profile $PROFILE)"
  printf '%s' "$ocid"
}

# instance_by_color <blue|green> -> "<ocid> <ephemeral_public_ip> <ad>" or empty
instance_by_color() {
  local comp="$1" color="$2" row
  row="$(oci compute instance list -c "$comp" --profile "$PROFILE" \
    --display-name "esellar-$color" --lifecycle-state RUNNING \
    --query 'sort_by(data, &"time-created")[-1] | ["id", "availability-domain"] | join('\'' '\'', @)' \
    --raw-output 2>/dev/null || true)"
  [[ -n "$row" ]] || return 0
  local iid ad
  read -r iid ad <<<"$row"
  local vnic pub
  vnic="$(oci compute vnic-attachment list -c "$comp" --profile "$PROFILE" \
    --instance-id "$iid" --query 'data[0]."vnic-id"' --raw-output 2>/dev/null || true)"
  [[ -n "$vnic" ]] || { printf '%s %s %s\n' "$iid" "" "$ad"; return 0; }
  pub="$(oci network vnic get --vnic-id "$vnic" --profile "$PROFILE" \
    --query 'data."public-ip"' --raw-output 2>/dev/null || true)"
  printf '%s %s %s\n' "$iid" "${pub:-}" "$ad"
}

# reserved_ip_ocid -> "<ocid> <address> <private_ip_id_or_->" (single reserved IP expected)
reserved_ip() {
  local comp="$1" row
  row="$(oci network public-ip list -c "$comp" --profile "$PROFILE" \
    --scope REGION --lifetime RESERVED --all \
    --query 'data[0] | ["id", "ip-address", "private-ip-id" || `-`] | join('\'' '\'', @)' \
    --raw-output 2>/dev/null || true)"
  printf '%s' "$row"
}

# primary_vnic_of <instance_ocid> -> primary VNIC ocid (vnic-attachment list
# REQUIRES the compartment flag — reverse of private-ip list, which rejects
# it; both pinned in the stub tests)
primary_vnic_of() {
  local iid="$1"
  oci compute vnic-attachment list -c "$(compartment_ocid)" --profile "$PROFILE" \
    --instance-id "$iid" --query 'data[0]."vnic-id"' --raw-output 2>/dev/null || true
}

# reserved_anchor_ip <vnic_ocid> -> private-ip ocid to anchor the reserved
# public ip on. OCI allows ONE public ip per private ip: the PRIMARY private
# ip holds the instance's launch-time EPHEMERAL public ip, so assigning the
# reserved there is a 409 Conflict ("already has a public IP"). The reserved anchors on a SECONDARY private ip instead: both
# colors keep their ephemeral address + reachability, the flip moves only
# the reserved ip between secondaries.
# existing_anchor_ip <vnic> -> the SECONDARY private-ip ocid or empty.
# LOOKUP-ONLY: auto-rollback/rollback resolve holders with this — they must
# never create artifacts on a color they are merely pointing traffic at.
existing_anchor_ip() {
  local vnic="$1"
  oci network private-ip list --profile "$PROFILE" --vnic-id "$vnic" \
    --query 'data[? "is-primary" == `false` ] | [0].id' --raw-output 2>/dev/null || true
}

# reserved_anchor_ip <vnic> -> the anchor ocid, creating it when absent (the
# flip TARGET is the only legitimate creation site).
reserved_anchor_ip() {
  local vnic="$1" sec
  sec="$(existing_anchor_ip "$vnic")"
  if [[ "$sec" == ocid1.privateip* ]]; then
    printf '%s' "$sec"
    return 0
  fi
  oci network private-ip create --profile "$PROFILE" --vnic-id "$vnic" \
    --display-name "esellar-reserved-anchor" \
    --query 'data.id' --raw-output 2>/dev/null
}

# Flip-time pacing (tests run with FLIP_POLL_SLEEP=0).
FLIP_POLL_SLEEP="${FLIP_POLL_SLEEP:-5}"
FLIP_ADDR_TRIES="${FLIP_ADDR_TRIES:-12}"   # guest watcher pickup: 12 x 5s = 60s
FLIP_ACME_TRIES="${FLIP_ACME_TRIES:-24}"   # LE HTTP-01: 24 x 5s = 120s

# Guest anchor protocol (the esellar-anchor watcher half lives in
# infra/alpine-host/ansible/roles/container-service/files/esellar-anchor.sh —
# both halves of the conf path must stay in sync: /etc/esellar/anchor.conf).
# Remote commands are composed client-side BY DESIGN (vm-prepare convention);
# the interpolated values are OCI-API derived and regex-gated at the call
# sites, never user input.

# shellcheck disable=SC2029
write_anchor_conf() {
  local ip="$1" addr="$2"
  ssh "${SSH_OPTS[@]}" "root@$ip" \
    "umask 077; mkdir -p /etc/esellar; printf 'ANCHOR_ADDR=%s\nANCHOR_IFACE=\n' '$addr' > /etc/esellar/anchor.conf && echo ANCHOR_CONF_WRITTEN"
}

# shellcheck disable=SC2029
anchor_addr_ready() {
  local ip="$1" addr="$2"
  ssh "${SSH_OPTS[@]}" "root@$ip" "ip -4 addr show | grep -qF -- '$addr'"
}

# read_anchor_conf_addr <ip> -> the guest's current ANCHOR_ADDR (with prefix)
# or empty. Quotes stripped — the conf is shell-sourceable by the watcher.
read_anchor_conf_addr() {
  local ip="$1" line addr
  line="$(ssh "${SSH_OPTS[@]}" "root@$ip" \
    'grep -h "^ANCHOR_ADDR=" /etc/esellar/anchor.conf 2>/dev/null | head -n 1' 2>/dev/null || true)"
  addr="${line#ANCHOR_ADDR=}"
  addr="${addr//\"/}"
  addr="${addr//\'/}"
  [[ "$addr" == */* ]] && printf '%s' "$addr"
}

# delete_guest_addr <ip> <addr> — the flip tool's explicit cleanup (the
# WATCHER is add-only by design; removal is always ours, after the conf is
# gone so it cannot be re-added).
# shellcheck disable=SC2029
delete_guest_addr() {
  local ip="$1" addr="$2"
  ssh "${SSH_OPTS[@]}" "root@$ip" \
    "iface=\$(ip -4 route show default 2>/dev/null | awk '{print \$5; exit}'); [ -n \"\$iface\" ] && ip addr del '$addr' dev \"\$iface\" 2>/dev/null; true" \
    >/dev/null 2>&1 || true
}

# cleanup_target_anchor <ip> <addr_with_prefix> — conf removal + address
# deletion. The watcher may have sourced the conf just before removal and
# re-added the address once; retry the delete across one watcher interval.
cleanup_target_anchor() {
  local ip="$1" addr="$2" i
  ssh "${SSH_OPTS[@]}" "root@$ip" "rm -f /etc/esellar/anchor.conf" >/dev/null 2>&1 || true
  for ((i = 1; i <= 3; i++)); do
    delete_guest_addr "$ip" "$addr"
    anchor_addr_ready "$ip" "$addr" >/dev/null 2>&1 || return 0
    sleep "$((FLIP_POLL_SLEEP * 2))"
  done
  say "warning: guest anchor address $addr still present on $ip after cleanup (watcher resurrection?) — inert once the reserved ip moves, verify before reuse" >&2
}

# flip_failure_rollback <failed_color> <other_color> <comp> <reserved_ocid> <target_ip> <target_addr>
# Post-assign failure path: reassign the reserved ip to the other color's
# EXISTING anchor (lookup-ONLY — auto-rollback must never mint artifacts on
# the holder we are failing away from), else unassign to dormant; then clean
# the failed target's guest state.
flip_failure_rollback() {
  local to="$1" ob="$2" comp="$3" rocid="$4" tpub="$5" taddr="$6"
  local recovered=0 brow bnic bpip
  say "post-assign failure — auto-rollback" >&2
  brow="$(instance_by_color "$comp" "$ob")"
  if [[ -n "$brow" ]]; then
    bnic="$(primary_vnic_of "$(cut -d' ' -f1 <<<"$brow")")"
    bpip=""
    [[ -n "$bnic" ]] && bpip="$(existing_anchor_ip "$bnic")"
    if [[ "$bpip" == ocid1.privateip* ]]; then
      if oci network public-ip update --public-ip-id "$rocid" --profile "$PROFILE" \
        --private-ip-id "$bpip" --force >/dev/null 2>&1; then
        say "rolled back to esellar-$ob (existing anchor $bpip)" >&2
        recovered=1
      fi
    fi
  fi
  if (( ! recovered )); then
    if oci network public-ip update --public-ip-id "$rocid" --profile "$PROFILE" \
      --private-ip-id "" --force --wait-for-state AVAILABLE >/dev/null 2>&1; then
      say "reserved ip UNASSIGNED (dormant) — no existing anchor on esellar-$ob" >&2
    else
      cleanup_target_anchor "$tpub" "$taddr"
      die "AUTO-ROLLBACK FAILED — reserved ip state unknown; flip manually via console: $rocid"
    fi
  fi
  cleanup_target_anchor "$tpub" "$taddr"
  say "esellar-$to cleaned (anchor.conf removed, anchor address deleted) — investigate before retrying" >&2
}

# instance_healthy <ephemeral_ip> -> ssh + loopback app check.
# busybox wget, NOT curl: the golden image is deliberately minimal (ssh +
# OpenRC + busybox) and ships no curl (a curl-based gate reports
# "unhealthy" for a healthy instance because curl is absent).
instance_healthy() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  ssh "${SSH_OPTS[@]}" "root@$ip" \
    "rc-service esellar-api status >/dev/null 2>&1 && busybox wget -q -O /dev/null http://127.0.0.1:8080/up" 2>/dev/null
}

# instance_wait_running <iid> — poll lifecycle-state to RUNNING. The OCI CLI's
# `instance get` has NO --wait-for-state option (CLI 3.94.1: "No such
# option"), so poll.
# Dies on the terminal-bad states; everything else (PROVISIONING, STARTING…)
# keeps the loop going.
instance_wait_running() {
  local iid="$1" sleep_s="${INJECT_PROBE_SLEEP:-5}" tries="${WAIT_RUNNING_TRIES:-120}"
  local state="" i
  for ((i = 1; i <= tries; i++)); do
    state="$(oci compute instance get --instance-id "$iid" --profile "$PROFILE" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    case "$state" in
      RUNNING) return 0 ;;
      FAILED | TERMINATED | TERMINATING) die "esellar instance reached $state — nothing to inject, check the console" ;;
    esac
    sleep "$sleep_s"
  done
  die "instance never reached RUNNING (last state: ${state:-unknown}) after $((tries * 10))s"
}

# inject_alpine <color> <ip> <qcow2> — provision-via-migrate: stream the golden
# Alpine disk onto a RUNNING platform-image instance's boot volume. The disk
# write that built green: qcow2 -> raw locally, gzip | ssh 'gunzip | sudo dd'
# over the ssh-detected boot disk (lsblk PKNAME of the / mount — never
# hardcoded), conv=fsync, `reboot -f` (the fs it would unmount is gone), then
# verify Alpine answers on ssh. Instance + boot-volume image metadata stay the
# platform image — exactly like green.
inject_alpine() {
  local color="$1" ip="$2" qcow2="$3"
  local probe_sleep="${INJECT_PROBE_SLEEP:-5}" probe_tries="${INJECT_PROBE_TRIES:-60}"
  local ruser="${PLATFORM_SSH_USER:-ubuntu}" rel="" raw kh
  # Dedicated throwaway known-hosts for the WHOLE injection phase: the same
  # IP runs sshd on TWO different host keys (Ubuntu platform first boot ->
  # injected Alpine first boot). accept-new takes the first, then refuses
  # the CHANGED key after the reboot — the user's known_hosts would wedge
  # the Alpine verify forever. The scrub below
  # clears the phase file between the two boots; the user's file is never
  # touched.
  kh="$(mktemp "${TMPDIR:-/tmp}/esellar-inject-kh.XXXXXX")"
  iss() { ssh -o UserKnownHostsFile="$kh" "${SSH_OPTS[@]}" "$@"; }
  say "inject: waiting for ssh (${ruser}@${ip}, platform-image first boot)…"
  ssh_wait_probe() { iss "${ruser}@${ip}" true; }
  local i
  for ((i = 1; i <= probe_tries; i++)); do
    ssh_wait_probe >/dev/null 2>&1 && break
    [[ "$i" == "$probe_tries" ]] && die "ssh never came up on ${ip} (${ruser}) — check the instance console connection"
    sleep "$probe_sleep"
  done
  raw="$(mktemp "${TMPDIR:-/tmp}/esellar-inject-raw.XXXXXX")"
  say "inject: converting ${qcow2} -> raw…"
  qemu-img convert -O raw "$qcow2" "$raw"
  say "inject: streaming golden disk -> ${ip} boot volume (gunzip | dd, conv=fsync)…"
  if ! gzip -c "$raw" | iss "${ruser}@${ip}" \
    'set -eu; DISK="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")"; [ -n "$DISK" ] || exit 3; echo "[inject] writing /dev/$DISK"; gunzip -c | sudo dd of="/dev/$DISK" bs=4M conv=fsync status=progress'; then
    rm -f "$raw" "$kh"
    die "disk stream to ${ip} failed — instance left UNBOOTABLE-ish (platform image partially overwritten): terminate it, do NOT flip to ${color}"
  fi
  rm -f "$raw"
  # ClientAlive keepalives on the reboot call: reboot -f kills the platform
  # sshd WITHOUT closing the TCP session, and ConnectTimeout only bounds
  # connection ESTABLISHMENT — a wedged session hangs the whole provisioner
  # (the guest is long up when the client gives up).
  # ClientAliveCountMax x Interval bounds a dead session to ~15s.
  say "inject: rebooting into the injected disk (reboot -f — the old fs is gone)…"
  # Surface the reboot failure: a `|| true` here once false-INJECTED — the
  # wedged (un-rebooted) guest kept answering
  # ssh and the probe below accepted its banner as "Alpine boots". The
  # reboot must SUCCEED for the inject to be real (the disk was replaced).
  if ! iss -o ClientAliveInterval=5 -o ClientAliveCountMax=3 "${ruser}@${ip}" 'sudo reboot -f' >/dev/null 2>&1; then
    die "inject: reboot -f FAILED on ${ip} — the injection did not take (terminate, do NOT flip to ${color})"
  fi
  # the injected Alpine boots a NEW host key under the SAME ip — scrub the
  # phase file so the probes below see it as a fresh accept-new
  ssh-keygen -R "$ip" -f "$kh" >/dev/null 2>&1 || true
  say "inject: waiting for Alpine ssh (root@${ip})…"
  rel=""
  for ((i = 1; i <= probe_tries; i++)); do
    rel="$(iss "root@${ip}" 'cat /etc/alpine-release' 2>/dev/null || true)"
    # Verify the RELEASE STRING, not non-empty output: a non-empty check
    # false-INJECTS when the un-rebooted platform guest's ssh banner satisfies
    # a non-empty check. /etc/alpine-release only exists on a real Alpine
    # boot and reads 3.x for every image we ship.
    if [[ "$rel" =~ ^3\.[0-9]+\.[0-9]+ ]]; then break; fi
    rel=""
    sleep "$probe_sleep"
  done
  rm -f "$kh"
  [[ -n "$rel" ]] || die "injection streamed but no ALPINE 3.x ssh on ${ip} after reboot (got: '${rel:-nothing}') — check the serial console; terminate, do NOT flip to ${color}"
  say "INJECTED esellar-$color: Alpine ${rel} boots on ${ip} (instance image metadata stays the platform image — like green)"
  say "next: kampodine vm-prepare --host root@${ip} -> kampodine deploy --host root@${ip}"
  say "then 'bluegreen.sh flip --to ${color}' (health-gated) once its app checks green."
}

cmd="${1:-}"
# Any -h/--help in the args answers with usage for that sub-step (exit 0) —
# before any validation or OCI call, so help is always hermetic.
for help_arg in "$@"; do
  case "$help_arg" in
    -h|--help)
      case "$cmd" in
        status|init|provision|flip|rollback) step_usage "$cmd" ;;
        *) usage ;;
      esac
      ;;
  esac
done
case "$cmd" in
  status)
    comp="$(compartment_ocid)"
    rp="$(reserved_ip "$comp")"
    say "== esellar blue/green pair (compartment $COMPARTMENT_NAME) =="
    if [[ -n "$rp" ]]; then
      read -r rocid raddr rholder <<<"$rp"
      say "reserved IP : $raddr ($rocid)"
      if [[ "$rholder" == "-" ]]; then say "assigned to : UNASSIGNED (dormant — flip will attach)"; else say "assigned to : $rholder"; fi
    else
      say "reserved IP : NONE (run 'kampodine bluegreen init')"
    fi
    for color in blue green; do
      row="$(instance_by_color "$comp" "$color")" || true
      if [[ -n "$row" ]]; then
        read -r iid pub ad <<<"$row"
        if instance_healthy "$pub"; then verdict=HEALTHY; else verdict=UNHEALTHY/unreachable; fi
        say "esellar-$color : $iid  ip=${pub:-none}  ad=${ad:-?}  app=$verdict"
      else
        say "esellar-$color : not provisioned"
      fi
    done
    ;;

  init)
    comp="$(compartment_ocid)"
    rp="$(reserved_ip "$comp")"
    if [[ -n "$rp" ]]; then
      read -r _ raddr _ <<<"$rp"
      say "reserved IP already exists: $raddr — nothing to do"
      exit 0
    fi
    addr="$(oci network public-ip create -c "$comp" --profile "$PROFILE" \
      --lifetime RESERVED --display-name esellar-active \
      --query 'data."ip-address"' --raw-output)"
    say "created DORMANT reserved IP: $addr (unassigned — no instance attached)"
    say "Point DNS/SSLIP at this address when the pair goes active."
    ;;

  provision)
    shift
    color="${1:-}"
    [[ "$color" == blue || "$color" == green ]] || die "usage: kampodine bluegreen provision <blue|green>"
    comp="$(compartment_ocid)"
    instance_by_color "$comp" "$color" | grep -q . && die "esellar-$color already RUNNING"
    # base: the OTHER color's AD + subnet (same fault domain layout), golden image
    other=green; [[ "$color" == green ]] && other=blue
    orow="$(instance_by_color "$comp" "$other")"
    [[ -n "$orow" ]] || die "esellar-$other not RUNNING — need its AD/subnet as the pair template"
    # instance_by_color rows are "<ocid> <ephemeral_public_ip> <ad>" — field 2
    # is the IP, the AD is field 3 (launching with the IP as AD fails).
    read -r oiid _ oad <<<"$orow"
    subnet="$(oci compute vnic-attachment list -c "$comp" --profile "$PROFILE" \
      --instance-id "$oiid" --query 'data[0]."subnet-id"' --raw-output)"

    # Route selection. NATIVE only with a UEFI_64 esellar-alpine* custom image:
    # OCI pins IMPORTED images to firmware=BIOS and A1 is UEFI-only, so a BIOS
    # verdict means the import would die at launch (Shape ... is not valid for
    # image) — skip it. Otherwise take the template's LIVE image-id from its
    # instance record and inject the golden disk (provision-via-migrate).
    mode="" image=""
    custom="$(oci compute image list -c "$comp" --profile "$PROFILE" --all --sort-by TIMECREATED \
      --query "data[?\"display-name\" != null && starts_with(\"display-name\", 'esellar-alpine')] | [0].id" \
      --raw-output 2>/dev/null || true)"
    if [[ "$custom" == ocid1.image* ]]; then
      fw="$(oci compute image get --image-id "$custom" --profile "$PROFILE" \
        --query 'data."launch-options"."firmware"' --raw-output 2>/dev/null || true)"
      if [[ "$fw" == "UEFI_64" ]]; then
        image="$custom" mode="native"
      else
        say "note: newest esellar-alpine* custom image is firmware=${fw:-unknown} — A1 rejects BIOS-pinned imports, skipping to the platform-image + injection route"
      fi
    fi
    if [[ -z "$image" ]]; then
      image="$(oci compute instance get --instance-id "$oiid" --profile "$PROFILE" \
        --query 'data."image-id"' --raw-output 2>/dev/null || true)"
      [[ "$image" == ocid1.image* ]] || die "template instance has no resolvable image-id — cannot launch or inject"
      mode="inject"
      qcow2="${ALPINE_QCOW2:-${REPO_ROOT}/infra/alpine-host/build/esellar-alpine-3.22.6-aarch64.qcow2}"
      [[ -f "$qcow2" ]] || die "golden qcow2 not found: $qcow2 (build via packer, or set ALPINE_QCOW2)"
      command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found in PATH (brew install qemu) — required for the qcow2 -> raw conversion"
      # ops ssh public key for the platform-image first boot. OPS_SSH_PUBKEY
      # (explicit file) wins; else derive from the ssh AGENT (ssh-add -L) —
      # the agent key is what every kampodine ssh + the golden image's baked
      # ops key expect; ~/.ssh/id_ed25519.pub can be a stale personal key
      # (launching with a stale pub = unreachable instance).
      if [[ -n "${OPS_SSH_PUBKEY:-}" ]]; then
        [[ -f "$OPS_SSH_PUBKEY" ]] || die "ops ssh public key not found: $OPS_SSH_PUBKEY (set OPS_SSH_PUBKEY or load the key into the agent)"
        keyfile="$OPS_SSH_PUBKEY"
      else
        agent_keys="$(ssh-add -L 2>/dev/null | grep -v '\.pub$' || true)"
        [[ -n "$agent_keys" ]] || die "no ssh key available: OPS_SSH_PUBKEY unset and ssh-add lists no keys (ssh-add ~/.ssh/id_ed25519-esellar, or set OPS_SSH_PUBKEY)"
        keyfile="$(mktemp "${TMPDIR:-/tmp}/esellar-ops-pubkey.XXXXXX")"
        printf '%s\n' "$agent_keys" > "$keyfile"
        chmod 600 "$keyfile"
      fi
    fi

    say "launching esellar-$color: image=${image:0:60}… ad=$oad subnet=${subnet:0:60}… mode=$mode"
    # NOTE: --profile stays ON the launch line (script-gates static scan reads
    # the invocation line, not array contents).
    launch_args=(-c "$comp" --availability-domain "$oad" --subnet-id "$subnet"
      --image-id "$image" --shape VM.Standard.A1.Flex --shape-config '{"ocpus":2,"memoryInGBs":12}'
      --assign-public-ip true --display-name "esellar-$color")
    [[ "$mode" == "inject" ]] && launch_args+=(--ssh-authorized-keys-file "$keyfile")
    iid="$(oci compute instance launch "${launch_args[@]}" --profile "$PROFILE" --query 'data.id' --raw-output)"
    say "LAUNCHED esellar-$color: $iid"
    if [[ "$mode" == "native" ]]; then
      say "next: wait RUNNING -> ssh in -> kampodine vm-prepare -> kampodine deploy --host root@<ephemeral-ip>"
      say "then 'bluegreen.sh flip --to $color' (health-gated) once its app checks green."
      exit 0
    fi
    say "waiting for RUNNING (inject mode)…"
    instance_wait_running "$iid"
    pubip="$(instance_by_color "$comp" "$color" | cut -d' ' -f2)"
    [[ -n "$pubip" ]] || die "no ephemeral public ip on $iid yet — re-check with 'bluegreen status' and run the injection manually"
    inject_alpine "$color" "$pubip" "$qcow2"
    ;;

  flip)
    shift || true
    to=""; force=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to) to="$2"; shift 2 ;;
        --force) force=1; shift ;;
        *) die "unknown flip flag: $1" ;;
      esac
    done
    [[ "$to" == blue || "$to" == green ]] || { say "usage: kampodine bluegreen flip --to <blue|green> [--force]"; say "(rollback = unassign to dormant: 'kampodine bluegreen rollback')"; exit 2; }
    comp="$(compartment_ocid)"
    rp="$(reserved_ip "$comp")"
    [[ -n "$rp" ]] || die "no reserved IP (run 'kampodine bluegreen init' first)"
    read -r rocid raddr _ <<<"$rp"
    rhost="${raddr//./-}.sslip.io"
    trow="$(instance_by_color "$comp" "$to")"
    [[ -n "$trow" ]] || die "esellar-$to is not RUNNING — nothing to flip to"
    read -r tiid tpub _ <<<"$trow"
    tvnic="$(primary_vnic_of "$tiid")"
    [[ -n "$tvnic" ]] || die "no primary VNIC on esellar-$to"
    tpip="$(reserved_anchor_ip "$tvnic")"
    [[ "$tpip" == ocid1.privateip* ]] || die "could not resolve/create the reserved-anchor secondary private ip on esellar-$to"
    if instance_healthy "$tpub"; then
      say "target health: esellar-$to app HEALTHY on its own IP"
    else
      (( force )) || die "esellar-$to app UNHEALTHY — refusing flip (override: --force)"
      say "target health: UNHEALTHY — flipping anyway (--force)"
    fi

    # ACME-FIRST: HTTP-01 for the reserved-IP sslip name can only complete
    # once the hostname resolves to the reserved ip AND routes to the target,
    # so the guest anchor address goes FIRST, then the assign, then the cert.
    ob=green; [[ "$to" == green ]] && ob=blue
    say "flip[1/4]: anchor conf -> esellar-$to guest ($tpub), watcher configures the address"
    tsubnet="$(oci compute vnic-attachment list -c "$comp" --profile "$PROFILE" \
      --instance-id "$tiid" --query 'data[0]."subnet-id"' --raw-output 2>/dev/null || true)"
    [[ "$tsubnet" == ocid1.subnet* ]] || die "could not resolve esellar-$to's subnet id"
    tcidr="$(oci network subnet get --subnet-id "$tsubnet" --profile "$PROFILE" \
      --query 'data."cidr-block"' --raw-output 2>/dev/null || true)"
    [[ "$tcidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "could not resolve esellar-$to's subnet cidr (got: ${tcidr:-none})"
    tanchor_addr="$(oci network private-ip get --private-ip-id "$tpip" --profile "$PROFILE" \
      --query 'data."ip-address"' --raw-output 2>/dev/null || true)"
    [[ "$tanchor_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not resolve the anchor private address on esellar-$to"
    taddr_cidr="${tanchor_addr}/${tcidr##*/}"
    if ! write_anchor_conf "$tpub" "$taddr_cidr" >/dev/null 2>&1; then
      die "anchor.conf write failed on esellar-$to ($tpub) — nothing mutated, flip aborted"
    fi
    addr_ok=0
    for ((i = 1; i <= FLIP_ADDR_TRIES; i++)); do
      if anchor_addr_ready "$tpub" "$taddr_cidr" >/dev/null 2>&1; then addr_ok=1; break; fi
      sleep "$FLIP_POLL_SLEEP"
    done
    if (( ! addr_ok )); then
      cleanup_target_anchor "$tpub" "$taddr_cidr"
      die "guest watcher never configured $taddr_cidr on esellar-$to — is rc-service esellar-anchor running? (conf removed, NOTHING mutated)"
    fi
    say "flip[2/4]: guest answers on $taddr_cidr — reserved $raddr -> esellar-$to (anchor $tpip)"
    oci network public-ip update --public-ip-id "$rocid" --profile "$PROFILE" \
      --private-ip-id "$tpip" --force --wait-for-state ASSIGNED >/dev/null \
      || { cleanup_target_anchor "$tpub" "$taddr_cidr"; die "OCI flip call failed — guest conf removed; run 'kampodine bluegreen status'"; }
    say "flip[3/4]: reserved IP ASSIGNED — registering $rhost on esellar-$to's kamal-proxy (ACME HTTP-01 through the reserved ip)…"
    if ! ssh "${SSH_OPTS[@]}" "root@$tpub" \
      "podman exec kamal-proxy kamal-proxy deploy esellar-api --host=$rhost --target=esellar-api:8080 --tls --health-check-path=/api/auth/ok"; then
      flip_failure_rollback "$to" "$ob" "$comp" "$rocid" "$tpub" "$taddr_cidr"
      exit 1
    fi
    acme_ok=0
    for ((i = 1; i <= FLIP_ACME_TRIES; i++)); do
      if curl -sf -m 8 --resolve "$rhost:443:$raddr" "https://$rhost/up"; then acme_ok=1; break; fi
      sleep "$FLIP_POLL_SLEEP"
    done
    if (( ! acme_ok )); then
      say "https://$rhost/ never answered with a VALID cert through $raddr (rate limits? HTTP-01 unreachable?)" >&2
      flip_failure_rollback "$to" "$ob" "$comp" "$rocid" "$tpub" "$taddr_cidr"
      exit 1
    fi
    served="$(curl -s -m 8 --resolve "$rhost:443:$raddr" "https://$rhost/api/auth/ok" || true)"
    say "flip[4/4]: cert for $rhost VALID + serving through $raddr"
    say "FLIPPED: https://$raddr/ (https://$rhost/) now serves from esellar-$to"
    say "served /api/auth/ok: ${served:-<no body>}"
    ;;

  rollback)
    # DORMANT rollback: holder guest cleanup
    # (anchor.conf removal + anchor address delete — the flip tool's explicit
    # job; the esellar-anchor watcher is add-only) then the OCI unassign
    # (documented CLI semantics: an empty --private-ip-id unassigns). For a
    # real pair where traffic must land on the other color, use
    # 'flip --to <other>' — it runs the full ACME-first sequence there.
    comp="$(compartment_ocid)"
    rp="$(reserved_ip "$comp")"
    [[ -n "$rp" ]] || die "no reserved IP"
    read -r rocid raddr rholder <<<"$rp"
    if [[ -z "$rholder" || "$rholder" == "-" ]]; then
      say "reserved $raddr already UNASSIGNED (dormant) — nothing to roll back"
      exit 0
    fi
    # resolve the holder color by matching its anchor (LOOKUP-ONLY)
    holder_color="" holder_ip=""
    for color in blue green; do
      crow="$(instance_by_color "$comp" "$color")"
      [[ -n "$crow" ]] || continue
      cnic="$(primary_vnic_of "$(cut -d' ' -f1 <<<"$crow")")"
      capip=""
      [[ -n "$cnic" ]] && capip="$(existing_anchor_ip "$cnic")"
      if [[ "$capip" == "$rholder" ]]; then
        holder_color="$color"
        holder_ip="$(cut -d' ' -f2 <<<"$crow")"
        break
      fi
    done
    if [[ -z "$holder_color" ]]; then
      say "warning: reserved $raddr held by an anchor of neither RUNNING color (terminated instance?) — unassigning without guest cleanup"
    else
      say "current holder: esellar-$holder_color ($holder_ip) — cleaning the guest anchor, then unassigning"
      conf_addr="$(read_anchor_conf_addr "$holder_ip")"
      cleanup_target_anchor "$holder_ip" "$conf_addr"
      say "esellar-$holder_color guest cleaned (anchor.conf removed${conf_addr:+, address $conf_addr deleted})"
    fi
    say "unassigning reserved $raddr (-> dormant)…"
    oci network public-ip update --public-ip-id "$rocid" --profile "$PROFILE" \
      --private-ip-id "" --force --wait-for-state AVAILABLE >/dev/null \
      || die "unassign failed — check 'kampodine bluegreen status' and the console"
    say "ROLLED BACK: reserved $raddr UNASSIGNED (dormant)"
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
