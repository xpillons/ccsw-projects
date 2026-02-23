#!/bin/bash

set -euo pipefail

# Global variables
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TL_ROOT="/opt/thinlinc"
LOG_FILE="/var/log/thinlinc-webaccess-config.log"
enable_web="True"
thinlinc_web_port=443

# Logging function to prefix messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] $*" | tee -a "$LOG_FILE"
}

# Error handler function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Initialize logging
initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    log "Starting ThinLinc Web Access configuration"
}

# Check if ThinLinc is installed and accessible
validate_thinlinc_installation() {
    log "Validating ThinLinc installation"
    
    if [ ! -d "$TL_ROOT" ]; then
        error_exit "ThinLinc root directory not found: $TL_ROOT"
    fi
    
    if [ ! -f "/opt/thinlinc/bin/tl-config" ]; then
        error_exit "ThinLinc configuration tool not found"
    fi
    
    log "ThinLinc installation validation passed"
}

# Configure ThinLinc web access port
configure_web_port() {
    log "Configuring ThinLinc Web Access port to $thinlinc_web_port"
    
    if ! /opt/thinlinc/bin/tl-config "/webaccess/listen_port=$thinlinc_web_port"; then
        error_exit "Failed to configure ThinLinc Web Access port number"
    fi
    
    log "ThinLinc Web Access port configured successfully"
}

# Configure proxy settings for reverse proxy compatibility
# After successful authentication, Thinlinc's main.py generates an absolute
# redirect URL (https://<host>:<port>/agent) which bypasses the OOD reverse
# proxy. This function replaces that absolute redirect with a relative path
# (../../../agent) that works correctly both through the proxy and directly.
#
# The relative path resolves as follows:
#   Through proxy: /secure-rnode/<host>/<port>/connect/<agent>/agent
#     ../../../agent -> /secure-rnode/<host>/<port>/agent (proxied correctly)
#   Direct access: /connect/<agent>/agent
#     ../../../agent -> /agent (works as before)
configure_proxy_settings() {
    log "Configuring proxy settings for reverse proxy compatibility"

    local main_py="$TL_ROOT/modules/thinlinc/tlwebaccess/main.py"

    if [ ! -f "$main_py" ]; then
        error_exit "Thinlinc main.py not found: $main_py"
    fi

    # Backup main.py before modification
    cp "$main_py" "${main_py}.backup.$(date +%Y%m%d_%H%M%S)" || \
        error_exit "Failed to backup main.py"

    # Replace the absolute redirect URL with a relative path
    # Original: "https://%s:%s/agent" % ( OO0000 , I1i )
    # Fixed:    "../../agent"
    #
    # URL resolution from browser at:
    #   /secure-rnode/<host>/<port>/connect/<agent>/agent
    # Base dir: /secure-rnode/<host>/<port>/connect/<agent>/
    #   ../../agent -> /secure-rnode/<host>/<port>/agent (proxied correctly)
    log "Updating main.py to use relative redirect path"
    if ! sed -i 's|"https://%s:%s/agent" % ( OO0000 , I1i )|"../../agent"|' "$main_py"; then
        error_exit "Failed to update redirect URL in main.py"
    fi

    # Verify the change was applied
    if grep -q 'https://%s:%s/agent' "$main_py"; then
        error_exit "Failed to verify redirect URL change in main.py"
    fi

    log "Proxy settings configured successfully"
}

# Restart tlwebaccess service
restart_tlwebaccess_service() {
    log "Restarting ThinLinc Web Access service"
    
    if ! systemctl restart tlwebaccess; then
        error_exit "Failed to restart tlwebaccess service"
    fi
    
    # Verify service is running
    if ! systemctl is-active --quiet tlwebaccess; then
        error_exit "ThinLinc Web Access service failed to start"
    fi
    
    log "ThinLinc Web Access service restarted successfully"
}

# Disable tlwebaccess service
disable_tlwebaccess_service() {
    log "Disabling ThinLinc Web Access service"
    
    if ! systemctl disable --now tlwebaccess; then
        error_exit "Failed to disable tlwebaccess service"
    fi
    
    # Verify service is stopped
    if systemctl is-active --quiet tlwebaccess; then
        error_exit "ThinLinc Web Access service failed to stop"
    fi
    
    log "ThinLinc Web Access service disabled successfully"
}

# Configure /etc/pam.d/sshd for ThinLinc password authentication
configure_sshd_pam() {
    log "Configuring PAM sshd for ThinLinc"
    
    local sshd_pam="/etc/pam.d/sshd"
    local pam_line="auth\t   [success=done ignore=ignore default=die] pam_tlpasswd.so"
    
    # Configure PAM for sshd
    if [ ! -f "$sshd_pam" ]; then
        error_exit "SSHD PAM configuration file not found: $sshd_pam"
    fi
    
    # Check if pam_tlpasswd already configured
    if grep -q "pam_tlpasswd.so" "$sshd_pam"; then
        log "pam_tlpasswd already configured in $sshd_pam"
        return 0
    fi
    
    # Backup and add PAM line at the top
    log "Adding pam_tlpasswd to $sshd_pam"
    cp "$sshd_pam" "${sshd_pam}.pre-tlpasswd.$(date +%Y%m%d_%H%M%S)" || error_exit "Failed to backup $sshd_pam"
    
    local temp_file="/tmp/sshd_pam_temp.$$"
    {
        echo -e "$pam_line"
        cat "$sshd_pam"
    } > "$temp_file"
    
    mv "$temp_file" "$sshd_pam" || error_exit "Failed to update $sshd_pam"
    chmod 644 "$sshd_pam" || error_exit "Failed to set $sshd_pam permissions"
    
    log "PAM sshd configured successfully"
}

# Install custom xsession file from ood-thinlinc repository
install_xsession() {
    log "Installing custom xsession file"
    
    local xsession_url="https://raw.githubusercontent.com/cendio/ood-thinlinc/main/prequisites/xsession"
    local xsession_dest="$TL_ROOT/etc/xsession"
    local tmp_file="/tmp/xsession.$$"
    
    log "Downloading xsession from $xsession_url"
    if ! wget -q -O "$tmp_file" "$xsession_url"; then
        error_exit "Failed to download xsession"
    fi
    
    install -m 755 "$tmp_file" "$xsession_dest" || error_exit "Failed to install xsession to $xsession_dest"
    rm -f "$tmp_file"
    
    log "Custom xsession file installed successfully"
}

# Enable and configure ThinLinc Web Access
enable_web_access() {
    log "Enabling ThinLinc Web Access"
    
    configure_sshd_pam
    install_xsession
    configure_web_port
    configure_proxy_settings
    restart_tlwebaccess_service
    
    log "ThinLinc Web Access enabled and configured successfully"
}

# Disable ThinLinc Web Access
disable_web_access() {
    log "Disabling ThinLinc Web Access"
    
    disable_tlwebaccess_service
    
    log "ThinLinc Web Access disabled successfully"
}

# Display configuration summary
show_configuration_summary() {
    log ""
    log "=== ThinLinc Web Access Configuration Summary ==="
    log "Status: $([ "$enable_web" = "True" ] && echo "ENABLED" || echo "DISABLED")"
    
    if [ "$enable_web" = "True" ]; then
        log "Web port: $thinlinc_web_port"
        log "Service status: $(systemctl is-active tlwebaccess || echo "inactive")"
        log "Proxy base URL: secure-rnode/$(hostname)/$thinlinc_web_port/"
        log ""
        log "Access URL: https://$(hostname):$thinlinc_web_port/"
        log "Reverse proxy path: /secure-rnode/$(hostname)/$thinlinc_web_port/"
    fi
    
    log "Configuration completed successfully"
}

# Main execution function
main() {
    initialize_logging
    
    log "Script: $0"
    log "User: $(whoami)"
    log "Date: $(date)"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    validate_thinlinc_installation
    
    if [ "$enable_web" = "True" ]; then
        enable_web_access
    else
        disable_web_access
    fi
    
    show_configuration_summary
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
