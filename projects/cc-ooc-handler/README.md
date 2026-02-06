# cc-ooc-handler

CycleCloud project for handling Out-of-Capacity (OOC) scenarios in Slurm clusters using load-balanced partition assignment.

## Overview

This project installs and configures a Slurm `job_submit` Lua plugin that intercepts job submissions and implements load-balanced partition assignment. When a job is submitted to a partition with configured fallbacks, the plugin automatically routes the job to the least-loaded partition, helping distribute workload and handle capacity constraints.

## Features

- Load-balanced partition assignment based on node allocation
- Partition mapping configuration for fallback routing
- Integration with capacity state tracking
- Automatic skipping of partitions marked as INACTIVE

## How It Works

1. Define partition mappings in `/etc/slurm/partition_config.conf`
2. When a job targets a mapped partition, the plugin queries current load
3. The job is assigned to the least-loaded fallback partition
4. Partitions marked INACTIVE in the state file are skipped

## Configuration

### Partition Mappings

Edit `/etc/slurm/partition_config.conf` to define partition mappings:

```
# Format: partition: fallback1,fallback2,fallback3
hpc: hpc_eastus,hpc_westus,hpc_northeu
gpu: gpu_eastus,gpu_westus
```

### Installation Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEBUG_LOGGING` | `false` | Enable verbose installation logging |
| `SLURM_CONFIG_DIR` | `/etc/slurm` | Slurm configuration directory |
| `SLURM_STATE_DIR` | `/var/run/slurm` | Directory for capacity state file |

## Installation

The plugin is automatically installed by CycleCloud cluster-init. Manual installation:

```bash
sudo /opt/cycle/jetpack/system/embedded/bin/bash \
    /opt/cycle/jetpack/specs/default/cluster-init/scripts/00_install.sh
```

## Files Installed

- `/etc/slurm/job_submit.lua` - Main plugin script
- `/etc/slurm/partition_config.conf` - Partition mapping configuration
- `/var/run/slurm/` - State directory for capacity tracking

## Post-Installation

After installation, restart slurmctld to load the plugin:

```bash
systemctl restart slurmctld
```

Verify the plugin is loaded:

```bash
scontrol show config | grep JobSubmitPlugins
```

## Customization

To customize the plugin behavior:

1. Edit partition mappings in `/etc/slurm/partition_config.conf`
2. Provide a custom `partition_config.conf` in `specs/default/cluster-init/files/`
