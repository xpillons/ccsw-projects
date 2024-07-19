#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"

source "$SPEC_FILE_ROOT/common.sh" 
PROM_CONFIG=/opt/prometheus/prometheus.yml

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