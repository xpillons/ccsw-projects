#!/bin/bash
set -o pipefail

platform_family=$(jetpack config platform_family)
platform=$(jetpack config platform)
platform_version=$(jetpack config platform_version)

VERSION=3.1.4

case $platform in
    ubuntu)
        wget https://github.com/TurboVNC/turbovnc/releases/download/${VERSION}/turbovnc_${VERSION}_amd64.deb
        DEBIAN_FRONTEND=noninteractive apt install -y ./turbovnc_${VERSION}_amd64.deb
        DEBIAN_FRONTEND=noninteractive apt-get install -y websockify
        ;;
    almalinux)
        dnf install -y https://github.com/TurboVNC/turbovnc/releases/download/${VERSION}/turbovnc_${VERSION}.x86_64.rpm
        dnf install -y python3-websockify
        ;;
    *)
        echo "Untested OS $platform $platform_family $platform_version"
        exit 0
        ;;
esac

# retrieve the number of GPUs
NB_GPU=$(nvidia-smi -L | wc -l)
# if NB_GPU greater than 0 then configure /etc/X11/xorg.conf for the number of GPUs
if [ $NB_GPU -gt 0 ]; then
    nvidia-xconfig --enable-all-gpus --allow-empty-initial-configuration -c /etc/X11/xorg.conf --virtual=1920x1200 -s
    sed -i '/Section "Device"/a\    Option         "HardDPMS" "false"' /etc/X11/xorg.conf
fi
