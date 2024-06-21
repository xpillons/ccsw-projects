#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$script_dir/../files/common.sh" 

NODE_EXPORTER_VERSION=1.8.1
SPEC_FILE_ROOT="$script_dir/../files"

function install_node_exporter() {
    # If /opt/node_exporter doen't exist, download and extract node_exporter
    if [ ! -d /opt/node_exporter ]; then
        cd /opt
        wget https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
        tar xvf node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz
        mv node_exporter-$NODE_EXPORTER_VERSION.linux-amd64 node_exporter
        chown root:root -R node_exporter
    fi

    # Install node exporter service
    cp -v $SPEC_FILE_ROOT/node_exporter.service /etc/systemd/system/

    # Create node_exporter group and user
    if ! getent group node_exporter >/dev/null; then
        groupadd -r node_exporter
    fi

    # Create node_exporter user
    if ! id -u node_exporter >/dev/null 2>&1; then
        useradd -r -g node_exporter -s /sbin/nologin node_exporter
    fi

    # Install node exporter socket
    cp -v $SPEC_FILE_ROOT/node_exporter.socket /etc/systemd/system/

    # Create /etc/sysconfig directory
    mkdir -pv /etc/sysconfig

    # Copy node exporter configuration file
    cp -v $SPEC_FILE_ROOT/sysconfig.node_exporter /etc/sysconfig/node_exporter

    # Create textfile_collector directory
    mkdir -pv /var/lib/node_exporter/textfile_collector
    chown node_exporter:node_exporter /var/lib/node_exporter/textfile_collector

    # Enable and start node exporter service
    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter
}

if is_scheduler || is_login ; then
    install_node_exporter
fi