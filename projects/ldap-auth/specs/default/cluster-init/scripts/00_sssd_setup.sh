#!/bin/bash
set -e

#### 
# The below settings must be edited by the user.
# The settings are the configuration values for the sssd.conf file in ../files.
# Alternativley the sssd.conf may be edited directly, this is useful for more complex setups.
# The BIND_DN refers to the read only service account that is used for retrieving data from the LDAP server.
####
USE_KEYVAULT="False" # If True the BIND_DN_PASSWORD is retrieved from Azure Keyvault. If False the password is stored in plain text in this script.
KEYVAULT_NAME="mykeyvault" # Name of the Azure Keyvault where the BIND_DN_PASSWORD secret is stored.
KEYVAULT_SECRET_NAME="ldap-bind-password" # Name of the secret in the Keyvault where the BIND_DN_PASSWORD is stored.
CACHE_Credentials="True" # Determines if user credentials are also cached in the local LDB cache. True by default for tuning.
LDAP_URI="ldap://172.20.90.4" # comma-separated list of URIs of the LDAP servers to which SSSD should connect in the order of preference.
LDAP_search_base="dc=hpc,dc=azure" # default base DN to use for performing LDAP user operations. eg searching for users
LDAP_Schema="AD" # Schema Type in use on the target LDAP server. supported values are rfc2307, rfc2307bis, IPA, AD
LDAP_default_bind_dn="CN=Linux Binder,CN=Users,DC=hpc,DC=azure" # default bind DN to use for performing LDAP operations.
BIND_DN_PASSWORD="Service account password" # default bind DN password. This is obfuscated in the sssd.conf file
TLS_reqcert="allow" # what checks to perform on server certificates in a TLS session. Supported values are never, allow, try, demand, hard
ID_mapping="True" # SSSD should attempt to map user and group IDs from the ldap_user_objectsid and ldap_group_objectsid attributes instead of relying on ldap_user_uid_number and ldap_group_gid_number.
HPC_ADMIN_GROUP="HPC Admins" # LDAP group that will be granted sudo access on the nodes.
ENUMERATE="False" # determines if a domain can be enumerated. Default to False for performance reasons.
HOME_DIR="/shared/home" # user home directory for ldap users.
HOME_DIR_TOP=$(echo "$HOME_DIR" | awk -F/ '{print FS $2}')

# If Keyvault is being used retrieve the BIND_DN_PASSWORD from the keyvault
if [ "${USE_KEYVAULT,,}" == "true" ]; then
    # Logon using the VM identity
    az login --identity
    echo "Retrieving LDAP bind password from Keyvault"
    BIND_DN_PASSWORD=$(az keyvault secret show --name "$KEYVAULT_SECRET_NAME" --vault-name "$KEYVAULT_NAME" --query value -o tsv)
    if [ -z "$BIND_DN_PASSWORD" ]; then
        echo "Error: Unable to retrieve LDAP bind password from Keyvault"
        exit 1
    fi
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
    DEBIAN_FRONTEND=noninteractive apt install -y sssd sssd-tools sssd-ldap ldap-utils dos2unix
    TLS_CERT_Location="/etc/ssl/certs/ca-certificates.crt"

fi

if [ "$platform" == "almalinux" ] || [ "$platform" == "redhat" ] || [ "$platform_family" == "rhel" ]; then 
    if [ "$platform" == "almalinux" ]; then
        yum install epel-release -y
    fi
    yum install -y sssd sssd-tools sssd-ldap openldap-clients dos2unix oddjob-mkhomedir
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

    zypper install -y sssd sssd-tools sssd-ldap openldap2-client dos2unix authselect oddjob-mkhomedir
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

dos2unix /etc/sssd/sssd.conf # convert to unix format
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
