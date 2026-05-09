#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Azure bootstrap
# Spins up N Azure VMs in a dedicated resource group and installs WolfStack
# via cloud-init. Uses one resource group per cluster (named after the
# prefix) so --destroy is a single 'az group delete' call.
#
# Prerequisites:
#   * az CLI installed (https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
#   * `az login` done (or service principal via env vars)
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3× Standard_B2s in eastus, ~$90/mo):
#   ./bootstrap.sh
#
# Tear down (deletes the entire resource group, fastest path):
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="eastus"          # US East — cheapest US region
# shellcheck disable=SC2034
ws_default_ssh_key=""

ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="Standard_B2s";  OS_DISK_GB=50;  SIZE_DESC="2 vCPU / 4 GB / 50 GB — ~\$30/mo (eval only)" ;;
        medium) WS_TYPE="Standard_B2ms"; OS_DISK_GB=100; SIZE_DESC="2 vCPU / 8 GB / 100 GB — ~\$60/mo (recommended)" ;;
        large)  WS_TYPE="Standard_B4ms"; OS_DISK_GB=200; SIZE_DESC="4 vCPU / 16 GB / 200 GB — ~\$120/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
IMAGE="Ubuntu2404"
ADMIN_USER="azureuser"
SSH_USER="$ADMIN_USER"
OS_DISK_GB=100  # default if --type used directly

print_help() {
    cat <<'HELP'
WolfStack — Azure bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of VMs (default: 3)
  --prefix STR        Hostname prefix and resource-group name suffix
                      (default: wolfstack → resource group 'wolfstack-rg')
  --region STR        Azure location: eastus, westus2, westeurope,
                      uksouth, australiaeast, etc. Default: eastus.
  --size CLASS        small / medium / large. Default: medium. Also sets
                      the OS disk size — Azure's default is too tight.
                        small  = Standard_B2s  · 2 vCPU / 4 GB / 50 GB  — ~$30/mo (eval only)
                        medium = Standard_B2ms · 2 vCPU / 8 GB / 100 GB — ~$60/mo (recommended)
                        large  = Standard_B4ms · 4 vCPU / 16 GB / 200 GB — ~$120/mo
  --type STR          Override --size with explicit Azure VM size
                      (Standard_B1s, Standard_D2s_v5, Standard_D4s_v5, etc.).
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
  --image STR         OS image alias (default: Ubuntu2404).
  --beta              Install WolfStack from the beta branch.
  --destroy           Delete the resource group (and everything in it).
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Cost estimate (May 2026 eastus, on-demand):
  Standard_B1s     ≈ $8/mo   →  3 nodes ≈ $24/mo
  Standard_B2s     ≈ $30/mo  →  3 nodes ≈ $90/mo
  Standard_D2s_v5  ≈ $70/mo  →  3 nodes ≈ $210/mo
HELP
}

PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --destroy) ACTION="destroy" ;;
        --image) shift; IMAGE="${1:-}"; [ -n "$IMAGE" ] || ws_fatal "--image requires a value" ;;
        *) PASSTHROUGH_ARGS+=("$1") ;;
    esac
    shift
done
ws_parse_args "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"

SIZE_DESC=""
if [ -z "$WS_TYPE" ]; then
    ws_size_to_type
fi

ws_require_cli "az" "https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
ws_require_cli "jq" "your distro's package manager"

if ! az account show >/dev/null 2>&1; then
    ws_err "Azure CLI not logged in."
    echo "  Run: az login" >&2
    exit 2
fi
SUB=$(az account show --query name --output tsv 2>/dev/null)
ws_info "Azure subscription: ${SUB}"

RG="${WS_PREFIX}-rg"

# ─── Destroy path — single 'az group delete' call ───────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "Azure — tearing down WolfStack cluster '${WS_PREFIX}'"
    if ! az group show --name "$RG" >/dev/null 2>&1; then
        ws_warn "Resource group '$RG' does not exist."
        exit 0
    fi
    echo "  Will delete resource group: $RG (and everything inside it)"
    az resource list --resource-group "$RG" --query "[].{Name:name,Type:type}" --output table 2>/dev/null || true
    ws_confirm "Delete resource group '$RG' permanently?"
    az group delete --name "$RG" --yes --no-wait >/dev/null
    ws_ok "Resource-group deletion initiated (Azure runs this asynchronously)."
    ws_info "Check status with: az group show --name $RG"
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "Azure — provisioning a WolfStack cluster"
echo "  Subscription: ${SUB}"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:        ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:        ${WS_NODES} × ${WS_TYPE} (custom, ${OS_DISK_GB}GB OS disk) in ${WS_REGION}"
fi
echo "  Resource grp: ${RG}"
echo "  Prefix:       ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  SSH key:      ${WS_SSH_KEY}"
echo "  Branch:       ${WS_BRANCH}"

# Validate region. az's account list-locations is the authoritative list.
if ! az account list-locations --query "[].name" --output tsv 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Region '${WS_REGION}' not valid for this subscription."
    echo "  Run: az account list-locations --query \"[].name\" --output tsv" >&2
    exit 2
fi

# Validate VM size in this region.
if ! az vm list-sizes --location "$WS_REGION" --query "[].name" --output tsv 2>/dev/null | grep -qx "$WS_TYPE"; then
    ws_fatal "VM size '${WS_TYPE}' not available in ${WS_REGION}. Run: az vm list-sizes --location ${WS_REGION}"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── Resource group ─────────────────────────────────────────────────────────
if az group show --name "$RG" >/dev/null 2>&1; then
    ws_warn "Resource group '$RG' already exists — VMs will be added to it."
else
    ws_info "Creating resource group '$RG' in ${WS_REGION}"
    az group create --name "$RG" --location "$WS_REGION" \
        --tags "WolfStackBootstrap=${WS_PREFIX}" >/dev/null
    ws_ok "Resource group created"
fi

# ─── NSG with WolfStack ports ───────────────────────────────────────────────
NSG_NAME="${WS_PREFIX}-nsg"
if az network nsg show --resource-group "$RG" --name "$NSG_NAME" >/dev/null 2>&1; then
    ws_info "NSG '$NSG_NAME' already exists — reusing"
else
    ws_info "Creating NSG '$NSG_NAME'"
    az network nsg create --resource-group "$RG" --name "$NSG_NAME" --location "$WS_REGION" >/dev/null

    # Priority must be unique per NSG; start at 1000 and increment.
    az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_NAME" \
        --name AllowSSH --priority 1000 --destination-port-ranges 22 \
        --access Allow --protocol Tcp --direction Inbound >/dev/null
    az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_NAME" \
        --name AllowDashboard --priority 1010 --destination-port-ranges 8553 \
        --access Allow --protocol Tcp --direction Inbound >/dev/null
    az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_NAME" \
        --name AllowInterNode --priority 1020 --destination-port-ranges 8554 \
        --access Allow --protocol Tcp --direction Inbound >/dev/null
    az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_NAME" \
        --name AllowWolfNet --priority 1030 --destination-port-ranges 9600 9601 \
        --access Allow --protocol Udp --direction Inbound >/dev/null
    ws_ok "NSG rules created (TCP 22/8553/8554; UDP 9600/9601)"
fi

# ─── Pre-flight: name collision ─────────────────────────────────────────────
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if az vm show --resource-group "$RG" --name "$hn" >/dev/null 2>&1; then
        ws_fatal "VM '$hn' already exists in $RG. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_NAMES=()
cleanup_on_error() {
    [ ${#CREATED_NAMES[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_NAMES[@]} VM(s)..."
    for name in "${CREATED_NAMES[@]}"; do
        az vm delete --resource-group "$RG" --name "$name" --yes >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Creating ${WS_NODES} VMs in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    ud_file="/tmp/wolfstack-azure-$$-$i.yaml"
    out_file="/tmp/wolfstack-azure-$$-$i.out"
    printf '%s\n' "$cloud_init_yaml" > "$ud_file"
    (
        az vm create \
            --resource-group "$RG" \
            --name "$hn" \
            --location "$WS_REGION" \
            --image "$IMAGE" \
            --size "$WS_TYPE" \
            --admin-username "$ADMIN_USER" \
            --ssh-key-values "$WS_SSH_KEY" \
            --custom-data "$ud_file" \
            --os-disk-size-gb "$OS_DISK_GB" \
            --nsg "$NSG_NAME" \
            --public-ip-sku Standard \
            --tags "WolfStackBootstrap=${WS_PREFIX}" \
            --output none > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}|${ud_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    IFS='|' read -r hn out_file ud_file <<< "$entry"
    if wait "$pid"; then
        CREATED_NAMES+=("$hn")
        ws_ok "Created $hn"
    else
        ws_err "Failed to create $hn"
        cat "$out_file" >&2 || true
        all_ok=false
    fi
    rm -f "$out_file" "$ud_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more VMs failed. Cleanup ran."
fi

# ─── Collect IPs + wait for cloud-init ──────────────────────────────────────
PAIRS=()
for name in "${CREATED_NAMES[@]}"; do
    ipv4=$(az vm show --resource-group "$RG" --name "$name" --show-details \
        --query "publicIps" --output tsv 2>/dev/null | tr -d ' \r\n')
    PAIRS+=("${name}:${ipv4}")
done

ws_info "Waiting for WolfStack to come up on each VM (~90-120 seconds)..."
echo ""
for pair in "${PAIRS[@]}"; do
    hn="${pair%%:*}"
    ip="${pair##*:}"
    if ! ws_wait_for_dashboard "$hn" "$ip"; then
        echo "    Inspect: ssh ${SSH_USER}@${ip} 'journalctl -u wolfstack -n 50'" >&2
    fi
done

trap - ERR INT TERM
ws_form_cluster "$SSH_USER" "$CLUSTER_SECRET" "${PAIRS[@]}"
WS_ROOT_PASSWORD="$ROOT_PASSWORD" ws_summary "${PAIRS[@]}"
