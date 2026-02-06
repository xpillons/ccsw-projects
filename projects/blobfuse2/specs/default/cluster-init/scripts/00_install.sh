#!/bin/bash
# Blobfuse2 Installation and Configuration Script
# This script installs and configures blobfuse2 for Azure Blob Storage mounting
# on CycleCloud clusters

set -euo pipefail

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/var/log/blobfuse2-install.log"
CONFIG_DIR="/etc/blobfuse2"

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

# Detect OS type and version
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
        OS_NAME="${NAME}"
    else
        error_exit "Cannot detect OS. /etc/os-release not found."
    fi
    
    log "Detected OS: $OS_NAME ($OS_ID $OS_VERSION)"
}

# Load configuration from environment file if it exists
load_configuration() {
    local config_file="$SCRIPT_DIR/../files/blobfuse2-config.env"
    
    if [ -f "$config_file" ]; then
        log "Loading configuration from $config_file"
        source "$config_file"
    else
        log "Configuration file $config_file not found, using defaults"
    fi
    
    # Set defaults for required variables
    AUTH_METHOD="${AUTH_METHOD:-msi}"
    MOUNT_POINT="${MOUNT_POINT:-/blobfuse}"
    CACHE_SIZE_MB="${CACHE_SIZE_MB:-10240}"
    CACHE_TIMEOUT_SEC="${CACHE_TIMEOUT_SEC:-120}"
    FILE_CACHE_MODE="${FILE_CACHE_MODE:-file}"
    ALLOW_OTHER="${ALLOW_OTHER:-true}"
    READ_ONLY="${READ_ONLY:-true}"
    LOG_LEVEL="${LOG_LEVEL:-LOG_WARNING}"
    BLOBFUSE_LOG_FILE="${LOG_FILE:-/var/log/blobfuse2.log}"
    ENABLE_SYSTEMD_SERVICE="${ENABLE_SYSTEMD_SERVICE:-true}"
    DEBUG_LOGGING="${DEBUG_LOGGING:-false}"
    
    # Auto-detect cache directory if not specified
    if [ -z "${CACHE_DIR:-}" ]; then
        if [ -d "/mnt/nvme" ]; then
            CACHE_DIR="/mnt/nvme/blobfuse2-cache"
            debug_log "Auto-detected NVMe storage, using $CACHE_DIR"
        elif [ -d "/mnt/resource" ]; then
            CACHE_DIR="/mnt/resource/blobfuse2-cache"
            debug_log "Using Azure temp disk for cache: $CACHE_DIR"
        elif [ -d "/mnt" ]; then
            CACHE_DIR="/mnt/blobfuse2-cache"
            debug_log "Using /mnt storage for cache: $CACHE_DIR"
        else
            CACHE_DIR="/tmp/blobfuse2-cache"
            debug_log "Using default cache location: $CACHE_DIR"
        fi
    fi
    
    log "Configuration loaded:"
    log "  Auth method: $AUTH_METHOD"
    log "  Mount point: $MOUNT_POINT"
    log "  Cache directory: $CACHE_DIR"
    log "  Cache size: ${CACHE_SIZE_MB}MB"
    log "  Cache timeout: ${CACHE_TIMEOUT_SEC}s"
    log "  File cache mode: $FILE_CACHE_MODE"
    log "  Allow other: $ALLOW_OTHER"
    log "  Read only: $READ_ONLY"
    log "  Systemd service: $ENABLE_SYSTEMD_SERVICE"
}

# Install blobfuse2 on RHEL/CentOS/AlmaLinux/Rocky
install_rhel() {
    log "Installing blobfuse2 on RHEL-based system..."
    
    local major_version="${OS_VERSION%%.*}"
    
    # Configure Microsoft package repository
    log "Configuring Microsoft package repository..."
    rpm -Uvh "https://packages.microsoft.com/config/rhel/${major_version}/packages-microsoft-prod.rpm" 2>/dev/null || true
    
    # Install blobfuse2
    log "Installing blobfuse2 package..."
    dnf install -y blobfuse2 fuse3 || yum install -y blobfuse2 fuse3
    
    log "blobfuse2 installed successfully on RHEL-based system"
}

# Install blobfuse2 on Ubuntu/Debian
install_debian() {
    log "Installing blobfuse2 on Debian-based system..."
    
    # Install prerequisites
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    
    # Get distribution info
    local distro_name="${OS_ID}"
    local distro_version="${OS_VERSION}"
    
    # For Ubuntu, use the codename
    if [ "$distro_name" = "ubuntu" ]; then
        distro_version=$(lsb_release -cs)
    fi
    
    # Configure Microsoft package repository
    log "Configuring Microsoft package repository..."
    curl -fsSL "https://packages.microsoft.com/keys/microsoft.asc" | gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg 2>/dev/null || true
    
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/microsoft-${distro_name}-${distro_version}-prod ${distro_version} main" > /etc/apt/sources.list.d/microsoft.list
    
    apt-get update
    
    # Install blobfuse2
    log "Installing blobfuse2 package..."
    apt-get install -y blobfuse2 fuse3
    
    log "blobfuse2 installed successfully on Debian-based system"
}

# Install blobfuse2 based on OS
install_blobfuse2() {
    log "Starting blobfuse2 installation..."
    
    # Check if already installed
    if command -v blobfuse2 &>/dev/null; then
        local installed_version
        installed_version=$(blobfuse2 --version 2>&1 | head -1 || echo "unknown")
        log "blobfuse2 is already installed: $installed_version"
        return 0
    fi
    
    case "$OS_ID" in
        rhel|centos|almalinux|rocky|ol|fedora)
            install_rhel
            ;;
        ubuntu|debian)
            install_debian
            ;;
        *)
            error_exit "Unsupported OS: $OS_ID"
            ;;
    esac
    
    # Verify installation
    if command -v blobfuse2 &>/dev/null; then
        local version
        version=$(blobfuse2 --version 2>&1 | head -1 || echo "unknown")
        log "blobfuse2 installation verified: $version"
    else
        error_exit "blobfuse2 installation failed - command not found"
    fi
}

# Create cache directory
setup_cache_directory() {
    log "Setting up cache directory: $CACHE_DIR"
    
    mkdir -p "$CACHE_DIR"
    chmod 755 "$CACHE_DIR"
    
    log "Cache directory created successfully"
}

# Create mount point
setup_mount_point() {
    log "Setting up mount point: $MOUNT_POINT"
    
    mkdir -p "$MOUNT_POINT"
    chmod 755 "$MOUNT_POINT"
    
    log "Mount point created successfully"
}

# Create blobfuse2 configuration file
create_config_file() {
    log "Creating blobfuse2 configuration..."
    
    mkdir -p "$CONFIG_DIR"
    
    local config_file="$CONFIG_DIR/config.yaml"
    
    # Build allow-other config
    local allow_other_config=""
    if [ "$ALLOW_OTHER" = "true" ]; then
        allow_other_config="allow-other: true"
    else
        allow_other_config="allow-other: false"
    fi
    
    # Build read-only config
    local readonly_config=""
    if [ "$READ_ONLY" = "true" ]; then
        readonly_config="read-only: true"
    else
        readonly_config="read-only: false"
    fi
    
    # Create base config with file caching
    cat > "$config_file" << EOF
# Blobfuse2 Configuration
# Generated by CycleCloud cluster-init

logging:
  type: syslog
  level: ${LOG_LEVEL}
  file-path: ${BLOBFUSE_LOG_FILE}

components:
  - libfuse
  - file_cache
  - attr_cache
  - azstorage

libfuse:
  ${allow_other_config}
  ${readonly_config}
  attribute-expiration-sec: ${CACHE_TIMEOUT_SEC}
  entry-expiration-sec: ${CACHE_TIMEOUT_SEC}
  negative-entry-expiration-sec: ${CACHE_TIMEOUT_SEC}

file_cache:
  path: ${CACHE_DIR}
  timeout-sec: ${CACHE_TIMEOUT_SEC}
  max-size-mb: ${CACHE_SIZE_MB}
  allow-non-empty-temp: true

attr_cache:
  timeout-sec: ${CACHE_TIMEOUT_SEC}

azstorage:
  type: block
EOF

    # Add authentication section based on method
    if [ "$AUTH_METHOD" = "msi" ]; then
        cat >> "$config_file" << EOF
  mode: msi
EOF
        if [ -n "${STORAGE_ACCOUNT_NAME:-}" ]; then
            cat >> "$config_file" << EOF
  account-name: ${STORAGE_ACCOUNT_NAME}
  container: ${STORAGE_CONTAINER_NAME:-}
EOF
        fi
    elif [ "$AUTH_METHOD" = "key" ]; then
        if [ -z "${STORAGE_ACCOUNT_NAME:-}" ] || [ -z "${STORAGE_ACCOUNT_KEY:-}" ]; then
            log "WARNING: Storage account name/key not configured. Mount will require manual configuration."
        else
            cat >> "$config_file" << EOF
  mode: key
  account-name: ${STORAGE_ACCOUNT_NAME}
  account-key: ${STORAGE_ACCOUNT_KEY}
  container: ${STORAGE_CONTAINER_NAME:-}
EOF
        fi
    fi
    
    chmod 600 "$config_file"
    
    log "Configuration file created: $config_file"
}

# Configure FUSE to allow other users
configure_fuse() {
    log "Configuring FUSE..."
    
    local fuse_conf="/etc/fuse.conf"
    
    if [ "$ALLOW_OTHER" = "true" ]; then
        # Ensure user_allow_other is enabled in fuse.conf
        if [ -f "$fuse_conf" ]; then
            if ! grep -q "^user_allow_other" "$fuse_conf"; then
                echo "user_allow_other" >> "$fuse_conf"
                log "Enabled user_allow_other in $fuse_conf"
            else
                debug_log "user_allow_other already enabled in $fuse_conf"
            fi
        else
            echo "user_allow_other" > "$fuse_conf"
            log "Created $fuse_conf with user_allow_other"
        fi
    fi
}

# Create systemd service for auto-mount
create_systemd_service() {
    if [ "$ENABLE_SYSTEMD_SERVICE" != "true" ]; then
        log "Systemd service creation skipped (disabled in configuration)"
        return 0
    fi
    
    log "Creating systemd service for blobfuse2..."
    
    local service_file="/etc/systemd/system/blobfuse2.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=Blobfuse2 Azure Blob Storage Mount
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/blobfuse2 mount ${MOUNT_POINT} --config-file=${CONFIG_DIR}/config.yaml
ExecStop=/usr/bin/fusermount3 -u ${MOUNT_POINT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 "$service_file"
    
    # Reload systemd
    systemctl daemon-reload
    
    log "Systemd service created: $service_file"
    log "To enable auto-mount on boot: systemctl enable blobfuse2"
    log "To start mount now: systemctl start blobfuse2"
}

# Validate installation
validate_installation() {
    log "Validating blobfuse2 installation..."
    
    local validation_passed=true
    
    # Check blobfuse2 binary
    if command -v blobfuse2 &>/dev/null; then
        log "  ✓ blobfuse2 binary found"
    else
        log "  ✗ blobfuse2 binary not found"
        validation_passed=false
    fi
    
    # Check configuration file
    if [ -f "$CONFIG_DIR/config.yaml" ]; then
        log "  ✓ Configuration file exists"
    else
        log "  ✗ Configuration file missing"
        validation_passed=false
    fi
    
    # Check cache directory
    if [ -d "$CACHE_DIR" ]; then
        log "  ✓ Cache directory exists"
    else
        log "  ✗ Cache directory missing"
        validation_passed=false
    fi
    
    # Check mount point
    if [ -d "$MOUNT_POINT" ]; then
        log "  ✓ Mount point exists"
    else
        log "  ✗ Mount point missing"
        validation_passed=false
    fi
    
    # Check FUSE configuration
    if [ -f "/etc/fuse.conf" ] && grep -q "user_allow_other" /etc/fuse.conf; then
        log "  ✓ FUSE configured for allow_other"
    elif [ "$ALLOW_OTHER" = "true" ]; then
        log "  ✗ FUSE not configured for allow_other"
        validation_passed=false
    fi
    
    # Check systemd service
    if [ "$ENABLE_SYSTEMD_SERVICE" = "true" ]; then
        if [ -f "/etc/systemd/system/blobfuse2.service" ]; then
            log "  ✓ Systemd service installed"
        else
            log "  ✗ Systemd service missing"
            validation_passed=false
        fi
    fi
    
    if [ "$validation_passed" = true ]; then
        log "Validation completed successfully"
    else
        log "Validation completed with warnings"
    fi
}

# Print usage instructions
print_usage() {
    log ""
    log "=========================================="
    log "Blobfuse2 Installation Complete"
    log "=========================================="
    log ""
    log "Configuration file: $CONFIG_DIR/config.yaml"
    log "Mount point: $MOUNT_POINT"
    log "Cache directory: $CACHE_DIR"
    log ""
    log "To complete setup, configure your storage account in the config file:"
    log "  - Edit $CONFIG_DIR/config.yaml"
    log "  - Set account-name and container under azstorage section"
    log ""
    log "Manual mount command:"
    log "  blobfuse2 mount $MOUNT_POINT --config-file=$CONFIG_DIR/config.yaml"
    log ""
    log "Manual unmount command:"
    log "  fusermount3 -u $MOUNT_POINT"
    log ""
    if [ "$ENABLE_SYSTEMD_SERVICE" = "true" ]; then
        log "Systemd service commands:"
        log "  systemctl enable blobfuse2  # Enable auto-mount on boot"
        log "  systemctl start blobfuse2   # Mount now"
        log "  systemctl stop blobfuse2    # Unmount"
        log "  systemctl status blobfuse2  # Check status"
        log ""
    fi
}

# Main function
main() {
    log "=========================================="
    log "Blobfuse2 Installation Script"
    log "=========================================="
    
    # Ensure running as root
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    detect_os
    load_configuration
    install_blobfuse2
    setup_cache_directory
    setup_mount_point
    create_config_file
    configure_fuse
    create_systemd_service
    validate_installation
    print_usage
    
    log "Blobfuse2 installation and configuration completed successfully"
}

# Run main function
main "$@"
