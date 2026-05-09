#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Scaleway bootstrap
# Spins up N Scaleway instances and installs WolfStack via cloud-init.
# Tags each instance with the prefix so --destroy can find them.
#
# Prerequisites:
#   * scw CLI installed (https://github.com/scaleway/scaleway-cli)
#   * `scw init` done (or env vars SCW_ACCESS_KEY, SCW_SECRET_KEY,
#     SCW_DEFAULT_PROJECT_ID, SCW_DEFAULT_ORGANIZATION_ID)
#   * SSH public key registered in your Scaleway IAM Project SSH Keys
#
# Quick start (3× DEV1-S in fr-par-1, ~€11/mo):
#   ./bootstrap.sh
#
# Tear down:
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="fr-par-1"        # Paris zone 1
# shellcheck disable=SC2034
ws_default_ssh_key=""

# Size → Scaleway instance type
ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="DEV1-S";  SIZE_DESC="2 vCPU / 2 GB / 20 GB — €3.65/mo (eval only)" ;;
        medium) WS_TYPE="DEV1-L";  SIZE_DESC="4 vCPU / 8 GB / 80 GB — €14.61/mo (recommended)" ;;
        large)  WS_TYPE="PRO2-S";  SIZE_DESC="4 vCPU / 16 GB / 40 GB — ~€36/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
IMAGE="ubuntu_noble"                # Ubuntu 24.04 LTS
SSH_USER="root"

print_help() {
    cat <<'HELP'
WolfStack — Scaleway bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of instances (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        Scaleway zone: fr-par-1, fr-par-2, fr-par-3,
                      nl-ams-1, nl-ams-2, pl-waw-1, pl-waw-2.
                      Default: fr-par-1.
  --size CLASS        small / medium / large. Default: medium.
                        small  = DEV1-S · 2 vCPU / 2 GB / 20 GB  — €3.65/mo (eval only)
                        medium = DEV1-L · 4 vCPU / 8 GB / 80 GB  — €14.61/mo (recommended)
                        large  = PRO2-S · 4 vCPU / 16 GB / 40 GB — ~€36/mo
  --type STR          Override --size with explicit Scaleway type:
                      DEV1-S/M/L, GP1-XS/S/M/L, PRO2-XXS/XS/S/M/L, etc.
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
                      The key MUST already be registered in your Scaleway
                      IAM SSH Keys (we ensure this idempotently).
  --image STR         OS image (default: ubuntu_noble = Ubuntu 24.04).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down resources tagged with the prefix.
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Cost estimate (May 2026, ex-VAT):
  DEV1-S    ≈ €3.65/mo  →  3 nodes ≈ €10.95/mo
  DEV1-M    ≈ €7.30/mo  →  3 nodes ≈ €21.90/mo
  GP1-S     ≈ €30/mo    →  3 nodes ≈ €90/mo
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

ws_require_cli "scw" "https://github.com/scaleway/scaleway-cli/releases (or 'brew install scw')"
ws_require_cli "jq" "your distro's package manager"

if ! scw account project list -o json 2>/dev/null | jq -e '.[0].id' >/dev/null 2>&1; then
    ws_err "scw is not authenticated, or no project is configured."
    echo "  Run: scw init" >&2
    exit 2
fi

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "Scaleway — tearing down WolfStack cluster '${WS_PREFIX}'"
    instances=$(scw instance server list zone="$WS_REGION" -o json 2>/dev/null \
        | jq -r --arg p "${WS_PREFIX}-" '.[] | select(.name | startswith($p)) | "\(.id) \(.name)"' 2>/dev/null \
        || echo "")
    if [ -z "$instances" ]; then
        ws_warn "No instances found with prefix '${WS_PREFIX}-' in ${WS_REGION}."
    else
        echo "  Will delete:"
        echo "$instances" | awk '{printf "    • %s (id %s)\n", $2, $1}'
        ws_confirm "Delete these instances permanently? (Includes attached volumes and IPs.)"
        while read -r id _; do
            [ -z "$id" ] && continue
            # Stop, then delete with attached resources cleanup
            scw instance server stop "$id" zone="$WS_REGION" --wait >/dev/null 2>&1 || true
            if scw instance server delete "$id" zone="$WS_REGION" with-ip=true with-volumes=all >/dev/null 2>&1; then
                ws_ok "Deleted $id (with IP + volumes)"
            else
                ws_err "Failed to delete $id"
            fi
        done <<< "$instances"
    fi
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "Scaleway — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  Image:    ${IMAGE}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

# Validate zone — Scaleway zones are documented here:
# https://www.scaleway.com/en/docs/console/account/reference-content/products-availability/
case "$WS_REGION" in
    fr-par-1|fr-par-2|fr-par-3|nl-ams-1|nl-ams-2|pl-waw-1|pl-waw-2|pl-waw-3) ;;
    *) ws_fatal "Zone '${WS_REGION}' is not a known Scaleway zone." ;;
esac

# ─── SSH key (idempotent — ensure it's in IAM) ─────────────────────────────
KEY_NAME="${WS_PREFIX}-key"
SSH_PUB=$(cat "$WS_SSH_KEY")
existing_key_id=$(scw iam ssh-key list -o json 2>/dev/null \
    | jq -r --arg n "$KEY_NAME" '.[] | select(.name==$n) | .id' 2>/dev/null \
    | head -1 || echo "")
if [ -z "$existing_key_id" ]; then
    ws_info "Registering SSH key '$KEY_NAME' in IAM"
    scw iam ssh-key create name="$KEY_NAME" public-key="$SSH_PUB" >/dev/null
    ws_ok "SSH key registered"
else
    ws_info "SSH key '$KEY_NAME' already in IAM — reusing"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── Pre-flight: name collision ─────────────────────────────────────────────
existing=$(scw instance server list zone="$WS_REGION" -o json 2>/dev/null \
    | jq -r '.[].name' 2>/dev/null || echo "")
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if echo "$existing" | grep -qx "$hn"; then
        ws_fatal "Instance '$hn' already exists in zone ${WS_REGION}. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_IDS[@]} instance(s)..."
    for id in "${CREATED_IDS[@]}"; do
        scw instance server stop "$id" zone="$WS_REGION" --wait >/dev/null 2>&1 || true
        scw instance server delete "$id" zone="$WS_REGION" with-ip=true with-volumes=all >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Creating ${WS_NODES} instances in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    ud_file="/tmp/wolfstack-scw-$$-$i.yaml"
    out_file="/tmp/wolfstack-scw-$$-$i.out"
    printf '%s\n' "$cloud_init_yaml" > "$ud_file"
    (
        scw instance server create \
            zone="$WS_REGION" \
            name="$hn" \
            type="$WS_TYPE" \
            image="$IMAGE" \
            ip=new \
            cloud-init=@"$ud_file" \
            tags.0="$WS_PREFIX" \
            -o json > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}|${ud_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    IFS='|' read -r hn out_file ud_file <<< "$entry"
    if wait "$pid"; then
        id=$(jq -r '.id' < "$out_file" 2>/dev/null || echo "")
        if [ -n "$id" ] && [ "$id" != "null" ]; then
            CREATED_IDS+=("$id")
            ws_ok "Created $hn (id $id)"
        else
            ws_err "Created $hn but couldn't parse id"
            cat "$out_file" >&2 || true
            all_ok=false
        fi
    else
        ws_err "Failed to create $hn"
        cat "$out_file" >&2 || true
        all_ok=false
    fi
    rm -f "$out_file" "$ud_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more instances failed. Cleanup ran."
fi

# ─── Start instances + wait for IPs ─────────────────────────────────────────
ws_info "Powering on instances..."
for id in "${CREATED_IDS[@]}"; do
    scw instance server start "$id" zone="$WS_REGION" --wait >/dev/null 2>&1 || true
done

PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    json=$(scw instance server get "$id" zone="$WS_REGION" -o json 2>/dev/null)
    name=$(echo "$json" | jq -r '.name')
    ipv4=$(echo "$json" | jq -r '.public_ip.address // .public_ips[0].address')
    PAIRS+=("${name}:${ipv4}")
done

ws_info "Waiting for WolfStack to come up on each instance (~90-120 seconds)..."
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
