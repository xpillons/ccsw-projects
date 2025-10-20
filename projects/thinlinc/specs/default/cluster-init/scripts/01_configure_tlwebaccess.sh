#!/bin/bash

set -euo pipefail

# Global variables
SCRIPT_NAME="$(basename "$0")"
TL_ROOT="/opt/thinlinc"
TL_HTML_TEMPLATES="$TL_ROOT/share/tlwebaccess/templates"
LOG_FILE="/var/log/thinlinc-webaccess-config.log"

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

# Fetch configuration parameters from jetpack
fetch_configuration() {
    log "Fetching ThinLinc configuration parameters"
    
    enable_web=$(jetpack config thinlinc.enable_web False)
    thinlinc_web_port=$(jetpack config thinlinc.web_port 443)
    
    log "Configuration loaded:"
    log "  Enable web access: $enable_web"
    log "  Web port: $thinlinc_web_port"
    
    # Validate port number
    if ! [[ "$thinlinc_web_port" =~ ^[0-9]+$ ]] || [ "$thinlinc_web_port" -lt 1 ] || [ "$thinlinc_web_port" -gt 65535 ]; then
        error_exit "Invalid port number: $thinlinc_web_port"
    fi
    
    # Export for use in other functions
    export enable_web thinlinc_web_port
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

# Install OATH packages based on distribution
install_oath_packages() {
    log "Installing OATH authentication packages"
    
    local distro
    distro=$(detect_linux_distribution)
    
    case "$distro" in
        "rhel"|"centos"|"rocky"|"almalinux"|"fedora")
            log "Detected RHEL-based system: $distro"
            
            # Install EPEL repository if not already installed
            if ! rpm -q epel-release &>/dev/null; then
                log "Installing EPEL repository"
                if command -v dnf &>/dev/null; then
                    dnf install -y epel-release || error_exit "Failed to install EPEL repository"
                else
                    yum install -y epel-release || error_exit "Failed to install EPEL repository"
                fi
            fi
            
            # Install packages
            log "Installing pam_oath and oathtool packages"
            if command -v dnf &>/dev/null; then
                dnf install -y pam_oath oathtool || error_exit "Failed to install OATH packages"
            else
                yum install -y pam_oath oathtool || error_exit "Failed to install OATH packages"
            fi
            ;;
            
        "ubuntu"|"debian")
            log "Detected Debian-based system: $distro"
            
            # Update package list
            log "Updating package list"
            apt-get update || error_exit "Failed to update package list"
            
            # Install packages
            log "Installing libpam-oath and oathtool packages"
            apt-get install -y libpam-oath oathtool || error_exit "Failed to install OATH packages"
            ;;
            
        *)
            error_exit "Unsupported Linux distribution: $distro"
            ;;
    esac
    
    log "OATH packages installed successfully"
}

# Create backup of PAM configuration
backup_pam_configuration() {
    log "Creating backup of PAM configuration"
    
    local backup_file="/etc/pam.d/thinlinc"
    local source_file="/etc/pam.d/sshd"
    
    if [ ! -f "$source_file" ]; then
        error_exit "Source PAM file not found: $source_file"
    fi
    
    if [ -f "$backup_file" ]; then
        log "ThinLinc PAM configuration already exists, creating timestamped backup"
        cp "$backup_file" "${backup_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    cp "$source_file" "$backup_file" || error_exit "Failed to copy PAM configuration"
    log "PAM configuration backed up successfully"
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
    local proxy_base_url="rnode\/${hostname_var}\/${thinlinc_web_port}\/"
    
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

# Enable and configure ThinLinc Web Access
enable_web_access() {
    log "Enabling ThinLinc Web Access"
    
    backup_pam_configuration
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
        log "Proxy base URL: rnode/$(hostname)/$thinlinc_web_port/"
        log ""
        log "Access URL: https://$(hostname):$thinlinc_web_port/"
        log "Reverse proxy path: /rnode/$(hostname)/$thinlinc_web_port/"
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
    
    fetch_configuration
    validate_thinlinc_installation
    
    if [ "$enable_web" = "True" ]; then
        install_oath_packages
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
