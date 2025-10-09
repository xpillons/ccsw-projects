#!/usr/bin/env bash
# Installs Azure CLI (az) on Debian/Ubuntu and RHEL/CentOS/Fedora.
# Based on Microsoft Learn guidance as of 2025-08-05.

set -euo pipefail

log() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
  else
    err "Cannot detect OS (missing /etc/os-release)."
    exit 1
  fi

  OS_ID="${ID:-}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_VER="${VERSION_ID:-}"
  OS_MAJOR="${OS_VER%%.*}"

  log "Detected: ID=${OS_ID} ID_LIKE=${OS_ID_LIKE} VERSION_ID=${OS_VER}"
}

install_apt() {
  log "Installing Azure CLI via apt (Debian/Ubuntu family)…"
  apt-get update -y
  apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg
  mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft.gpg >/dev/null
  chmod go+r /etc/apt/keyrings/microsoft.gpg

  AZ_DIST="$(lsb_release -cs || true)"
  if [ -z "${AZ_DIST}" ]; then
    # Fallback if lsb_release is unavailable
    case "$OS_ID" in
      debian) AZ_DIST="bookworm" ;;
      ubuntu) AZ_DIST="jammy" ;;  # good default for many derivatives
      *) AZ_DIST="bookworm" ;;
    esac
  fi

  cat <<EOF | tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg
EOF

  apt-get update -y
  apt-get install -y azure-cli
}

# Common repo stanza for dnf/yum/tdnf-based systems
write_yum_repo() {
  local key_url="$1"
  rpm --import "$key_url"
  cat <<'EOF' | tee /etc/yum.repos.d/azure-cli.repo >/dev/null
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=__KEY_URL__
EOF
  # Inject the right key into the file
  sed -i "s|__KEY_URL__|$key_url|g" /etc/yum.repos.d/azure-cli.repo
}

install_dnf_yum() {
  log "Installing Azure CLI via dnf/yum (RHEL/CentOS/Fedora family)…"
  local pkgmgr
  if command -v dnf >/dev/null 2>&1; then
    pkgmgr="dnf"
  else
    pkgmgr="yum"
  fi

  # Use the 2025 key only for RHEL/CentOS Stream 10 per docs; otherwise use the standard key
  local key_url="https://packages.microsoft.com/keys/microsoft.asc"
  if { [ "${OS_ID}" = "rhel" ] || [ "${OS_ID}" = "centos" ]; } && [ "${OS_MAJOR}" = "10" ]; then
    key_url="https://packages.microsoft.com/keys/microsoft-2025.asc"
  fi

  write_yum_repo "$key_url"
  "$pkgmgr" -y makecache
  "$pkgmgr" -y install azure-cli
}

main() {
  detect_os

  # Quick path by package manager
  if command -v apt-get >/dev/null 2>&1 || echo "$OS_ID_LIKE" | grep -qi 'debian'; then
    install_apt
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || echo "$OS_ID_LIKE" | grep -qiE 'rhel|fedora|centos'; then
    install_dnf_yum
  else
    err "Unsupported or unrecognized Linux distribution: ${OS_ID} ${OS_VER}"
    echo "You can always use the official container:"
    echo "  docker run -it --rm mcr.microsoft.com/azure-cli:azurelinux3.0"
    exit 2
  fi

  echo
  log "Installation complete. Azure CLI version:"
  az --version || { err "az not found in PATH after install."; exit 1; }
}

main "$@"