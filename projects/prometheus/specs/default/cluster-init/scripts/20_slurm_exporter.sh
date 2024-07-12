#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"

source "$SPEC_FILE_ROOT/common.sh" 
GO_VERSION=1.22.4
SLURM_EXPORTER_VERSION=v1.5.1

function install_slurm_exporter()
{
    wget -q https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
    rm go$GO_VERSION.linux-amd64.tar.gz

    echo "export PATH=\$PATH:/usr/local/go/bin" >> /etc/bash.bashrc

    /usr/local/go/bin/go install github.com/rivosinc/prometheus-slurm-exporter@$SLURM_EXPORTER_VERSION

    cp $SPEC_FILE_ROOT/prometheus-slurm-exporter.service /etc/systemd/system
    systemctl daemon-reload
    systemctl enable prometheus-slurm-exporter
    systemctl start prometheus-slurm-exporter

}

# if is_scheduler ; then
#     install_slurm_exporter
# fi