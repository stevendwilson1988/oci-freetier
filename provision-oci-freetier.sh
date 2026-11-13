#!/usr/bin/env bash
# Provisions a free-tier OCI environment: VCN, subnet, IGW, route table,
# security list, and an Ampere A1 (ARM) compute instance.
#
# Safe to re-run: existing resources with the same display names are reused,
# and a pre-flight check against tenancy-wide usage aborts before anything
# would exceed the Always Free limits (see CLAUDE.md).
#
# Prereqs:
#   - oci CLI installed and `oci setup config` completed
#   - jq installed
#   - An SSH key pair at ~/.ssh/id_ed25519.pub (or set SSH_KEY_PATH)
#
# Usage:
#   ./provision-oci-freetier.sh
#   COMPARTMENT_ID=ocid1.compartment.oc1..xxxx ./provision-oci-freetier.sh

set -euo pipefail

### ---- CONFIG - edit these ----
OCI_CONFIG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
TENANCY_ID="$(awk -F= '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$OCI_CONFIG" 2>/dev/null || true)"
# Compartment to create resources in. Defaults to the tenancy (root
# compartment); override with COMPARTMENT_ID=... to use a sub-compartment.
COMPARTMENT_ID="${COMPARTMENT_ID:-$TENANCY_ID}"
DISPLAY_PREFIX="freetier"                       # prefix for all resource names
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
INSTANCE_SHAPE="VM.Standard.A1.Flex"
INSTANCE_OCPUS=2
INSTANCE_MEMORY_GB=12
BOOT_VOLUME_GB=50                               # explicit; counts toward the 200 GB storage limit
RETRY_SLEEP_SECONDS=60                          # pause between full sweeps of all ADs when every AD is out of capacity
### ------------------------------

### ---- Always Free limits (tenancy-wide) - keep in sync with CLAUDE.md ----
FREE_A1_OCPUS=4
FREE_A1_MEMORY_GB=24
FREE_STORAGE_GB=200                             # boot + block volumes combined
FREE_VCNS=2
### ------------------------------------------------------------------------

VCN_NAME="${DISPLAY_PREFIX}-vcn"
IGW_NAME="${DISPLAY_PREFIX}-igw"
SUBNET_NAME="${DISPLAY_PREFIX}-subnet"
INSTANCE_NAME="${DISPLAY_PREFIX}-instance"

[ -n "$TENANCY_ID" ] || { echo "No tenancy found in $OCI_CONFIG"; exit 1; }
[ -n "$COMPARTMENT_ID" ] || { echo "COMPARTMENT_ID not set"; exit 1; }
command -v jq >/dev/null || { echo "jq is required. Install it first."; exit 1; }
[ -f "$SSH_KEY_PATH" ] || { echo "SSH public key not found at $SSH_KEY_PATH"; exit 1; }

# Lists OCIDs of live (not terminated/terminating) resources of a given
# Search resource type across the whole tenancy.
live_resource_ids() {
  oci search resource structured-search \
    --query-text "query $1 resources" \
    --limit 1000 \
    | jq -r '.data.items[]
             | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")
             | .identifier'
}

# Echoes the OCID of the first live resource with the given display name, or nothing.
first_live_id() {
  jq -r --arg n "$1" '[.data[]? | select(."display-name" == $n)
                      | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty'
}

echo "==> Region: $(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null || echo 'check ~/.oci/config')"

# --- Existing instance? Nothing to do. ---
EXISTING_INSTANCE_ID=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" --display-name "$INSTANCE_NAME" --all | first_live_id "$INSTANCE_NAME")
if [ -n "$EXISTING_INSTANCE_ID" ]; then
  PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$EXISTING_INSTANCE_ID" --query 'data[0]."public-ip"' --raw-output)
  echo "==> Instance '$INSTANCE_NAME' already exists: $EXISTING_INSTANCE_ID"
  echo "    ssh ubuntu@${PUBLIC_IP}"
  exit 0
fi

# --- Existing VCN? (decides whether the VCN limit matters) ---
VCN_ID=$(oci network vcn list --compartment-id "$COMPARTMENT_ID" --display-name "$VCN_NAME" --all | first_live_id "$VCN_NAME")

# --- Pre-flight: tenancy-wide Always Free usage check ---
# Note: OCI Search can lag a minute or two behind very recent changes.
echo "==> Checking Always Free usage across the tenancy"
# Capture into variables (not process substitution) so any API failure aborts
# via set -e instead of silently reporting zero usage.
INSTANCE_IDS=$(live_resource_ids instance)
BOOT_VOLUME_IDS=$(live_resource_ids bootvolume)
VOLUME_IDS=$(live_resource_ids volume)
VCN_IDS=$(live_resource_ids vcn)

USED_OCPUS=0
USED_MEM=0
for id in $INSTANCE_IDS; do
  INFO=$(oci compute instance get --instance-id "$id")
  if [ "$(jq -r '.data.shape' <<<"$INFO")" = "VM.Standard.A1.Flex" ]; then
    USED_OCPUS=$(jq -n --argjson u "$USED_OCPUS" --argjson i "$INFO" '$u + $i.data."shape-config".ocpus')
    USED_MEM=$(jq -n --argjson u "$USED_MEM" --argjson i "$INFO" '$u + $i.data."shape-config"."memory-in-gbs"')
  fi
done

USED_STORAGE=0
for id in $BOOT_VOLUME_IDS; do
  size=$(oci bv boot-volume get --boot-volume-id "$id" --query 'data."size-in-gbs"' --raw-output)
  USED_STORAGE=$((USED_STORAGE + size))
done
for id in $VOLUME_IDS; do
  size=$(oci bv volume get --volume-id "$id" --query 'data."size-in-gbs"' --raw-output)
  USED_STORAGE=$((USED_STORAGE + size))
done

USED_VCNS=$(wc -w <<<"$VCN_IDS")

NEW_VCNS=0; [ -n "$VCN_ID" ] || NEW_VCNS=1

echo "    A1 OCPUs:  $USED_OCPUS used + $INSTANCE_OCPUS new (limit $FREE_A1_OCPUS)"
echo "    A1 memory: ${USED_MEM} GB used + ${INSTANCE_MEMORY_GB} GB new (limit ${FREE_A1_MEMORY_GB} GB)"
echo "    Storage:   ${USED_STORAGE} GB used + ${BOOT_VOLUME_GB} GB new (limit ${FREE_STORAGE_GB} GB)"
echo "    VCNs:      $USED_VCNS used + $NEW_VCNS new (limit $FREE_VCNS)"

over_limit() { jq -n --argjson a "$1" --argjson b "$2" --argjson l "$3" '($a + $b) > $l' | grep -q true; }
FAIL=0
over_limit "$USED_OCPUS"   "$INSTANCE_OCPUS"     "$FREE_A1_OCPUS"     && { echo "    !! Would exceed Always Free A1 OCPUs";  FAIL=1; }
over_limit "$USED_MEM"     "$INSTANCE_MEMORY_GB" "$FREE_A1_MEMORY_GB" && { echo "    !! Would exceed Always Free A1 memory"; FAIL=1; }
over_limit "$USED_STORAGE" "$BOOT_VOLUME_GB"     "$FREE_STORAGE_GB"   && { echo "    !! Would exceed Always Free storage";   FAIL=1; }
over_limit "$USED_VCNS"    "$NEW_VCNS"           "$FREE_VCNS"         && { echo "    !! Would exceed Always Free VCNs";      FAIL=1; }
[ "$FAIL" -eq 0 ] || { echo "Aborting: nothing was created."; exit 1; }

# --- VCN ---
if [ -n "$VCN_ID" ]; then
  echo "==> Reusing VCN: $VCN_ID"
else
  echo "==> Creating VCN"
  VCN_ID=$(oci network vcn create \
    --compartment-id "$COMPARTMENT_ID" \
    --display-name "$VCN_NAME" \
    --cidr-block "10.0.0.0/16" \
    --dns-label "${DISPLAY_PREFIX}vcn" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  echo "    VCN: $VCN_ID"
fi

# --- Internet Gateway ---
IGW_ID=$(oci network internet-gateway list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$IGW_NAME" --all | first_live_id "$IGW_NAME")
if [ -n "$IGW_ID" ]; then
  echo "==> Reusing Internet Gateway: $IGW_ID"
else
  echo "==> Creating Internet Gateway"
  IGW_ID=$(oci network internet-gateway create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --display-name "$IGW_NAME" \
    --is-enabled true \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  echo "    IGW: $IGW_ID"
fi

# --- Route Table (default RT already exists on the VCN; update it - idempotent) ---
echo "==> Updating default route table"
DEFAULT_RT_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)
oci network route-table update \
  --rt-id "$DEFAULT_RT_ID" \
  --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
  --force >/dev/null
echo "    Route table: $DEFAULT_RT_ID"

# --- Security List (default SL already exists; set SSH ingress - idempotent) ---
echo "==> Updating default security list (allow SSH:22 inbound)"
DEFAULT_SL_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-security-list-id"' --raw-output)
oci network security-list update \
  --security-list-id "$DEFAULT_SL_ID" \
  --ingress-security-rules '[
    {
      "source": "0.0.0.0/0",
      "protocol": "6",
      "isStateless": false,
      "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}}
    }
  ]' \
  --egress-security-rules '[
    {
      "destination": "0.0.0.0/0",
      "protocol": "all",
      "isStateless": false
    }
  ]' \
  --force >/dev/null
echo "    Security list: $DEFAULT_SL_ID"

# --- Subnet ---
SUBNET_ID=$(oci network subnet list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$SUBNET_NAME" --all | first_live_id "$SUBNET_NAME")
if [ -n "$SUBNET_ID" ]; then
  echo "==> Reusing subnet: $SUBNET_ID"
else
  echo "==> Creating public subnet"
  SUBNET_ID=$(oci network subnet create \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" \
    --display-name "$SUBNET_NAME" \
    --cidr-block "10.0.0.0/24" \
    --dns-label "${DISPLAY_PREFIX}sub" \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
  echo "    Subnet: $SUBNET_ID"
fi

# --- Availability Domains + Ampere image ---
echo "==> Listing availability domains"
mapfile -t ADS < <(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" --query 'data[*].name' --raw-output | jq -r '.[]')
[ "${#ADS[@]}" -gt 0 ] || { echo "No availability domains found."; exit 1; }
echo "    ADs: ${ADS[*]}"

echo "==> Finding latest Ubuntu 24.04 ARM (aarch64) image"
IMAGE_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "$INSTANCE_SHAPE" \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)
echo "    Image: $IMAGE_ID"

# --- Launch instance, cycling ADs until one has capacity ---
# Free-tier A1 capacity is scarce and per-AD; retry across every AD in the
# region and keep sweeping until one succeeds.
echo "==> Launching instance (will retry across ADs on out-of-capacity errors)"
INSTANCE_ID=""
AD=""
while [ -z "$INSTANCE_ID" ]; do
  for AD in "${ADS[@]}"; do
    echo "    Trying AD: $AD"
    LAUNCH_OUTPUT=$(oci compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD" \
      --display-name "$INSTANCE_NAME" \
      --shape "$INSTANCE_SHAPE" \
      --shape-config "{\"ocpus\": $INSTANCE_OCPUS, \"memoryInGBs\": $INSTANCE_MEMORY_GB}" \
      --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --metadata "{\"ssh_authorized_keys\": \"$(cat "$SSH_KEY_PATH")\"}" \
      --wait-for-state RUNNING \
      --query 'data.id' --raw-output 2>&1) && INSTANCE_ID="$LAUNCH_OUTPUT"

    if [ -n "$INSTANCE_ID" ]; then
      break
    fi

    if echo "$LAUNCH_OUTPUT" | grep -qiE "OutOfCapacity|Out of host capacity|InternalError"; then
      echo "    AD $AD out of capacity, trying next AD..."
      continue
    else
      echo "$LAUNCH_OUTPUT" >&2
      echo "    Launch failed for a reason other than capacity; aborting."
      exit 1
    fi
  done

  if [ -z "$INSTANCE_ID" ]; then
    echo "    All ADs out of capacity. Sleeping ${RETRY_SLEEP_SECONDS}s before next sweep..."
    sleep "$RETRY_SLEEP_SECONDS"
  fi
done
echo "    Instance: $INSTANCE_ID (AD: $AD)"

echo "==> Fetching public IP"
PUBLIC_IP=$(oci compute instance list-vnics \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0]."public-ip"' --raw-output)

echo ""
echo "=================================================="
echo " Done. SSH in with:"
echo "   ssh ubuntu@${PUBLIC_IP}"
echo "=================================================="
