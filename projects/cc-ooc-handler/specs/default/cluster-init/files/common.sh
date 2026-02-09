#!/bin/bash
# Common functions for OOC Handler installation scripts
# This script provides shared logging and utility functions

# Default log file (can be overridden before sourcing)
LOG_FILE="${LOG_FILE:-/var/log/cc-ooc-handler-install.log}"

# Logging function to prefix messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Debug logging function (only logs if DEBUG_LOGGING is true)
debug_log() {
    if [ "${DEBUG_LOGGING:-false}" = "true" ]; then
        log "DEBUG: $*"
    fi
}

# Error handler function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Check if this is the scheduler node by verifying slurmctld service exists
check_scheduler_node() {
    if ! systemctl list-unit-files slurmctld.service &>/dev/null || ! systemctl list-unit-files slurmctld.service | grep -q slurmctld; then
        echo "ERROR: slurmctld service not found. This script can only be executed on the scheduler node."
        exit 1
    fi
}

# Load configuration from environment file if it exists
# Usage: load_configuration "$SCRIPT_DIR"
load_base_configuration() {
    local script_dir="$1"
    local config_file="$script_dir/../files/ooc-handler-config.env"
    
    if [ -f "$config_file" ]; then
        log "Loading configuration from $config_file"
        source "$config_file"
    else
        log "Configuration file $config_file not found, using defaults"
    fi
    
    # Set defaults for common configuration variables
    DEBUG_LOGGING="${DEBUG_LOGGING:-false}"
}
