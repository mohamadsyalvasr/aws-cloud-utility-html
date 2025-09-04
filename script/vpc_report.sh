#!/bin/bash
# vpc_report.sh
# Gathers a summary report of VPC-related services and their quantities (per region).

set -euo pipefail

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/vpc_report.json"

# --- Logging Function ---
log() {
  echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -h               Show this help message.
EOF
    exit 1
}

# --- Process command-line arguments ---
while getopts "r:h" opt; do
    case "$opt" in
        r)
            IFS=',' read -r -a REGIONS <<< "$OPTARG"
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
check_dependencies() {
  log "🔎 Checking dependencies (aws cli, jq)..."
  if ! command -v aws >/dev/null 2>&1; then
    log "❌ AWS CLI not found. Please install it first."
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "❌ jq not found. Please install it first."
    exit 1
  fi
  log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
echo "" > "$OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

for region in "${REGIONS[@]}"; do
  log "Processing Region: \033[1;33m$region\033[0m"

  # VPCs
  VPC_COUNT=$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text)
  jq -n --arg region "$region" --arg service "VPC" --arg qty "$VPC_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Subnets
  SUBNET_COUNT=$(aws ec2 describe-subnets --region "$region" --query 'length(Subnets)' --output text)
  jq -n --arg region "$region" --arg service "Subnet" --arg qty "$SUBNET_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Internet Gateways
  IGW_COUNT=$(aws ec2 describe-internet-gateways --region "$region" --query 'length(InternetGateways)' --output text)
  jq -n --arg region "$region" --arg service "Internet Gateway" --arg qty "$IGW_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # NAT Gateways
  NAT_GW_COUNT=$(aws ec2 describe-nat-gateways --region "$region" --query 'length(NatGateways)' --output text)
  jq -n --arg region "$region" --arg service "NAT Gateway" --arg qty "$NAT_GW_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Route Tables
  ROUTE_TABLE_COUNT=$(aws ec2 describe-route-tables --region "$region" --query 'length(RouteTables)' --output text)
  jq -n --arg region "$region" --arg service "Route Table" --arg qty "$ROUTE_TABLE_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Network ACLs
  NACL_COUNT=$(aws ec2 describe-network-acls --region "$region" --query 'length(NetworkAcls)' --output text)
  jq -n --arg region "$region" --arg service "Network ACL" --arg qty "$NACL_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Security Groups
  SECURITY_GROUP_COUNT=$(aws ec2 describe-security-groups --region "$region" --query 'length(SecurityGroups)' --output text)
  jq -n --arg region "$region" --arg service "Security Group" --arg qty "$SECURITY_GROUP_COUNT" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  # Elastic IPs (Total / Used / Idle)
  EIP_TOTAL=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text)
  EIP_USED=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId!=null])' --output text)
  EIP_IDLE=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId==null])' --output text)
  jq -n --arg region "$region" --arg service "Elastic IP (Total)" --arg qty "$EIP_TOTAL" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"
  jq -n --arg region "$region" --arg service "Elastic IP (Used)" --arg qty "$EIP_USED" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"
  jq -n --arg region "$region" --arg service "Elastic IP (Idle)" --arg qty "$EIP_IDLE" '{"reportType": "VPC", "service": $service, "quantity": ($qty | tonumber), "region": $region}' >> "$OUTPUT_FILE"

  log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"