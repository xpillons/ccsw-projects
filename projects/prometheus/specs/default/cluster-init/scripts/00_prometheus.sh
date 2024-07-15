#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"

source "$SPEC_FILE_ROOT/common.sh" 

PROMETHEUS_VERSION=2.53.0
JETPACK=/opt/cycle/jetpack/bin/jetpack

function install_prometheus() {
    # If /opt/prometheus doen't exist, download and extract prometheus
    if [ ! -d /opt/prometheus ]; then
        cd /opt
        wget -q https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
        mkdir -pv prometheus
        tar xvf  prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz -C prometheus --strip-components=1
        chown -R root:root prometheus
        rm -fv prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz
    fi

    # Install prometheus service
    cp -v $SPEC_FILE_ROOT/prometheus.service /etc/systemd/system/

    # copy the prometheus configuration file
    cp -v $SPEC_FILE_ROOT/prometheus.yml /opt/prometheus/prometheus.yml

    INGESTION_ENDPOINT=$($JETPACK config monitoring.ingestion_endpoint)
    IDENTITY_CLIENT_ID=$($JETPACK config monitoring.identity_client_id)
    INSTANCE_NAME=$(hostname)
    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" /opt/prometheus/prometheus.yml
    sed -i "s@ingestion_endpoint@$INGESTION_ENDPOINT@" /opt/prometheus/prometheus.yml
    sed -i "s/identity_client_id/$IDENTITY_CLIENT_ID/" /opt/prometheus/prometheus.yml

    # Enable and start prometheus service
    systemctl daemon-reload
    systemctl enable prometheus
    systemctl start prometheus
}

if is_scheduler || is_login || is_compute; then
    install_prometheus
fi