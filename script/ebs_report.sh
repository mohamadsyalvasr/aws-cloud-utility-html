#!/bin/bash
# ebs_report.sh
# Generates a detailed report on EBS volumes with custom columns.

set -euo pipefail

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_report.json"

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

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_FILE")"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    VOLUMES_DATA=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

    if [[ "$(echo "$VOLUMES_DATA" | jq 'length')" -gt 0 ]]; then
        echo "$VOLUMES_DATA" | jq -c '.[]' | while read -r volume; do
            echo "$volume" | jq --arg region "$region" '
            {
                "reportType": "EBS",
                "name": (([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"),
                "volumeId": .VolumeId,
                "type": .VolumeType,
                "size": .Size,
                "iops": (.Iops // "N/A"),
                "throughput": (.Throughput // "N/A"),
                "snapshotId": (.SnapshotId // "N/A"),
                "created": .CreateTime,
                "availabilityZone": .AvailabilityZone,
                "volumeState": .State,
                "region": $region
            }' >> "$OUTPUT_FILE"
        done
    else
        log "  [EBS] No volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"