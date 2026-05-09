# shellcheck shell=bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# common.sh — shared helpers for the per-cloud WolfStack bootstrap scripts.
#
# Sourced (not executed) by hetzner/bootstrap.sh, aws/bootstrap.sh, etc.
# Centralises argument parsing, validation, cloud-init generation, banner
# printing, and partial-failure cleanup so each provider script can focus
# on the provider-specific provisioning calls.
#
# Conventions:
#   * Functions prefixed `ws_` to avoid clobbering shell builtins or any
#     environment the operator already has set
#   * Errors go to stderr (>&2) and exit non-zero
#   * Status output uses unicode arrows / ticks; readable without colour
#   * No `set -e` here — sourced files inherit the caller's options;
#     each provider script sets its own `set -euo pipefail`

# ─── Logging helpers ─────────────────────────────────────────────────────────
ws_info()  { printf '\033[36m→\033[0m %s\n' "$*"; }
ws_ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
ws_warn()  { printf '\033[33m⚠\033[0m %s\n' "$*" >&2; }
ws_err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ws_fatal() { ws_err "$*"; exit 1; }

ws_banner() {
    local title="$1"
    local width=72
    printf '\n'
    printf '%*s\n' "$width" '' | tr ' ' '─'
    printf '  %s\n' "$title"
    printf '%*s\n' "$width" '' | tr ' ' '─'
}

# ─── Default arguments common to every provider script ──────────────────────
# Provider scripts can override any of these before calling ws_parse_args.
ws_default_nodes=3
ws_default_prefix="wolfstack"
ws_default_branch="master"
ws_default_yes=false
ws_default_size="medium"
# Region, ssh_key are provider-specific and may be set by each script.
# `ws_default_type` is intentionally NOT set: each provider script maps
# WS_SIZE → WS_TYPE after ws_parse_args returns. The user can pass
# --type explicitly to override the size mapping for fine control.

# ─── Argument parser ─────────────────────────────────────────────────────────
# Reads argv into shell variables. Provider scripts call this AFTER setting
# their own `ws_default_*` overrides and provider-specific defaults.
#
# Common flags handled here:
#   --nodes N         number of VMs to create (default 3)
#   --prefix STR      hostname prefix (default 'wolfstack' → wolfstack-1, wolfstack-2…)
#   --region X        provider-specific region/zone/datacenter
#   --size CLASS      one of small / medium / large (default: medium).
#                     Each provider script maps these to a sensible
#                     instance type — see the provider's --help for what
#                     small/medium/large resolve to and their cost.
#   --type X          provider-specific VM type — overrides --size.
#                     Use this when you want a specific instance type
#                     that doesn't fit the small/medium/large bucket.
#   --ssh-key PATH    path to public SSH key file (default ~/.ssh/id_ed25519.pub
#                     or ~/.ssh/id_rsa.pub, whichever exists)
#   --beta            use the beta WolfStack branch
#   --yes, -y         skip the "are you sure?" prompt
#   --help, -h        provider script's print_help is called
#
# Sets the following variables for the provider script to consume:
#   WS_NODES, WS_PREFIX, WS_REGION, WS_SIZE, WS_TYPE, WS_SSH_KEY,
#   WS_BRANCH, WS_YES
# WS_TYPE is empty unless the user passed --type explicitly. Provider
# scripts inspect this and fall back to a size→type mapping when empty.
# (The shellcheck disable below is because these vars look unused inside
# common.sh — they're the function's contract with the caller.)
# shellcheck disable=SC2034
ws_parse_args() {
    WS_NODES="$ws_default_nodes"
    WS_PREFIX="$ws_default_prefix"
    WS_REGION="${ws_default_region:-}"
    WS_SIZE="$ws_default_size"
    WS_TYPE=""
    WS_SSH_KEY="${ws_default_ssh_key:-}"
    WS_BRANCH="$ws_default_branch"
    WS_YES="$ws_default_yes"

    while [ $# -gt 0 ]; do
        case "$1" in
            --nodes)
                shift
                if ! [[ "${1:-}" =~ ^[0-9]+$ ]] || [ "${1:-0}" -lt 1 ]; then
                    ws_fatal "--nodes requires a positive integer (got: '${1:-}')"
                fi
                WS_NODES="$1"
                ;;
            --prefix)
                shift
                WS_PREFIX="${1:-}"
                if [ -z "$WS_PREFIX" ]; then
                    ws_fatal "--prefix requires a name argument"
                fi
                # RFC 1123 prefix check — full-name is prefix-N, so prefix
                # itself must be DNS-safe minus the trailing index.
                if ! echo "$WS_PREFIX" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,58}[a-zA-Z0-9])?$'; then
                    ws_fatal "--prefix must be DNS-safe (letters, digits, hyphens; max 60 chars)"
                fi
                ;;
            --region)
                shift
                WS_REGION="${1:-}"
                [ -n "$WS_REGION" ] || ws_fatal "--region requires a value"
                ;;
            --size)
                shift
                case "${1:-}" in
                    small|medium|large) WS_SIZE="$1" ;;
                    *) ws_fatal "--size must be one of: small, medium, large (got: '${1:-}')" ;;
                esac
                ;;
            --type)
                shift
                WS_TYPE="${1:-}"
                [ -n "$WS_TYPE" ] || ws_fatal "--type requires a value"
                ;;
            --ssh-key)
                shift
                WS_SSH_KEY="${1:-}"
                [ -n "$WS_SSH_KEY" ] || ws_fatal "--ssh-key requires a path"
                ;;
            --beta)
                WS_BRANCH="beta"
                ;;
            --yes|-y)
                WS_YES=true
                ;;
            --help|-h)
                if declare -f print_help >/dev/null 2>&1; then
                    print_help
                else
                    echo "(no help available — provider script did not define print_help)"
                fi
                exit 0
                ;;
            *)
                ws_fatal "Unknown argument: '$1' (try --help)"
                ;;
        esac
        shift
    done

    # Auto-detect SSH key if not given — try ed25519 first, then RSA.
    if [ -z "$WS_SSH_KEY" ]; then
        for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
            if [ -f "$k" ]; then
                WS_SSH_KEY="$k"
                break
            fi
        done
    fi
    if [ -z "$WS_SSH_KEY" ] || [ ! -f "$WS_SSH_KEY" ]; then
        ws_fatal "No SSH public key found. Generate one with 'ssh-keygen -t ed25519' or pass --ssh-key PATH"
    fi
}

# ─── CLI tool detection ──────────────────────────────────────────────────────
# Provider scripts call this with the CLI binary name they need. If missing,
# print provider-specific install instructions and exit.
ws_require_cli() {
    local bin="$1"
    local install_hint="$2"
    if ! command -v "$bin" >/dev/null 2>&1; then
        ws_err "Required CLI tool not found: $bin"
        echo "  Install: $install_hint" >&2
        exit 2
    fi
}

# ─── Cloud-init generator ────────────────────────────────────────────────────
# Returns (on stdout) a #cloud-config YAML that:
#   1. write_files: pre-creates /etc/wolfstack/custom-cluster-secret with the
#      cluster's shared secret (mode 0600). This MUST exist before WolfStack
#      starts so inter-node X-WolfStack-Secret auth works for the cluster
#      polling that auto-forms the cluster.
#   2. runcmd: fetches and runs cloud-setup.sh from the WolfStack repo,
#      which sets the hostname and runs setup.sh non-interactively.
#
# Args:
#   $1  hostname for this VM
#   $2  WolfStack branch (master / beta)
#   $3  cluster secret (64 hex chars from `openssl rand -hex 32`)
#
# Note on secrecy: the cluster secret transits via the cloud provider's
# user-data store briefly. On all providers we tested, user-data is owner-
# scoped and removed when the VM is destroyed. Customers with regulatory
# paranoia about credentials in metadata can fall back to the manual
# token-paste flow (see the README).
ws_cloud_init() {
    local hostname="$1"
    local branch="$2"
    local cluster_secret="$3"
    cat <<EOF
#cloud-config
package_update: false
write_files:
  - path: /etc/wolfstack/custom-cluster-secret
    permissions: '0600'
    owner: root:root
    content: ${cluster_secret}
runcmd:
  - [ bash, -c, "curl --proto '=https' -fsSL 'https://raw.githubusercontent.com/wolfsoftwaresystemsltd/WolfStack/${branch}/cloud-setup.sh' | bash -s -- --hostname '${hostname}'" ]
EOF
}

# ─── Cluster auto-form helper ───────────────────────────────────────────────
# After every VM is up, fetch each one's self-generated node_id, build a
# unified nodes.json containing every peer (with join_verified=true so
# WolfStack's purge_unverified() doesn't drop them on next startup), push
# it to each VM, and restart wolfstack so it loads the cluster topology.
# Cluster polling (every 10s) takes over from there and the cluster forms.
#
# Args:
#   $1  ssh user (root / ubuntu / azureuser / etc — varies by provider)
#   $2..$N  pairs in the form "hostname:ip"
#
# Returns 0 on success. Logs warnings (but doesn't abort) if individual
# nodes fail to reach. The cluster is recoverable manually via the regular
# Add Node form if any single node didn't auto-join cleanly.
ws_form_cluster() {
    local ssh_user="$1"
    shift
    local pairs=("$@")
    local n=${#pairs[@]}
    if [ "$n" -lt 2 ]; then
        ws_info "Single-node cluster — no peers to wire up"
        return 0
    fi

    ws_info "Auto-forming cluster across $n nodes..."

    # SSH options: accept new host keys (we just provisioned them, so
    # there's no prior key to compare against), short timeout, batch mode
    # (no interactive prompts), don't pollute the user's known_hosts.
    local ssh_opts=(
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=/dev/null"
        -o "GlobalKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -o "ConnectTimeout=15"
        -o "BatchMode=yes"
    )

    # ─── Step 1: collect each node's self_id via SSH ─────────────────────
    local node_ids=()
    local hostnames=()
    local ips=()
    local i
    for i in "${!pairs[@]}"; do
        local pair="${pairs[$i]}"
        local hn="${pair%%:*}"
        local ip="${pair##*:}"
        hostnames+=("$hn")
        ips+=("$ip")

        local id=""
        local attempts=0
        # node_id is generated on first WolfStack startup; if cloud-init
        # is still running it might not exist yet. Poll for ~60s.
        while [ "$attempts" -lt 12 ]; do
            id=$(ssh "${ssh_opts[@]}" "${ssh_user}@${ip}" \
                "sudo cat /etc/wolfstack/node_id 2>/dev/null" 2>/dev/null \
                | tr -d ' \r\n' || echo "")
            [ -n "$id" ] && break
            sleep 5
            attempts=$((attempts + 1))
        done
        if [ -z "$id" ]; then
            ws_warn "Could not read node_id from $hn ($ip) — will skip auto-join for this node"
            id="UNKNOWN-$i"
        fi
        node_ids+=("$id")
    done

    # ─── Step 2: build nodes.json (one per VM, contains all OTHER peers) ─
    # WolfStack's save_nodes() only persists non-self nodes — i.e. each
    # node's nodes.json contains its peers, not itself. We mirror that.
    local now
    now=$(date -u +%s)
    for i in "${!pairs[@]}"; do
        local self_ip="${ips[$i]}"
        local self_hn="${hostnames[$i]}"

        # Build a JSON array of every OTHER node
        local entries=""
        local first=true
        local j
        for j in "${!pairs[@]}"; do
            [ "$j" = "$i" ] && continue
            [ "${node_ids[$j]}" = "UNKNOWN-$j" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                entries="${entries},"
            fi
            entries+=$(cat <<EOF
{"id":"${node_ids[$j]}","hostname":"${hostnames[$j]}","address":"${ips[$j]}","port":8553,"last_seen":${now},"metrics":null,"components":[],"online":false,"is_self":false,"docker_count":0,"lxc_count":0,"vm_count":0,"node_type":"wolfstack","join_verified":true,"has_docker":false,"has_lxc":false,"has_kvm":false,"login_disabled":false,"tls":true}
EOF
)
        done

        local nodes_json="[${entries}]"

        # ─── Step 3: push nodes.json to this VM and reload wolfstack ─────
        # Heredoc through ssh: tee the JSON in as root, fix permissions,
        # then restart wolfstack so load_nodes() picks it up.
        if printf '%s\n' "$nodes_json" \
            | ssh "${ssh_opts[@]}" "${ssh_user}@${self_ip}" \
                "sudo tee /etc/wolfstack/nodes.json >/dev/null \
                 && sudo chmod 600 /etc/wolfstack/nodes.json \
                 && sudo chown root:root /etc/wolfstack/nodes.json \
                 && sudo systemctl restart wolfstack" 2>/dev/null; then
            ws_ok "Wired ${self_hn} into the cluster"
        else
            ws_warn "Could not push nodes.json to ${self_hn} — join manually via the master's Add Node form"
        fi
    done

    ws_info "Cluster polling will reconcile peer state within ~10 seconds"
}

# ─── Confirmation prompt ─────────────────────────────────────────────────────
# Honours --yes (WS_YES=true skips the prompt). Returns 0 if the user
# confirms, exits non-zero otherwise.
ws_confirm() {
    local prompt="$1"
    if [ "${WS_YES:-false}" = "true" ]; then
        ws_info "$prompt — auto-confirmed (--yes)"
        return 0
    fi
    if [ ! -e /dev/tty ] || ! : < /dev/tty 2>/dev/null; then
        ws_fatal "$prompt — no TTY available, pass --yes to skip the prompt"
    fi
    echo ""
    printf '  %s [y/N] ' "$prompt"
    local reply=""
    read -r reply < /dev/tty || reply=""
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) ws_fatal "Cancelled by user" ;;
    esac
}

# ─── Final summary ───────────────────────────────────────────────────────────
# Prints a uniform "your cluster is up, here's what to do next" banner.
# Provider scripts pass the IPs as positional args. The first IP becomes
# the cluster master in the printed instructions; the rest are joiners.
#
# Usage: ws_summary <hostname1>:<ip1> <hostname2>:<ip2> ...
ws_summary() {
    if [ $# -eq 0 ]; then
        ws_warn "ws_summary called with no nodes — nothing to print"
        return
    fi
    ws_banner "WolfStack cluster provisioned"
    echo ""
    printf '  %-24s  %s\n' "Hostname" "Public IP"
    printf '  %-24s  %s\n' "─────────" "─────────"
    local first_pair=""
    for pair in "$@"; do
        [ -z "$first_pair" ] && first_pair="$pair"
        local hn="${pair%%:*}"
        local ip="${pair##*:}"
        printf '  %-24s  %s\n' "$hn" "$ip"
    done
    local first_ip="${first_pair##*:}"
    echo ""
    echo "  ─── Cluster ready ───────────────────────────────────────────────"
    echo ""
    if [ $# -gt 1 ]; then
        echo "  All nodes share the cluster secret and have each other in nodes.json."
        echo "  Cluster polling reconciles peer state every 10 seconds — by the time"
        echo "  you log in, the dashboard should already show every node online."
        echo ""
    fi
    echo "  Open the dashboard (any node — the cluster view is unified):"
    echo ""
    echo "     https://${first_ip}:8553"
    echo ""
    echo "  Login with the system user you SSH as (typically 'root' on cloud images,"
    echo "  'ubuntu' on AWS, 'azureuser' on Azure). The login uses your distro's"
    echo "  system password — set or reset it via SSH if needed:"
    echo "     ssh user@${first_ip} 'sudo passwd \$USER'"
    echo ""
    if [ $# -gt 1 ]; then
        echo "  If a node hasn't joined within ~30 seconds, fall back to the"
        echo "  manual flow: SSH in, 'sudo cat /etc/wolfstack/join-token', then"
        echo "  paste the token into the master's Cluster → Add Node form."
        echo ""
    fi
    echo "  To tear down later:"
    echo "     ./bootstrap.sh --destroy --prefix <your-prefix>"
    echo ""
    echo "  ─────────────────────────────────────────────────────────────────"
    echo ""
}

# ─── Hostname generator ──────────────────────────────────────────────────────
# Given a prefix and an index, returns "<prefix>-<index>". Used so each
# VM gets a distinct, predictable hostname (wolfstack-1, wolfstack-2, …).
ws_hostname() {
    local prefix="$1"
    local idx="$2"
    printf '%s-%d' "$prefix" "$idx"
}

# ─── Cleanup-on-failure trap helper ──────────────────────────────────────────
# Provider scripts register a cleanup function with `trap`. When the
# script aborts mid-provision, this function is responsible for tearing
# down whatever VMs were already created so the user isn't billed for
# orphan resources.
#
# Pattern (in provider script):
#     CREATED_IDS=()
#     cleanup_on_error() {
#         [ ${#CREATED_IDS[@]} -eq 0 ] && return
#         ws_warn "Provisioning failed mid-flight; tearing down created VMs..."
#         for id in "${CREATED_IDS[@]}"; do
#             provider-cli delete "$id" || true
#         done
#     }
#     trap 'cleanup_on_error' ERR INT TERM
