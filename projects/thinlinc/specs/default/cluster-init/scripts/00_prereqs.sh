#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../files/common.sh"

# Disable firewalld ports on AlmaLinux/RHEL if firewalld is running
disable_firewalld() {
    # Only proceed on RHEL-based systems
    local os_id
    os_id=$(source /etc/os-release && echo "$ID")
    if [[ "$os_id" != "almalinux" && "$os_id" != "rhel" && "$os_id" != "centos" && "$os_id" != "rocky" ]]; then
        log "Not a RHEL-based system ($os_id), skipping firewalld configuration"
        return 0
    fi

    systemctl stop firewalld || log "WARNING: Failed to stop firewalld (may not be running)"
    systemctl disable firewalld || log "WARNING: Failed to disable firewalld (may not be running)"

    log "firewalld disabled successfully"
}

# Disable SELinux if enabled
disable_selinux() {
    if ! command -v getenforce &>/dev/null; then
        log "SELinux not available on this system, skipping"
        return 0
    fi

    local current_status
    current_status=$(getenforce)
    if [[ "$current_status" == "Disabled" ]]; then
        log "SELinux is already disabled"
        return 0
    fi

    log "SELinux is $current_status, disabling..."

    # Disable at runtime
    setenforce 0 || log "WARNING: Failed to set SELinux to permissive (may already be permissive)"

    # Disable persistently
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || error_exit "Failed to update /etc/selinux/config"
        log "SELinux disabled persistently in /etc/selinux/config"
    fi

    log "SELinux disabled successfully"
}

# Main execution function
main() {
    initialize_logging
    log "Starting prerequisites installation"

    log "Script: $0"
    log "User: $(whoami)"
    log "Date: $(date)"

    check_root

    disable_firewalld
    disable_selinux

    log "Prerequisites installation completed successfully"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
