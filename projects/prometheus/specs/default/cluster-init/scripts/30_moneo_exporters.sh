#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"

source "$SPEC_FILE_ROOT/common.sh" 
MONEO_ROOT=/opt/azurehpc/tools/Moneo
PROM_CONFIG=/opt/prometheus/prometheus.yml

# If Mone is not present, exit silently
if [ ! -d $MONEO_ROOT ]; then
    exit 0
fi

function start_moneo()
{
    $MONEO_ROOT/linux_service/start_moneo_services.sh workers
}

# https://slurm.schedmd.com/prolog_epilog.html
# If multiple prolog and/or epilog scripts are specified, (e.g. "/etc/slurm/prolog.d/*") they will run in reverse alphabetical order (z-a -> Z-A -> 9-0)
function install_job_prolog_epilog()
{
    mkdir -pv /etc/slurm/prolog.d /etc/slurm/epilog.d/
    cp -vf $SPEC_FILE_ROOT/moneo_prolog.sh /etc/slurm/prolog.d
    cp -vf $SPEC_FILE_ROOT/moneo_epilog.sh /etc/slurm/epilog.d
    chmod +x /etc/slurm/prolog.d/* /etc/slurm/epilog.d/*
}

function add_scraper() {
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/moneo_exporters.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

if is_compute ; then
    install_job_prolog_epilog
    start_moneo
    install_yq
    add_scraper
fi