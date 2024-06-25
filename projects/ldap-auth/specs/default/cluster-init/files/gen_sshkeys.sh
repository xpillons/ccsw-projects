#!/bin/bash

# Only do this for uid >= 1000
if [ $(id -u) -le 1000 ]; then
    return
fi
if [ ! -f  ~/.ssh/id_rsa.pub ] ; then
    ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<<y >/dev/null 2>&1
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys # Add new ssh keys to authorized list, this enables passwordless ssh within the cluster
    echo "StrictHostKeyChecking no" >> ~/.ssh/config # Stops the host checking pop up when underlying server has changed but IP has not.
    chmod 644 ~/.ssh/authorized_keys
fi
