#!/bin/bash
set -e

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# if CYCLECLOUD_SPEC_PATH is not set use the script directory as the base path
if [ -z "$CYCLECLOUD_SPEC_PATH" ]; then
    export CYCLECLOUD_SPEC_PATH="$script_dir/.."
fi

#### 
# The below settings are read from the ldap-config.json file in ../files.
# Alternatively the sssd.conf may be edited directly, this is useful for more complex setups.
####

# Check if jq is installed, install it if not
if ! command -v jq &> /dev/null; then
    echo "jq not found, installing..."
    platform_family=$(jetpack config platform_family)
    platform=$(jetpack config platform)
    
    if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
        DEBIAN_FRONTEND=noninteractive apt update && apt install -y jq
    elif [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform_family" == "rhel" ]; then 
        yum install -y jq
    elif [ "$platform" == "suse" ] || [ "$platform" == "sles" ] || [ "$platform" == "sles_hpc" ] || [ "$platform_family" == "suse" ]; then 
        zypper install -y jq
    fi
fi

# Read configuration from JSON file
CONFIG_FILE="$CYCLECLOUD_SPEC_PATH/files/ldap-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

# Parse JSON configuration
USE_KEYVAULT=$(jq -r '.useKeyvault' "$CONFIG_FILE")
CLIENT_ID=$(jq -r '.clientId' "$CONFIG_FILE")
KEYVAULT_NAME=$(jq -r '.keyvaultName' "$CONFIG_FILE")
KEYVAULT_SECRET_NAME=$(jq -r '.keyvaultSecretName' "$CONFIG_FILE")
CACHE_Credentials=$(jq -r '.cacheCredentials' "$CONFIG_FILE")
LDAP_URI=$(jq -r '.ldapUri' "$CONFIG_FILE")
LDAP_search_base=$(jq -r '.ldapSearchBase' "$CONFIG_FILE")
LDAP_Schema=$(jq -r '.ldapSchema' "$CONFIG_FILE")
LDAP_default_bind_dn=$(jq -r '.ldapDefaultBindDn' "$CONFIG_FILE")
BIND_DN_PASSWORD=$(jq -r '.bindDnPassword' "$CONFIG_FILE")
TLS_reqcert=$(jq -r '.tlsReqcert' "$CONFIG_FILE")
ID_mapping=$(jq -r '.idMapping' "$CONFIG_FILE")
HPC_ADMIN_GROUP=$(jq -r '.hpcAdminGroup' "$CONFIG_FILE")
ENUMERATE=$(jq -r '.enumerate' "$CONFIG_FILE")
HOME_DIR=$(jq -r '.homeDir' "$CONFIG_FILE")
HOME_DIR_TOP=$(echo "$HOME_DIR" | awk -F/ '{print FS $2}')

# If Keyvault is being used retrieve the BIND_DN_PASSWORD from the keyvault
if [ "${USE_KEYVAULT,,}" == "true" ]; then
    # Install Azure CLI using the script install-azcli.sh if not already installed
    if ! command -v az &> /dev/null; then
        echo "Azure CLI not found, installing..."
        chmod +x "$CYCLECLOUD_SPEC_PATH/files/install-azcli.sh"
        bash "$CYCLECLOUD_SPEC_PATH/files/install-azcli.sh"
    fi
    # Logon using the VM identity
    echo "Logging in to Azure using managed identity with client ID $CLIENT_ID"
    az login --identity --client-id "$CLIENT_ID" || (echo "Error: az login failed"; exit 1)
    echo "Retrieving LDAP bind password from Keyvault"
    BIND_DN_PASSWORD=$(az keyvault secret show --name "$KEYVAULT_SECRET_NAME" --vault-name "$KEYVAULT_NAME" --query value -o tsv)
    if [ -z "$BIND_DN_PASSWORD" ]; then
        echo "Error: Unable to retrieve LDAP bind password from Keyvault"
        exit 1
    fi
else
    echo "Do not use KeyVault, using password from script"
fi
### node config values from OHAI
platform_family=$(jetpack config platform_family)
platform=$(jetpack config platform)
platform_version=$(jetpack config platform_version)

# Disable SSH password authentication
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config

# Disable SSH host key checking because the underlying server may change but the IP remains the same.
cat <<EOF >/etc/ssh/ssh_config
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF


#supported platforms RHEL 8/9, AlmaLinux 8/9, SLES 15, Ubuntu 20/22
# If statements check explicitly for supported OS then checks for the general "platform_family" to try and support any derivative OS of Debian/Rhel
if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
    DEBIAN_FRONTEND=noninteractive apt install -y sssd sssd-tools sssd-ldap ldap-utils
    TLS_CERT_Location="/etc/ssl/certs/ca-certificates.crt"
fi

if [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform_family" == "rhel" ]; then 
    if [ "$platform" == "almalinux" ]; then
        yum install epel-release -y
    fi
    yum install -y sssd sssd-tools sssd-ldap openldap-clients oddjob-mkhomedir
    TLS_CERT_Location="/etc/pki/tls/certs/ca-bundle.crt"
fi

if [ "$platform" == "suse" ] || [ "$platform" == "sles" ] || [ "$platform" == "sles_hpc" ] || [ "$platform_family" == "suse" ]; then 
    systemctl stop nscd
    systemctl disable nscd

    if zypper lr home_lemmy04_idm &> /dev/null; then
    zypper rr home_lemmy04_idm
    fi

    zypper addrepo -f https://download.opensuse.org/repositories/home:lemmy04:idm/"$platform_version"/home:lemmy04:idm.repo
    zypper --gpg-auto-import-keys refresh 

    zypper install -y sssd sssd-tools sssd-ldap openldap2-client  authselect oddjob-mkhomedir
    TLS_CERT_Location="/var/lib/ca-certificates/ca-bundle.pem"
fi

cp -f "$CYCLECLOUD_SPEC_PATH"/files/sssd.conf /etc/sssd/sssd.conf # Copy template file

### sed commands to replace values in template file from environment variables defined above
sed -i "s#LDAP_URI#$LDAP_URI#g" /etc/sssd/sssd.conf
sed -i "s#CACHE_Credentials#$CACHE_Credentials#g" /etc/sssd/sssd.conf
sed -i "s#LDAP_Schema#$LDAP_Schema#g" /etc/sssd/sssd.conf
sed -i "s#LDAP_search_base#$LDAP_search_base#g" /etc/sssd/sssd.conf
sed -i "s#LDAP_default_bind_dn#$LDAP_default_bind_dn#g" /etc/sssd/sssd.conf
sed -i "s#TLS_reqcert#$TLS_reqcert#g" /etc/sssd/sssd.conf
sed -i "s#ID_mapping#$ID_mapping#g" /etc/sssd/sssd.conf
sed -i "s#ENUMERATE#$ENUMERATE#g" /etc/sssd/sssd.conf
sed -i "s#TLS_CERT_Location#$TLS_CERT_Location#g" /etc/sssd/sssd.conf
sed -i "s#HOME_DIR#$HOME_DIR#g" /etc/sssd/sssd.conf

echo -n $BIND_DN_PASSWORD | sss_obfuscate --domain default -s #obfuscate the bind dn password

chmod 600 /etc/sssd/sssd.conf # permissions required by sssd
chown root:root /etc/sssd/sssd.conf # permissions required by sssd

systemctl start sssd.service #start sssd this will auto pick up the sssd.conf

if [ "$platform" == "ubuntu" ] || [ "$platform_family" == "debian" ]; then 
    mkdir -p "$HOME_DIR"
    DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir # auto create home directories on login
fi

if [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform" == "suse" ] || [ "$platform_family" == "rhel" ]; then 
    mkdir -p "$HOME_DIR"
    setsebool -P use_nfs_home_dirs 1
    semanage fcontext -a -e /home "$HOME_DIR" || true
    semanage fcontext -a -e /home "$HOME_DIR_TOP" || true
    # sets the selinux file context to match the /home folder. 
    #If the $HOME_DIR already exists and has already had the contexts set eg by cyclecloud this command fails. Pipeing the command to true ensure this does not throw an error in the CC GUI.
    # If context does not exist it gets created, if context does exit the script carrys on.
    restorecon -Rv "$HOME_DIR"
    restorecon -Rv "$HOME_DIR_TOP"
    systemctl enable --now oddjobd.service
    authselect select sssd with-mkhomedir --force # select sssd profile with auto make home dir on login and force overwrite files if it has been setup before
fi

if [ "$platform" == "suse" ] || [ "$platform" == "sles" ] || [ "$platform" == "sles_hpc" ] || [ "$platform_family" == "suse" ]; then 
    mkdir -p "$HOME_DIR"
    pam-config -a --sss
    pam-config -a --mkhomedir
    systemctl enable --now oddjobd.service
    authselect select sssd with-mkhomedir --force # select sssd profile with auto make home dir on login and force overwrite files if it has been setup before
fi

# Add LDAP HPC admin group to sudoers.d
echo "\"%$HPC_ADMIN_GROUP\" ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/hpc_admins

systemctl restart sssd.service
