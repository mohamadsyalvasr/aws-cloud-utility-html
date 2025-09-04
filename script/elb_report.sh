#!/bin/bash
# elb_report.sh
# Gathers a report on all Elastic Load Balancers (ELBv2: ALB/NLB/GWLB) across regions into a JSON.

set -euo pipefail

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/elb_report.json"

# --- Logging ---
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

# --- Prepare output ---
prepare_output() {
  log "✍️ Preparing output file: $OUTPUT_FILE"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  echo "" > "$OUTPUT_FILE"
}

# --- Export one region ---
export_region() {
  local region="$1"
  log "Processing Region: \033[1;33m$region\033[0m"

  # Fetch ELBv2 data
  local elb_data
  if ! elb_data=$(aws elbv2 describe-load-balancers --region "$region" --output json --page-size 400); then
    log "  ❌ Failed to describe load balancers in $region"
    return 1
  fi

  # If empty, log and continue
  if [[ "$(echo "$elb_data" | jq '.LoadBalancers | length // 0')" -eq 0 ]]; then
    log "  [ELB] No load balancers found."
  else
    # Build JSON objects
    echo "$elb_data" | jq --arg region "$region" -c '.LoadBalancers[] | 
    {
      "reportType": "ELB",
      "name": .LoadBalancerName,
      "state": .State.Code,
      "type": .Type,
      "scheme": .Scheme,
      "ipAddressType": .IpAddressType,
      "vpcId": .VpcId,
      "securityGroups": (.SecurityGroups | join(", ")),
      "dateCreated": .CreatedTime,
      "dnsName": .DNSName,
      "region": $region
    }' >> "$OUTPUT_FILE"
  fi

  log "Region \033[1;33m$region\033[0m Complete."
}

# --- Main ---
check_dependencies
prepare_output

for region in "${REGIONS[@]}"; do
  export_region "$region"
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"