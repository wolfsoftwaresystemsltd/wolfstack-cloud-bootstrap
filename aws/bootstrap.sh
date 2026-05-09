#!/bin/bash
# Written by Paul Clevett
# (C)Copyright Wolf Software Systems Ltd
# https://wolf.uk.com
#
#
# WolfStack — AWS EC2 bootstrap
# Spins up N EC2 instances in your chosen region and installs WolfStack
# on each via cloud-init. Handles security-group creation, key-pair
# import, AMI lookup (latest Ubuntu LTS via SSM), and tagging so
# --destroy can find the cluster again.
#
# Prerequisites:
#   * aws CLI v2 installed
#   * Credentials configured: 'aws configure' OR AWS_ACCESS_KEY_ID/_SECRET_ACCESS_KEY
#   * Default VPC in the target region (every AWS account has one unless
#     it's been deleted manually)
#
# Quick start (3 t3.small in us-east-1, ~$45/month):
#   ./bootstrap.sh
#
# Custom:
#   ./bootstrap.sh --nodes 5 --type t3.medium --region eu-west-2 --prefix prod
#
# Tear down (deletes every instance + SG + key pair tagged with the prefix):
#   ./bootstrap.sh --destroy --prefix prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/common.sh"

# ─── Provider defaults ──────────────────────────────────────────────────────
# shellcheck disable=SC2034
ws_default_region="us-east-1"        # N. Virginia — cheapest US region, widest AMI availability
# shellcheck disable=SC2034
ws_default_ssh_key=""                # auto-detected by ws_parse_args

# Size → EC2 instance type. AWS root-disk size is also lifted per size
# class (t3.small default 30 GB EBS gp3 is too tight for Docker images).
ws_size_to_type() {
    case "$WS_SIZE" in
        small)  WS_TYPE="t3.medium";  ROOT_DISK_GB=50;  SIZE_DESC="2 vCPU / 4 GB / 50 GB EBS — \$30/mo (eval only)" ;;
        medium) WS_TYPE="t3.large";   ROOT_DISK_GB=100; SIZE_DESC="2 vCPU / 8 GB / 100 GB EBS — \$60/mo (recommended)" ;;
        large)  WS_TYPE="t3.xlarge";  ROOT_DISK_GB=200; SIZE_DESC="4 vCPU / 16 GB / 200 GB EBS — \$120/mo" ;;
        *)      ws_fatal "Unknown size: $WS_SIZE" ;;
    esac
}

ACTION="provision"
SSH_USER="ubuntu"   # Canonical Ubuntu AMIs use 'ubuntu' as the default user
ROOT_DISK_GB=100    # Default — gets reset by ws_size_to_type if --size used

print_help() {
    cat <<'HELP'
WolfStack — AWS EC2 bootstrap

Usage:
  bootstrap.sh [options]
  bootstrap.sh --destroy --prefix <prefix>

Options:
  --nodes N           Number of EC2 instances (default: 3)
  --prefix STR        Hostname/tag prefix (default: wolfstack)
  --region STR        AWS region: us-east-1, us-west-2, eu-west-2,
                      ap-southeast-2, etc. Default: us-east-1.
  --size CLASS        small / medium / large. Default: medium. Also sets
                      the EBS root-disk size — t3's 8 GB default is too
                      small for Docker images.
                        small  = t3.medium · 2 vCPU / 4 GB / 50 GB EBS  — $30/mo (eval only)
                        medium = t3.large  · 2 vCPU / 8 GB / 100 GB EBS — $60/mo (recommended)
                        large  = t3.xlarge · 4 vCPU / 16 GB / 200 GB EBS — $120/mo
  --type STR          Override --size with explicit instance type
                      (t3.medium, m5.large, c5.large, r5.large, etc.).
                      EBS root-disk size stays at the size-class default.
  --ssh-key PATH      Path to public SSH key (default: ~/.ssh/id_ed25519.pub
                      or ~/.ssh/id_rsa.pub). Imported as a new key pair
                      named '<prefix>-key'.
  --beta              Install WolfStack from the beta branch.
  --destroy           Tear down all WolfStack resources matching the prefix.
  --yes, -y           Skip confirmation prompts.
  --help, -h          Show this help.

Environment:
  AWS_PROFILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
                      Standard AWS CLI auth. We honour whatever 'aws configure
                      list' shows. --region overrides AWS_REGION at runtime.

Resources created (all tagged WolfStackBootstrap=<prefix>):
  • EC2 instances — one per node, in the default VPC's default subnet
  • Security group '<prefix>-sg' — allows 22 (SSH), 8553 (dashboard),
    8554 (inter-node), 9600/9601 (WolfNet), all from 0.0.0.0/0
  • Key pair '<prefix>-key' — imported from your local public key

On-demand cost estimate (May 2026 us-east-1 pricing):
  t3.small  ≈ $0.0208/hr ≈ $15.18/mo  →  3 nodes ≈ $45.55/mo
  t3.medium ≈ $0.0416/hr ≈ $30.37/mo  →  3 nodes ≈ $91.10/mo
  m5.large  ≈ $0.0960/hr ≈ $70.08/mo  →  3 nodes ≈ $210.24/mo

Spot instances and Savings Plans are NOT used by this script — keeping
the math simple and the teardown clean. For long-term savings, switch
to Reserved Instances or a Compute Savings Plan via the AWS console.
HELP
}

# ─── Pre-parse provider flags ───────────────────────────────────────────────
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

# ─── Sanity ─────────────────────────────────────────────────────────────────
ws_require_cli "aws" "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
ws_require_cli "jq" "your distro's package manager"

# Use --region from now on rather than the env default. Aws CLI will prefer
# the explicit flag over AWS_REGION / config-file region.
AWS="aws --region ${WS_REGION} --output json"

# Auth check — sts get-caller-identity is the cheapest API call that
# confirms credentials work.
if ! $AWS sts get-caller-identity >/dev/null 2>&1; then
    ws_err "AWS credentials missing or invalid for region ${WS_REGION}."
    echo "  Try one of:" >&2
    echo "    aws configure" >&2
    echo "    aws configure sso" >&2
    echo "    export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=..." >&2
    exit 2
fi

CALLER_ARN=$($AWS sts get-caller-identity --query Arn --output text)
ws_info "AWS identity: ${CALLER_ARN}"

# ─── Destroy path ───────────────────────────────────────────────────────────
if [ "$ACTION" = "destroy" ]; then
    ws_banner "AWS — tearing down WolfStack cluster '${WS_PREFIX}'"

    # Find every instance tagged WolfStackBootstrap=<prefix>
    instance_ids=$($AWS ec2 describe-instances \
        --filters "Name=tag:WolfStackBootstrap,Values=${WS_PREFIX}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

    if [ -z "$instance_ids" ]; then
        ws_warn "No instances found with tag WolfStackBootstrap=${WS_PREFIX} in ${WS_REGION}."
    else
        echo "  Will terminate:"
        for id in $instance_ids; do
            name=$($AWS ec2 describe-tags --filters "Name=resource-id,Values=$id" "Name=key,Values=Name" \
                --query 'Tags[0].Value' --output text 2>/dev/null || echo "?")
            echo "    • $id ($name)"
        done
    fi

    sg_id=$($AWS ec2 describe-security-groups --filters "Name=group-name,Values=${WS_PREFIX}-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    if [ "$sg_id" != "None" ] && [ -n "$sg_id" ]; then
        echo "  Will delete security group ${WS_PREFIX}-sg (${sg_id})"
    fi

    key_exists=$($AWS ec2 describe-key-pairs --key-names "${WS_PREFIX}-key" --query 'KeyPairs[0].KeyName' \
        --output text 2>/dev/null || echo "None")
    if [ "$key_exists" != "None" ] && [ -n "$key_exists" ]; then
        echo "  Will delete key pair ${WS_PREFIX}-key"
    fi

    if [ -z "$instance_ids" ] && [ "$sg_id" = "None" ] && [ "$key_exists" = "None" ]; then
        ws_ok "Nothing to tear down."
        exit 0
    fi

    ws_confirm "Permanently tear down these resources?"

    if [ -n "$instance_ids" ]; then
        # shellcheck disable=SC2086  # word splitting is intentional
        $AWS ec2 terminate-instances --instance-ids $instance_ids >/dev/null
        ws_info "Termination requested; waiting for instances to stop..."
        # shellcheck disable=SC2086
        $AWS ec2 wait instance-terminated --instance-ids $instance_ids
        ws_ok "All instances terminated."
    fi

    # SG can only be deleted after instances are gone (ENIs released).
    if [ "$sg_id" != "None" ] && [ -n "$sg_id" ]; then
        if $AWS ec2 delete-security-group --group-id "$sg_id" 2>/dev/null; then
            ws_ok "Security group deleted."
        else
            ws_warn "Couldn't delete security group ${sg_id} — it may still have references. Re-run --destroy in a minute."
        fi
    fi

    if [ "$key_exists" != "None" ] && [ -n "$key_exists" ]; then
        $AWS ec2 delete-key-pair --key-name "${WS_PREFIX}-key" >/dev/null
        ws_ok "Key pair deleted."
    fi

    ws_ok "Tear-down complete."
    exit 0
fi

# ─── Provision path ─────────────────────────────────────────────────────────
ws_banner "AWS EC2 — provisioning a WolfStack cluster"
if [ -n "$SIZE_DESC" ]; then
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (${WS_SIZE}: ${SIZE_DESC}) in ${WS_REGION}"
else
    echo "  Nodes:    ${WS_NODES} × ${WS_TYPE} (custom, ${ROOT_DISK_GB}GB EBS) in ${WS_REGION}"
fi
echo "  Prefix:   ${WS_PREFIX} → ${WS_PREFIX}-1 .. ${WS_PREFIX}-${WS_NODES}"
echo "  SSH key:  ${WS_SSH_KEY}"
echo "  Branch:   ${WS_BRANCH}"

# Validate region (cheap call).
if ! $AWS ec2 describe-availability-zones --query 'AvailabilityZones[0]' >/dev/null 2>&1; then
    ws_fatal "Region '${WS_REGION}' rejected by EC2 — typo or not enabled in your account."
fi

# Validate instance type. Some types are not available in every region.
if ! $AWS ec2 describe-instance-types --instance-types "$WS_TYPE" \
        --query 'InstanceTypes[0].InstanceType' --output text >/dev/null 2>&1; then
    ws_fatal "Instance type '${WS_TYPE}' is not available in region ${WS_REGION}."
fi

# Look up latest Ubuntu 24.04 LTS AMI via SSM Parameter Store.
# Canonical publishes these for every region. The path is the canonical
# mechanism rather than scraping describe-images.
ws_info "Looking up latest Ubuntu 24.04 LTS AMI in ${WS_REGION}..."
AMI_ID=$($AWS ssm get-parameters \
    --names "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" \
    --query 'Parameters[0].Value' --output text 2>/dev/null || echo "")
if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    ws_fatal "Could not look up Ubuntu 24.04 AMI via SSM. Your IAM principal may need ssm:GetParameters."
fi
ws_ok "AMI: ${AMI_ID}"

# Find the default VPC and a default subnet to launch into. Most AWS
# accounts have a default VPC per region; we don't manage VPCs in this
# script (would be too much for a bootstrap tool).
DEFAULT_VPC=$($AWS ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
if [ "$DEFAULT_VPC" = "None" ] || [ -z "$DEFAULT_VPC" ]; then
    ws_fatal "No default VPC in ${WS_REGION}. Either create one (aws ec2 create-default-vpc) or use a region that has one."
fi
ws_info "Using default VPC: ${DEFAULT_VPC}"

DEFAULT_SUBNET=$($AWS ec2 describe-subnets --filters "Name=vpc-id,Values=${DEFAULT_VPC}" \
    --query 'Subnets[0].SubnetId' --output text)
ws_info "Subnet: ${DEFAULT_SUBNET}"

# Cost preview — pricing API is region-specific and complex, so we just
# print the on-demand hourly rate from the instance type description.
hourly_usd=$($AWS pricing get-products --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=${WS_TYPE}" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
              "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
              "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
              "Type=TERM_MATCH,Field=regionCode,Value=${WS_REGION}" \
    --query 'PriceList[0]' --output text --region us-east-1 2>/dev/null \
    | jq -r 'fromjson | .terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2>/dev/null \
    || echo "")
if [ -n "$hourly_usd" ] && [ "$hourly_usd" != "null" ]; then
    monthly=$(awk "BEGIN { printf \"%.2f\", $hourly_usd * 24 * 30 * $WS_NODES }")
    echo "  Estimated cost: \$${monthly}/mo for the cluster (on-demand, ${WS_NODES}× ${WS_TYPE} in ${WS_REGION})"
else
    echo "  (Pricing API unreachable — check the AWS Pricing page for your instance type.)"
fi

ws_confirm "Provision ${WS_NODES}× ${WS_TYPE} in ${WS_REGION}?"

CLUSTER_SECRET=$(openssl rand -hex 32)
ROOT_PASSWORD=$(ws_generate_password)

# ─── Key pair (idempotent import) ───────────────────────────────────────────
KEY_NAME="${WS_PREFIX}-key"
if $AWS ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    ws_info "Key pair '$KEY_NAME' already exists — reusing"
else
    ws_info "Importing local SSH key as '$KEY_NAME'"
    $AWS ec2 import-key-pair --key-name "$KEY_NAME" \
        --public-key-material "fileb://${WS_SSH_KEY}" >/dev/null
    ws_ok "Key pair imported"
fi

# ─── Security group (idempotent) ────────────────────────────────────────────
SG_NAME="${WS_PREFIX}-sg"
SG_ID=$($AWS ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${DEFAULT_VPC}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    ws_info "Creating security group '$SG_NAME' in ${DEFAULT_VPC}"
    SG_ID=$($AWS ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "WolfStack cluster ${WS_PREFIX} (created by bootstrap.sh)" \
        --vpc-id "$DEFAULT_VPC" \
        --query 'GroupId' --output text)
    $AWS ec2 create-tags --resources "$SG_ID" \
        --tags "Key=WolfStackBootstrap,Value=${WS_PREFIX}" "Key=Name,Value=${SG_NAME}" >/dev/null

    # Open ports: 22 (SSH), 8553 (dashboard HTTPS), 8554 (inter-node),
    # 9600 + 9601 UDP (WolfNet mesh + discovery).
    for port in 22 8553 8554; do
        $AWS ec2 authorize-security-group-ingress --group-id "$SG_ID" \
            --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null
    done
    for port in 9600 9601; do
        $AWS ec2 authorize-security-group-ingress --group-id "$SG_ID" \
            --protocol udp --port "$port" --cidr 0.0.0.0/0 >/dev/null
    done
    ws_ok "Security group created: $SG_ID"
else
    ws_info "Security group '$SG_NAME' already exists ($SG_ID) — reusing"
fi

# ─── Pre-flight: name collision check ───────────────────────────────────────
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    existing=$($AWS ec2 describe-instances \
        --filters "Name=tag:Name,Values=${hn}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        ws_fatal "Instance with Name tag '${hn}' already exists in ${WS_REGION}. Pick a different --prefix or --destroy first."
    fi
done

# ─── Provision (one run-instances call per node, in parallel) ───────────────
CREATED_IDS=()
cleanup_on_error() {
    [ ${#CREATED_IDS[@]} -eq 0 ] && return
    ws_warn "Provisioning aborted — terminating ${#CREATED_IDS[@]} instance(s)..."
    $AWS ec2 terminate-instances --instance-ids "${CREATED_IDS[@]}" >/dev/null 2>&1 || true
}
trap 'cleanup_on_error' ERR INT TERM

ws_info "Launching ${WS_NODES} instances in parallel..."
declare -A pid_to_hostname
for i in $(seq 1 "$WS_NODES"); do
    hn="$(ws_hostname "$WS_PREFIX" "$i")"
    cloud_init_yaml=$(ws_cloud_init "$hn" "$WS_BRANCH" "$CLUSTER_SECRET" "$ROOT_PASSWORD")
    cloud_init_b64=$(printf '%s\n' "$cloud_init_yaml" | base64 | tr -d '\n')
    out_file="/tmp/wolfstack-aws-$$-$i.out"
    (
        $AWS ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$WS_TYPE" \
            --key-name "$KEY_NAME" \
            --security-group-ids "$SG_ID" \
            --subnet-id "$DEFAULT_SUBNET" \
            --associate-public-ip-address \
            --user-data "$cloud_init_b64" \
            --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${ROOT_DISK_GB},VolumeType=gp3,DeleteOnTermination=true}" \
            --tag-specifications \
                "ResourceType=instance,Tags=[{Key=Name,Value=${hn}},{Key=WolfStackBootstrap,Value=${WS_PREFIX}}]" \
            --query 'Instances[0].InstanceId' --output text > "$out_file" 2>&1
    ) &
    pid_to_hostname[$!]="${hn}|${out_file}"
done

all_ok=true
for pid in "${!pid_to_hostname[@]}"; do
    entry="${pid_to_hostname[$pid]}"
    hn="${entry%|*}"
    out_file="${entry##*|}"
    if wait "$pid"; then
        id=$(tr -d ' \n' < "$out_file")
        if [[ "$id" =~ ^i-[a-f0-9]+$ ]]; then
            CREATED_IDS+=("$id")
            ws_ok "Launched $hn (id $id)"
        else
            ws_err "Launched $hn but couldn't parse id"
            cat "$out_file" >&2 || true
            all_ok=false
        fi
    else
        ws_err "Failed to launch $hn"
        cat "$out_file" >&2 || true
        all_ok=false
    fi
    rm -f "$out_file" 2>/dev/null || true
done

if [ "$all_ok" != "true" ]; then
    ws_fatal "One or more instances failed to launch. Cleanup ran."
fi

# ─── Wait for running + public IP, then for cloud-init to finish ────────────
ws_info "Waiting for instances to enter the 'running' state..."
$AWS ec2 wait instance-running --instance-ids "${CREATED_IDS[@]}"
ws_ok "All instances running."

PAIRS=()
for id in "${CREATED_IDS[@]}"; do
    json=$($AWS ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0]' --output json)
    name=$(echo "$json" | jq -r '.Tags[]? | select(.Key=="Name") | .Value' | head -1)
    ipv4=$(echo "$json" | jq -r '.PublicIpAddress')
    PAIRS+=("${name}:${ipv4}")
done

ws_info "Waiting for cloud-init to install WolfStack on each node (~2-3 minutes)..."
echo "  (AWS instance-running ≠ application-ready. Polling :8553 to confirm.)"
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
