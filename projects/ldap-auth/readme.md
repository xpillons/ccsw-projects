# LDAP Authentication Project for CycleCloud

This project provides comprehensive LDAP authentication setup for Azure CycleCloud clusters using SSSD (System Security Services Daemon). It supports multiple Linux distributions and offers both initial setup and password rotation capabilities with Azure Key Vault integration.

## 🚀 Features

- **Multi-Platform Support**: RHEL, CentOS, AlmaLinux, Ubuntu, and SLES
- **Secure Password Management**: Azure Key Vault integration for secure password storage
- **Idempotent Operations**: Safe to run multiple times without side effects
- **Password Rotation**: Automated password update detection and application
- **Comprehensive Configuration**: SSH hardening, PAM setup, home directory creation
- **Admin Access**: Configurable LDAP group for sudo access
- **Offline Authentication**: Cached credentials with configurable expiration
- **Function-Based Architecture**: Modular, maintainable script design

## 📋 Prerequisites

- Azure CycleCloud 8.0 or higher
- LDAP server accessible from cluster nodes
- Azure Key Vault (optional, for secure password management)
- Managed Identity with Key Vault access (if using Key Vault)

## 🛠️ Installation & Setup

### 1. Clone the Repository

SSH to your CycleCloud VM and switch to root:

```bash
sudo su -
cd /opt/ccw
git clone https://github.com/xpillons/ccsw-projects.git
cd ccsw-projects/projects/ldap-auth
```

### 2. Configure LDAP Settings

Create and edit the configuration file:

```bash
cp specs/default/cluster-init/files/ldap-config.json.example specs/default/cluster-init/files/ldap-config.json
```

Edit `ldap-config.json` with your LDAP server details:

```json
{
  "useKeyvault": "False",
  "clientId": "your-managed-identity-client-id",
  "keyvaultName": "mykeyvault",
  "keyvaultSecretName": "ldap-bind-password",
  "cacheCredentials": "True",
  "ldapUri": "ldap://your-ldap-server.domain.com",
  "ldapSearchBase": "dc=yourdomain,dc=com",
  "ldapSchema": "AD",
  "ldapDefaultBindDn": "CN=Service Account,CN=Users,DC=yourdomain,DC=com",
  "bindDnPassword": "your-service-account-password",
  "tlsReqcert": "allow",
  "idMapping": "True",
  "hpcAdminGroup": "HPC Admins",
  "enumerate": "False",
  "homeDir": "/shared/home"
}
```

### 3. Azure Key Vault Setup (Optional but Recommended)

For enhanced security, store your LDAP bind password in Azure Key Vault:

#### Create Key Vault and Secret:
```bash
# Create Key Vault
az keyvault create --name mykeyvault --resource-group myrg --location eastus

# Store LDAP password
az keyvault secret set --vault-name mykeyvault --name ldap-bind-password --value "your-secure-password"
```

#### Configure Managed Identity:
```bash
# Create managed identity
az identity create --name ldap-auth-identity --resource-group myrg

# Assign Key Vault Secrets User role
az role assignment create \
  --assignee <managed-identity-client-id> \
  --role "Key Vault Secrets User" \
  --scope /subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/mykeyvault
```

**Important**: The managed identity must be assigned to the CycleCloud cluster nodes. In your CycleCloud cluster template, configure the managed identity for the node arrays that will use LDAP authentication.


Update your `ldap-config.json`:
```json
{
  "useKeyvault": "True",
  "clientId": "your-managed-identity-client-id",
  "keyvaultName": "mykeyvault",
  "keyvaultSecretName": "ldap-bind-password"
}
```

### 4. Deploy to CycleCloud

Upload the project:
```bash
cyclecloud project upload azure-storage
```

Add to your cluster template or update existing clusters to include the LDAP authentication project.

### 5. Apply Configuration

Drain existing nodes and start new ones to apply the LDAP authentication configuration.

## ⚙️ Configuration Options

### JSON Configuration Parameters

| Parameter | Description | Example | Required |
|-----------|-------------|---------|----------|
| `useKeyvault` | Enable Azure Key Vault for password retrieval | `"True"` or `"False"` | Yes |
| `clientId` | Managed Identity client ID for Key Vault access | `"12345678-1234-1234-1234-123456789012"` | If using Key Vault |
| `keyvaultName` | Name of the Azure Key Vault | `"mykeyvault"` | If using Key Vault |
| `keyvaultSecretName` | Name of the secret containing LDAP password | `"ldap-bind-password"` | If using Key Vault |
| `cacheCredentials` | Enable credential caching for offline authentication | `"True"` or `"False"` | Yes |
| `ldapUri` | LDAP server URI (comma-separated for multiple servers) | `"ldap://server1.com,ldap://server2.com"` | Yes |
| `ldapSearchBase` | Base DN for LDAP searches | `"dc=company,dc=com"` | Yes |
| `ldapSchema` | LDAP schema type | `"AD"`, `"rfc2307"`, `"rfc2307bis"`, `"IPA"` | Yes |
| `ldapDefaultBindDn` | DN for the LDAP bind account | `"CN=ServiceAccount,CN=Users,DC=company,DC=com"` | Yes |
| `bindDnPassword` | LDAP bind account password (if not using Key Vault) | `"password123"` | If not using Key Vault |
| `tlsReqcert` | TLS certificate verification level | `"never"`, `"allow"`, `"try"`, `"demand"`, `"hard"` | Yes |
| `idMapping` | Use SID-based ID mapping for AD | `"True"` or `"False"` | Yes |
| `hpcAdminGroup` | LDAP group granted sudo access | `"HPC Admins"` | Yes |
| `enumerate` | Allow domain enumeration | `"True"` or `"False"` | Yes |
| `homeDir` | Base directory for user home directories | `"/shared/home"` | Yes |

## 🔄 Password Rotation

The project supports automated password rotation with two modes:

### Full Setup Mode (Default)
```bash
./00_sssd_setup.sh
```
Performs complete LDAP authentication setup including package installation, configuration, and service management.

### Password-Only Update Mode
```bash
./00_sssd_setup.sh --password-update-only
```
Only checks for password changes in Key Vault and updates SSSD configuration if needed. Perfect for:
- Automated password rotation schedules
- CI/CD pipelines
- Maintenance windows
- Security compliance automation

### Automation Example

Create a cron job for regular password rotation checks:

```bash
# Check for password updates every hour
0 * * * * /opt/ccw/ccsw-projects/projects/ldap-auth/specs/default/cluster-init/scripts/00_sssd_setup.sh --password-update-only >> /var/log/ldap-password-rotation.log 2>&1
```

## 🔧 Script Behavior & Idempotency

The setup script is designed to be idempotent:

- **First Run**: Complete setup with all components
- **Subsequent Runs**: Only updates when changes are detected
- **Key Vault Mode**: Tracks secret update timestamps
- **Local Mode**: Checks for existing configuration files

### Change Detection Logic

1. **Key Vault Mode**: Compares secret `updated` timestamp with stored marker
2. **Local Mode**: Checks for existence of `/etc/sssd/sssd.conf`
3. **Service Management**: Only restarts SSSD when configuration changes
4. **Marker Files**: Stored in `/var/lib/ldap-auth/` for state tracking

## ✅ Verification & Testing

### 1. Verify LDAP Connectivity
```bash
# Test LDAP connection
ldapsearch -H ldap://your-server.com -x -D "CN=ServiceAccount,CN=Users,DC=company,DC=com" -w 'password' -b "dc=company,dc=com"
```

### 2. Test User Authentication
```bash
# Switch to LDAP user
sudo su - ldapuser

# Check user info
id ldapuser
getent passwd ldapuser
```

### 3. Verify Home Directory Creation
```bash
# Check if home directory exists
ls -la /shared/home/ldapuser
```

### 4. Test Sudo Access (for admin group members)
```bash
# Switch to admin user
sudo su - ldapadmin

# Test sudo access
sudo whoami
```

## 🔍 Troubleshooting

### Common Issues & Solutions

#### SSSD Service Issues
```bash
# Check SSSD status
systemctl status sssd

# View SSSD logs
tail -f /var/log/sssd/*.log

# Restart SSSD manually
systemctl restart sssd
```

#### Key Vault Access Issues
```bash
# Test managed identity
az login --identity --client-id your-client-id

# Test Key Vault access
az keyvault secret show --vault-name mykeyvault --name ldap-bind-password
```

#### Network Connectivity Issues
```bash
# Test LDAP server connectivity
telnet your-ldap-server.com 389

# Check DNS resolution
nslookup your-ldap-server.com

# Test with different ports (LDAPS)
telnet your-ldap-server.com 636
```

#### Permission Issues
```bash
# Check file permissions
ls -la /etc/sssd/sssd.conf

# Verify marker file permissions
ls -la /var/lib/ldap-auth/
```

### Log Locations

- **SSSD Logs**: `/var/log/sssd/`
- **Setup Script Logs**: Check CycleCloud node logs
- **Password Rotation Logs**: `/var/log/ldap-password-rotation.log` (if using cron)
- **Marker Files**: `/var/lib/ldap-auth/`

### Debug Mode

For detailed debugging, run the script with bash debug mode:
```bash
bash -x ./00_sssd_setup.sh
```

## 📂 Project Structure

```
ldap-auth/
├── project.ini                          # CycleCloud project definition
├── readme.md                           # This documentation
└── specs/
    └── default/
        └── cluster-init/
            ├── files/
            │   ├── install-azcli.sh     # Azure CLI installation script
            │   ├── ldap-config.json     # LDAP configuration
            │   └── sssd.conf            # SSSD configuration template
            └── scripts/
                └── 00_sssd_setup.sh     # Main setup script
```

## 🆘 Support

For issues and questions:
1. Check the troubleshooting section above
2. Review SSSD and CycleCloud documentation
3. Open an issue in the GitHub repository
