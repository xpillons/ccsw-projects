#!/bin/bash
set -e
source "$CYCLECLOUD_SPEC_PATH/files/common.sh" 

function configure_ssh_keys() {
    cp -f "$CYCLECLOUD_SPEC_PATH"/files/init_sshkeys.sh /etc/profile.d # Copy setup script file
}

# Configure SSH keys only on login nodes or scheduler node
if ! is_compute ; then
    configure_ssh_keys
fi
