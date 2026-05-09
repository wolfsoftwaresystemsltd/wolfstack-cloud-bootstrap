#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Vultr bootstrap
# Spins up N Vultr Cloud Compute instances and installs WolfStack via
# cloud-init. Tags each instance with the prefix so --destroy can find them.
#
# Prerequisites:
#   * vultr-cli installed (https://github.com/vultr/vultr-cli)
#   * VULTR_API_KEY env var set
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3× vc2-2c-4gb in ewr, ~$60/mo):
#   ./bootstrap.sh
#
# Tear down:
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="ewr"             # Newark, NJ
# shellcheck disable=SC2034
ws_default_ssh_key=""

ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="vc2-2c-4gb";  SIZE_DESC="2 vCPU / 4 GB / 80 GB SSD — \$24/mo (eval only)" ;;
        medium) WS_TYPE="vc2-4c-8gb";  SIZE_DESC="4 vCPU / 8 GB / 160 GB SSD — \$48/mo (recommended)" ;;
        large)  WS_TYPE="vc2-6c-16gb"; SIZE_DESC="6 vCPU / 16 GB / 320 GB SSD — \$96/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
SSH_USER="root"

print_help() {
    cat <<'HELP'
WolfStack — Vultr bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of instances (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        Vultr location: ewr, lax, ord, mia, atl, sea, hnl,
                      lhr, ams, fra, par, sgp, nrt, syd, mel, etc.
                      Default: ewr.
  --size CLASS        small / medium / large. Default: medium.
                        small  = vc2-2c-4gb  · 2 vCPU / 4 GB / 80 GB SSD  — $24/mo (eval only)
                        medium = vc2-4c-8gb  · 4 vCPU / 8 GB / 160 GB SSD — $48/mo (recommended)
                        large  = vc2-6c-16gb · 6 vCPU / 16 GB / 320 GB SSD — $96/mo
  --type STR          Override --size with explicit Vultr plan id.
                      Run 'vultr-cli plans list' for the menu.
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down resources tagged with the prefix.
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Cost estimate (May 2026):
  vc2-1c-1gb  ≈ $6/mo   →  3 nodes ≈ $18/mo
  vc2-2c-4gb  ≈ $20/mo  →  3 nodes ≈ $60/mo
  vc2-4c-8gb  ≈ $40/mo  →  3 nodes ≈ $120/mo
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

ws_require_cli "vultr-cli" "https://github.com/vultr/vultr-cli/releases (or 'brew install vultr/vultr-cli/vultr-cli')"
ws_require_cli "jq" "your distro's package manager"

if [ -z "${VULTR_API_KEY:-}" ]; then
    ws_err "VULTR_API_KEY env var is not set."
    echo "  Get a key at: https://my.vultr.com/settings/#settingsapi" >&2
    echo "  Then: export VULTR_API_KEY=..." >&2
    exit 2
fi

if ! vultr-cli account >/dev/null 2>&1; then
    ws_err "vultr-cli could not reach the Vultr API. Check VULTR_API_KEY validity."
    exit 2
fi

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "Vultr — tearing down WolfStack cluster '${WS_PREFIX}'"
    # Vultr instances are filtered by hostname prefix (no native tag filter
    # in the CLI list output).
    instances=$(vultr-cli instance list -o json 2>/dev/null \
        | jq -r --arg p "${WS_PREFIX}-" '.instances[] | select(.label | startswith($p)) | "\(.id) \(.label)"' 2>/dev/null \
        || echo "")
    if [ -z "$instances" ]; then
        ws_warn "No instances found with prefix '${WS_PREFIX}-'."
    else
        echo "  Will delete:"
        echo "$instances" | awk '{printf "    • %s (id %s)\n", $2, $1}'
        ws_confirm "Delete these instances permanently?"
        while read -r id _; do
            [ -z "$id" ] && continue
            if vultr-cli instance delete "$id" >/dev/null 2>&1; then
                ws_ok "Deleted $id"
            else
                ws_err "Failed to delete $id"
            fi
        done <<< "$instances"
    fi
    # Remove the SSH key associated with this prefix
    key_id=$(vultr-cli ssh-key list -o json 2>/dev/null \
        | jq -r --arg n "${WS_PREFIX}-key" '.ssh_keys[] | select(.name==$n) | .id' 2>/dev/null \
        || echo "")
    if [ -n "$key_id" ]; then
        vultr-cli ssh-key delete "$key_id" >/dev/null 2>&1 || true
        ws_ok "SSH key deleted"
    fi
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "Vultr — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

# Validate region.
if ! vultr-cli regions list -o json 2>/dev/null \
    | jq -r '.regions[].id' 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Region '${WS_REGION}' not valid for Vultr."
    echo "  Run: vultr-cli regions list" >&2
    exit 2
fi

# Validate plan.
if ! vultr-cli plans list -o json 2>/dev/null \
    | jq -r '.plans[].id' 2>/dev/null | grep -qx "$WS_TYPE"; then
    ws_err "Plan '${WS_TYPE}' not valid for Vultr."
    echo "  Run: vultr-cli plans list" >&2
    exit 2
fi

# Look up Ubuntu 24.04 OS ID dynamically — Vultr's numeric IDs change as
# new images are added.
OS_ID=$(vultr-cli os list -o json 2>/dev/null \
    | jq -r '.os[] | select(.name | test("Ubuntu 24.04"; "i")) | .id' 2>/dev/null \
    | head -1 || echo "")
if [ -z "$OS_ID" ]; then
    ws_fatal "Could not find Ubuntu 24.04 OS ID. Run 'vultr-cli os list' to see what's available and set --image-id by editing this script."
fi
ws_info "Ubuntu 24.04 OS id: ${OS_ID}"

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── SSH key (idempotent) ───────────────────────────────────────────────────
KEY_NAME="${WS_PREFIX}-key"
SSH_PUB=$(cat "$WS_SSH_KEY")
KEY_ID=$(vultr-cli ssh-key list -o json 2>/dev/null \
    | jq -r --arg n "$KEY_NAME" '.ssh_keys[] | select(.name==$n) | .id' 2>/dev/null \
    || echo "")
if [ -z "$KEY_ID" ]; then
    ws_info "Uploading SSH key '$KEY_NAME'"
    KEY_ID=$(vultr-cli ssh-key create --name "$KEY_NAME" --key "$SSH_PUB" -o json 2>/dev/null \
        | jq -r '.ssh_key.id')
    [ -n "$KEY_ID" ] && [ "$KEY_ID" != "null" ] || ws_fatal "Failed to create SSH key"
    ws_ok "SSH key uploaded (id $KEY_ID)"
else
    ws_info "SSH key '$KEY_NAME' already exists (id $KEY_ID) — reusing"
fi

# ─── Pre-flight: name collision ─────────────────────────────────────────────
existing_labels=$(vultr-cli instance list -o json 2>/dev/null | jq -r '.instances[].label' 2>/dev/null || echo "")
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if echo "$existing_labels" | grep -qx "$hn"; then
        ws_fatal "Instance '$hn' already exists. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_IDS[@]} instance(s)..."
    for id in "${CREATED_IDS[@]}"; do
        vultr-cli instance delete "$id" >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Creating ${WS_NODES} instances in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    # Vultr accepts cloud-init via --userdata as base64-encoded.
    ud_b64=$(printf '%s\n' "$cloud_init_yaml" | base64 | tr -d '\n')
    out_file="/tmp/wolfstack-vultr-$$-$i.out"
    (
        vultr-cli instance create \
            --region "$WS_REGION" \
            --plan "$WS_TYPE" \
            --os "$OS_ID" \
            --hostname "$hn" \
            --label "$hn" \
            --ssh-keys "$KEY_ID" \
            --userdata "$ud_b64" \
            -o json > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    hn="${entry%|*}"
    out_file="${entry##*|}"
    if wait "$pid"; then
        id=$(jq -r '.instance.id' < "$out_file" 2>/dev/null || echo "")
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
    rm -f "$out_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more instances failed. Cleanup ran."
fi

# ─── Wait for IPs (Vultr provisions async) ──────────────────────────────────
ws_info "Waiting for instances to receive public IPs..."
PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    ip=""
    for _ in $(seq 1 60); do
        ip=$(vultr-cli instance get "$id" -o json 2>/dev/null | jq -r '.instance.main_ip' 2>/dev/null || echo "")
        if [ -n "$ip" ] && [ "$ip" != "null" ] && [ "$ip" != "0.0.0.0" ]; then
            break
        fi
        sleep 5
    done
    label=$(vultr-cli instance get "$id" -o json 2>/dev/null | jq -r '.instance.label')
    PAIRS+=("${label}:${ip}")
    ws_info "  $label → $ip"
done

ws_info "Waiting for WolfStack to come up on each instance (~2-3 minutes)..."
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
