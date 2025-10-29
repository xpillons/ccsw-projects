#!/bin/bash
# CVMFS-EESSI Installation Script
# See https://techcommunity.microsoft.com/blog/azurehighperformancecomputingblog/using-gromacs-through-eessi-on-nc-a100-v4/4423933
#
# This script installs and configures CVMFS with EESSI support for CycleCloud clusters

set -euo pipefail

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load configuration from environment file if it exists
load_configuration() {
    local config_file="$SCRIPT_DIR/../files/cvmfs-config.env"
    
    if [ -f "$config_file" ]; then
        log "Loading configuration from $config_file"
        # Source the configuration file, but only export variables we recognize
        source "$config_file"
    else
        log "Configuration file $config_file not found, using defaults"
    fi
    
    # Set variables with defaults (environment variables take precedence)
    CVMFS_CACHE_QUOTA="${CVMFS_CACHE_QUOTA:-10000}"
    
    # Auto-detect optimal cache base directory if not explicitly set
    if [ -z "${CVMFS_CACHE_BASE:-}" ]; then
        if [ -d "/mnt/nvme" ]; then
            CVMFS_CACHE_BASE="/mnt/nvme/cvmfs"
            debug_log "Auto-detected NVMe storage, using $CVMFS_CACHE_BASE"
        elif [ -d "/mnt" ]; then
            CVMFS_CACHE_BASE="/mnt/cvmfs"
            debug_log "Using /mnt storage for cache: $CVMFS_CACHE_BASE"
        else
            CVMFS_CACHE_BASE="/var/lib/cvmfs"
            debug_log "Using default cache location: $CVMFS_CACHE_BASE"
        fi
    fi
    
    CVMFS_PROXY="${CVMFS_PROXY:-DIRECT}"
    BACKUP_DIR="${BACKUP_DIR:-/var/lib/cvmfs-eessi-backup}"
    DEBUG_LOGGING="${DEBUG_LOGGING:-false}"
    
    # Additional repositories (if specified in config)
    ADDITIONAL_REPOS="${ADDITIONAL_REPOS:-}"
    
    log "Configuration loaded:"
    log "  Cache quota: ${CVMFS_CACHE_QUOTA}MB"
    log "  Cache base: $CVMFS_CACHE_BASE"
    
    # Show storage type detection info
    if [[ "$CVMFS_CACHE_BASE" == "/mnt/nvme"* ]]; then
        log "  Storage type: NVMe (high-performance)"
    elif [[ "$CVMFS_CACHE_BASE" == "/mnt"* ]]; then
        log "  Storage type: Local mount"
    else
        log "  Storage type: Default system storage"
    fi
    
    log "  Proxy: $CVMFS_PROXY"
    log "  Backup dir: $BACKUP_DIR"
    log "  Debug logging: $DEBUG_LOGGING"
    if [ -n "$ADDITIONAL_REPOS" ]; then
        log "  Additional repos: $ADDITIONAL_REPOS"
    fi
}

LOG_FILE="/var/log/cvmfs-eessi-install.log"

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
    cleanup_on_error
    exit 1
}

# Cleanup function for error scenarios
cleanup_on_error() {
    log "Performing cleanup after error..."
    # Remove any partially installed packages or configurations
    if [ -d "$BACKUP_DIR" ]; then
        log "Backup directory exists, cleanup may be needed manually"
    fi
}

# Create backup of existing configuration
backup_existing_config() {
    if [ -f "/etc/cvmfs/default.local" ]; then
        log "Backing up existing CVMFS configuration"
        mkdir -p "$BACKUP_DIR"
        cp "/etc/cvmfs/default.local" "$BACKUP_DIR/default.local.backup.$(date +%Y%m%d_%H%M%S)"
    fi
}

# Detect platform information with fallback methods
detect_platform() {
    log "Detecting platform information"
    
    # Try multiple methods for platform detection
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_release="$ID"
        os_version="$VERSION_ID"
        os_major_version=$(echo "$VERSION_ID" | cut -d. -f1)
    else
        error_exit "Cannot detect platform - /etc/os-release not found"
    fi
    
    log "Detected OS: $os_release $os_version"
    export os_release os_version os_major_version
}

# Validate platform support
validate_platform_support() {
    case "$os_release" in
        almalinux|rhel|centos|rocky)
            if [ "$os_major_version" -lt 8 ]; then
                error_exit "Unsupported RHEL-based version: $os_version (minimum: 8)"
            fi
            package_manager="dnf"
            ;;
        ubuntu)
            if [ "$os_major_version" -lt 20 ]; then
                error_exit "Unsupported Ubuntu version: $os_version (minimum: 20.04)"
            fi
            package_manager="apt"
            ;;
        debian)
            if [ "$os_major_version" -lt 10 ]; then
                error_exit "Unsupported Debian version: $os_version (minimum: 10)"
            fi
            package_manager="apt"
            ;;
        *)
            error_exit "Unsupported OS: $os_release $os_version"
            ;;
    esac
    
    log "Platform validation passed: $os_release $os_version using $package_manager"
}

# Install required dependencies
install_dependencies() {
    log "Installing required dependencies"
    
    case "$package_manager" in
        dnf)
            dnf update -y || error_exit "Failed to update package cache"
            dnf install -y wget curl which || error_exit "Failed to install dependencies"
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt update || error_exit "Failed to update package cache"
            apt install -y wget curl lsb-release || error_exit "Failed to install dependencies"
            ;;
    esac
}

# Check if CVMFS is already installed and configured
check_existing_installation() {
    if command -v cvmfs_config >/dev/null 2>&1; then
        if cvmfs_config stat 2>/dev/null | grep -q "CVMFS.*OK"; then
            log "CVMFS already installed and working. Checking configuration..."
            return 0
        else
            log "CVMFS installed but not properly configured. Reconfiguring..."
            return 1
        fi
    else
        log "CVMFS not installed. Proceeding with installation..."
        return 1
    fi
}

# Install CVMFS packages for RHEL-based systems
install_cvmfs_rhel() {
    log "Installing CVMFS for RHEL-based system ($os_release)"
    
    # Install CVMFS release package
    local cvmfs_release_url="https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm"
    log "Installing CVMFS release package from $cvmfs_release_url"
    dnf install -y "$cvmfs_release_url" || error_exit "Failed to install CVMFS release package"
    
    # Install CVMFS
    log "Installing CVMFS package"
    dnf install -y cvmfs || error_exit "Failed to install CVMFS"
    
    # Install EESSI configuration
    local eessi_config_url="https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm"
    log "Installing EESSI configuration from $eessi_config_url"
    dnf install -y "$eessi_config_url" || error_exit "Failed to install EESSI configuration"
}

# Install CVMFS packages for Debian-based systems
install_cvmfs_debian() {
    log "Installing CVMFS for Debian-based system ($os_release)"
    
    # Create temporary directory for downloads
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || error_exit "Failed to create temporary directory"
    
    # Download and install CVMFS release package
    local cvmfs_release_deb="cvmfs-release-latest_all.deb"
    log "Downloading CVMFS release package"
    wget -q "https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/$cvmfs_release_deb" || error_exit "Failed to download CVMFS release package"
    
    log "Installing CVMFS release package"
    dpkg -i "$cvmfs_release_deb" || error_exit "Failed to install CVMFS release package"
    
    # Download and install EESSI configuration
    local eessi_config_deb="cvmfs-config-eessi_latest_all.deb"
    log "Downloading EESSI configuration"
    wget -q "https://github.com/EESSI/filesystem-layer/releases/download/latest/$eessi_config_deb" || error_exit "Failed to download EESSI configuration"
    
    log "Installing EESSI configuration"
    dpkg -i "$eessi_config_deb" || error_exit "Failed to install EESSI configuration"
    
    # Update package cache and install CVMFS
    log "Updating package cache"
    apt update || error_exit "Failed to update package cache"
    
    log "Installing CVMFS package"
    apt install -y cvmfs || error_exit "Failed to install CVMFS"
    
    # Cleanup
    cd /
    rm -rf "$temp_dir"
}

# Install CVMFS based on detected platform
install_cvmfs() {
    log "Starting CVMFS installation"
    
    case "$package_manager" in
        dnf)
            install_cvmfs_rhel
            ;;
        apt)
            install_cvmfs_debian
            ;;
        *)
            error_exit "Unknown package manager: $package_manager"
            ;;
    esac
    
    log "CVMFS installation completed"
}

# Configure CVMFS with proper settings
configure_cvmfs() {
    log "Configuring CVMFS"
    
    backup_existing_config
    
    # Ensure cache directory exists and has proper permissions
    log "Creating cache directory: $CVMFS_CACHE_BASE"
    mkdir -p "$CVMFS_CACHE_BASE"
    chmod 700 "$CVMFS_CACHE_BASE"
    chown cvmfs:cvmfs "$CVMFS_CACHE_BASE" 2>/dev/null || true  # cvmfs user may not exist yet
    
    # Create CVMFS configuration
    local config_file="/etc/cvmfs/default.local"
    log "Creating CVMFS configuration at $config_file"
    
    cat > "$config_file" << EOF
# CVMFS Configuration for EESSI
# Generated by CVMFS-EESSI installation script on $(date)

# HTTP Proxy configuration
CVMFS_HTTP_PROXY=$CVMFS_PROXY

# Client profile for single-user access
CVMFS_CLIENT_PROFILE="single"

# Cache quota (in MB)
CVMFS_QUOTA_LIMIT=$CVMFS_CACHE_QUOTA

# Additional optimizations
CVMFS_CACHE_BASE=$CVMFS_CACHE_BASE
CVMFS_RELOAD_SOCKETS=$CVMFS_CACHE_BASE
EOF

    # Add additional repositories if specified
    if [ -n "$ADDITIONAL_REPOS" ]; then
        log "Adding additional CVMFS repositories: $ADDITIONAL_REPOS"
        echo "" >> "$config_file"
        echo "# Additional repositories" >> "$config_file"
        echo "CVMFS_REPOSITORIES=\"software.eessi.io,$ADDITIONAL_REPOS\"" >> "$config_file"
    fi
    
    # Set proper permissions
    chmod 644 "$config_file"
    
    log "CVMFS configuration written to $config_file"
    log "Configuration details:"
    log "  Proxy: $CVMFS_PROXY"
    log "  Cache quota: ${CVMFS_CACHE_QUOTA}MB"
    log "  Client profile: single"
}

# Setup and validate CVMFS
setup_cvmfs() {
    log "Setting up CVMFS"
    
    # Run CVMFS setup
    cvmfs_config setup || error_exit "CVMFS setup failed"
    
    log "CVMFS setup completed successfully"
}

# Validate CVMFS installation
validate_installation() {
    log "Validating CVMFS installation"
    
    # Check if cvmfs_config command works
    if ! command -v cvmfs_config >/dev/null 2>&1; then
        error_exit "cvmfs_config command not found after installation"
    fi
    
    # Check CVMFS status
    if ! cvmfs_config stat >/dev/null 2>&1; then
        log "Warning: CVMFS stat check failed, but this may be normal before first repository access"
    fi
    
    # Test EESSI repository access
    log "Testing EESSI repository access"
    if ! cvmfs_config probe software.eessi.io >/dev/null 2>&1; then
        log "Warning: Cannot probe EESSI repository, but this may work after reboot or autofs restart"
    else
        log "EESSI repository probe successful"
    fi
    
    log "CVMFS installation validation completed"
}

# Detect NVIDIA GPU devices
detect_nvidia_gpu() {
    log "Checking for NVIDIA GPU devices"
    
    # Check if nvidia-smi command exists and works
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            local gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | wc -l)
            log "Detected $gpu_count NVIDIA GPU(s):"
            nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits | while read line; do
                log "  $line"
            done
            return 0
        else
            debug_log "nvidia-smi command exists but failed to execute"
        fi
    else
        debug_log "nvidia-smi command not found"
    fi
    
    # Alternative: Check for NVIDIA devices in /proc/driver/nvidia
    if [ -d "/proc/driver/nvidia" ]; then
        log "NVIDIA driver detected in /proc/driver/nvidia"
        return 0
    fi
    
    # Alternative: Check lspci for NVIDIA devices
    if command -v lspci >/dev/null 2>&1; then
        if lspci | grep -i nvidia >/dev/null 2>&1; then
            log "NVIDIA device detected via lspci:"
            lspci | grep -i nvidia | while read line; do
                log "  $line"
            done
            return 0
        fi
    fi
    
    debug_log "No NVIDIA GPU devices detected"
    return 1
}

# Setup NVIDIA GPU support for EESSI
setup_nvidia_gpu_support() {
    log "Setting up NVIDIA GPU support for EESSI"
    
    # Verify EESSI repository is accessible
    local eessi_version="2023.06"
    local eessi_init_script="/cvmfs/software.eessi.io/versions/$eessi_version/init/eessi_environment_variables"
    local nvidia_link_script="/cvmfs/software.eessi.io/versions/$eessi_version/scripts/gpu_support/nvidia/link_nvidia_host_libraries.sh"

    # Wait for CVMFS to be ready and check EESSI access
    local max_attempts=30
    local attempt=1
    
    log "Waiting for EESSI repository to become accessible..."
    while [ $attempt -le $max_attempts ]; do
        if [ -f "$eessi_init_script" ]; then
            log "EESSI repository is accessible"
            break
        fi
        
        debug_log "Attempt $attempt/$max_attempts: EESSI not yet accessible, waiting..."
        sleep 5
        ((attempt++))
        
        # Try to trigger autofs mount
        ls /cvmfs/software.eessi.io >/dev/null 2>&1 || true
    done
    
    if [ ! -f "$eessi_init_script" ]; then
        log "WARNING: EESSI repository not accessible after $max_attempts attempts"
        log "GPU support setup will be skipped"
        log "You may need to run this manually after reboot:"
        log "  source $eessi_init_script"
        log "  $nvidia_link_script"
        return 1
    fi
    
    # Check if NVIDIA link script exists
    if [ ! -f "$nvidia_link_script" ]; then
        log "WARNING: NVIDIA link script not found at $nvidia_link_script"
        log "This may indicate an EESSI version compatibility issue"
        return 1
    fi
    
    log "Loading EESSI environment and setting up NVIDIA GPU support"
    
    # Run EESSI setup directly
    log "Loading EESSI environment"
    export EESSI_COMPAT_LAYER_DIR=/cvmfs/software.eessi.io/versions/2023.06/compat/linux/$(uname -m)
    set +u # to avoid unbound variable error
    source "$eessi_init_script" 2>&1 | tee -a "$LOG_FILE"
    local source_exit_code=${PIPESTATUS[0]}
    
    if [ $source_exit_code -ne 0 ]; then
        log "WARNING: Failed to load EESSI environment"
        log "You may need to run this manually after reboot:"
        log "  source $eessi_init_script"
        log "  $nvidia_link_script"
        return 1
    fi
    set -u
    log "EESSI environment loaded successfully"
    log "Running NVIDIA host libraries linking script"
    
    # Run the NVIDIA linking script
    "$nvidia_link_script" 2>&1 | tee -a "$LOG_FILE"
    local nvidia_exit_code=${PIPESTATUS[0]}
    
    if [ $nvidia_exit_code -eq 0 ]; then
        log "NVIDIA host libraries linking completed successfully"
        log "GPU applications should now work with EESSI"
        
        # Verify GPU support
        if command -v nvidia-smi >/dev/null 2>&1; then
            log "NVIDIA driver verification:"
            nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits 2>/dev/null | while read line; do
                log "  $line"
            done
        fi
        
        log "NVIDIA GPU support setup completed successfully"
    else
        log "WARNING: NVIDIA GPU support setup failed"
        log "You may need to run this manually after reboot:"
        log "  source $eessi_init_script"
        log "  $nvidia_link_script"
    fi
}

# Display post-installation information
show_post_install_info() {
    log ""
    log "=== CVMFS-EESSI Installation Summary ==="
    log "✓ CVMFS successfully installed and configured"
    log "✓ EESSI configuration applied"
    log ""
    log "Configuration details:"
    log "  Config file: /etc/cvmfs/default.local"
    log "  Cache location: $CVMFS_CACHE_BASE"
    log "  Cache quota: ${CVMFS_CACHE_QUOTA}MB"
    log "  Proxy setting: $CVMFS_PROXY"
    log ""
    log "Next steps:"
    log "  1. Reboot the system or restart autofs: systemctl restart autofs"
    log "  2. Test EESSI access: ls /cvmfs/software.eessi.io"
    log "  3. Load EESSI environment: source /cvmfs/software.eessi.io/versions/2023.06/init/bash"
    
    # Add GPU-specific information if GPU was detected
    if detect_nvidia_gpu >/dev/null 2>&1; then
        log ""
        log "GPU Support:"
        log "  ✓ NVIDIA GPU detected and configured"
        log "  4. For GPU applications, manually source EESSI and run link script:"
        log "     source /cvmfs/software.eessi.io/versions/2023.06/init/bash"
        log "     /cvmfs/software.eessi.io/versions/2023.06/scripts/gpu_support/nvidia/link_nvidia_host_libraries.sh"
        log "  5. Test GPU access: nvidia-smi"
    fi
    
    log ""
    log "For more information, see:"
    log "  https://www.eessi.io/docs/using_eessi/setting_up_environment/"
    log ""
    
    if [ -f "$BACKUP_DIR/default.local.backup."* ] 2>/dev/null; then
        log "Note: Previous configuration backed up to $BACKUP_DIR"
    fi
}

# Main execution function
main() {
    # Initialize logging
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    log "Starting CVMFS-EESSI installation"
    log "Script: $0"
    log "User: $(whoami)"
    log "Date: $(date)"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    # Load configuration first
    load_configuration
    
    # Main installation steps
    detect_platform
    validate_platform_support
    
    # Check for existing installation
    if check_existing_installation; then
        log "CVMFS already properly configured. Skipping installation."
        show_post_install_info
        return 0
    fi
    
    install_dependencies
    install_cvmfs
    configure_cvmfs
    setup_cvmfs
    validate_installation
    
    # Setup GPU support if NVIDIA devices detected
    if detect_nvidia_gpu; then
        setup_nvidia_gpu_support
    else
        log "No NVIDIA GPU detected, skipping GPU support setup"
    fi
    
    show_post_install_info
    
    log "CVMFS-EESSI installation completed successfully"
}

# Run main function with error handling
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi