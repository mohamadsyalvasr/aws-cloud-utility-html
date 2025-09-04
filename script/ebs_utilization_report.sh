#!/bin/bash
# ebs_report.sh
# Generates a report on EBS volumes, showing attachment status, disk size, and utilization metrics.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_utilization_report.json"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-h]

Options:
  -b <start_date>  REQUIRED: The start date for utilization metrics (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for utilization metrics (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions to scan. Default: ap-southeast-1,ap-southeast-3
  -h               Show this help message.
EOF
    exit 1
}

# Add a log function for this script to be self-contained
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Process command-line arguments
while getopts "b:e:r:h" opt; do
    case "$opt" in
        b)
            START_DATE="$OPTARG"
            ;;
        e)
            END_DATE="$OPTARG"
            ;;
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

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

log "✍️ Preparing output file: $OUTPUT_FILE"
echo "" > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    VOLUMES_DATA=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

    if [[ "$(echo "$VOLUMES_DATA" | jq 'length')" -gt 0 ]]; then
        echo "$VOLUMES_DATA" | jq -c '.[]' | while read -r volume; do
            ID=$(echo "$volume" | jq -r '.VolumeId')
            ATTACHMENT=$(echo "$volume" | jq -r '.Attachments[0].InstanceId // "Not Attached"')

            DISK_USED_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace CWAgent \
                --metric-name disk_used_percent \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")

            DISK_READ_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name DiskReadBytes \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")

            DISK_WRITE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name DiskWriteBytes \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")

            echo "$volume" | jq --argjson disk_used_percent "$([[ "$DISK_USED_PERCENT" == "N/A" ]] && echo null || echo "$DISK_USED_PERCENT")" \
            --argjson disk_read_bytes "$([[ "$DISK_READ_BYTES" == "N/A" ]] && echo null || echo "$DISK_READ_BYTES")" \
            --argjson disk_write_bytes "$([[ "$DISK_WRITE_BYTES" == "N/A" ]] && echo null || echo "$DISK_WRITE_BYTES")" \
            --arg region "$region" \
            '{
                "reportType": "EBS Utilization",
                "volumeId": .VolumeId,
                "sizeGib": .Size,
                "state": .State,
                "attachedInstanceId": (.Attachments[0].InstanceId // "Not Attached"),
                "diskUsedPercent": $disk_used_percent,
                "avgReadBytes": $disk_read_bytes,
                "avgWriteBytes": $disk_write_bytes,
                "creationTime": .CreateTime,
                "region": $region
            }' >> "$OUTPUT_FILE"
        done
    else
        log "  [EBS] No volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"