# Pull Request Description

## Summary

This PR introduces a comprehensive Out-of-Capacity (OOC) handler for Slurm clusters deployed on Azure CycleCloud. The solution implements load-balanced partition assignment to handle capacity constraints and improve job scheduling efficiency across multiple Azure regions.

## Type of Change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [x] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Configuration change
- [ ] Refactoring (no functional changes)
- [ ] Other (please describe):

## Related Issues

N/A

## Changes Made

This PR adds a new CycleCloud project `cc-ooc-handler` that provides:

### Core Components

1. **Slurm Job Submit Plugin** (`job_submit_round_robin.lua`)
   - Intercepts job submissions at the Slurm scheduler level
   - Implements load-balanced partition assignment based on node allocation
   - Automatically routes jobs to the least-loaded partition from configured fallback options
   - Skips partitions marked as INACTIVE in the capacity state file

2. **Capacity Check Service** (`capacity_check.sh`)
   - Monitors Azure VM capacity availability across regions
   - Detects out-of-capacity scenarios for configured VM types
   - Updates partition states (ACTIVE/INACTIVE) based on capacity availability
   - Integrates with Slurm partition management

3. **Configuration Management**
   - Partition mapping configuration (`partition_config.conf`)
   - Centralized environment configuration (`ooc-handler-config.env`)
   - Log rotation for capacity monitoring

### Installation Scripts

- `00_install_job_plugin.sh` - Installs and configures the Slurm job submit plugin
- `01_install_capacity_check.sh` - Sets up the capacity monitoring service

### Documentation

- Comprehensive README with installation and configuration instructions
- Inline documentation for the job submit plugin
- Configuration examples and usage guidelines

## How It Works

1. **Partition Mapping**: Define logical-to-physical partition mappings in `/etc/slurm/partition_config.conf`
   ```
   # Example: hpc partition maps to three regional fallbacks
   hpc: hpc_eastus,hpc_westus,hpc_northeu
   ```

2. **Job Submission**: When a job targets a mapped partition:
   - Plugin queries current load across all fallback partitions
   - Assigns job to the partition with lowest node allocation
   - Skips any partitions marked INACTIVE by capacity checker

3. **Capacity Monitoring**: Background service continuously:
   - Checks VM capacity in configured Azure regions
   - Marks partitions INACTIVE when capacity is exhausted
   - Marks partitions ACTIVE when capacity becomes available

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEBUG_LOGGING` | `false` | Enable verbose installation logging |
| `SLURM_CONFIG_DIR` | `/etc/slurm` | Slurm configuration directory |
| `SLURM_STATE_DIR` | `/var/run/slurm` | Directory for capacity state file |

## Testing

- [x] Manual testing performed

### Test Approach

This is a CycleCloud cluster configuration project that:
- Deploys via CycleCloud's cluster-init mechanism
- Integrates with existing Slurm infrastructure
- Requires Azure VM capacity monitoring

Testing validates:
- Script syntax and structure
- Configuration file formats
- Slurm integration points
- Installation workflow

### Test Environment

- OS: Linux (compatible with CycleCloud Slurm clusters)
- Platform: Azure CycleCloud
- Slurm Version: Compatible with Lua job_submit plugin API

## Files Added

- `projects/cc-ooc-handler/README.md` - Project documentation
- `projects/cc-ooc-handler/project.ini` - CycleCloud project configuration
- `projects/cc-ooc-handler/specs/default/cluster-init/files/capacity_check.logrotate` - Log rotation config
- `projects/cc-ooc-handler/specs/default/cluster-init/files/capacity_check.md` - Capacity checker docs
- `projects/cc-ooc-handler/specs/default/cluster-init/files/capacity_check.sh` - Capacity monitoring script
- `projects/cc-ooc-handler/specs/default/cluster-init/files/common.sh` - Shared utility functions
- `projects/cc-ooc-handler/specs/default/cluster-init/files/job_round_robin.md` - Job plugin docs
- `projects/cc-ooc-handler/specs/default/cluster-init/files/job_submit_round_robin.lua` - Slurm job plugin
- `projects/cc-ooc-handler/specs/default/cluster-init/files/ooc-handler-config.env` - Environment config
- `projects/cc-ooc-handler/specs/default/cluster-init/files/partition_config.conf` - Partition mappings
- `projects/cc-ooc-handler/specs/default/cluster-init/scripts/00_install_job_plugin.sh` - Plugin installer
- `projects/cc-ooc-handler/specs/default/cluster-init/scripts/01_install_capacity_check.sh` - Capacity checker installer

## Checklist

- [x] My code follows the project's style guidelines
- [x] I have performed a self-review of my own code
- [x] I have commented my code, particularly in hard-to-understand areas
- [x] I have made corresponding changes to the documentation
- [x] My changes generate no new warnings
- [ ] I have added tests that prove my fix is effective or that my feature works
- [ ] New and existing unit tests pass locally with my changes

## Screenshots

N/A - This is a backend service/infrastructure component with no UI.

## Additional Notes

### Benefits

- **Improved Job Success Rates**: Automatically routes jobs away from capacity-constrained regions
- **Better Resource Utilization**: Distributes workload across available capacity
- **Reduced Manual Intervention**: Automatic handling of OOC scenarios
- **Multi-Region Support**: Seamlessly works across Azure regions

### Deployment

This project integrates with Azure CycleCloud's cluster-init mechanism and will be automatically deployed when:
1. The project is uploaded to CycleCloud
2. Referenced in a cluster template
3. The cluster is started

### Post-Installation Requirements

After deployment, administrators should:
1. Configure partition mappings in `/etc/slurm/partition_config.conf`
2. Restart `slurmctld` to activate the job submit plugin
3. Verify capacity monitoring is running
4. Monitor logs in `/var/log/slurm/capacity_check.log`
