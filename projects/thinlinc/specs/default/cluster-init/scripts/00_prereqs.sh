#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../files/common.sh"

# Install nslookup if missing
install_nslookup() {
    if command -v nslookup &>/dev/null; then
        log "nslookup is already installed"
        return 0
    fi

    log "nslookup not found, installing..."
    local os_id
    os_id=$(source /etc/os-release && echo "$ID")
    case "$os_id" in
        almalinux|rhel|centos|rocky|fedora)
            dnf install -y bind-utils || error_exit "Failed to install bind-utils"
            ;;
        ubuntu|debian)
            apt-get update && apt-get install -y dnsutils || error_exit "Failed to install dnsutils"
            ;;
        *)
            error_exit "Unsupported OS for nslookup installation: $os_id"
            ;;
    esac
    log "nslookup installed successfully"
}

# Configure firewalld ports on AlmaLinux/RHEL if firewalld is running
configure_firewalld() {
    # Only proceed on RHEL-based systems
    local os_id
    os_id=$(source /etc/os-release && echo "$ID")
    if [[ "$os_id" != "almalinux" && "$os_id" != "rhel" && "$os_id" != "centos" && "$os_id" != "rocky" ]]; then
        log "Not a RHEL-based system ($os_id), skipping firewalld configuration"
        return 0
    fi

    systemctl stop firewalld || log "WARNING: Failed to stop firewalld (may not be running)"
    systemctl disable firewalld || log "WARNING: Failed to disable firewalld (may not be running)"
    
    # Only proceed if firewalld is active
    if ! systemctl is-active --quiet firewalld; then
        log "firewalld is not running, skipping firewall configuration"
        return 0
    fi

    log "Configuring firewalld ports for Slurm, HTTPS, and CycleCloud"

    # HTTPS
    firewall-cmd --permanent --add-service=https || error_exit "Failed to add HTTPS service to firewalld"

    # Slurm ports: slurmctld (6817), slurmd (6818), slurmdbd (6819)
    firewall-cmd --permanent --add-port=6817-6819/tcp || error_exit "Failed to add Slurm ports to firewalld"

    # CycleCloud (9443)
    firewall-cmd --permanent --add-port=9443/tcp || error_exit "Failed to add CycleCloud port to firewalld"

    # Reload to apply changes
    firewall-cmd --reload || error_exit "Failed to reload firewalld"

    log "firewalld configured successfully"
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

    install_nslookup
    configure_firewalld
    disable_selinux

    log "Prerequisites installation completed successfully"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
