#!/bin/bash
# See https://techcommunity.microsoft.com/blog/azurehighperformancecomputingblog/using-gromacs-through-eessi-on-nc-a100-v4/4423933

set -eo pipefail
read_os()
{
    os_release=$(cat /etc/os-release | grep "^ID\=" | cut -d'=' -f 2 | xargs)
    os_maj_ver=$(cat /etc/os-release | grep "^VERSION_ID\=" | cut -d'=' -f 2 | xargs)
    full_version=$(cat /etc/os-release | grep "^VERSION\=" | cut -d'=' -f 2 | xargs)
}

read_os
case $os_release in
    almalinux)
        dnf install -y https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
        dnf install -y cvmfs
        dnf install -y https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm
        ;;
    ubuntu)
        wget https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
        dpkg -i cvmfs-release-latest_all.deb
        wget https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi_latest_all.deb
        dpkg -i cvmfs-config-eessi_latest_all.deb
        apt update
        apt install -y cvmfs
        ;;
    *)
        logger -s "Untested OS $os_release $os_version"
        exit 0
        ;;
esac

# configure CernVM-FS (no proxy, 10GB quota for CernVM-FS cache)
bash -c "echo 'CVMFS_HTTP_PROXY=DIRECT' > /etc/cvmfs/default.local"
bash -c "echo 'CVMFS_CLIENT_PROFILE="single"' > /etc/cvmfs/default.local"
bash -c "echo 'CVMFS_QUOTA_LIMIT=10000' >> /etc/cvmfs/default.local"
cvmfs_config setup
