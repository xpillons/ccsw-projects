# Blobfuse2 Installation Project

This project provides automated installation and configuration of Blobfuse2 for mounting Azure Blob Storage on Azure CycleCloud clusters.

## 🚀 Features

- **Multi-Platform Support**: RHEL/CentOS/AlmaLinux/Rocky 8+, Ubuntu 20.04+, Debian 10+
- **Intelligent Storage Detection**: Automatically uses fastest available cache storage (NVMe → Azure temp disk → local → default)
- **Multiple Authentication Methods**: Support for Managed Identity (MSI) and Storage Account Key
- **Systemd Integration**: Optional auto-mount on boot via systemd service
- **Robust Error Handling**: Comprehensive error checking and validation
- **Idempotent Operations**: Safe to run multiple times
- **Configurable Settings**: Customizable cache size, mount point, authentication, and more
- **Detailed Logging**: Timestamped logs for troubleshooting

## 📋 Prerequisites

- Azure CycleCloud cluster
- For MSI authentication: VM must have a Managed Identity with access to the storage account
- For Key authentication: Storage account name and key

## 🔧 Configuration

Configuration is managed through the `files/blobfuse2-config.env` file. Key settings include:

### Storage Account Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE_ACCOUNT_NAME` | (empty) | Azure Storage Account name |
| `STORAGE_CONTAINER_NAME` | (empty) | Blob container to mount |
| `AUTH_METHOD` | `msi` | Authentication method: `msi` or `key` |
| `STORAGE_ACCOUNT_KEY` | (empty) | Storage account key (only for `key` auth) |
| `MSI_CLIENT_ID` | (empty) | Client ID of the user-assigned managed identity (required when the VM has multiple identities) |
| `MSI_RESOURCE_ID` | (empty) | Resource ID of the user-assigned managed identity (alternative to `MSI_CLIENT_ID`) |
| `MSI_OBJECT_ID` | (empty) | Object ID of the user-assigned managed identity (requires Azure CLI on the node) |

### Mount Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `MOUNT_POINT` | `/blobfuse` | Where to mount the blob storage |
| `ALLOW_OTHER` | `true` | Allow other users to access the mount |
| `READ_ONLY` | `true` | Mount as read-only |

### Cache Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `CACHE_DIR` | (auto-detect) | Cache directory location |
| `CACHE_SIZE_MB` | `10240` | Maximum cache size in MB |
| `CACHE_TIMEOUT_SEC` | `120` | Cache timeout in seconds |
| `FILE_CACHE_MODE` | `file` | Cache mode: `file` or `stream` |

### Service Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_SYSTEMD_SERVICE` | `true` | Create systemd service for auto-mount |
| `LOG_LEVEL` | `LOG_WARNING` | Logging level |
| `LOG_FILE` | `/var/log/blobfuse2.log` | Log file location |

## 📦 Installation

The installation script (`scripts/00_install.sh`) performs the following steps:

1. **OS Detection**: Identifies the Linux distribution
2. **Package Installation**: Installs blobfuse2 from Microsoft repositories
3. **Cache Setup**: Creates and configures cache directory
4. **Mount Point Setup**: Creates the mount point directory
5. **Configuration**: Generates `/etc/blobfuse2/config.yaml`
6. **FUSE Configuration**: Enables `user_allow_other` in `/etc/fuse.conf`
7. **Systemd Service**: Creates the systemd service and, when the storage account/container are configured, enables and starts it for auto-mount (optional)
8. **Validation**: Verifies installation and configuration

## 🚦 Usage

### CycleCloud Integration

Add this project to your CycleCloud cluster template:

```ini
[cluster myCluster]
    [[node defaults]]
        [[[cluster-init blobfuse2:default:1.0.0]]]
```

### Manual Mount Commands

After installation, you can manually mount:

```bash
# Mount using config file
blobfuse2 mount /blobfuse --config-file=/etc/blobfuse2/config.yaml

# Unmount
fusermount3 -u /blobfuse
```

### Systemd Service Commands

```bash
# Enable auto-mount on boot
systemctl enable blobfuse2

# Start mount now
systemctl start blobfuse2

# Check status
systemctl status blobfuse2

# Stop/unmount
systemctl stop blobfuse2
```

## 📁 File Structure

```
blobfuse2/
├── project.ini
├── README.md
└── specs/
    └── default/
        └── cluster-init/
            ├── files/
            │   └── blobfuse2-config.env
            └── scripts/
                └── 00_install.sh
```

## 🔒 Security Best Practices

1. **Use Managed Identity**: Prefer MSI authentication over storage account keys
2. **Least Privilege**: Grant only necessary permissions to the storage account
3. **Config Protection**: The configuration file is created with 600 permissions
4. **Private Endpoints**: Consider using private endpoints for storage account access

## 🐛 Troubleshooting

### Check Installation Logs

```bash
cat /var/log/blobfuse2-install.log
```

### Check Blobfuse2 Logs

```bash
cat /var/log/blobfuse2.log
journalctl -u blobfuse2
```

### Verify Mount Status

```bash
mount | grep blobfuse2
df -h /blobfuse
```

### Common Issues

1. **Permission Denied**: Ensure the VM's Managed Identity has Storage Blob Data Contributor role
2. **Mount Fails**: Check if the storage account and container names are correct
3. **Cache Issues**: Verify the cache directory has sufficient space
4. **FUSE Errors**: Ensure `user_allow_other` is in `/etc/fuse.conf`
5. **Multiple User-Assigned Identities**: If you see *"Multiple user assigned identities exist, please specify the clientId / resourceId of the identity in the token request"*, set `MSI_CLIENT_ID` (or `MSI_RESOURCE_ID`) in `blobfuse2-config.env` to the identity that holds the Storage Blob Data role.

## 📖 References

- [Blobfuse2 Documentation](https://github.com/Azure/azure-storage-fuse)
- [Azure Blob Storage Documentation](https://docs.microsoft.com/azure/storage/blobs/)
- [CycleCloud Cluster-Init](https://docs.microsoft.com/azure/cyclecloud/how-to/cluster-init)
