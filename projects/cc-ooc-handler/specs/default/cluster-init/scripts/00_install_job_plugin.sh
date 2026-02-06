#!/bin/bash
# Slurm job_submit Plugin Installation Script
# This script installs and configures the job_submit Lua plugin for Slurm
# to handle out-of-capacity (OOC) scenarios on CycleCloud clusters
# using load-balanced partition assignment

set -euo pipefail

# Global variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/var/log/cc-ooc-handler-install.log"
SLURM_CONFIG_DIR="/etc/slurm"
SLURM_STATE_DIR="/var/run/slurm"
PLUGIN_SOURCE="job_submit_round_robin.lua"
PLUGIN_DEST="job_submit.lua"

# Source common functions
source "$SCRIPT_DIR/../files/common.sh"

# Check if this is the scheduler node
check_scheduler_node

# Load configuration from environment file if it exists
load_configuration() {
    load_base_configuration "$SCRIPT_DIR"
    
    # Slurm configuration paths
    SLURM_CONFIG_DIR="${SLURM_CONFIG_DIR:-/etc/slurm}"
    SLURM_STATE_DIR="${SLURM_STATE_DIR:-/var/run/slurm}"
    
    log "Configuration loaded:"
    log "  Slurm config dir: $SLURM_CONFIG_DIR"
    log "  Slurm state dir: $SLURM_STATE_DIR"
}

# Create required directories
setup_directories() {
    log "Setting up directories..."
    
    mkdir -p "$SLURM_CONFIG_DIR"
    chmod 755 "$SLURM_CONFIG_DIR"
    
    mkdir -p "$SLURM_STATE_DIR"
    chmod 755 "$SLURM_STATE_DIR"
    chown slurm:slurm "$SLURM_STATE_DIR" 2>/dev/null || true
    
    log "Created directories: $SLURM_CONFIG_DIR, $SLURM_STATE_DIR"
}

# Install the job_submit Lua plugin
install_plugin() {
    log "Installing job_submit Lua plugin..."
    
    local plugin_source="$SCRIPT_DIR/../files/$PLUGIN_SOURCE"
    local plugin_dest="$SLURM_CONFIG_DIR/$PLUGIN_DEST"
    
    if [ -f "$plugin_source" ]; then
        cp "$plugin_source" "$plugin_dest"
        chmod 644 "$plugin_dest"
        log "Installed plugin from $plugin_source to $plugin_dest"
    else
        error_exit "Plugin source file not found at $plugin_source"
    fi
}

# Create the partition configuration file if it doesn't exist
create_partition_config() {
    log "Setting up partition configuration..."
    
    local config_dest="$SLURM_CONFIG_DIR/partition_config.conf"
    local config_source="$SCRIPT_DIR/../files/partition_config.conf"
    
    # If a config file is provided, use it
    if [ -f "$config_source" ]; then
        cp "$config_source" "$config_dest"
        chmod 644 "$config_dest"
        log "Installed partition config from $config_source to $config_dest"
        return 0
    fi
    
    # If config already exists, don't overwrite
    if [ -f "$config_dest" ]; then
        log "Partition configuration already exists at $config_dest"
        return 0
    fi
    
    # Create sample configuration
    cat > "$config_dest" << 'EOF'
# Partition Configuration for Load-Balanced Job Submission
# Format: partition: fallback1,fallback2,fallback3
# 
# When a job is submitted to a partition listed here, the plugin will
# load-balance across the specified fallback partitions based on
# current node allocation.
#
# Example:
# hpc: hpc_eastus,hpc_westus,hpc_northeu
# gpu: gpu_eastus,gpu_westus
#
# Lines starting with # are comments, empty lines are ignored.

EOF

    chmod 644 "$config_dest"
    log "Created sample partition configuration at $config_dest"
    log "Edit this file to define partition mappings for load balancing"
}

# Configure Slurm to use the job_submit plugin
configure_slurm() {
    log "Configuring Slurm to use job_submit plugin..."
    
    local slurm_conf="$SLURM_CONFIG_DIR/slurm.conf"
    local plugin_path="$SLURM_CONFIG_DIR/$PLUGIN_DEST"
    
    if [ ! -f "$slurm_conf" ]; then
        log "WARNING: slurm.conf not found at $slurm_conf"
        log "Manual configuration required. Add to slurm.conf:"
        log "  JobSubmitPlugins=lua"
        return 0
    fi
    
    # Check if JobSubmitPlugins is already configured
    if grep -q "^JobSubmitPlugins=" "$slurm_conf"; then
        local current_plugins
        current_plugins=$(grep "^JobSubmitPlugins=" "$slurm_conf" | cut -d'=' -f2)
        
        if echo "$current_plugins" | grep -q "lua"; then
            log "JobSubmitPlugins already includes 'lua'"
        else
            log "WARNING: JobSubmitPlugins is configured but does not include 'lua'"
            log "Current setting: JobSubmitPlugins=$current_plugins"
            log "Please add 'lua' to the JobSubmitPlugins configuration"
        fi
    else
        log "Adding JobSubmitPlugins=lua to slurm.conf"
        echo "" >> "$slurm_conf"
        echo "# Added by cc-ooc-handler" >> "$slurm_conf"
        echo "JobSubmitPlugins=lua" >> "$slurm_conf"
    fi
    
    log "Slurm configuration updated"
}

# Validate the installation
validate_installation() {
    log "Validating installation..."
    
    local validation_passed=true
    local plugin_path="$SLURM_CONFIG_DIR/$PLUGIN_DEST"
    local config_path="$SLURM_CONFIG_DIR/partition_config.conf"
    
    # Check plugin file
    if [ -f "$plugin_path" ]; then
        log "  ✓ Plugin file exists: $plugin_path"
    else
        log "  ✗ Plugin file missing"
        validation_passed=false
    fi
    
    # Check partition config file
    if [ -f "$config_path" ]; then
        log "  ✓ Partition configuration exists: $config_path"
    else
        log "  ✗ Partition configuration missing"
        validation_passed=false
    fi
    
    # Check state directory
    if [ -d "$SLURM_STATE_DIR" ]; then
        log "  ✓ State directory exists: $SLURM_STATE_DIR"
    else
        log "  ✗ State directory missing"
        validation_passed=false
    fi
    
    # Check slurm.conf for JobSubmitPlugins
    if [ -f "$SLURM_CONFIG_DIR/slurm.conf" ]; then
        if grep -q "JobSubmitPlugins=.*lua" "$SLURM_CONFIG_DIR/slurm.conf"; then
            log "  ✓ Slurm configured to use lua plugin"
        else
            log "  ✗ Slurm not configured for lua plugin"
            validation_passed=false
        fi
    else
        log "  - slurm.conf not found, skipping configuration check"
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
    log "OOC Handler Installation Complete"
    log "=========================================="
    log ""
    log "Plugin location: $SLURM_CONFIG_DIR/$PLUGIN_DEST"
    log "Partition config: $SLURM_CONFIG_DIR/partition_config.conf"
    log "State directory: $SLURM_STATE_DIR"
    log ""
    log "To configure partition load balancing, edit:"
    log "  $SLURM_CONFIG_DIR/partition_config.conf"
    log ""
    log "To apply changes, restart slurmctld:"
    log "  systemctl restart slurmctld"
    log ""
    log "To verify the plugin is loaded:"
    log "  scontrol show config | grep JobSubmitPlugins"
    log ""
}

# Main function
main() {
    log "=========================================="
    log "OOC Handler Installation Script"
    log "=========================================="
    
    # Ensure running as root
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
    
    load_configuration
    setup_directories
    install_plugin
    create_partition_config
    configure_slurm
    validate_installation
    print_usage
    
    log "OOC Handler installation completed successfully"
}

# Run main function
main "$@"
