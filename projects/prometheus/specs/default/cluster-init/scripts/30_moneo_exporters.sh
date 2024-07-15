#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"

source "$SPEC_FILE_ROOT/common.sh" 

function start_moneo()
{
    /opt/azurehpc/tools/Moneo/linux_service/start_moneo_services.sh workers
}

function add_scraper() {
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' /opt/prometheus/prometheus.yml $SPEC_FILE_ROOT/moneo_exporters.yml > tmp.yml
    mv -vf tmp.yml /opt/prometheus/prometheus.yml

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" /opt/prometheus/prometheus.yml

    systemctl restart prometheus
}

if is_compute ; then
    start_moneo
    install_yq
    add_scraper
fi