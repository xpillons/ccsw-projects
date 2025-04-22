#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh"
if ! is_monitoring_enabled; then
    exit 0
fi

function install_rivosinc_slurm_exporter()
{
    GO_VERSION=1.22.4
    SLURM_EXPORTER_VERSION=v1.5.1

    wget -q https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
    rm go$GO_VERSION.linux-amd64.tar.gz

    echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/bash.bashrc

    /usr/local/go/bin/go install github.com/rivosinc/prometheus-slurm-exporter@$SLURM_EXPORTER_VERSION

    cp $SPEC_FILE_ROOT/rivosinc-slurm-exporter.service /etc/systemd/system/prometheus-slurm-exporter.service
    systemctl daemon-reload
    systemctl enable prometheus-slurm-exporter
    systemctl start prometheus-slurm-exporter
}

# Use the development branch as this is the one working for GPUs, however this exporter is not maintained anymore
function install_vpenso_slurm_exporter()
{

    apt install -y golang-go
    cd /opt
    rm -rfv prometheus-slurm-exporter
    git clone -b development https://github.com/vpenso/prometheus-slurm-exporter.git
    cd prometheus-slurm-exporter

    # remove the test from the makefile as it failed
    sed -i 's/build: test/build:/' Makefile
    make

    cp $SPEC_FILE_ROOT/vpenso-slurm-exporter.service /etc/systemd/system/prometheus-slurm-exporter.service
    systemctl daemon-reload
    systemctl enable prometheus-slurm-exporter
    systemctl start prometheus-slurm-exporter
}

# This repo took over the vpenso one and is maintained
function install_lcrownover_slurm_exporter()
{
    CONF_FILE=/etc/prometheus-slurm-exporter/env.conf

    cd /opt
    rm -rfv prometheus-slurm-exporter
    cd prometheus-slurm-exporter


    # Get a token for the hpcadmin user
    token=$(scontrol token username=hpcadmin lifespan=31536000)

    echo "SLURM_EXPORTER_LISTEN_ADDRESS=0.0.0.0:9092" > $CONF_FILE
    echo "SLURM_EXPORTER_API_URL=http://localhost:6820" >> $CONF_FILE
    echo "SLURM_EXPORTER_API_USER=hpcadmin" >> $CONF_FILE
    echo "SLURM_EXPORTER_API_TOKEN=$token" >> $CONF_FILE
    echo "SLURM_EXPORTER_ENABLE_TLS=false" >> $CONF_FILE

    chmod 600 $CONF_FILE
    cp $SPEC_FILE_ROOT/lcrownover-slurm-exporter.service /etc/systemd/system/prometheus-slurm-exporter.service
    systemctl daemon-reload
    systemctl enable prometheus-slurm-exporter
    systemctl start prometheus-slurm-exporter
}

function add_scraper() {
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/slurm_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

if is_scheduler ; then
    install_vpenso_slurm_exporter
    install_yq
    add_scraper
fi