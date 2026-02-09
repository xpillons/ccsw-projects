#!/bin/bash
# Capacity Check Installation Script
# This script installs and configures the capacity_check.sh as a cron job
# to monitor CycleCloud cluster capacity and handle out-of-capacity scenarios

set -euo pipefail

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/var/log/capacity_check.log"
INSTALL_DIR="/opt/azurehpc/slurm"

# Source common functions
source "$SCRIPT_DIR/../files/common.sh"

# Check if this is the scheduler node
check_scheduler_node

# Load configuration from environment file if it exists
load_configuration() {
    load_base_configuration "$SCRIPT_DIR"
    
    # Capacity check configuration
    CAPACITY_CHECK_CRON="${CAPACITY_CHECK_CRON:-*/6 * * * *}"
    INSTALL_DIR="${INSTALL_DIR:-/opt/azurehpc/slurm}"
    
    # Verify INSTALL_DIR exists
    if [ ! -d "$INSTALL_DIR" ]; then
        error_exit "Install directory $INSTALL_DIR does not exist"
    fi
    
    log "Configuration loaded:"
    log "  Cron schedule: ${CAPACITY_CHECK_CRON}"
    log "  Install directory: $INSTALL_DIR"
}

# Install the capacity check script
install_script() {
    log "Installing capacity check script..."
    
    local script_source="$SCRIPT_DIR/../files/capacity_check.sh"
    local script_dest="$INSTALL_DIR/capacity_check.sh"
    
    if [ -f "$script_source" ]; then
        cp "$script_source" "$script_dest"
        chmod 755 "$script_dest"
        log "Installed script to $script_dest"
    else
        error_exit "Script source file not found at $script_source"
    fi
}

# Install logrotate configuration
install_logrotate() {
    log "Installing logrotate configuration..."
    
    local logrotate_source="$SCRIPT_DIR/../files/capacity_check.logrotate"
    local logrotate_dest="/etc/logrotate.d/capacity-check"
    
    if [ -f "$logrotate_source" ]; then
        cp "$logrotate_source" "$logrotate_dest"
        chmod 644 "$logrotate_dest"
        log "Installed logrotate config to $logrotate_dest"
    else
        log "WARNING: Logrotate config not found at $logrotate_source, skipping"
    fi
}

# Install the cron job
install_cron() {
    log "Installing cron job..."
    
    local cron_file="/etc/cron.d/capacity-check"
    
    cat > "$cron_file" << EOF
# CycleCloud Capacity Check for Slurm
# Runs every 6 minutes to monitor partition capacity
${CAPACITY_CHECK_CRON} root ${INSTALL_DIR}/capacity_check.sh >> /var/log/capacity_check.log 2>&1
EOF
    chmod 644 "$cron_file"
    log "Created cron job: $cron_file"
}

# Main installation function
main() {
    log "========================================="
    log "Starting Capacity Check Service Installation"
    log "=========================================="
    
    # Ensure running as root
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    load_configuration
    install_script
    install_logrotate
    install_cron
    
    log "=========================================="
    log "Capacity Check Installation Complete"
    log "=========================================="
    log ""
    log "The capacity check runs on schedule: ${CAPACITY_CHECK_CRON}"
    log "To view logs: tail -f /var/log/capacity_check.log"
    log "To run manually: ${INSTALL_DIR}/capacity_check.sh"
}

main "$@"
