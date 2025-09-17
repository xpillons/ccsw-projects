# LDAP Authentication project for CycleCloud
This project configures LDAP authentication for CycleCloud clusters using SSSD. It supports RHEL, CentOS, AlmaLinux, Ubuntu, and SLES operating systems.
## Features
- Installs and configures SSSD for LDAP authentication.
- Configures SSH for secure access.
- Supports multiple LDAP servers for redundancy.
- Automatically updates SSSD configuration on cluster start.
- Disables SSH password authentication

## Prerequisites
- A running CycleCloud instance.
- An LDAP server accessible from the CycleCloud cluster.
- CycleCloud version 8.0 or higher.

## Installation
From the CycleCloud VM

1. Clone the repository and navigate to the project directory:
```bash
git clone https://github.com/xpillons/ccsw-projects.git
cd ccsw-projects/projects/ldap-auth
```

2. Update file `specs/default/cluster-init/scripts/00_sssd_setup.sh` with your LDAP server details.


3. Upload the project to your CycleCloud instance:
```bash
cyclecloud project upload azure-storage
```

4. Update an existing cluster to include the LDAP authentication project to the node arrays and VM configuration.

5. Drain nodes and start new ones to apply the changes.


## Verification
Attempt to log in using an LDAP user account to verify that authentication is working correctly.
Running with `su` means no password is required, but you can also test with `ssh` if you have SSH keys set up for the LDAP user.

```bash
sudo su - <ldap-username>
```

## Troubleshooting
- Check the SSSD logs located at `/var/log/sssd/` for any errors.
- Ensure that the LDAP server is reachable from the CycleCloud nodes.
- Verify that the LDAP user exists and has the correct permissions.
- Ensure that the SSH configuration is correct and that password authentication is disabled if required.

You can use the ldapsearch command to verify connectivity to the LDAP server, replace `<uri>` and the bind DN and password with your LDAP server details

```bash
ldapsearch -H ldap://<uri> -x -D "CN=Linux Binder,CN=Users,DC=hpc,DC=azure" -w 'password' -b "dc=hpc,dc=azure"
```
