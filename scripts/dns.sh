#!/usr/bin/env bash
# dns.sh — OCI DNS record management: the single surface for the coming DNS
# era (today the stack is raw IP + sslip.io; when real zones land, records
# are managed here, never by hand in the console).
#
# AUTH RULE (hard): the `oci` CLI's own auth ONLY — its config file
# (~/.oci/config, selected via --profile) or instance principal. kampodine
# NEVER accepts, stores, or logs credential material: no key flags, no
# credential env vars, nothing token-shaped in args or output. The OCI config
# file stays the single credential store.
#
# Types are pinned to A | AAAA | CNAME. `add` merges into the existing RRSet
# (round-robin records survive); `rm` filters it; both are idempotence-aware.
#
# Zone/compartment: OCI_PROFILE (default esellar-api), OCI_COMPARTMENT
# (default esellar). Zone defaults to the compartment's ONLY zone; pass
# --zone <id-or-name> when several exist.
#
# Usage:
#   kampodine dns records [--zone <id-or-name>]                  # list records: domain / type / ttl / value
#   kampodine dns add --name <label> --type A|AAAA|CNAME --value <target> [--ttl 300]
#   kampodine dns rm --name <label> --type <A|AAAA|CNAME> --value <target>
#   (all: optional --zone <id-or-name>; --instance-principal for instance auth)
set -euo pipefail

PROFILE="${OCI_PROFILE:-esellar-api}"
COMPARTMENT_NAME="${OCI_COMPARTMENT:-esellar}"
AUTH_ARGS=()

say() { printf '\033[1;34m[dns]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[dns] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  local code="${1:-0}"
  printf 'Usage:\n'
  grep '^#   kampodine dns' "$0" | sed 's/^#   //'
  cat <<'EOF'

Auth is the oci CLI's own — its config file (--profile) or instance
principal. kampodine never accepts, stores, or logs credential material.
Zone/compartment: OCI_PROFILE (default esellar-api), OCI_COMPARTMENT (default
esellar). Types are pinned to A | AAAA | CNAME; ttl range 60..172800.

Examples:
  kampodine dns records
  kampodine dns records --zone esellar.example.com
  kampodine dns add --name app --type A --value 203.0.113.10 --zone esellar.example.com
  kampodine dns add --name www --type CNAME --value app.example.com --ttl 3600
  kampodine dns rm --name app --type A --value 203.0.113.10
EOF
  exit "$code"
}

# --- pure validators (no side effects, run before any provider call) ----------
is_ipv4() {
  local ip="$1" i octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for i in 1 2 3 4; do
    octet="${BASH_REMATCH[i]}"
    [[ $((10#$octet)) -le 255 ]] || return 1
  done
  return 0
}

is_ipv6() {
  local ip="$1" colons
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ -n "${ip//:/}" ]] || return 1        # at least one hex digit
  [[ "$ip" != *":::"* ]] || return 1      # no triple colons
  colons="${ip//[0-9A-Fa-f]/}"
  [[ ${#colons} -le 7 ]] || return 1      # at most 8 groups
  [[ "${ip/::/}" != *"::"* ]] || return 1 # at most one "::"
  return 0
}

is_hostname() {
  [[ "$1" =~ ^([A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.)+[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.?$ ]]
}

# --- dispatch -----------------------------------------------------------------
CMD="${1:-}"
case "$CMD" in
  records|add|rm) shift ;;
  -h|--help|help) usage 0 ;;
  "") usage 2 ;;
  *)
    printf 'kampodine dns: unknown subcommand: %s\n\n' "$CMD" >&2
    usage 2
    ;;
esac

ZONE_ARG=""
NAME=""
RTYPE=""
VALUE=""
TTL="300"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone) ZONE_ARG="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --type) RTYPE="$2"; shift 2 ;;
    --value) VALUE="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --instance-principal) AUTH_ARGS=(--auth instance_principal); shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done

need_provider() {
  command -v oci >/dev/null 2>&1 \
    || die "oci CLI not found — brew install oci-cli (https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm), then: oci setup config"
  command -v jq >/dev/null 2>&1 \
    || die "jq not found — brew install jq (dns.sh uses it for RRSet surgery)"
}

compartment_ocid() {
  local ocid
  ocid="$(oci iam compartment list --all --profile "$PROFILE" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    --query "data[?name=='$COMPARTMENT_NAME'].id | [0]" --raw-output 2>/dev/null || true)"
  [[ "$ocid" == ocid1.compartment* ]] || die "compartment '$COMPARTMENT_NAME' not found (profile $PROFILE)"
  printf '%s' "$ocid"
}

# resolve_zone -> ZONE_NAME + ZONE_ID (explicit --zone wins; otherwise the
# compartment must hold exactly one zone — never guess between several).
resolve_zone() {
  local zj zl count
  COMPARTMENT_OCID="$(compartment_ocid)"
  if [[ -n "$ZONE_ARG" ]]; then
    if [[ "$ZONE_ARG" == ocid1.dns-zone* ]]; then
      zj="$(oci dns zone get --zone-name-or-id "$ZONE_ARG" -c "$COMPARTMENT_OCID" --profile "$PROFILE" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null)" \
        || die "zone not found: $ZONE_ARG"
      ZONE_NAME="$(jq -r '.data.name' <<<"$zj")"
      ZONE_ID="$ZONE_ARG"
    else
      ZONE_NAME="${ZONE_ARG%.}"
      ZONE_ID="$ZONE_ARG"
    fi
    return 0
  fi
  zl="$(oci dns zone list --all -c "$COMPARTMENT_OCID" --profile "$PROFILE" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null)" \
    || die "zone list failed (profile $PROFILE, compartment $COMPARTMENT_NAME)"
  count="$(jq '.data.items | length' <<<"$zl")"
  if [[ "$count" -eq 0 ]]; then
    die "no DNS zones in compartment '$COMPARTMENT_NAME' — create one in the OCI console first (or pass --zone <id-or-name>)"
  fi
  if [[ "$count" -gt 1 ]]; then
    printf '\033[1;31m[dns] FAIL:\033[0m multiple zones in %s — pass --zone with one of:\n' "$COMPARTMENT_NAME" >&2
    jq -r '.data.items[].name' <<<"$zl" | sed 's/^/  /' >&2
    exit 1
  fi
  ZONE_NAME="$(jq -r '.data.items[0].name' <<<"$zl")"
  ZONE_ID="$(jq -r '.data.items[0].id' <<<"$zl")"
}

# turn --name into the record domain: plain label -> label.zone; fqdn must
# live inside the zone (never write into someone else's zone by accident).
validate_name_shape() {
  [[ -n "$NAME" ]] || die "--name is required (--help)"
  [[ "$NAME" =~ ^[A-Za-z0-9_-]{1,63}$ ]] && return 0
  is_hostname "$NAME" || die "invalid --name '$NAME' — use a DNS label (app) or an fqdn inside the zone (app.example.com)"
}

resolve_domain() {
  if [[ "$NAME" =~ ^[A-Za-z0-9_-]{1,63}$ ]]; then
    DOMAIN="$NAME.$ZONE_NAME"
    return 0
  fi
  DOMAIN="${NAME%.}"
  [[ "$DOMAIN" == *".$ZONE_NAME" || "$DOMAIN" == "$ZONE_NAME" ]] \
    || die "--name '$NAME' is outside zone '$ZONE_NAME' — pass --zone <that-zone> explicitly if intended"
}

validate_type() {
  case "$RTYPE" in
    A|AAAA|CNAME) return 0 ;;
    "") die "--type is required: A, AAAA, or CNAME (--help)" ;;
    *) die "--type must be one of: A, AAAA, CNAME (got: $RTYPE)" ;;
  esac
}

validate_value() {
  [[ -n "$VALUE" ]] || die "--value is required (--help)"
  case "$VALUE" in *[\"\\]*) die "invalid --value — quotes/backslashes are never valid in a record value" ;; esac
  case "$RTYPE" in
    A) is_ipv4 "$VALUE" || die "invalid --value '$VALUE' for A — need dotted-quad IPv4 (203.0.113.10)" ;;
    AAAA) is_ipv6 "$VALUE" || die "invalid --value '$VALUE' for AAAA — need an IPv6 literal (fd00::1)" ;;
    CNAME) is_hostname "$VALUE" || die "invalid --value '$VALUE' for CNAME — need a hostname (app.example.com)" ;;
  esac
}

validate_ttl() {
  [[ "$TTL" =~ ^[0-9]+$ ]] || die "invalid --ttl '$TTL' — seconds (60..172800)"
  [[ "$TTL" -ge 60 && "$TTL" -le 172800 ]] || die "invalid --ttl $TTL — OCI allows 60..172800 seconds"
}

# fetch_rrset -> ITEMS (canonical JSON array of {domain,rtype,ttl,rdata};
# a missing RRSet reads as empty — first add must not 404).
fetch_rrset() {
  local rj
  rj="$(oci dns record rrset get -c "$COMPARTMENT_OCID" --zone-name-or-id "$ZONE_ID" --domain "$DOMAIN" --rtype "$RTYPE" --profile "$PROFILE" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>/dev/null || true)"
  if [[ -n "$rj" ]]; then
    ITEMS="$(jq -c '.data.items | map({domain, rtype, ttl, rdata})' <<<"$rj")" || ITEMS="[]"
  else
    ITEMS="[]"
  fi
}

case "$CMD" in
  records)
    need_provider
    resolve_zone
    say "DNS records — zone $ZONE_NAME ($ZONE_ID), profile $PROFILE:"
    oci dns record zone get -c "$COMPARTMENT_OCID" --zone-name-or-id "$ZONE_ID" --profile "$PROFILE" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} --all \
      | jq -r '.data.items[] | [.domain, .rtype, (.ttl|tostring), .rdata] | @tsv'
    ;;

  add)
    [[ -n "$NAME" ]] || die "--name is required (--help)"
    validate_type
    validate_value
    validate_ttl
    validate_name_shape
    need_provider
    resolve_zone
    resolve_domain
    fetch_rrset
    norm_value="${VALUE%.}"
    present="$(jq -r --arg v "$norm_value" 'any(.[]; (.rdata | sub("\\.$"; "")) == $v)' <<<"$ITEMS")"
    if [[ "$present" == "true" ]]; then
      say "already present: $DOMAIN $RTYPE $VALUE — nothing to do"
      exit 0
    fi
    new_items="$(jq -c --arg d "$DOMAIN" --arg t "$RTYPE" --arg v "$VALUE" --argjson ttl "$TTL" \
      '. + [{domain: $d, rtype: $t, ttl: $ttl, rdata: $v}]' <<<"$ITEMS")"
    # NOTE: --profile stays ON the first line (script-gates static scan reads it there)
    oci dns record rrset update --profile "$PROFILE" -c "$COMPARTMENT_OCID" --zone-name-or-id "$ZONE_ID" \
      --domain "$DOMAIN" --rtype "$RTYPE" --items "$new_items" --force ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} >/dev/null \
      || die "RRSet update failed for $DOMAIN $RTYPE (zone $ZONE_NAME)"
    say "added: $DOMAIN $RTYPE $VALUE (ttl $TTL)"
    ;;

  rm)
    [[ -n "$NAME" ]] || die "--name is required (--help)"
    validate_type
    validate_value
    validate_name_shape
    need_provider
    resolve_zone
    resolve_domain
    fetch_rrset
    [[ "$ITEMS" == "[]" ]] && die "no matching record: $DOMAIN $RTYPE $VALUE (see: kampodine dns records)"
    norm_value="${VALUE%.}"
    remaining="$(jq -c --arg v "$norm_value" '[.[] | select((.rdata | sub("\\.$"; "")) != $v)]' <<<"$ITEMS")"
    [[ "$(jq 'length' <<<"$remaining")" -eq "$(jq 'length' <<<"$ITEMS")" ]] \
      && die "no matching record: $DOMAIN $RTYPE $VALUE (see: kampodine dns records)"
    # an emptied RRSet is legal: --items '[]' removes it entirely
    # NOTE: --profile stays ON the first line (script-gates static scan reads it there)
    oci dns record rrset update --profile "$PROFILE" -c "$COMPARTMENT_OCID" --zone-name-or-id "$ZONE_ID" \
      --domain "$DOMAIN" --rtype "$RTYPE" --items "$remaining" --force ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} >/dev/null \
      || die "RRSet update failed for $DOMAIN $RTYPE (zone $ZONE_NAME)"
    say "removed: $DOMAIN $RTYPE $VALUE"
    ;;
esac
