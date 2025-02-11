#!/bin/bash

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
