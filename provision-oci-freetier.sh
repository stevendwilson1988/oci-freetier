#!/usr/bin/env bash
# Provisions a free-tier OCI environment: VCN, subnet, IGW, route table,
# security list, and an Ampere A1 (ARM) compute instance.
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
# Compartment to create resources in. Defaults to the tenancy OCID from
# ~/.oci/config (the root compartment); override with COMPARTMENT_ID=... to use
# a sub-compartment.
COMPARTMENT_ID="${COMPARTMENT_ID:-$(awk -F= '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${OCI_CONFIG_FILE:-$HOME/.oci/config}" 2>/dev/null)}"
DISPLAY_PREFIX="freetier"                       # prefix for all resource names
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
INSTANCE_SHAPE="VM.Standard.A1.Flex"
INSTANCE_OCPUS=2                                # Always Free: up to 4 OCPUs / 24GB total across A1 instances
INSTANCE_MEMORY_GB=12
RETRY_SLEEP_SECONDS=60                          # pause between full sweeps of all ADs when every AD is out of capacity
### ------------------------------

[ -n "$COMPARTMENT_ID" ] || { echo "COMPARTMENT_ID not set and no tenancy found in ~/.oci/config"; exit 1; }
command -v jq >/dev/null || { echo "jq is required. Install it first."; exit 1; }
[ -f "$SSH_KEY_PATH" ] || { echo "SSH public key not found at $SSH_KEY_PATH"; exit 1; }

echo "==> Region: $(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null || echo 'check ~/.oci/config')"

# --- VCN ---
echo "==> Creating VCN"
VCN_ID=$(oci network vcn create \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "${DISPLAY_PREFIX}-vcn" \
  --cidr-block "10.0.0.0/16" \
  --dns-label "${DISPLAY_PREFIX}vcn" \
  --wait-for-state AVAILABLE \
  --query 'data.id' --raw-output)
echo "    VCN: $VCN_ID"

# --- Internet Gateway ---
echo "==> Creating Internet Gateway"
IGW_ID=$(oci network internet-gateway create \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --display-name "${DISPLAY_PREFIX}-igw" \
  --is-enabled true \
  --wait-for-state AVAILABLE \
  --query 'data.id' --raw-output)
echo "    IGW: $IGW_ID"

# --- Route Table (default RT already exists on the VCN; update it) ---
echo "==> Updating default route table"
DEFAULT_RT_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)
oci network route-table update \
  --rt-id "$DEFAULT_RT_ID" \
  --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" \
  --force >/dev/null
echo "    Route table: $DEFAULT_RT_ID"

# --- Security List (default SL already exists; add SSH ingress) ---
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
echo "==> Creating public subnet"
SUBNET_ID=$(oci network subnet create \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --display-name "${DISPLAY_PREFIX}-subnet" \
  --cidr-block "10.0.0.0/24" \
  --dns-label "${DISPLAY_PREFIX}sub" \
  --wait-for-state AVAILABLE \
  --query 'data.id' --raw-output)
echo "    Subnet: $SUBNET_ID"

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
      --display-name "${DISPLAY_PREFIX}-instance" \
      --shape "$INSTANCE_SHAPE" \
      --shape-config "{\"ocpus\": $INSTANCE_OCPUS, \"memoryInGBs\": $INSTANCE_MEMORY_GB}" \
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
