#!/bin/bash
# Capacity Check Service Installation Script
# This script installs and configures the capacity_check.sh as a systemd service
# to monitor CycleCloud cluster capacity and handle out-of-capacity scenarios

set -euo pipefail

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/var/log/capacity_check.log"
SERVICE_NAME="capacity-check"
INSTALL_DIR="/opt/azurehpc/slurm"

# Source common functions
source "$SCRIPT_DIR/../files/common.sh"

# Check if this is the scheduler node
check_scheduler_node

# Load configuration from environment file if it exists
load_configuration() {
    load_base_configuration "$SCRIPT_DIR"
    
    # Capacity check service configuration
    CAPACITY_CHECK_INTERVAL="${CAPACITY_CHECK_INTERVAL:-300}"
    INSTALL_DIR="${INSTALL_DIR:-/opt/azurehpc/slurm}"
    
    # Verify INSTALL_DIR exists
    if [ ! -d "$INSTALL_DIR" ]; then
        error_exit "Install directory $INSTALL_DIR does not exist"
    fi
    
    log "Configuration loaded:"
    log "  Capacity check interval: ${CAPACITY_CHECK_INTERVAL}s"
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

# Create and install the systemd service unit
install_systemd_service() {
    log "Installing systemd service..."
    
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    local timer_file="/etc/systemd/system/${SERVICE_NAME}.timer"
    
    # Create the service unit (oneshot, triggered by timer)
    cat > "$service_file" << EOF
[Unit]
Description=CycleCloud Capacity Check for Slurm
After=network.target slurmctld.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/capacity_check.sh
StandardOutput=append:/var/log/capacity_check.log
StandardError=append:/var/log/capacity_check.log
User=root

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$service_file"
    log "Created service unit: $service_file"
    
    # Create the timer unit
    cat > "$timer_file" << EOF
[Unit]
Description=Run CycleCloud Capacity Check periodically
After=slurmctld.service
Requires=slurmctld.service

[Timer]
OnBootSec=60
OnUnitActiveSec=${CAPACITY_CHECK_INTERVAL}
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$timer_file"
    log "Created timer unit: $timer_file"
}

# Enable and start the systemd timer
enable_service() {
    log "Enabling and starting capacity check timer..."
    
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.timer"
    systemctl start "${SERVICE_NAME}.timer"
    
    log "Timer enabled and started"
    log "Timer status:"
    systemctl status "${SERVICE_NAME}.timer" --no-pager || true
}

# Main installation function
main() {
    log "========================================="
    log "Starting Capacity Check Service Installation"
    log "=========================================="
    
    load_configuration
    install_script
    install_logrotate
    install_systemd_service
    enable_service
    
    log "=========================================="
    log "Capacity Check Service Installation Complete"
    log "=========================================="
    log ""
    log "The capacity check runs every ${CAPACITY_CHECK_INTERVAL} seconds."
    log "To check status: systemctl status ${SERVICE_NAME}.timer"
    log "To view logs: tail -f /var/log/capacity_check.log"
    log "To run manually: systemctl start ${SERVICE_NAME}.service"
}

main "$@"
