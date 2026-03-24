#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../default/cluster-init/files/common.sh"

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

    log "OOD ThinLinc app installation completed successfully"
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
