#!/bin/bash

# Only do this for uid >= 1000 - CycleCloud is uid 1000
if [ $(id -u) -le 1000 ]; then
    return
fi
if [ ! -f  ~/.ssh/id_rsa.pub ] ; then
    mkdir -p ~/.ssh
    # BUGBUG: This is actually failing on AlmaLinux 8.7 : Error looking up public keys
    PUB_KEY=$(/usr/bin/sss_ssh_authorizedkeys $USER) # Get the ssh keys from LDAP
    # if PUB_KEY is not empty, then write it to id_rsa.pub, otherwise generate a new key pair
    if [ -z "$PUB_KEY" ]; then
        ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<<y >/dev/null 2>&1
    else
        echo $PUB_KEY > ~/.ssh/id_rsa.pub 
    fi

    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys # Add new ssh keys to authorized list, this enables passwordless ssh within the cluster
    echo "StrictHostKeyChecking no" >> ~/.ssh/config # Stops the host checking pop up when underlying server has changed but IP has not.
    chmod 644 ~/.ssh/authorized_keys
fi
