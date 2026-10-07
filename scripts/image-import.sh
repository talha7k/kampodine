#!/usr/bin/env bash
# image-import.sh — upload the packer-built qcow2 to Object Storage and import
# it as an OCI custom image (runs on the BUILD machine; the VM never touches
# OCI APIs).
#
# VALIDATED CONSTRAINTS this script encodes:
# - Alpine is NOT in OCI's supported custom-image import OS list -> the import
#   runs "self-supported": generic OS metadata, PARAVIRTUALIZED launch mode
#   (Ampere shapes are UEFI-only and our image has the grub-efi BOOTAA64.EFI
#   fallback baked in — see install.sh).
# - qcow2 upload path: oci os object put -> oci compute image import
#   from-object -> poll to AVAILABLE -> print the image OCID.
#
# Auth: ~/.oci/config (brew install oci-cli; oci setup config) by default, or
# --from-pass to source API credentials from the local pass store — the key
# NEVER enters this repo, the image, or any log (values only go into env vars).
# Every oci call pins --profile $PROFILE (OCI_PROFILE, default esellar-api) —
# the CLI's DEFAULT profile is NOT the esellar tenancy.
# Placeholder pass paths (create yours to match):
#   esellar/oci/user         user OCID
#   esellar/oci/tenancy      tenancy OCID
#   esellar/oci/fingerprint  API key fingerprint
#   esellar/oci/api-key      PEM private key
#
# Usage:
#   kampodine image-import                       # defaults below
#   kampodine image-import --from-pass
#   kampodine image-import --image build/esellar-alpine-3.22.6-aarch64.qcow2
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGE=""
BUCKET="${OCI_IMPORT_BUCKET:-esellar-image-import}"
NAME_PREFIX="${OCI_IMPORT_NAME:-esellar-alpine}"
COMPARTMENT_NAME="${OCI_COMPARTMENT:-esellar}"
PROFILE="${OCI_PROFILE:-esellar-api}"
FROM_PASS=0
KEEP_OBJECT=0

say() { printf '[import] %s\n' "$*"; }
die() { printf '[import][FAIL] %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage:
  kampodine image-import [--image <qcow2>] [--bucket <name>] [--name-prefix <p>]
                         [--compartment <name>] [--from-pass] [--keep-object]

Examples:
EOF
  grep '^#   kampodine image-import' "$0" | sed 's/^#   //'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --compartment) COMPARTMENT_NAME="$2"; shift 2 ;;
    --from-pass) FROM_PASS=1; shift ;;
    --keep-object) KEEP_OBJECT=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done

command -v oci >/dev/null 2>&1 || die "oci CLI not found — brew install oci-cli, then: oci setup config (infra/oci/README.md § CLI setup)"
command -v pass >/dev/null 2>&1 || true

if [[ $FROM_PASS -eq 1 ]]; then
  command -v pass >/dev/null 2>&1 || die "pass not installed (brew install pass)"
  say "sourcing OCI API credentials from pass (values never printed/logged)…"
  for entry in user tenancy fingerprint api-key; do
    pass show "esellar/oci/$entry" >/dev/null 2>&1 || die "missing pass entry esellar/oci/$entry"
  done
  OCI_CLI_USER="$(pass show esellar/oci/user)"
  OCI_CLI_TENANCY="$(pass show esellar/oci/tenancy)"
  OCI_CLI_FINGERPRINT="$(pass show esellar/oci/fingerprint)"
  OCI_CLI_KEY_CONTENT="$(pass show esellar/oci/api-key)"
  export OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT OCI_CLI_KEY_CONTENT
fi

# --- image file ------------------------------------------------------------------
if [[ -z "$IMAGE" ]]; then
  # Constrained glob (our own build output names) — ls is fine here.
  # shellcheck disable=SC2012
  IMAGE="$(ls -t "$REPO_ROOT/infra/alpine-host/build"/esellar-alpine-*.qcow2 2>/dev/null | head -1 || true)"
  [[ -n "$IMAGE" ]] || die "no qcow2 under infra/alpine-host/build/ — run: (cd infra/alpine-host && packer build .)"
fi
[[ -f "$IMAGE" ]] || die "image not found: $IMAGE"

COMPARTMENT_OCID="$(oci iam compartment list --all --profile "$PROFILE" --query "data[?name=='$COMPARTMENT_NAME'].id | [0]" --raw-output 2>/dev/null || true)"
[[ "$COMPARTMENT_OCID" == ocid1.compartment* ]] || die "compartment '$COMPARTMENT_NAME' not found (profile $PROFILE)"
NAMESPACE="$(oci os ns get --profile "$PROFILE" --query data --raw-output)"
[[ -n "$NAMESPACE" ]] || die "could not resolve the tenancy namespace"

STAMP="$(date +%Y%m%d-%H%M%S)"
OBJECT_NAME="${NAME_PREFIX}-${STAMP}.qcow2"
IMAGE_NAME="${NAME_PREFIX}-$(basename "$IMAGE" .qcow2 | sed 's/^esellar-alpine-//')-${STAMP}"

say "uploading $(basename "$IMAGE") -> os://$BUCKET/$OBJECT_NAME"
oci os object put -bn "$BUCKET" --profile "$PROFILE" --file "$IMAGE" --name "$OBJECT_NAME" --force \
  || die "object upload failed (bucket exists? oci os bucket create -bn $BUCKET -c $COMPARTMENT_OCID)"

say "importing as custom image '$IMAGE_NAME' (self-supported: PARAVIRTUALIZED)…"
# A1/Ampere firmware gate (OCI platform behavior, pinned empirically):
# OCI pins imported images to launch-options firmware=BIOS. It is NOT
# derived from the --operating-system string (a recognized aarch64 string
# still yields BIOS) and NOT re-derivable via `compute image update` (OS
# metadata is writable, firmware is frozen). A1 shape launch validation
# rejects BIOS images — "Shape VM.Standard.A1.Flex is not valid for image"
# — and NO launch-time override passes it: --launch-options firmware /
# --launch-mode CUSTOM were both rejected. There is also no image->boot-
# volume API (bootVolumes sourceDetails rejects type "image"). The only
# sanctioned route to an A1-launchable custom image is CAPTURE FROM A
# RUNNING A1 INSTANCE (compute image create --instance-id). The check
# below warns loudly when the import lands BIOS.
IMPORT_JSON="$(oci compute image import from-object --profile "$PROFILE" \
  -c "$COMPARTMENT_OCID" \
  --bucket-name "$BUCKET" \
  --namespace "$NAMESPACE" \
  --name "$OBJECT_NAME" \
  --display-name "$IMAGE_NAME" \
  --source-image-type QCOW2 \
  --operating-system "Linux" \
  --operating-system-version "Alpine 3.22.6 (self-supported)" \
  --launch-mode PARAVIRTUALIZED \
  --query 'data.id' --raw-output)" || die "import call failed"
[[ "$IMPORT_JSON" == ocid1.image* ]] || die "unexpected import response: $IMPORT_JSON"

say "polling import -> AVAILABLE (up to 30m)…"
STATE="PENDING_IMPORT"
for _ in $(seq 1 120); do
  STATE="$(oci compute image get --image-id "$IMPORT_JSON" --profile "$PROFILE" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo UNKNOWN)"
  case "$STATE" in
    AVAILABLE) break ;;
    PENDING_IMPORT|IMPORTING|UPLOADING) sleep 15 ;;
    *) die "import reached terminal state: $STATE (console -> Compute -> Custom images for the error)" ;;
  esac
done
[[ "$STATE" == "AVAILABLE" ]] || die "import did not become AVAILABLE in 30m (state: $STATE)"

# Firmware verdict — A1/Ampere (UEFI-only) rejects BIOS-pinned images
# at launch (see the import-call comment above). Loud, non-fatal: other
# (x86) shapes launch fine from a BIOS image.
IMPORT_FIRMWARE="$(oci compute image get --image-id "$IMPORT_JSON" --profile "$PROFILE" --query 'data."launch-options"."firmware"' --raw-output 2>/dev/null || echo UNKNOWN)"
if [[ "$IMPORT_FIRMWARE" != "UEFI_64" ]]; then
  say "WARN: import landed firmware=$IMPORT_FIRMWARE — VM.Standard.A1.Flex (Ampere, UEFI-only) WILL reject this image at launch."
  say "      OCI has no import-time firmware control: the sanctioned A1 route is"
  say "      capture-from-instance: boot the qcow2 elsewhere, then 'oci compute image create --instance-id <running-a1>'."
  say "      x86 shapes CAN launch this image directly."
fi

if [[ $KEEP_OBJECT -eq 0 ]]; then
  say "deleting the staged object (image data now lives in the custom image)…"
  oci os object delete -bn "$BUCKET" --profile "$PROFILE" --name "$OBJECT_NAME" --force >/dev/null || say "WARN: staged object delete failed (cleanup manually)"
fi

say "IMPORTED:"
say "  image OCID: $IMPORT_JSON"
say "  display   : $IMAGE_NAME"
say "  firmware  : $IMPORT_FIRMWARE"
say "next:"
if [[ "$IMPORT_FIRMWARE" == "UEFI_64" ]]; then
  say "  A1-ready. kampodine bluegreen provision <blue|green> picks this image (newest esellar-alpine*)."
else
  say "  A1 launch will REJECT this image (firmware $IMPORT_FIRMWARE) — see the WARN above."
fi
