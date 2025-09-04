#!/bin/bash
# efs_report.sh
# Gathers a report on all EFS file systems, including size and status details.

set -euo pipefail

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/efs_report.json"

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

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all EFS file systems in the region
    EFS_DATA=$(aws efs describe-file-systems --region "$region" --output json)
    
    # Use the `// []` trick to provide an empty array if `FileSystems` is null
    if [[ "$(echo "$EFS_DATA" | jq '.FileSystems // [] | length')" -gt 0 ]]; then
        echo "$EFS_DATA" | jq -c '.FileSystems[]' | while read -r fs_info; do
            echo "$fs_info" | jq --arg region "$region" '
            {
                "reportType": "EFS",
                "name": (([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"),
                "fileSystemId": .FileSystemId,
                "encrypted": .Encrypted,
                "totalSize": (.SizeInBytes.Value // "N/A"),
                "sizeInEfsStandard": (.SizeInBytes.ValueInStandard // "N/A"),
                "sizeInEfsIa": (.SizeInBytes.ValueInInfrequentAccess // "N/A"),
                "sizeInArchive": "N/A",
                "fileSystemState": .LifeCycleState,
                "creationTime": .CreationTime,
                "region": $region
            }' >> "$OUTPUT_FILE"
        done
    else
        log "  [EFS] No file systems found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"