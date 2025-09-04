#!/bin/bash
# aws_rds_report.sh
# Gathers a detailed report on RDS instances, including specifications and average utilization metrics.

set -euo pipefail

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
FILENAME="${OUTPUT_DIR}/aws_rds_report.json"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-h]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -h               Show this help message.
EOF
    exit 1
}

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
echo "" > "$FILENAME"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- PROCESS RDS ---
    log "  [RDS] Fetching DB instance data..."
    RDS_DATA=$(aws rds describe-db-instances --region "$region" --query 'DBInstances[]' --output json)

    if [[ "$(echo "$RDS_DATA" | jq 'length')" -gt 0 ]]; then
        declare -A RDS_SPECS_CACHE
        mapfile -t UNIQUE_ENGINES < <(echo "$RDS_DATA" | jq -r '.[].Engine' | sort -u)
        
        log "  [RDS] Caching specs for engines: ${UNIQUE_ENGINES[*]}..."
        for engine in "${UNIQUE_ENGINES[@]}"; do
            CLASS_SPECS=$(aws rds describe-orderable-db-instance-options --region "$region" --engine "$engine" --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass, Vcpu:Vcpu, Mem:Memory}' --output json 2>/dev/null || echo "[]")
            while IFS= read -r spec; do
                class=$(echo "$spec" | jq -r '.Class')
                vcpu=$(echo "$spec" | jq -r '.Vcpu')
                mem_gib=$(echo "$spec" | jq -r '.Mem')

                if [[ "$class" == "null" ]]; then continue; fi
                if [[ "$vcpu" == "null" ]]; then vcpu="N/A"; fi
                if [[ "$mem_gib" == "null" ]]; then mem_gib="N/A"; fi

                CACHE_KEY="$class,$engine"
                RDS_SPECS_CACHE["$CACHE_KEY"]="$vcpu,$mem_gib"
            done < <(echo "$CLASS_SPECS" | jq -c '.[]')
        done

        log "  [RDS] Processing and writing to JSON..."
        while IFS= read -r db_instance; do
            ID=$(echo "$db_instance" | jq -r '.DBInstanceIdentifier')
            STATE=$(echo "$db_instance" | jq -r '.DBInstanceStatus')
            CLASS=$(echo "$db_instance" | jq -r '.DBInstanceClass')
            ENGINE=$(echo "$db_instance" | jq -r '.Engine')
            CREATE_TIME=$(echo "$db_instance" | jq -r '.InstanceCreateTime')
            DISK_GIB=$(echo "$db_instance" | jq -r '.AllocatedStorage')
            DB_ARN=$(echo "$db_instance" | jq -r '.DBInstanceArn')
            
            NAME=$(aws rds list-tags-for-resource --resource-name "$DB_ARN" --region "$region" --query 'TagList[?Key==`Name`].Value' --output text | tr -d '\n' || echo "N/A")
            NAME=${NAME:-"N/A"}

            CACHE_KEY_TO_FIND="$CLASS,$ENGINE"
            SPECS=${RDS_SPECS_CACHE[$CACHE_KEY_TO_FIND]:="N/A,N/A"}
            VCPU=$(echo "$SPECS" | cut -d',' -f1)
            MEM_GIB=$(echo "$SPECS" | cut -d',' -f2)

            CPU_UTIL=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name CPUUtilization \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")

            FREE_MEM=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name FreeableMemory \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text || echo "N/A")
            
            AVG_MEMORY_PERCENT="N/A"
            if [[ -n "$MEM_GIB" && "$MEM_GIB" != "N/A" && -n "$FREE_MEM" && "$FREE_MEM" != "N/A" ]]; then
                TOTAL_MEMORY_BYTES=$(echo "scale=0; $MEM_GIB * 1073741824" | bc)
                AVG_MEMORY_PERCENT=$(echo "scale=2; (1 - (${FREE_MEM:-0} / ${TOTAL_MEMORY_BYTES:-1})) * 100" | bc)
            fi
            
            jq -n --arg name "$NAME" \
                --arg id "$ID" \
                --arg state "$STATE" \
                --arg type "RDS" \
                --arg engine "$ENGINE" \
                --arg class "$CLASS" \
                --arg create_time "$CREATE_TIME" \
                --arg vcpu "$VCPU" \
                --arg mem_gib "$MEM_GIB" \
                --arg disk_gib "$DISK_GIB" \
                --arg cpu_util "$CPU_UTIL" \
                --arg avg_mem_percent "$AVG_MEMORY_PERCENT" \
                --arg region "$region" \
                '{
                    "reportType": "RDS",
                    "name": $name,
                    "instanceId": $id,
                    "instanceState": $state,
                    "type": $type,
                    "engine": $engine,
                    "instanceType": $class,
                    "elasticIp": "N/A",
                    "launchTime": $create_time,
                    "vCPUs": $vcpu,
                    "memoryGib": $mem_gib,
                    "diskGib": $disk_gib,
                    "avgCpuPercent": $cpu_util,
                    "avgMemoryPercent": $avg_mem_percent,
                    "region": $region
                }' >> "$FILENAME"

        done < <(echo "$RDS_DATA" | jq -c '.[]')
    else
        log "  [RDS] No DB instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Results saved to: $FILENAME"