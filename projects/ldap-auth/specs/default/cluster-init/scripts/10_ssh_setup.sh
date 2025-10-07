#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# if CYCLECLOUD_SPEC_PATH is not set use the script directory as the base path
if [ -z "$CYCLECLOUD_SPEC_PATH" ]; then
    export CYCLECLOUD_SPEC_PATH="$script_dir/.."
fi

source "$CYCLECLOUD_SPEC_PATH/files/common.sh" 

function configure_ssh_keys() {
    cp -f "$CYCLECLOUD_SPEC_PATH"/files/init_sshkeys.sh /etc/profile.d # Copy setup script file
}

# Configure SSH keys only on login nodes or scheduler node
if ! is_compute ; then
    configure_ssh_keys
fi
