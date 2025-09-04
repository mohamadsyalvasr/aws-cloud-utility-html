#!/bin/bash
# eks_report.sh
# Gathers a report on all EKS clusters and saves it to a dated output directory.

set -euo pipefail

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/eks_report.json"

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

# Create the output directory with the full date path
log "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log "✅ Directory created."

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all EKS clusters in the region
    EKS_CLUSTERS=$(aws eks list-clusters --region "$region" --query 'clusters' --output json)
    
    if [[ "$(echo "$EKS_CLUSTERS" | jq 'length')" -gt 0 ]]; then
        echo "$EKS_CLUSTERS" | jq -c '.[]' | while read -r cluster_name; do
            # Remove surrounding quotes from the cluster name
            CLUSTER_NAME=$(echo "$cluster_name" | tr -d '"')
            
            # Get detailed information for each cluster
            CLUSTER_DETAILS=$(aws eks describe-cluster --region "$region" --name "$CLUSTER_NAME" --output json)

            echo "$CLUSTER_DETAILS" | jq -r --arg region "$region" '
            .cluster |
            {
                "reportType": "EKS",
                "name": .name,
                "status": .status,
                "kubernetesVersion": .version,
                "dateCreated": .createdAt,
                "provider": "AWS",
                "region": $region
            }' >> "$OUTPUT_FILE"

        done
    else
        log "  [EKS] No clusters found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"