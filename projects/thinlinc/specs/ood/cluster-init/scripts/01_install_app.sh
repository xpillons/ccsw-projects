#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../default/files/common.sh"

OOD_APPS_DIR="/var/www/ood/apps/sys"
APP_NAME="ood-thinlinc"
APP_DIR="$OOD_APPS_DIR/$APP_NAME"
REPO_URL="https://github.com/cendio/ood-thinlinc.git"

# Install git if missing
install_git() {
    if command -v git &>/dev/null; then
        log "git is already installed"
        return 0
    fi

    log "git not found, installing..."
    local os_id
    os_id=$(source /etc/os-release && echo "$ID")
    case "$os_id" in
        almalinux|rhel|centos|rocky|fedora)
            dnf install -y git || error_exit "Failed to install git"
            ;;
        ubuntu|debian)
            apt-get update && apt-get install -y git || error_exit "Failed to install git"
            ;;
        *)
            error_exit "Unsupported OS for git installation: $os_id"
            ;;
    esac
    log "git installed successfully"
}

# Install the OOD ThinLinc application
install_ood_app() {
    if [ -d "$APP_DIR" ]; then
        log "OOD ThinLinc app already exists at $APP_DIR, updating..."
        git -C "$APP_DIR" pull || error_exit "Failed to update $APP_DIR"
    else
        log "Cloning OOD ThinLinc app from $REPO_URL"
        git clone "$REPO_URL" "$APP_DIR" || error_exit "Failed to clone $REPO_URL"
    fi

    log "OOD ThinLinc app installed at $APP_DIR"
}

# Copy custom configuration files
copy_config_files() {
    local files_dir="$SCRIPT_DIR/../files"

    for file in form.yml submit.yml.erb; do
        if [ ! -f "$files_dir/$file" ]; then
            error_exit "Configuration file not found: $files_dir/$file"
        fi
        log "Copying $file to $APP_DIR"
        cp "$files_dir/$file" "$APP_DIR/$file" || error_exit "Failed to copy $file"
    done

    log "Configuration files copied successfully"
}

# Configure custom_location_directives in the OOD portal configuration file /etc/ood/config/ood-portal.yml
#
# custom_location_directives:
#   - '<If "%{REQUEST_URI} =~ m|^/secure-rnode/([^/]+)/(\d+)/connect/\1|">'
#   - '  AddOutputFilterByType SUBSTITUTE text/html application/javascript'
#   - '  Substitute "s|https://([^/:]+):(\d+)/|/secure-rnode/$1/$2/|i"'
#   - '</If>'

configure_location_directives() {
    local config_file="/etc/ood/config/ood-portal.yml"
    local marker="AddOutputFilterByType SUBSTITUTE"

    if [ ! -f "$config_file" ]; then
        error_exit "OOD portal configuration file not found: $config_file"
    fi

    # Already present and uncommented — nothing to do
    if grep -qP "^\\s+- .*$marker" "$config_file"; then
        log "custom_location_directives already configured in $config_file, skipping"
        return 0
    fi

    # Present but commented — uncomment the block
    if grep -qP '^#\s*custom_location_directives:' "$config_file"; then
        log "Uncommenting custom_location_directives in $config_file"
        sed -i '/^#\s*custom_location_directives:/,/^[^#]/{
            s/^#\s\{0,\}//
        }' "$config_file"
    # Not present at all — append the full block
    elif ! grep -qP '^custom_location_directives:' "$config_file"; then
        log "Adding custom_location_directives to $config_file"
        cat >> "$config_file" <<'EOF'

custom_location_directives:
  - '<If "%{REQUEST_URI} =~ m|^/secure-rnode/([^/]+)/(\d+)/connect/\1|">'
  - '  AddOutputFilterByType SUBSTITUTE text/html application/javascript'
  - '  Substitute "s|https://([^/:]+):(\d+)/|/secure-rnode/$1/$2/|i"'
  - '</If>'
EOF
    fi

    /opt/ood/ood-portal-generator/sbin/update_ood_portal -f || error_exit "Failed to update OOD portal configuration with custom_location_directives"
    log "custom_location_directives configured in $config_file"
}
# Main execution function
main() {
    initialize_logging
    log "Starting OOD ThinLinc app installation"

    log "Script: $0"
    log "User: $(whoami)"
    log "Date: $(date)"

    check_root

    if [ ! -d "$OOD_APPS_DIR" ]; then
        error_exit "OOD apps directory not found: $OOD_APPS_DIR"
    fi

    install_git
    install_ood_app
    copy_config_files
    configure_location_directives

    log "OOD ThinLinc app installation completed successfully"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
