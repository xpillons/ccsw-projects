#!/bin/bash

set -euo pipefail

# Global variables
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TL_ROOT="/opt/thinlinc"
TL_HTML_TEMPLATES="$TL_ROOT/share/tlwebaccess/templates"
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
    
    if [ ! -d "$TL_HTML_TEMPLATES" ]; then
        error_exit "ThinLinc HTML templates directory not found: $TL_HTML_TEMPLATES"
    fi
    
    log "ThinLinc installation validation passed"
}

# Detect Linux distribution
detect_linux_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/debian_version ]; then
        echo "ubuntu"
    else
        error_exit "Unable to detect Linux distribution"
    fi
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
configure_proxy_settings() {
    log "Configuring proxy settings for reverse proxy compatibility"
    
    local hostname_var
    hostname_var=$(hostname)
    local proxy_base_url="secure-rnode\/${hostname_var}\/${thinlinc_web_port}\/"
    
    log "Using proxy base URL: $proxy_base_url"
    
    # Backup template files before modification
    backup_template_files
    
    # Update main.tmpl
    log "Updating main.tmpl template"
    if ! sed -i -e "s/action=\"\/\"/action=\"\/${proxy_base_url}\"/" "$TL_HTML_TEMPLATES/main.tmpl"; then
        error_exit "Failed to update action URL in main.tmpl"
    fi
    
    if ! sed -i -e "s/\$qh(\$targetserver)/\/${proxy_base_url}/" "$TL_HTML_TEMPLATES/main.tmpl"; then
        error_exit "Failed to update target server URL in main.tmpl"
    fi
    
    # Update vnc.tmpl
    log "Updating vnc.tmpl template"
    if ! sed -i -e "s/href=\"\/\"/href=\"\/${proxy_base_url}\"/" "$TL_HTML_TEMPLATES/vnc.tmpl"; then
        error_exit "Failed to update href URL in vnc.tmpl"
    fi
    
	# Replace websocket with "secure-rnode/$(hostname)/port/websocket"
    log "Updating websocket proxy in agent.py"
    if ! sed -i -e "s/websocket\//\/${proxy_base_url}websocket\//" "$TL_ROOT/modules/thinlinc/tlwebaccess/agent.py"; then
        error_exit "Failed to update websocket URL in agent.py"
    fi
	
    log "Proxy settings configured successfully"
}

# Create backup of template files
backup_template_files() {
    log "Creating backup of template files"
    
    local backup_dir="/opt/thinlinc/share/tlwebaccess/templates.backup.$(date +%Y%m%d_%H%M%S)"
    
    if ! mkdir -p "$backup_dir"; then
        error_exit "Failed to create template backup directory"
    fi
    
    if ! cp "$TL_HTML_TEMPLATES"/*.tmpl "$backup_dir/" 2>/dev/null; then
        log "Warning: Failed to backup some template files (they may not exist)"
    else
        log "Template files backed up to: $backup_dir"
    fi
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

# Install and configure PAM ThinLinc password module
install_pam_tlpasswd() {
    log "Installing PAM ThinLinc password module"
    
    local pam_url="https://github.com/cendio/ood-thinlinc/releases/download/v1.0/pam_tlpasswd.so"
    local pam_dir="/lib64/security"
    local pam_dest="$pam_dir/pam_tlpasswd.so"
    local sshd_pam="/etc/pam.d/sshd"
    local pam_line="auth\t   [success=done ignore=ignore default=die] pam_tlpasswd.so"
    
    # Download PAM module
    log "Downloading pam_tlpasswd.so from $pam_url"
    local tmp_file="/tmp/pam_tlpasswd.so.$$"
    if ! wget -q -O "$tmp_file" "$pam_url"; then
        error_exit "Failed to download pam_tlpasswd.so"
    fi
    
    # Create target directory and install module
    mkdir -p "$pam_dir" || error_exit "Failed to create $pam_dir"
    install "$tmp_file" "$pam_dest" || error_exit "Failed to install pam_tlpasswd.so"
    rm -f "$tmp_file"
    log "PAM module installed to $pam_dest"
    
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
    
    log "PAM ThinLinc password module configured successfully"
}

# Install custom xsession file
install_xsession() {
    log "Installing custom xsession file"
    
    local xsession_source="$SCRIPT_DIR/../files/xsession"
    local xsession_dest="$TL_ROOT/etc/xsession"
    
    if [ ! -f "$xsession_source" ]; then
        error_exit "xsession source file not found: $xsession_source"
    fi
    
    cp "$xsession_source" "$xsession_dest" || error_exit "Failed to copy xsession to $xsession_dest"
    chmod 755 "$xsession_dest" || error_exit "Failed to set xsession permissions"
    
    log "Custom xsession file installed successfully"
}

# Enable and configure ThinLinc Web Access
enable_web_access() {
    log "Enabling ThinLinc Web Access"
    
    install_pam_tlpasswd
    install_xsession
    configure_web_port
    #configure_proxy_settings
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
