#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Google Cloud Platform bootstrap
# Spins up N Compute Engine VMs in your chosen zone and installs WolfStack
# via cloud-init. Creates a firewall rule scoped to the prefix-tagged VMs
# so other projects in the GCP project aren't exposed.
#
# Prerequisites:
#   * gcloud CLI installed (https://cloud.google.com/sdk/docs/install)
#   * `gcloud auth login` and `gcloud config set project <PROJECT_ID>` done
#   * Compute Engine API enabled (gcloud services enable compute.googleapis.com)
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3× e2-medium in us-central1-a, ~$72/mo):
#   ./bootstrap.sh
#
# Tear down:
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="us-central1-a"   # Iowa — cheap, well-connected
# shellcheck disable=SC2034
ws_default_ssh_key=""

ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="e2-medium";     BOOT_DISK_GB=50;  SIZE_DESC="2 vCPU shared / 4 GB / 50 GB — ~\$24/mo (eval only)" ;;
        medium) WS_TYPE="e2-standard-2"; BOOT_DISK_GB=100; SIZE_DESC="2 vCPU / 8 GB / 100 GB — ~\$48/mo (recommended)" ;;
        large)  WS_TYPE="e2-standard-4"; BOOT_DISK_GB=200; SIZE_DESC="4 vCPU / 16 GB / 200 GB — ~\$96/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
SSH_USER="root"   # We inject "root:<pubkey>" via ssh-keys metadata
BOOT_DISK_GB=100  # default if --type used directly

print_help() {
    cat <<'HELP'
WolfStack — GCP Compute Engine bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of VMs (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        GCP zone: us-central1-a, us-west1-b, europe-west2-a,
                      asia-southeast1-a, etc. NOTE: this is a ZONE, not a
                      region — GCP requires zone-level placement.
                      Default: us-central1-a.
  --size CLASS        small / medium / large. Default: medium. Also sets
                      the boot-disk size — GCE's 10 GB default is too tight
                      for Docker images.
                        small  = e2-medium     · 2 vCPU shared / 4 GB / 50 GB  — ~$24/mo (eval only)
                        medium = e2-standard-2 · 2 vCPU / 8 GB / 100 GB        — ~$48/mo (recommended)
                        large  = e2-standard-4 · 4 vCPU / 16 GB / 200 GB       — ~$96/mo
  --type STR          Override --size with explicit machine type
                      (e2-small, n2-standard-2, c2-standard-4, etc.).
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down resources tagged with the prefix.
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Cost estimate (May 2026 us-central1, on-demand):
  e2-small      ≈ $14/mo  →  3 nodes ≈ $42/mo
  e2-medium     ≈ $24/mo  →  3 nodes ≈ $72/mo
  e2-standard-2 ≈ $55/mo  →  3 nodes ≈ $165/mo

Sustained-use discounts apply automatically; the figures above are pre-discount.
HELP
}

PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --destroy) ACTION="destroy" ;;
        *) PASSTHROUGH_ARGS+=("$1") ;;
    esac
    shift
done
ws_parse_args "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"

SIZE_DESC=""
if [ -z "$WS_TYPE" ]; then
    ws_size_to_type
fi

ws_require_cli "gcloud" "https://cloud.google.com/sdk/docs/install"

PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
    ws_err "No GCP project configured."
    echo "  Run: gcloud config set project <YOUR_PROJECT_ID>" >&2
    exit 2
fi
ws_info "GCP project: ${PROJECT}"

if ! gcloud compute zones list --filter="name=${WS_REGION}" --format="value(name)" 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Zone '${WS_REGION}' not valid for project ${PROJECT}."
    echo "  Run: gcloud compute zones list" >&2
    exit 2
fi

NETWORK_TAG="wolfstack-${WS_PREFIX}"
FIREWALL_RULE="wolfstack-${WS_PREFIX}-allow"

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "GCP — tearing down WolfStack cluster '${WS_PREFIX}'"
    instances=$(gcloud compute instances list \
        --filter="tags.items=${NETWORK_TAG}" \
        --format="value(name,zone)" 2>/dev/null || echo "")
    if [ -n "$instances" ]; then
        echo "  Will delete:"
        echo "$instances" | awk '{print "    • " $1 " (zone " $2 ")"}'
    fi
    fw_exists=$(gcloud compute firewall-rules list --filter="name=${FIREWALL_RULE}" --format="value(name)" 2>/dev/null || echo "")
    [ -n "$fw_exists" ] && echo "  Will delete firewall rule: ${FIREWALL_RULE}"

    if [ -z "$instances" ] && [ -z "$fw_exists" ]; then
        ws_ok "Nothing to tear down."
        exit 0
    fi
    ws_confirm "Permanently tear down these resources?"

    if [ -n "$instances" ]; then
        while read -r name zone; do
            [ -z "$name" ] && continue
            if gcloud compute instances delete "$name" --zone="$zone" --quiet >/dev/null 2>&1; then
                ws_ok "Deleted $name"
            else
                ws_err "Failed to delete $name"
            fi
        done <<< "$instances"
    fi
    if [ -n "$fw_exists" ]; then
        if gcloud compute firewall-rules delete "$FIREWALL_RULE" --quiet >/dev/null 2>&1; then
            ws_ok "Firewall rule deleted"
        else
            ws_warn "Could not delete firewall rule"
        fi
    fi
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "GCP Compute Engine — provisioning a WolfStack cluster"
echo "  Project:  ${PROJECT}"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom, ${BOOT_DISK_GB}GB disk) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

if ! gcloud compute machine-types describe "$WS_TYPE" --zone="$WS_REGION" >/dev/null 2>&1; then
    ws_fatal "Machine type '${WS_TYPE}' not available in zone ${WS_REGION}."
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)

# ─── Firewall rule (idempotent) ─────────────────────────────────────────────
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
    ws_info "Creating firewall rule '${FIREWALL_RULE}' (TCP 22, 8553, 8554; UDP 9600, 9601)"
    gcloud compute firewall-rules create "$FIREWALL_RULE" \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22,tcp:8553,tcp:8554,udp:9600,udp:9601 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="$NETWORK_TAG" \
        --description="WolfStack cluster ${WS_PREFIX}" >/dev/null
    ws_ok "Firewall rule created"
else
    ws_info "Firewall rule '${FIREWALL_RULE}' already exists — reusing"
fi

# ─── SSH key (project-level via metadata) ───────────────────────────────────
# Best practice: per-instance SSH key via the OS Login API or metadata.
# We'll attach as instance metadata so each VM gets root@hostname access.
SSH_KEY_VALUE="root:$(cat "$WS_SSH_KEY")"

# ─── Pre-flight: name collision ─────────────────────────────────────────────
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if gcloud compute instances list --filter="name=${hn}" --format="value(name)" 2>/dev/null | grep -qx "$hn"; then
        ws_fatal "Instance '$hn' already exists. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_NAMES=()
cleanup_on_error() {
    [ ${#CREATED_NAMES[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_NAMES[@]} VM(s)..."
    for name in "${CREATED_NAMES[@]}"; do
        gcloud compute instances delete "$name" --zone="$WS_REGION" --quiet >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Creating ${WS_NODES} VMs in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET")
    ud_file="/tmp/wolfstack-gcp-$$-$i.yaml"
    out_file="/tmp/wolfstack-gcp-$$-$i.out"
    printf '%s\n' "$cloud_init_yaml" > "$ud_file"

    # Write the SSH key to a temp file so --metadata-from-file accepts it.
    key_file="/tmp/wolfstack-gcp-$$-$i.sshkey"
    printf '%s\n' "$SSH_KEY_VALUE" > "$key_file"

    (
        gcloud compute instances create "$hn" \
            --zone="$WS_REGION" \
            --machine-type="$WS_TYPE" \
            --image-family="$IMAGE_FAMILY" \
            --image-project="$IMAGE_PROJECT" \
            --boot-disk-size="${BOOT_DISK_GB}GB" \
            --boot-disk-type=pd-balanced \
            --tags="$NETWORK_TAG" \
            --metadata-from-file="user-data=${ud_file},ssh-keys=${key_file}" \
            --quiet > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}|${ud_file}|${key_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    IFS='|' read -r hn out_file ud_file key_file <<< "$entry"
    if wait "$pid"; then
        CREATED_NAMES+=("$hn")
        ws_ok "Created $hn"
    else
        ws_err "Failed to create $hn"
        cat "$out_file" >&2 || true
        all_ok=false
    fi
    rm -f "$out_file" "$ud_file" "$key_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more VMs failed. Cleanup ran."
fi

# ─── Collect IPs + wait for cloud-init ──────────────────────────────────────
PAIRS=()
for name in "${CREATED_NAMES[@]}"; do
    ipv4=$(gcloud compute instances describe "$name" --zone="$WS_REGION" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)
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
ws_summary "${PAIRS[@]}"
