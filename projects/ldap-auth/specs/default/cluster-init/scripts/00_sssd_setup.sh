#!/bin/bash
set -e

# Global variables
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Logging function to prefix messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Parse command line arguments
PASSWORD_UPDATE_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --password-update-only)
            PASSWORD_UPDATE_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--password-update-only]"
            echo "  --password-update-only: Only check for password updates and update SSSD config if needed"
            exit 1
            ;;
    esac
done

# Initialize environment and paths
initialize_environment() {
    # if CYCLECLOUD_SPEC_PATH is not set use the script directory as the base path
    if [ -z "$CYCLECLOUD_SPEC_PATH" ]; then
        export CYCLECLOUD_SPEC_PATH="$script_dir/.."
    fi
    
    CONFIG_FILE="$CYCLECLOUD_SPEC_PATH/files/ldap-config.json"
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Error: Configuration file $CONFIG_FILE not found"
        exit 1
    fi
    
    # allow access to ldap-config.json only to root and cyclecloud user
    chown root:cyclecloud "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
}

# Detect platform information
detect_platform() {
    # Try to use jetpack if available, otherwise fall back to OS detection
    if command -v jetpack >/dev/null 2>&1; then
        platform_family=$(jetpack config platform_family 2>/dev/null)
        platform=$(jetpack config platform 2>/dev/null)
        platform_version=$(jetpack config platform_version 2>/dev/null)
    fi
    
    # Fallback platform detection if jetpack is not available (e.g., when running in cron)
    if [ -z "$platform_family" ] || [ -z "$platform" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu)
                    platform="ubuntu"
                    platform_family="debian"
                    platform_version="$VERSION_ID"
                    ;;
                debian)
                    platform="debian" 
                    platform_family="debian"
                    platform_version="$VERSION_ID"
                    ;;
                rhel|redhat)
                    platform="redhat"
                    platform_family="rhel"
                    platform_version="$VERSION_ID"
                    ;;
                almalinux)
                    platform="almalinux"
                    platform_family="rhel"
                    platform_version="$VERSION_ID"
                    ;;
                centos)
                    platform="centos"
                    platform_family="rhel"
                    platform_version="$VERSION_ID"
                    ;;
                *)
                    log "Warning: Unknown platform ID: $ID, attempting to detect family"
                    if [ -f /etc/debian_version ]; then
                        platform_family="debian"
                        platform="debian"
                    elif [ -f /etc/redhat-release ]; then
                        platform_family="rhel"
                        platform="redhat"
                    else
                        log "Error: Unable to detect platform"
                        exit 1
                    fi
                    ;;
            esac
        else
            log "Error: Cannot detect platform - /etc/os-release not found"
            exit 1
        fi
    fi
    
    export platform_family platform platform_version
    log "Detected platform: $platform (family: $platform_family, version: $platform_version)"
}

# Install required packages based on platform
install_dependencies() {
    # Only detect platform if not already detected
    if [ -z "$platform_family" ] || [ -z "$platform" ]; then
        detect_platform
    fi
    
    # Check if jq is installed, install it if not
    if ! command -v jq &> /dev/null; then
        log "jq not found, installing..."
        
        if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
            DEBIAN_FRONTEND=noninteractive apt update && apt install -y jq
        elif [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform" == "centos" ] || [ "$platform_family" == "rhel" ]; then 
            yum install -y jq
        else
            log "Error: Unsupported platform for dependency installation: $platform"
            exit 1
        fi
    fi
}

# Load configuration from JSON file
load_configuration() {
    log "Loading configuration from $CONFIG_FILE"
    
    # Parse JSON configuration
    USE_KEYVAULT=$(jq -r '.useKeyvault' "$CONFIG_FILE")
    CLIENT_ID=$(jq -r '.clientId' "$CONFIG_FILE")
    KEYVAULT_NAME=$(jq -r '.keyvaultName' "$CONFIG_FILE")
    KEYVAULT_SECRET_NAME=$(jq -r '.keyvaultSecretName' "$CONFIG_FILE")
    CACHE_Credentials=$(jq -r '.cacheCredentials' "$CONFIG_FILE")
    LDAP_URI=$(jq -r '.ldapUri' "$CONFIG_FILE")
    LDAP_search_base=$(jq -r '.ldapSearchBase' "$CONFIG_FILE")
    LDAP_Schema=$(jq -r '.ldapSchema' "$CONFIG_FILE")
    LDAP_default_bind_dn=$(jq -r '.ldapDefaultBindDn' "$CONFIG_FILE")
    BIND_DN_PASSWORD=$(jq -r '.bindDnPassword' "$CONFIG_FILE")
    TLS_reqcert=$(jq -r '.tlsReqcert' "$CONFIG_FILE")
    ID_mapping=$(jq -r '.idMapping' "$CONFIG_FILE")
    HPC_ADMIN_GROUP=$(jq -r '.hpcAdminGroup' "$CONFIG_FILE")
    ENUMERATE=$(jq -r '.enumerate' "$CONFIG_FILE")
    HOME_DIR=$(jq -r '.homeDir' "$CONFIG_FILE")
    HOME_DIR_TOP=$(echo "$HOME_DIR" | awk -F/ '{print FS $2}')
    SETUP_CRON=$(jq -r '.setupCron' "$CONFIG_FILE")
    
    # Export variables for use in other functions
    export USE_KEYVAULT CLIENT_ID KEYVAULT_NAME KEYVAULT_SECRET_NAME CACHE_Credentials
    export LDAP_URI LDAP_search_base LDAP_Schema LDAP_default_bind_dn BIND_DN_PASSWORD
    export TLS_reqcert ID_mapping HPC_ADMIN_GROUP ENUMERATE HOME_DIR HOME_DIR_TOP SETUP_CRON
}

# Handle Azure Key Vault authentication and secret retrieval
handle_keyvault_auth() {
    SSSD_CONFIG_NEEDS_UPDATE=false
    
    if [ "${USE_KEYVAULT,,}" == "true" ]; then
        log "Using Azure Key Vault for password retrieval"
        
        # Define marker file path
        MARKER_FILE="/var/lib/ldap-auth/${KEYVAULT_SECRET_NAME}_last_updated.txt"
        mkdir -p "$(dirname "$MARKER_FILE")"
        
        # Install Azure CLI using the script install-azcli.sh if not already installed
        if ! command -v az &> /dev/null; then
            log "Azure CLI not found, installing..."
            chmod +x "$CYCLECLOUD_SPEC_PATH/files/install-azcli.sh"
            bash "$CYCLECLOUD_SPEC_PATH/files/install-azcli.sh"
        fi
        
        # Logon using the VM identity
        log "Logging in to Azure using managed identity with client ID $CLIENT_ID"
        az login --identity --client-id "$CLIENT_ID" >/dev/null 2>&1 || (log "Error: az login failed"; exit 1)
        
        log "Retrieving LDAP bind password from Keyvault"
        SECRET_JSON=$(az keyvault secret show --name "$KEYVAULT_SECRET_NAME" --vault-name "$KEYVAULT_NAME" -o json)
        BIND_DN_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.value')
        SECRET_UPDATED=$(echo "$SECRET_JSON" | jq -r '.attributes.updated')
        
        if [ -z "$BIND_DN_PASSWORD" ] || [ "$BIND_DN_PASSWORD" == "null" ]; then
            log "Error: Unable to retrieve LDAP bind password from Keyvault"
            exit 1
        fi

        # Check if secret has been updated since last run
        if [ -f "$MARKER_FILE" ]; then
            LAST_SECRET_UPDATED=$(cat "$MARKER_FILE" 2>/dev/null || echo "0")
            if [ "$SECRET_UPDATED" != "$LAST_SECRET_UPDATED" ]; then
                log "Secret has been updated since last run (was: $LAST_SECRET_UPDATED, now: $SECRET_UPDATED)"
                SSSD_CONFIG_NEEDS_UPDATE=true
            else
                log "Secret unchanged since last run (updated: $SECRET_UPDATED)"
                SSSD_CONFIG_NEEDS_UPDATE=false
            fi
        else
            log "First time retrieving secret from KeyVault"
            SSSD_CONFIG_NEEDS_UPDATE=true
        fi
        
        # Save current secret updated timestamp to marker file
        echo "$SECRET_UPDATED" > "$MARKER_FILE"
        chmod 600 "$MARKER_FILE"
        
        log "Secret last updated: $(date -d @$SECRET_UPDATED 2>/dev/null || date -r $SECRET_UPDATED 2>/dev/null || echo $SECRET_UPDATED)"
        export BIND_DN_PASSWORD
    else
        log "Do not use KeyVault, using password from parameter file"
        # When not using KeyVault, check if sssd.conf exists to determine if update is needed
        if [ ! -f "/etc/sssd/sssd.conf" ]; then
            SSSD_CONFIG_NEEDS_UPDATE=true
        fi
    fi
    
    export SSSD_CONFIG_NEEDS_UPDATE
}

# Configure SSH settings
configure_ssh() {
    log "Configuring SSH settings"
    
    # Disable SSH password authentication
    sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config

    # Disable SSH host key checking because the underlying server may change but the IP remains the same.
    cat <<EOF >/etc/ssh/ssh_config
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
}

# Install SSSD packages based on platform
install_sssd_packages() {
    # Only detect platform if not already detected
    if [ -z "$platform_family" ] || [ -z "$platform" ]; then
        detect_platform
    fi
    
    log "Installing SSSD packages for platform: $platform"
    
    #supported platforms RHEL 8/9, AlmaLinux 8/9, Ubuntu 20/22
    # If statements check explicitly for supported OS then checks for the general "platform_family" to try and support any derivative OS of Debian/Rhel
    if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
        DEBIAN_FRONTEND=noninteractive apt install -y sssd sssd-tools sssd-ldap ldap-utils
        TLS_CERT_Location="/etc/ssl/certs/ca-certificates.crt"
    elif [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform" == "centos" ] || [ "$platform_family" == "rhel" ]; then 
        if [ "$platform" == "almalinux" ]; then
            yum install epel-release -y
        fi
        yum install -y sssd sssd-tools sssd-ldap openldap-clients oddjob-mkhomedir
        TLS_CERT_Location="/etc/pki/tls/certs/ca-bundle.crt"
    else
        log "Unsupported platform: $platform"
        exit 1
    fi
    
    export TLS_CERT_Location
}

# Configure SSSD configuration file
configure_sssd() {
    if [ "$SSSD_CONFIG_NEEDS_UPDATE" = "true" ]; then
        log "Configuring SSSD (configuration update needed)"
        
        # Copy template file
        cp -f "$CYCLECLOUD_SPEC_PATH"/files/sssd.conf /etc/sssd/sssd.conf
        
        # Replace values in template file from environment variables
        sed -i "s#LDAP_URI#$LDAP_URI#g" /etc/sssd/sssd.conf
        sed -i "s#CACHE_Credentials#$CACHE_Credentials#g" /etc/sssd/sssd.conf
        sed -i "s#LDAP_Schema#$LDAP_Schema#g" /etc/sssd/sssd.conf
        sed -i "s#LDAP_search_base#$LDAP_search_base#g" /etc/sssd/sssd.conf
        sed -i "s#LDAP_default_bind_dn#$LDAP_default_bind_dn#g" /etc/sssd/sssd.conf
        sed -i "s#TLS_reqcert#$TLS_reqcert#g" /etc/sssd/sssd.conf
        sed -i "s#ID_mapping#$ID_mapping#g" /etc/sssd/sssd.conf
        sed -i "s#ENUMERATE#$ENUMERATE#g" /etc/sssd/sssd.conf
        sed -i "s#TLS_CERT_Location#$TLS_CERT_Location#g" /etc/sssd/sssd.conf
        sed -i "s#HOME_DIR#$HOME_DIR#g" /etc/sssd/sssd.conf

        # Obfuscate the bind DN password
        echo -n "$BIND_DN_PASSWORD" | sss_obfuscate --domain default -s

        # Set proper permissions
        chmod 600 /etc/sssd/sssd.conf
        chown root:root /etc/sssd/sssd.conf
        
        log "SSSD configuration updated successfully"
    else
        log "SSSD configuration update skipped - no changes needed"
    fi
}

# Password-only update function for Key Vault password changes
update_sssd_password_only() {
    log "Password-only update mode: Checking for Key Vault password changes"
    
    if [ "${USE_KEYVAULT,,}" != "true" ]; then
        log "Error: Password-only update mode requires Key Vault to be enabled"
        exit 1
    fi
    
    if [ ! -f "/etc/sssd/sssd.conf" ]; then
        log "Error: SSSD configuration file not found. Run full setup first."
        exit 1
    fi
    
    if [ "$SSSD_CONFIG_NEEDS_UPDATE" = "true" ]; then
        log "Password update detected, updating SSSD configuration"
        
        # Read the current SSSD config to preserve other settings
        # Only update the obfuscated password in the existing config
        echo -n "$BIND_DN_PASSWORD" | sss_obfuscate --domain default -s
        
        log "SSSD password updated successfully"
        
        # Restart SSSD service
        log "Restarting SSSD service due to password change"
        systemctl restart sssd.service
        
        log "Password update completed successfully"
    else
        log "No password update needed - secret unchanged"
    fi
}

# Set up cron job for password rotation checks
setup_password_rotation_cron() {
    log "Setting up cron job for password rotation checks"
    
    # Get the absolute path to the script
    SCRIPT_PATH="$(readlink -f "$script_dir/00_sssd_setup.sh")"
    LOG_FILE="/var/log/ldap-password-rotation.log"
    # Set a proper PATH for cron execution to ensure system commands are found
    CRON_JOB="*/5 * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $SCRIPT_PATH --password-update-only >> $LOG_FILE 2>&1"
    
    log "Script path: $SCRIPT_PATH"
    
    # Ensure the marker directory exists
    mkdir -p /var/lib/ldap-auth
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --password-update-only"; then
        log "Cron job for password rotation already exists"
        return 0
    fi
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # Get current crontab and add new job
    current_crontab=$(crontab -l 2>/dev/null || echo "")
    if [ -n "$current_crontab" ]; then
        echo "$current_crontab" | crontab -
        echo "$CRON_JOB" | crontab -
    else
        echo "$CRON_JOB" | crontab -
    fi
    
    # Verify the cron job was added
    log "Verifying cron job installation..."
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --password-update-only"; then
        log "✓ Cron job added successfully:"
        log "  Schedule: Every 5 minutes"
        log "  Command: $SCRIPT_PATH --password-update-only"
        log "  Log file: $LOG_FILE"
        log "  PATH: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        
        # Show current crontab for verification
        log ""
        log "Current crontab entries:"
        crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || log "  (no entries found)"
    else
        log "✗ Failed to add cron job. Please check manually with 'crontab -l'"
        return 1
    fi
    
    # Ensure cron service is running
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
        log "✓ Cron service is running"
    fi
}

# Configure PAM and home directory creation
configure_pam_and_homedir() {
    log "Configuring PAM and home directory creation"
    
    if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
        mkdir -p "$HOME_DIR"
        DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir
    elif [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform_family" == "rhel" ]; then 
        mkdir -p "$HOME_DIR"
        setsebool -P use_nfs_home_dirs 1
        semanage fcontext -a -e /home "$HOME_DIR" || true
        semanage fcontext -a -e /home "$HOME_DIR_TOP" || true
        # sets the selinux file context to match the /home folder. 
        #If the $HOME_DIR already exists and has already had the contexts set eg by cyclecloud this command fails. Pipeing the command to true ensure this does not throw an error in the CC GUI.
        # If context does not exist it gets created, if context does exit the script carrys on.
        restorecon -Rv "$HOME_DIR"
        restorecon -Rv "$HOME_DIR_TOP"
        systemctl enable --now oddjobd.service
        authselect select sssd with-mkhomedir --force
    fi
}

# Configure sudo access for LDAP admin group
configure_sudo_access() {
    log "Configuring sudo access for LDAP admin group: $HPC_ADMIN_GROUP"
    echo "\"%$HPC_ADMIN_GROUP\" ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/hpc_admins
}

# Start and enable SSSD service
start_sssd_service() {
    log "Managing SSSD service"
    
    # Always ensure the service is started
    if ! systemctl is-active --quiet sssd.service; then
        log "Starting SSSD service"
        systemctl start sssd.service
    fi
    
    # Only restart if configuration was updated
    if [ "$SSSD_CONFIG_NEEDS_UPDATE" = "true" ]; then
        log "Restarting SSSD service due to configuration changes"
        systemctl restart sssd.service
    else
        log "SSSD service restart skipped - no configuration changes detected"
    fi
}

# Main function to orchestrate the setup
main() {
    if [ "$PASSWORD_UPDATE_ONLY" = "true" ]; then
        log "Starting LDAP password-only update"
        
        initialize_environment
        install_dependencies
        load_configuration
        handle_keyvault_auth
        update_sssd_password_only
        
        log "LDAP password update completed successfully"
    else
        log "Starting LDAP authentication setup"
        
        initialize_environment
        install_dependencies
        load_configuration
        handle_keyvault_auth
        configure_ssh
        install_sssd_packages
        configure_sssd
        configure_pam_and_homedir
        configure_sudo_access
        start_sssd_service
        
        # Set up cron job if enabled in configuration and using Key Vault
        if [ "${SETUP_CRON,,}" = "true" ] && [ "${USE_KEYVAULT,,}" = "true" ]; then
            log ""
            log "Setting up password rotation cron job..."
            setup_password_rotation_cron
        elif [ "${SETUP_CRON,,}" = "true" ] && [ "${USE_KEYVAULT,,}" != "true" ]; then
            log ""
            log "Warning: Cron setup is enabled but Key Vault is not configured. Skipping cron setup."
        fi
        
        log "LDAP authentication setup completed successfully"
    fi
}

# Run main function
main "$@"
