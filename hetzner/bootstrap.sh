#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — Hetzner Cloud bootstrap
# Spins up N Hetzner Cloud VMs in your chosen location and installs
# WolfStack on each via cloud-init. After provisioning, follow the
# printed instructions to fetch each node's join token and wire them
# into a cluster from the master's dashboard.
#
# Prerequisites:
#   * hcloud CLI installed (https://github.com/hetznercloud/cli)
#   * HCLOUD_TOKEN env var set (or `hcloud context create` configured)
#   * SSH public key (default: ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
#
# Quick start (3 cx21 nodes in Nuremberg, ~€16.50/mo):
#   export HCLOUD_TOKEN="..."
#   ./bootstrap.sh
#
# Custom:
#   ./bootstrap.sh --nodes 5 --type cx31 --region fsn1 --prefix prod
#
# Tear down (deletes every VM whose name starts with the prefix):
#   ./bootstrap.sh --destroy --prefix prod

set -euo pipefail

# Source the shared helpers. Resolve relative to this script so the
# repo can be cloned anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# ─── Provider defaults (override via flags) ─────────────────────────────────
# These look unused to shellcheck because they're consumed by ws_parse_args
# (defined in common.sh) via lookup. They're the contract.
# shellcheck disable=SC2034
ws_default_region="nbg1"     # Nuremberg, Germany — cheap, well-connected
# shellcheck disable=SC2034
ws_default_ssh_key=""        # auto-detected by ws_parse_args

# Size → Hetzner server type mapping (May 2026 pricing, ex-VAT).
# small  = evaluation only, NOT for production workloads
# medium = the default; runs Docker + a few LXCs comfortably
# large  = serious workloads, multiple VMs / heavy Docker / dense LXC
ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="cx22"; SIZE_DESC="2 vCPU / 4 GB / 40 GB — €4.51/mo (eval only)" ;;
        medium) WS_TYPE="cx32"; SIZE_DESC="4 vCPU / 8 GB / 80 GB — €9.42/mo (recommended)" ;;
        large)  WS_TYPE="cx42"; SIZE_DESC="8 vCPU / 16 GB / 160 GB — €19.69/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

# Provider-specific extras
ACTION="provision"
IMAGE="ubuntu-24.04"
SSH_USER="root"   # Hetzner cloud images ship with root + SSH-key auth

print_help() {
    cat <<'HELP'
WolfStack — Hetzner Cloud bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of VMs to create (default: 3)
  --prefix STR        Hostname prefix → '<prefix>-1', '<prefix>-2', …
                      (default: wolfstack). Also used by --destroy to find
                      VMs to delete.
  --region STR        Hetzner location code: nbg1 (Nuremberg), fsn1 (Falkenstein),
                      hel1 (Helsinki), ash (Ashburn US), hil (Hillsboro US),
                      sin (Singapore). Default: nbg1.
  --size CLASS        small / medium / large. Default: medium.
                        small  = cx22  · 2 vCPU / 4 GB / 40 GB  — €4.51/mo (eval only)
                        medium = cx32  · 4 vCPU / 8 GB / 80 GB  — €9.42/mo (recommended)
                        large  = cx42  · 8 vCPU / 16 GB / 160 GB — €19.69/mo
                      4 GB is too tight for real Docker + LXC + VM workloads;
                      we default to medium. Use --size small only if you're
                      evaluating WolfStack itself with no other workloads.
  --type STR          Override --size with an explicit Hetzner server type
                      (cx22, cx32, cx42, cpx21, cpx31, cpx41, cpx51, etc.).
                      Run 'hcloud server-type list' for the full menu.
  --ssh-key PATH      Public SSH key to upload (default: ~/.ssh/id_ed25519.pub
                      or ~/.ssh/id_rsa.pub).
  --image STR         OS image (default: ubuntu-24.04).
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down every VM whose name starts with --prefix.
  --yes, -y           Skip confirmation prompts.
  --help, -h          Show this help.

Environment:
  HCLOUD_TOKEN        Hetzner Cloud API token. Required if not configured
                      via 'hcloud context create'.

Examples:
  ./bootstrap.sh                                # 3× cx32 (medium) in nbg1 ≈ €28.26/mo
  ./bootstrap.sh --size large --region fsn1     # 3× cx42 ≈ €59.07/mo
  ./bootstrap.sh --type cpx41 --nodes 5         # 5× cpx41 (custom)
  ./bootstrap.sh --destroy --prefix wolfstack   # tear down
HELP
}

# ─── Parse provider-specific flags BEFORE common args ───────────────────────
# Walk argv twice: first pull out our --destroy / --image flags, then hand
# the remainder to ws_parse_args. This keeps common.sh agnostic to provider-
# specific options.
PASSTHROUGH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --destroy) ACTION="destroy" ;;
        --image)
            shift
            IMAGE="${1:-}"
            [ -n "$IMAGE" ] || ws_fatal "--image requires a value"
            ;;
        *) PASSTHROUGH_ARGS+=("$1") ;;
    esac
    shift
done
ws_parse_args "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"

# Resolve --size → --type (only when --type wasn't given explicitly).
SIZE_DESC=""
if [ -z "$WS_TYPE" ]; then
    ws_size_to_type
fi

# ─── Sanity checks ──────────────────────────────────────────────────────────
ws_require_cli "hcloud" "https://github.com/hetznercloud/cli/releases (or 'brew install hcloud')"
ws_require_cli "jq" "your distro's package manager ('apt install jq' / 'brew install jq')"

# Verify credentials early — a bad token here is the #1 cause of failure.
if ! hcloud server list >/dev/null 2>&1; then
    ws_err "hcloud could not reach the Hetzner API."
    echo "  Either:" >&2
    echo "    • Set HCLOUD_TOKEN to a valid API token from console.hetzner.cloud → Security → API Tokens" >&2
    echo "    • Or run 'hcloud context create wolfstack' and paste the token interactively" >&2
    exit 2
fi

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "Hetzner Cloud — tearing down WolfStack cluster"
    # List every server whose name starts with the prefix.
    matching=$(hcloud server list -o noheader -o columns=id,name 2>/dev/null \
        | awk -v p="${WS_PREFIX}-" '$2 ~ "^"p {print $1, $2}')
    if [ -z "$matching" ]; then
        ws_warn "No servers found with prefix '${WS_PREFIX}-' — nothing to do."
        exit 0
    fi
    echo "  Will delete:"
    echo "$matching" | awk '{printf "    • %s (id %s)\n", $2, $1}'
    ws_confirm "Delete these ${WS_PREFIX}-* servers permanently?"
    while read -r id _; do
        ws_info "Deleting server id=$id"
        if hcloud server delete "$id" >/dev/null 2>&1; then
            ws_ok "Deleted $id"
        else
            ws_err "Failed to delete $id"
        fi
    done <<< "$matching"
    # Also clean the SSH key we created (named after the prefix). If other
    # clusters share the prefix, this is a no-op (key in use).
    hcloud ssh-key delete "${WS_PREFIX}-key" >/dev/null 2>&1 || true
    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "Hetzner Cloud — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  Image:    ${IMAGE}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

# Validate the chosen region exists. hcloud's `location list` is the
# authoritative source — region codes change over time.
if ! hcloud location list -o noheader -o columns=name 2>/dev/null | grep -qx "$WS_REGION"; then
    ws_err "Region '$WS_REGION' is not valid for Hetzner Cloud."
    echo "  Available locations:" >&2
    hcloud location list -o columns=name,city,country >&2
    exit 2
fi

# Validate the server type. Same reasoning as region.
if ! hcloud server-type list -o noheader -o columns=name 2>/dev/null | grep -qx "$WS_TYPE"; then
    ws_err "Server type '$WS_TYPE' is not valid for Hetzner Cloud."
    echo "  Run 'hcloud server-type list' for the full menu." >&2
    exit 2
fi

# Validate the image exists in the chosen architecture. cx-series uses x86,
# cax-series uses ARM — wrong combo gives a confusing error from the API.
if ! hcloud image list --type system -o noheader -o columns=name 2>/dev/null | grep -qx "$IMAGE"; then
    ws_warn "Image '$IMAGE' not found in the public list — proceeding anyway"
    ws_warn "(Hetzner sometimes lists images by version. Check 'hcloud image list' if create fails.)"
fi

# Cost preview. Hetzner's per-type hourly cost is in the API; the monthly
# estimate is just hourly × 24 × 30 (their billing rounds differently but
# the number is close enough for a "what will this cost me" gut check).
hourly_eur=$(hcloud server-type describe "$WS_TYPE" -o json 2>/dev/null \
    | jq -r --arg loc "$WS_REGION" \
        '.prices[] | select(.location==$loc) | .price_hourly.gross' 2>/dev/null \
    || echo "")
if [ -n "$hourly_eur" ] && [ "$hourly_eur" != "null" ]; then
    monthly=$(awk "BEGIN { printf \"%.2f\", $hourly_eur * 24 * 30 * $WS_NODES }")
    echo "  Estimated cost: €${monthly}/month for the cluster (gross, ${WS_NODES}× ${WS_TYPE} in ${WS_REGION})"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

# ─── Generate cluster secret ────────────────────────────────────────────────
# Used by every node's WolfStack instance for inter-node auth. Distributed
# via cloud-init write_files to /etc/wolfstack/custom-cluster-secret on each
# VM. ws_form_cluster relies on this being shared so the master can poll
# peers without per-node tokens.
CLUSTER_SECRET=$(openssl rand -hex 32)

# ─── Upload SSH key (idempotent) ────────────────────────────────────────────
KEY_NAME="${WS_PREFIX}-key"
if hcloud ssh-key list -o noheader -o columns=name 2>/dev/null | grep -qx "$KEY_NAME"; then
    ws_info "SSH key '$KEY_NAME' already in Hetzner — reusing"
else
    ws_info "Uploading SSH key '$KEY_NAME' to Hetzner"
    hcloud ssh-key create --name "$KEY_NAME" --public-key-from-file "$WS_SSH_KEY" >/dev/null
    ws_ok "SSH key uploaded"
fi

# ─── Provision in parallel with cleanup-on-failure trap ─────────────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — tearing down ${#CREATED_IDS[@]} created VM(s)..."
    for id in "${CREATED_IDS[@]}"; do
        hcloud server delete "$id" >/dev/null 2>&1 || true
    done
    ws_ok "Cleanup complete."
}
trap 'cleanup_on_error' ERR INT TERM

# Pre-flight: refuse if any of the target hostnames already exist as
# servers — protects the operator from accidentally clobbering an
# existing cluster they forgot about.
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    if hcloud server list -o noheader -o columns=name 2>/dev/null | grep -qx "$hn"; then
        ws_fatal "Server '$hn' already exists in your Hetzner account. Pick a different --prefix or --destroy first."
    fi
done

# Provision in parallel using background jobs. Keep PIDs in an array so we
# can wait on them and capture failures.
ws_info "Provisioning ${WS_NODES} servers in parallel..."
declare -A pid_to_hostname
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET")
    # `--user-data` accepts the YAML on stdin via process substitution.
    # We capture stdout (the new server ID + name) so we know what to
    # roll back if a later one fails.
    (
        hcloud server create \
            --name "$hn" \
            --type "$WS_TYPE" \
            --image "$IMAGE" \
            --location "$WS_REGION" \
            --ssh-key "$KEY_NAME" \
            --user-data-from-file <(printf '%s\n' "$cloud_init_yaml") \
            -o noheader -o columns=id,name \
            > "/tmp/wolfstack-hcloud-$$-$i.out" 2>&1
    ) &
    pid_to_hostname[$!]="$hn"
done

# Wait for each background job; record IDs for cleanup-on-failure.
all_ok=true
for pid in "${!pid_to_hostname[@]}"; do
    hn="${pid_to_hostname[$pid]}"
    if wait "$pid"; then
        out_file="/tmp/wolfstack-hcloud-$$-${hn##*-}.out"
        id=$(awk '{print $1}' < "$out_file" 2>/dev/null || echo "")
        if [ -n "$id" ]; then
            CREATED_IDS+=("$id")
            ws_ok "Created $hn (id $id)"
        else
            ws_err "Created $hn but couldn't parse id (output below)"
            cat "$out_file" >&2 || true
            all_ok=false
        fi
    else
        ws_err "Failed to create $hn"
        cat "/tmp/wolfstack-hcloud-$$-${hn##*-}.out" >&2 || true
        all_ok=false
    fi
    rm -f "/tmp/wolfstack-hcloud-$$-${hn##*-}.out" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more servers failed to provision. Cleanup ran. See errors above."
fi

# ─── Wait for IPs + cloud-init to finish ────────────────────────────────────
ws_info "Waiting for cloud-init to finish on each node (~60-90 seconds)..."
echo "  (WolfStack downloads + installs a ~30MB binary on first boot.)"
echo ""

PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    json=$(hcloud server describe "$id" -o json)
    name=$(echo "$json" | jq -r '.name')
    ipv4=$(echo "$json" | jq -r '.public_net.ipv4.ip')
    PAIRS+=("${name}:${ipv4}")
done

# Poll port 8553 (the WolfStack dashboard) on each node. Once it's up,
# cloud-init has finished and the node is alive.
for pair in "${PAIRS[@]}"; do
    hn="${pair%%:*}"
    ip="${pair##*:}"
    ws_info "Waiting for ${hn} (${ip}:8553) ..."
    waited=0
    while [ $waited -lt 600 ]; do
        if curl -k --connect-timeout 3 -o /dev/null -s "https://${ip}:8553/" 2>/dev/null; then
            ws_ok "${hn} is up"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    if [ $waited -ge 600 ]; then
        ws_warn "${hn} did not come up within 10 minutes. SSH in to inspect: ssh root@${ip} 'journalctl -u wolfstack -n 50'"
    fi
done

# ─── Disable the cleanup trap — we made it past the danger zone ────────────
trap - ERR INT TERM

# ─── Auto-form the cluster ──────────────────────────────────────────────────
# SSH into each VM, fetch its node_id, build a unified nodes.json with all
# peers, push it back, restart wolfstack. Cluster polling reconciles state
# within ~10 seconds.
ws_form_cluster "$SSH_USER" "${PAIRS[@]}"

ws_summary "${PAIRS[@]}"
