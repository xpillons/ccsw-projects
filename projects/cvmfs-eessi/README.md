# CVMFS-EESSI Installation Project

This project provides automated installation and configuration of CVMFS (CernVM File System) with EESSI (European Environment for Scientific Software Installations) support for Azure CycleCloud clusters.

## 🚀 Features

- **Multi-Platform Support**: RHEL/CentOS/AlmaLinux 8+, Ubuntu 20.04+, Debian 10+
- **Intelligent Storage Detection**: Automatically uses fastest available storage (NVMe → local → default)
- **Robust Error Handling**: Comprehensive error checking and recovery
- **Idempotent Operations**: Safe to run multiple times
- **Configurable Settings**: Customizable cache size, location, proxy settings
- **Backup & Recovery**: Automatic backup of existing configurations
- **Detailed Logging**: Timestamped logs for troubleshooting
- **Validation**: Post-installation verification and testing

## 📋 Prerequisites

- Root access on target systems
- Internet connectivity for package downloads
- Minimum 10GB available disk space for CVMFS cache (configurable)

## 🛠️ Installation

### Quick Start

1. Deploy the project through Azure CycleCloud:
   ```bash
   # The script runs automatically during cluster initialization
   # Check logs at: /var/log/cvmfs-eessi-install.log
   ```

### Manual Installation

1. Copy the installation script:
   ```bash
   sudo su -
   cd /opt
   git clone <repository-url>
   cd ccsw-projects/projects/cvmfs-eessi
   ```

2. Run the installation:
   ```bash
   chmod +x specs/default/cluster-init/scripts/00_install.sh
   ./specs/default/cluster-init/scripts/00_install.sh
   ```

## ⚙️ Configuration

### Environment Variables

You can customize the installation by setting environment variables:

```bash
# Set cache quota to 20GB
export CVMFS_CACHE_QUOTA=20000

# Override automatic cache location detection
export CVMFS_CACHE_BASE=/shared/scratch/cvmfs

# Use a proxy server
export CVMFS_PROXY=http://proxy.company.com:8080

# Run installation
./00_install.sh
```

### Configuration File

Edit `specs/default/cluster-init/files/cvmfs-config.env` to set default values:

```bash
# CVMFS Cache quota in MB
CVMFS_CACHE_QUOTA=10000

# Cache base directory (auto-detected if not set)
# Auto-detection order: /mnt/nvme/cvmfs -> /mnt/cvmfs -> /var/lib/cvmfs
#CVMFS_CACHE_BASE=/custom/path/cvmfs

# Proxy configuration
CVMFS_PROXY=DIRECT

# Enable debug logging
DEBUG_LOGGING=false
```

### Intelligent Storage Detection

The script automatically detects and uses the best available storage for CVMFS cache:

| Detection Order | Path | Azure VM Types | Performance | Use Case |
|----------------|------|----------------|-------------|----------|
| 1st Priority | `/mnt/nvme/cvmfs` | **HPC**: HBv3, HBv4, NDv4, NDv5<br>**Storage**: Lsv3, Lasv3<br>**Compute**: NVadsA10v5 | ⚡ Excellent<br>400K+ IOPS | NVMe local storage |
| 2nd Priority | `/mnt/cvmfs` | **General**: Dv4, Dv5, Ev4, Ev5<br>**Compute**: Fv2<br>**Memory**: Mv2, Mdsv2<br>**GPU**: NCv3, NCasT4v3 | ✅ Good<br>20K+ IOPS | Local temp storage |
| 3rd Priority | `/var/lib/cvmfs` | **Basic**: Av2, Dv3<br>**Burstable**: Bv2<br>**Any VM without temp storage** | ⚠️ Standard<br>Basic IOPS | OS disk fallback |

**Override Detection:**
```bash
# Force specific location
export CVMFS_CACHE_BASE=/shared/scratch/cvmfs
```

### Platform Support

| Platform | Versions | Package Manager | Status |
|----------|----------|----------------|---------|
| AlmaLinux | 8, 9 | dnf | ✅ Supported |
| RHEL | 8, 9 | dnf | ✅ Supported |
| CentOS | 8, 9 | dnf | ✅ Supported |
| Rocky Linux | 8, 9 | dnf | ✅ Supported |
| Ubuntu | 20.04, 22.04+ | apt | ✅ Supported |
| Debian | 10, 11+ | apt | ✅ Supported |

## 🔧 Usage

### Testing EESSI Access

After installation, test EESSI repository access:

```bash
# List available software
ls /cvmfs/software.eessi.io

# Load EESSI environment
source /cvmfs/software.eessi.io/versions/2023.06/init/bash

# Check available modules
module avail

# Load and use software (example: GROMACS)
module load GROMACS
gmx --version
```

### Managing CVMFS

```bash
# Check CVMFS status
sudo cvmfs_config stat

# Probe repositories
sudo cvmfs_config probe software.eessi.io

# Reload configuration
sudo cvmfs_config reload

# Check quota usage
sudo cvmfs_config showconfig | grep QUOTA
```

## 📊 Monitoring & Troubleshooting

### Log Files

- **Installation Log**: `/var/log/cvmfs-eessi-install.log`
- **CVMFS Logs**: `/var/log/cvmfs/*.log`
- **System Logs**: `journalctl -u cvmfs`

### Common Issues

#### EESSI Repository Not Accessible

```bash
# Check CVMFS status
sudo cvmfs_config stat

# Restart autofs
sudo systemctl restart autofs

# Test repository probe
sudo cvmfs_config probe software.eessi.io
```

#### Cache Full

```bash
# Check current cache usage (use actual cache location)
df -h $(sudo cvmfs_config showconfig | grep CVMFS_CACHE_BASE | cut -d= -f2)

# Or check common locations
df -h /mnt/nvme/cvmfs /mnt/cvmfs /var/lib/cvmfs 2>/dev/null

# Clean cache
sudo cvmfs_config cleanup

# Increase quota (edit /etc/cvmfs/default.local)
sudo nano /etc/cvmfs/default.local
```

#### Network Issues

```bash
# Test connectivity to CVMFS stratum
ping cvmfs-stratum-one.cern.ch

# Check proxy settings
sudo cvmfs_config showconfig | grep PROXY
```

### Performance Tuning

For high-performance computing workloads:

```bash
# Increase cache quota
CVMFS_CACHE_QUOTA=50000  # 50GB

# Use custom high-performance storage (overrides auto-detection)
CVMFS_CACHE_BASE=/shared/nvme/cvmfs

# Enable local proxy for multi-node clusters
CVMFS_PROXY=http://squid-proxy:3128

# The script automatically detects fastest storage, but you can override:
# - NVMe storage: Detected automatically on Lsv3/Lasv3 VMs
# - Custom storage: Set CVMFS_CACHE_BASE explicitly
# - Shared storage: Use for multi-node consistency
```

**Azure VM Storage Recommendations:**

| VM Series | Storage Type | Recommended Cache Location | Expected Performance |
|-----------|--------------|---------------------------|---------------------|
| **HPC VMs** | | | |
| HBv3, HBv4 | NVMe SSD | Auto-detected `/mnt/nvme/cvmfs` | ⚡ 400K+ IOPS, < 1ms latency |
| **GPU/AI VMs** | | | |
| NDv4, NDv5 | NVMe SSD | Auto-detected `/mnt/nvme/cvmfs` | ⚡ 400K+ IOPS |
| NCv3, NCasT4v3 | Local SSD | Auto-detected `/mnt/cvmfs` | ✅ 40K+ IOPS |
| NVadsA10v5 | NVMe SSD | Auto-detected `/mnt/nvme/cvmfs` | ⚡ 400K+ IOPS |
| **Storage Optimized** | | | |
| Lsv3, Lasv3 | NVMe SSD | Auto-detected `/mnt/nvme/cvmfs` | ⚡ 400K+ IOPS |
| **General Purpose** | | | |
| Dv5, Ev5 | Local SSD | Auto-detected `/mnt/cvmfs` | ✅ 20K+ IOPS |
| Dv4, Ev4 | Local SSD | Auto-detected `/mnt/cvmfs` | ✅ 20K+ IOPS |


**Multi-Node HPC Clusters:**
- Consider shared storage: `export CVMFS_CACHE_BASE=/shared/scratch/cvmfs`
- Use cluster-wide NFS or Lustre for consistency across compute nodes
- Single cache reduces network traffic for frequently accessed software

## 🔄 Updates & Maintenance

### Updating EESSI Configuration

```bash
# Check for updates
sudo dnf check-update cvmfs-config-eessi  # RHEL-based
sudo apt list --upgradable | grep cvmfs   # Debian-based

# Update packages
sudo dnf update cvmfs-config-eessi        # RHEL-based
sudo apt update && sudo apt upgrade cvmfs # Debian-based

# Reload configuration
sudo cvmfs_config reload
```

### Backup & Recovery

The script automatically backs up existing configurations to:
- `/var/lib/cvmfs-eessi-backup/`

To restore a previous configuration:
```bash
sudo cp /var/lib/cvmfs-eessi-backup/default.local.backup.* /etc/cvmfs/default.local
sudo cvmfs_config reload
```

## 🔗 References & Documentation

- **EESSI Documentation**: https://www.eessi.io/docs/
- **CVMFS Documentation**: https://cvmfs.readthedocs.io/
- **Azure Blog Post**: https://techcommunity.microsoft.com/blog/azurehighperformancecomputingblog/using-gromacs-through-eessi-on-nc-a100-v4/4423933
- **EESSI GitHub**: https://github.com/EESSI/software-layer

## 🆘 Support

For issues and questions:

1. Check the installation log: `/var/log/cvmfs-eessi-install.log`
2. Review CVMFS status: `sudo cvmfs_config stat`
3. Test repository access: `ls /cvmfs/software.eessi.io`
4. Check cache usage: `df -h $(sudo cvmfs_config showconfig | grep CVMFS_CACHE_BASE | cut -d= -f2)`
5. Verify storage detection: Look for "Storage type:" in the installation log

## 📄 License

This project follows the same license as the parent CycleCloud projects repository.