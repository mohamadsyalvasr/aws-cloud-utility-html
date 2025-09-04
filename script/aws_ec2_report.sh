#!/bin/bash
# aws_ec2_report.sh
# Gathers a detailed report on EC2 instances, including specifications and average utilization metrics.

set -euo pipefail

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
SUM_ALL_EBS=false
TS=$(date +"%Y%m%d-%H%M%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
FILENAME="${OUTPUT_DIR}/aws_ec2_report.json"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-s] [-h]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -s               Enables the summation of all attached EBS volumes.
                   Default: Only calculates the root disk size.
  -h               Show this help message.
EOF
    exit 1
}

while getopts "b:e:r:sh" opt; do
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
        s)
            SUM_ALL_EBS=true
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
log "✍️ Preparing output file: $FILENAME"
echo "[" > "$FILENAME" # Start of JSON array

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- PROCESS EC2 ---
    log "  [EC2] Fetching instance data..."
    EC2_DATA=$(aws ec2 describe-instances --region "$region" --query 'Reservations[].Instances[]' --output json)

    if [[ "$(echo "$EC2_DATA" | jq 'length')" -gt 0 ]]; then
        mapfile -t INSTANCE_TYPES < <(echo "$EC2_DATA" | jq -r '.[].InstanceType' | sort -u)
        declare -A INSTANCE_SPECS
        if [[ ${#INSTANCE_TYPES[@]} -gt 0 ]]; then
            log "  [EC2] Caching specs for ${#INSTANCE_TYPES[@]} instance types..."
            TYPE_SPECS=$(aws ec2 describe-instance-types --region "$region" --instance-types "${INSTANCE_TYPES[@]}" --query 'InstanceTypes[].{Type:InstanceType, Vcpu:VCpuInfo.DefaultVCpus, Mem:MemoryInfo.SizeInMiB}' --output json)
            
            while IFS= read -r spec; do
                type=$(echo "$spec" | jq -r '.Type')
                vcpu=$(echo "$spec" | jq -r '.Vcpu')
                mem_mib=$(echo "$spec" | jq -r '.Mem')
                mem_gib=$(awk "BEGIN {printf \"%.2f\", ${mem_mib}/1024}")
                INSTANCE_SPECS["$type"]="$vcpu,$mem_gib"
            done < <(echo "$TYPE_SPECS" | jq -c '.[]')
        fi

        local first_item=true
        log "  [EC2] Processing and writing to JSON..."
        while IFS= read -r instance; do
            if [ "$first_item" = true ]; then
                first_item=false
            else
                echo "," >> "$FILENAME"
            fi
            ID=$(echo "$instance" | jq -r '.InstanceId')
            STATE=$(echo "$instance" | jq -r '.State.Name')
            TYPE=$(echo "$instance" | jq -r '.InstanceType')
            LAUNCH_TIME=$(echo "$instance" | jq -r '.LaunchTime')
            NAME=$(echo "$instance" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
            
            SPECS=${INSTANCE_SPECS[$TYPE]:="N/A,N/A"}
            VCPU=$(echo "$SPECS" | cut -d',' -f1)
            MEM_GIB=$(echo "$SPECS" | cut -d',' -f2)
            
            DISK_GIB=0
            if [[ "$SUM_ALL_EBS" == "true" ]]; then
                mapfile -t VOL_IDS < <(echo "$instance" | jq -r '.BlockDeviceMappings[].Ebs.VolumeId')
                if [[ ${#VOL_IDS[@]} -gt 0 ]]; then
                    DISK_GIB=$(aws ec2 describe-volumes --region "$region" --volume-ids "${VOL_IDS[@]}" --query 'sum(Volumes[].Size)' --output text)
                fi
            else
                ROOT_DEVICE=$(echo "$instance" | jq -r '.RootDeviceName')
                if [[ "$ROOT_DEVICE" != "null" ]]; then
                    ROOT_VOL_ID=$(echo "$instance" | jq -r --arg rd "$ROOT_DEVICE" '.BlockDeviceMappings[] | select(.DeviceName==$rd).Ebs.VolumeId')
                    if [[ -n "$ROOT_VOL_ID" ]]; then
                        DISK_GIB=$(aws ec2 describe-volumes --region "$region" --volume-id "$ROOT_VOL_ID" --query 'Volumes[0].Size' --output text)
                    fi
                fi
            fi
            DISK_GIB=${DISK_GIB:-0}

            CPU_UTIL=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name CPUUtilization \
                --dimensions Name=InstanceId,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")

            AVG_MEMORY_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace CWAgent \
                --metric-name mem_used_percent \
                --dimensions Name=InstanceId,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")
            
            ELASTIC_IP=$(echo "$instance" | jq -r '.PublicIpAddress // "N/A"')

            jq -n \
                --arg name "$NAME" \
                --arg id "$ID" \
                --arg state "$STATE" \
                --arg type "EC2" \
                --arg instance_type "$TYPE" \
                --arg elastic_ip "$ELASTIC_IP" \
                --arg launch_time "$LAUNCH_TIME" \
                --arg vcpu "$VCPU" \
                --arg mem_gib "$MEM_GIB" \
                --arg disk_gib "$DISK_GIB" \
                --arg cpu_util "$CPU_UTIL" \
                --arg avg_mem_percent "$AVG_MEMORY_PERCENT" \
                --arg region "$region" \
                '{
                    "reportType": "EC2",
                    "name": $name,
                    "instanceId": $id,
                    "instanceState": $state,
                    "type": $type,
                    "instanceType": $instance_type,
                    "elasticIp": $elastic_ip,
                    "launchTime": $launch_time,
                    "vCPUs": ($vcpu | tonumber),
                    "memoryGib": ($mem_gib | tonumber),
                    "diskGib": ($disk_gib | tonumber),
                    "avgCpuPercent": ($cpu_util | tonumber),
                    "avgMemoryPercent": ($avg_mem_percent | tonumber),
                    "region": $region
                }' >> "$FILENAME"

        done < <(echo "$EC2_DATA" | jq -c '.[]')
    else
        log "  [EC2] No instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

echo "]" >> "$FILENAME" # End of JSON array
log "✅ DONE. Results saved to: $FILENAME"