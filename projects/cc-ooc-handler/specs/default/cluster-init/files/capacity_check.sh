#!/bin/bash
#
# Capacity Check Script for Slurm with CycleCloud
#
# This script detects out-of-capacity partitions and:
# 1. Sets partitions with capacity failures to INACTIVE
# 2. Restores partitions to UP when capacity is available
# 3. Moves pending jobs from INACTIVE partitions to fallback partitions
#
# Usage: Run via cron every few minutes
#   */5 * * * * /path/to/capacity_check.sh >> /var/log/capacity_check.log 2>&1
#

set -euo pipefail

# Activate the azslurm Python virtual environment
if [[ -f /opt/azurehpc/slurm/venv/bin/activate ]]; then
    source /opt/azurehpc/slurm/venv/bin/activate
else
    echo "ERROR: azslurm virtual environment not found at /opt/azurehpc/slurm/venv/bin/activate" >&2
    exit 1
fi

# Configuration file for partition mappings (shared with job_submit_round_robin.lua)
PARTITION_CONFIG_FILE="/etc/slurm/partition_config.conf"

# State file to track partition states
STATE_FILE="/var/run/slurm/capacity_state.json"

# Load partition mappings from external config file
# Populates FALLBACK_MAPPING associative array
# Format: partition: fallback1,fallback2,fallback3
load_partition_mapping() {
    if [[ ! -f "$PARTITION_CONFIG_FILE" ]]; then
        log_error "Partition config file not found: $PARTITION_CONFIG_FILE"
        return 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove carriage returns (Windows line endings) and skip comments/empty lines
        line=$(echo "$line" | tr -d '\r')
        [[ "$line" =~ ^[[:space:]]*#.*$ || -z "${line// /}" ]] && continue
        
        # Parse "partition: fallback1,fallback2,fallback3"
        local partition fallbacks
        partition=$(echo "$line" | cut -d: -f1 | tr -d '[:space:]')
        fallbacks=$(echo "$line" | cut -d: -f2 | tr -d '[:space:]')
        
        if [[ -n "$partition" && -n "$fallbacks" ]]; then
            FALLBACK_MAPPING["$partition"]="$fallbacks"
            log "Loaded mapping: $partition -> $fallbacks"
        fi
    done < "$PARTITION_CONFIG_FILE"
    
    log "Loaded ${#FALLBACK_MAPPING[@]} partition mappings from $PARTITION_CONFIG_FILE"
}

# Fallback partition mappings (populated from config file)
declare -A FALLBACK_MAPPING

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Initialize state file if it doesn't exist
init_state_file() {
    local state_dir
    state_dir=$(dirname "$STATE_FILE")
    
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir"
    fi
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"partitions":{}}' > "$STATE_FILE"
        log "Initialized state file: $STATE_FILE"
    fi
}

# Read partition state from state file
read_partition_state() {
    local partition="$1"
    jq -r --arg p "$partition" '.partitions[$p] // empty' "$STATE_FILE" 2>/dev/null
}

# Update partition state in state file
update_state_file() {
    local partition="$1"
    local state="$2"
    local reason="${3:-}"
    local timestamp
    timestamp=$(date -Iseconds)
    
    local tmp_file="${STATE_FILE}.tmp"
    
    jq --arg p "$partition" \
       --arg s "$state" \
       --arg r "$reason" \
       --arg t "$timestamp" \
       '.partitions[$p] = {"state": $s, "reason": $r, "updated": $t}' \
       "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    
    log "State file updated: $partition -> $state"
}

# Remove partition from state file (when restored to normal)
remove_from_state_file() {
    local partition="$1"
    local tmp_file="${STATE_FILE}.tmp"
    
    jq --arg p "$partition" 'del(.partitions[$p])' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    log "State file updated: $partition removed (restored)"
}

# ============================================================================
# Capacity Status Retrieval Function
# ============================================================================
# This function retrieves capacity status for all nodearrays.
# Output format: JSON array with objects containing:
#   - nodearray: name of the nodearray/partition
#   - last_capacity_failure: seconds since last failure, or null if no failure
#
# To use an alternative implementation, replace this function.
# ============================================================================
get_capacity_status() {
    # Default implementation: Use azslurm buckets command
    local buckets_json
    if ! buckets_json=$(azslurm buckets --output-columns nodearray,vm_size,last_capacity_failure --output-format json 2>&1); then
        log_error "Failed to query azslurm buckets: $buckets_json"
        return 1
    fi
    
    # Normalize output to standard format
    echo "$buckets_json" | jq '[.[] | {nodearray: .nodearray, vm_type: .vm_size, last_capacity_failure: .last_capacity_failure}]'
}

# Alternative implementation using CycleCloud REST API
get_capacity_status_rest() {
    local autoscale_config="/opt/azurehpc/slurm/autoscale.json"
    local username password url cluster_name
    
    username=$(jq -r '.username' "$autoscale_config")
    password=$(jq -r '.password' "$autoscale_config")
    url=$(jq -r '.url' "$autoscale_config")
    cluster_name=$(jq -r '.cluster_name' "$autoscale_config")
    
    local status_json
    if ! status_json=$(curl -sk -u "$username:$password" "$url/clusters/$cluster_name/status" 2>&1); then
        log_error "Failed to query CycleCloud API: $status_json"
        return 1
    fi
    
    # Transform CycleCloud format to standard format
    # lastCapacityFailure of -1.0 means no failure, convert to null
    echo "$status_json" | jq '[.nodearrays[] | .name as $name | .buckets[] | {
        nodearray: $name,
        vm_type: .definition.machineType,
        last_capacity_failure: (if .lastCapacityFailure == -1.0 then null else .lastCapacityFailure end)
    }]'
}

# Get partition state (UP, DOWN, INACTIVE, etc.)
get_partition_state() {
    local partition="$1"
    scontrol show partition "$partition" 2>/dev/null | grep -oP 'State=\K\w+' || echo "UNKNOWN"
}

# Check if partition exists
partition_exists() {
    local partition="$1"
    scontrol show partition "$partition" &>/dev/null
}

# Get first available UP fallback partition
get_available_fallback() {
    local partition="$1"
    local fallbacks="${FALLBACK_MAPPING[$partition]:-}"
    
    if [[ -z "$fallbacks" ]]; then
        log "No fallback mapping defined for partition '$partition'"
        return 1
    fi
    
    IFS=',' read -ra fallback_list <<< "$fallbacks"
    for fallback in "${fallback_list[@]}"; do
        if partition_exists "$fallback"; then
            local state
            state=$(get_partition_state "$fallback")
            if [[ "$state" == "UP" ]]; then
                echo "$fallback"
                return 0
            fi
        fi
    done
    
    log "No available UP fallback partition found for '$partition'"
    return 1
}

# Move pending jobs from a partition to fallback
move_pending_jobs() {
    local partition="$1"
    local fallback="$2"
    
    # Get pending jobs in the partition
    local pending_jobs
    pending_jobs=$(squeue -p "$partition" -t PENDING -h -o "%i" 2>/dev/null || true)
    
    if [[ -z "$pending_jobs" ]]; then
        log "No pending jobs in partition '$partition'"
        return 0
    fi
    
    local count=0
    while IFS= read -r jobid; do
        if [[ -n "$jobid" ]]; then
            log "Moving job $jobid from '$partition' to '$fallback'"
            if scontrol update jobid="$jobid" partition="$fallback" 2>/dev/null; then
                count=$((count + 1))
            else
                log_error "Failed to move job $jobid to partition '$fallback'"
            fi
        fi
    done <<< "$pending_jobs"
    
    log "Moved $count pending jobs from '$partition' to '$fallback'"
}

# Power down nodes with configuring jobs in an INACTIVE partition
# This triggers job requeueing so jobs can be moved to fallback partitions
power_down_partition_nodes() {
    local partition="$1"
    
    # Get nodes with jobs in CONFIGURING state (waiting for nodes to power up)
    local configuring_nodes
    configuring_nodes=$(squeue -p "$partition" -t CONFIGURING -h -o "%N" 2>/dev/null | tr ',' '\n' | sort -u || true)
    
    if [[ -z "$configuring_nodes" ]]; then
        log "No CONFIGURING jobs in partition '$partition'"
        return 0
    fi
    
    log "Found nodes with CONFIGURING jobs in partition '$partition'"
    while IFS= read -r node; do
        if [[ -n "$node" ]]; then
            log "Powering down node '$node' to trigger job requeue"
            if scontrol update nodename="$node" state=power_down_force reason="capacity_failure" 2>/dev/null; then
                log "Node '$node' set to power_down_force"
            else
                log_error "Failed to power down node '$node'"
            fi
        fi
    done <<< "$configuring_nodes"
}

# Main capacity check logic
main() {
    log "Starting capacity check..."
    
    # Initialize state file
    init_state_file
    
    # Load partition mappings from config file
    if ! load_partition_mapping; then
        log_error "Failed to load partition mappings"
        exit 1
    fi
    
    # Query capacity status using the pluggable function
    local capacity_json
    if ! capacity_json=$(get_capacity_status_rest); then
        log_error "Failed to retrieve capacity status"
        exit 1
    fi
    
    # Parse each nodearray entry
    local nodearrays
    nodearrays=$(echo "$capacity_json" | jq -r '.[].nodearray' | sort -u)
    
    for nodearray in $nodearrays; do
        # Get the last_capacity_failure and vm_type for this nodearray
        local last_failure vm_type
        last_failure=$(echo "$capacity_json" | jq -r --arg na "$nodearray" \
            '.[] | select(.nodearray == $na) | .last_capacity_failure // empty')
        vm_type=$(echo "$capacity_json" | jq -r --arg na "$nodearray" \
            '.[] | select(.nodearray == $na) | .vm_type // "unknown"' | head -1)
        
        log "Nodearray '$nodearray': vm_type=$vm_type, last_capacity_failure=$last_failure"
        
        local partition="$nodearray"
        
        if ! partition_exists "$partition"; then
            continue
        fi
        
        local current_state
        current_state=$(get_partition_state "$partition")
        
        if [[ -n "$last_failure" && "$last_failure" != "null" ]]; then
            # Capacity failure detected
            log "Partition '$partition' has capacity failure (last failure: ${last_failure}s ago)"
            
            if [[ "$current_state" != "INACTIVE" ]]; then
                log "Setting partition '$partition' to INACTIVE"
                scontrol update PartitionName="$partition" State=INACTIVE
            fi
            
            # Update state file
            update_state_file "$partition" "INACTIVE" "capacity_failure: ${last_failure}s ago"
            
        else
            # No capacity failure - capacity is available
            if [[ "$current_state" == "INACTIVE" ]]; then
                # Check if we marked it INACTIVE (vs manually set)
                local saved_state
                saved_state=$(read_partition_state "$partition")
                if [[ -n "$saved_state" ]]; then
                    log "Capacity restored for partition '$partition', setting to UP"
                    scontrol update PartitionName="$partition" State=UP
                    remove_from_state_file "$partition"
                else
                    log "Partition '$partition' is INACTIVE but not tracked by us, skipping"
                fi
            fi
        fi
    done
    
    # Move pending jobs from INACTIVE partitions to fallback partitions
    log "Checking for pending jobs in INACTIVE partitions..."
    for partition in "${!FALLBACK_MAPPING[@]}"; do
        if ! partition_exists "$partition"; then
            continue
        fi
        
        local state
        state=$(get_partition_state "$partition")
        
        if [[ "$state" == "INACTIVE" ]]; then
            # Power down nodes with configuring jobs and requeue running jobs
            power_down_partition_nodes "$partition"
            
            local fallback
            if fallback=$(get_available_fallback "$partition"); then
                move_pending_jobs "$partition" "$fallback"
            fi
        fi
    done
    
    log "Capacity check complete"
}

main "$@"
