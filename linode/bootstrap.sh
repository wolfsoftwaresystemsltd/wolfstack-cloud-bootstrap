#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Linode (Akamai Cloud) bootstrap
# Spins up N Linodes and installs WolfStack via cloud-init metadata.
# Tags each Linode with the prefix so --destroy can find them.
#
# Prerequisites:
#   * linode-cli installed (pip install linode-cli  OR  brew install linode-cli)
#   * `linode-cli configure` done (or LINODE_CLI_TOKEN env var)
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3× g6-standard-2 in us-east, ~$72/mo):
#   ./bootstrap.sh
#
# Tear down:
#   ./bootstrap.sh --destroy --prefix wolfstack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# shellcheck disable=SC2034
ws_default_region="us-east"         # Newark, NJ
# shellcheck disable=SC2034
ws_default_ssh_key=""

ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="g6-standard-2"; SIZE_DESC="2 vCPU / 4 GB / 80 GB SSD — \$24/mo (eval only)" ;;
        medium) WS_TYPE="g6-standard-4"; SIZE_DESC="4 vCPU / 8 GB / 160 GB SSD — \$48/mo (recommended)" ;;
        large)  WS_TYPE="g6-standard-6"; SIZE_DESC="6 vCPU / 16 GB / 320 GB SSD — \$96/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
IMAGE="linode/ubuntu24.04"
SSH_USER="root"

print_help() {
    cat <<'HELP'
WolfStack — Linode (Akamai Cloud) bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of Linodes (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        Linode region: us-east, us-west, us-central, eu-west,
                      ap-south, ap-southeast, etc. Default: us-east.
  --size CLASS        small / medium / large. Default: medium.
                        small  = g6-standard-2 · 2 vCPU / 4 GB / 80 GB SSD  — $24/mo (eval only)
                        medium = g6-standard-4 · 4 vCPU / 8 GB / 160 GB SSD — $48/mo (recommended)
                        large  = g6-standard-6 · 6 vCPU / 16 GB / 320 GB SSD — $96/mo
  --type STR          Override --size with explicit Linode type
                      (g6-nanode-1, g6-standard-1, g6-dedicated-2, etc.).
  --ssh-key PATH      Public SSH key (default: auto-detect ~/.ssh/id_*.pub).
  --image STR         OS image (default: linode/ubuntu24.04).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down resources tagged with the prefix.
  --yes, -y           Skip confirmation.
  --help, -h          Show this help.

Cost estimate (May 2026):
  g6-nanode-1     ≈ $5/mo   →  3 nodes ≈ $15/mo
  g6-standard-2   ≈ $24/mo  →  3 nodes ≈ $72/mo
  g6-standard-4   ≈ $48/mo  →  3 nodes ≈ $144/mo
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

ws_require_cli "linode-cli" "pip install linode-cli  OR  brew install linode-cli"
ws_require_cli "jq" "your distro's package manager"

# Auth check — `linode-cli account view` is the cheapest verifiable call.
if ! linode-cli account view --json >/dev/null 2>&1; then
    ws_err "linode-cli is not authenticated."
    echo "  Run: linode-cli configure" >&2
    echo "  Or:  export LINODE_CLI_TOKEN=..." >&2
    exit 2
fi

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "Linode — tearing down WolfStack cluster '${WS_PREFIX}'"
    instances=$(linode-cli linodes list --json 2>/dev/null \
        | jq -r --arg p "${WS_PREFIX}-" '.[] | select(.label | startswith($p)) | "\(.id) \(.label)"' 2>/dev/null \
        || echo "")
    if [ -z "$instances" ]; then
        ws_warn "No Linodes found with prefix '${WS_PREFIX}-'."
    else
        echo "  Will delete:"
        echo "$instances" | awk '{printf "    • %s (id %s)\n", $2, $1}'
        ws_confirm "Delete these Linodes permanently?"
        while read -r id _; do
            [ -z "$id" ] && continue
            if linode-cli linodes delete "$id" >/dev/null 2>&1; then
                ws_ok "Deleted $id"
            else
                ws_err "Failed to delete $id"
            fi
        done <<< "$instances"
    fi
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "Linode — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  Image:    ${IMAGE}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

if ! linode-cli regions list --json 2>/dev/null \
    | jq -r '.[].id' 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Region '${WS_REGION}' not valid for Linode."
    echo "  Run: linode-cli regions list" >&2
    exit 2
fi
if ! linode-cli linodes types --json 2>/dev/null \
    | jq -r '.[].id' 2>/dev/null | grep -qx "$WS_TYPE"; then
    ws_err "Type '${WS_TYPE}' not valid for Linode."
    echo "  Run: linode-cli linodes types" >&2
    exit 2
fi

# Cost preview from the types list.
hourly_cents=$(linode-cli linodes types --json 2>/dev/null \
    | jq -r --arg t "$WS_TYPE" '.[] | select(.id==$t) | .price.hourly' 2>/dev/null || echo "")
if [ -n "$hourly_cents" ] && [ "$hourly_cents" != "null" ]; then
    monthly=$(awk "BEGIN { printf \"%.2f\", $hourly_cents * 24 * 30 * $WS_NODES }")
    echo "  Estimated cost: \$${monthly}/mo for the cluster"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── Pre-flight: name collision ─────────────────────────────────────────────
existing=$(linode-cli linodes list --json 2>/dev/null | jq -r '.[].label' 2>/dev/null || echo "")
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if echo "$existing" | grep -qx "$hn"; then
        ws_fatal "Linode '$hn' already exists. Pick a different --prefix or --destroy first."
    fi
done

# Linode requires a root password at create time. Use ROOT_PASSWORD (the
# same one cloud-init sets via chpasswd) so what we tell the operator
# matches what's actually on the box. Otherwise the Linode-set password
# would briefly disagree with the chpasswd one, then cloud-init overwrites
# it and the operator's printed password works only after a few seconds.
ROOT_PASS="$ROOT_PASSWORD"

# ─── Provision ──────────────────────────────────────────────────────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — deleting ${#CREATED_IDS[@]} Linode(s)..."
    for id in "${CREATED_IDS[@]}"; do
        linode-cli linodes delete "$id" >/dev/null 2>&1 || true
    done
}
trap 'cleanup_on_error' ERR INT TERM

SSH_PUB=$(cat "$WS_SSH_KEY")

ws_info "Creating ${WS_NODES} Linodes in parallel..."
declare -A pid_to_entry
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    ud_b64=$(printf '%s\n' "$cloud_init_yaml" | base64 | tr -d '\n')
    out_file="/tmp/wolfstack-linode-$$-$i.out"
    (
        linode-cli linodes create \
            --type "$WS_TYPE" \
            --region "$WS_REGION" \
            --image "$IMAGE" \
            --label "$hn" \
            --root_pass "$ROOT_PASS" \
            --authorized_keys "$SSH_PUB" \
            --tags "$WS_PREFIX" \
            --metadata.user_data "$ud_b64" \
            --json > "$out_file" 2>&1
    ) &
    pid_to_entry[$!]="${hn}|${out_file}"
done

all_ok=true
for pid in "${!pid_to_entry[@]}"; do
    entry="${pid_to_entry[$pid]}"
    hn="${entry%|*}"
    out_file="${entry##*|}"
    if wait "$pid"; then
        id=$(jq -r '.[0].id' < "$out_file" 2>/dev/null || echo "")
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
    rm -f "$out_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more Linodes failed. Cleanup ran."
fi

# ─── Collect IPs + wait for cloud-init ──────────────────────────────────────
PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    json=$(linode-cli linodes view "$id" --json 2>/dev/null)
    label=$(echo "$json" | jq -r '.[0].label')
    ipv4=$(echo "$json" | jq -r '.[0].ipv4[0]')
    PAIRS+=("${label}:${ipv4}")
done

ws_info "Waiting for WolfStack to come up on each Linode (~2-3 minutes)..."
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
