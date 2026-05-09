#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — DigitalOcean bootstrap
# Spins up N Droplets and installs WolfStack on each via cloud-init.
# Tags each Droplet with the prefix so --destroy can find them.
#
# Prerequisites:
#   * doctl CLI installed (https://github.com/digitalocean/doctl)
#   * `doctl auth init` configured (or DIGITALOCEAN_ACCESS_TOKEN env var)
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3× s-2vcpu-4gb in nyc3, ~$72/mo):
#   ./bootstrap.sh
#
# Tear down:
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="nyc3"            # New York 3 — common, cheap egress
# shellcheck disable=SC2034
ws_default_ssh_key=""

# Size → DigitalOcean droplet slug (May 2026 list price).
ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="s-2vcpu-4gb";  SIZE_DESC="2 vCPU / 4 GB / 80 GB SSD — \$24/mo (eval only)" ;;
        medium) WS_TYPE="s-4vcpu-8gb";  SIZE_DESC="4 vCPU / 8 GB / 160 GB SSD — \$48/mo (recommended)" ;;
        large)  WS_TYPE="s-8vcpu-16gb"; SIZE_DESC="8 vCPU / 16 GB / 320 GB SSD — \$96/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
IMAGE="ubuntu-24-04-x64"
SSH_USER="root"

print_help() {
    cat <<'HELP'
WolfStack — DigitalOcean bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of Droplets (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        DO slug: nyc3, sfo3, lon1, fra1, ams3, sgp1, syd1, blr1, tor1.
                      Default: nyc3.
  --size CLASS        small / medium / large. Default: medium.
                        small  = s-2vcpu-4gb  · 2 vCPU / 4 GB / 80 GB SSD  — $24/mo (eval only)
                        medium = s-4vcpu-8gb  · 4 vCPU / 8 GB / 160 GB SSD — $48/mo (recommended)
                        large  = s-8vcpu-16gb · 8 vCPU / 16 GB / 320 GB SSD — $96/mo
  --type STR          Override --size with an explicit DO slug
                      (s-1vcpu-1gb, s-2vcpu-2gb, c-2, g-2vcpu-8gb, etc.).
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
  --image STR         OS image (default: ubuntu-24-04-x64).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down resources tagged with the prefix.
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Examples:
  ./bootstrap.sh                                # 3× medium in nyc3 ≈ $144/mo
  ./bootstrap.sh --size large --region lon1     # 3× large in London ≈ $288/mo
  ./bootstrap.sh --type c-4 --nodes 5           # 5× CPU-optimised c-4 (custom)
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

# Resolve --size → --type unless --type was explicit
SIZE_DESC=""
if [ -z "$WS_TYPE" ]; then
    ws_size_to_type
fi

ws_require_cli "doctl" "https://github.com/digitalocean/doctl/releases (or 'brew install doctl')"
ws_require_cli "jq" "your distro's package manager"

if ! doctl account get >/dev/null 2>&1; then
    ws_err "doctl could not reach the DigitalOcean API."
    echo "  Configure: 'doctl auth init' (interactive)" >&2
    echo "  Or:       export DIGITALOCEAN_ACCESS_TOKEN=..." >&2
    exit 2
fi

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "DigitalOcean — tearing down WolfStack cluster '${WS_PREFIX}'"
    ids=$(doctl compute droplet list --tag-name "$WS_PREFIX" --format ID,Name --no-header 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ { print $1, $2 }')
    if [ -z "$ids" ]; then
        ws_warn "No Droplets tagged '${WS_PREFIX}'."
    else
        echo "  Will delete:"
        echo "$ids" | awk '{printf "    • %s (id %s)\n", $2, $1}'
        ws_confirm "Delete these Droplets permanently?"
        while read -r id _; do
            if doctl compute droplet delete "$id" --force >/dev/null 2>&1; then
                ws_ok "Deleted $id"
            else
                ws_err "Failed to delete $id"
            fi
        done <<< "$ids"
    fi
    # Clean up the SSH key if no other Droplets reference it.
    doctl compute ssh-key delete "${WS_PREFIX}-key" --force >/dev/null 2>&1 || true
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "DigitalOcean — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  Image:    ${IMAGE}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

if ! doctl compute region list --format Slug --no-header 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Region slug '${WS_REGION}' not valid for DigitalOcean."
    doctl compute region list >&2
    exit 2
fi
if ! doctl compute size list --format Slug --no-header 2>/dev/null | grep -qx "$WS_TYPE"; then
    ws_err "Size slug '${WS_TYPE}' not valid for DigitalOcean."
    echo "  Run 'doctl compute size list' for the full menu." >&2
    exit 2
fi

# Cost preview from doctl size list.
hourly_usd=$(doctl compute size list --format Slug,PriceHourly --no-header 2>/dev/null \
    | awk -v t="$WS_TYPE" '$1==t {print $2}' || echo "")
if [ -n "$hourly_usd" ]; then
    monthly=$(awk "BEGIN { printf \"%.2f\", $hourly_usd * 24 * 30 * $WS_NODES }")
    echo "  Estimated cost: \$${monthly}/mo for the cluster"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

# Cluster secret — distributed via cloud-init for inter-node auth.
CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── SSH key (idempotent) ───────────────────────────────────────────────────
KEY_NAME="${WS_PREFIX}-key"
KEY_FP=$(ssh-keygen -lf "$WS_SSH_KEY" 2>/dev/null | awk '{print $2}' | tr -d '\n' || echo "")
if [ -z "$KEY_FP" ]; then
    ws_fatal "Could not compute fingerprint for $WS_SSH_KEY"
fi

# DO returns a different fingerprint format (MD5) from ssh-keygen's modern
# default (SHA256). The reliable check is by name.
if doctl compute ssh-key list --format Name --no-header 2>/dev/null | grep -qx "$KEY_NAME"; then
    ws_info "SSH key '$KEY_NAME' already in DigitalOcean — reusing"
else
    ws_info "Importing SSH key as '$KEY_NAME'"
    doctl compute ssh-key import "$KEY_NAME" --public-key-file "$WS_SSH_KEY" >/dev/null
    ws_ok "SSH key imported"
fi

KEY_ID=$(doctl compute ssh-key list --format ID,Name --no-header 2>/dev/null | awk -v n="$KEY_NAME" '$2==n {print $1}')

# ─── Pre-flight: name collision ─────────────────────────────────────────────
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if doctl compute droplet list --format Name --no-header 2>/dev/null | grep -qx "$hn"; then
        ws_fatal "Droplet '$hn' already exists. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_IDS[@]} Droplet(s)..."
    for id in "${CREATED_IDS[@]}"; do
        doctl compute droplet delete "$id" --force >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Creating ${WS_NODES} Droplets in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    ud_file="/tmp/wolfstack-do-$$-$i.yaml"
    out_file="/tmp/wolfstack-do-$$-$i.out"
    printf '%s\n' "$cloud_init_yaml" > "$ud_file"
    (
        doctl compute droplet create "$hn" \
            --size "$WS_TYPE" \
            --image "$IMAGE" \
            --region "$WS_REGION" \
            --ssh-keys "$KEY_ID" \
            --tag-name "$WS_PREFIX" \
            --user-data-file "$ud_file" \
            --wait \
            --format ID --no-header > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}|${ud_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    hn="${entry%%|*}"
    rest="${entry#*|}"
    out_file="${rest%%|*}"
    ud_file="${rest##*|}"
    if wait "$pid"; then
        id=$(tr -d ' \n' < "$out_file")
        if [[ "$id" =~ ^[0-9]+$ ]]; then
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
    ws_fatal "One or more Droplets failed. Cleanup ran."
fi

# ─── Wait for cloud-init ────────────────────────────────────────────────────
PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    json=$(doctl compute droplet get "$id" --output json 2>/dev/null)
    name=$(echo "$json" | jq -r '.[0].name')
    ipv4=$(echo "$json" | jq -r '.[0].networks.v4[] | select(.type=="public") | .ip_address')
    PAIRS+=("${name}:${ipv4}")
done

ws_info "Waiting for WolfStack to come up on each Droplet (~60-90 seconds)..."
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
