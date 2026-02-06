# Load-Balanced Partition Assignment for Slurm

A LUA job submission plugin that maps logical partitions to a set of actual partitions and load balances across them.

## Overview

This plugin allows users to submit jobs to a "logical" partition (e.g., `hpc`) which is then automatically mapped and load balanced across multiple actual partitions (e.g., `hpc_1`, `hpc_2`, `hpc_3`).

**Key features:**
- **Partition mapping** - Define logical partitions that map to multiple actual partitions
- **Load balancing** - Jobs are assigned to the least loaded partition in the mapping
- **Capacity-aware** - Integrates with `capacity_check.sh` to skip INACTIVE partitions
- **Transparent to users** - Users submit to familiar partition names

**Balancing strategies:**
- **By job count** - Balance based on total number of jobs
- **By node count** - Balance based on total nodes allocated to jobs

**Job states counted:**
- `pending` - Jobs waiting in the queue
- `running` - Jobs currently executing
- `configuring` - Jobs waiting for nodes to start (e.g., cloud nodes powering up)

## Files

- `job_submit_round_robin.lua` - The Lua plugin script
- `job_submit_prompt.md` - Prompt template for generating similar scripts
- `partition_config.conf` - External configuration file for partition mappings
- `capacity_check.sh` - Script that maintains partition state file
- `capacity_check.md` - Documentation for capacity check script

## Installation

1. Copy the plugin to your Slurm configuration directory:
   ```bash
   sudo cp job_submit_round_robin.lua /etc/slurm/job_submit.lua
   ```

2. Copy the partition configuration file:
   ```bash
   sudo cp partition_config.conf /etc/slurm/partition_config.conf
   ```

3. Edit `/etc/slurm/slurm.conf` and add:
   ```
   JobSubmitPlugins=lua
   ```

4. Restart the Slurm controller:
   ```bash
   sudo systemctl restart slurmctld
   ```

## Configuration

Edit `/etc/slurm/partition_config.conf` to define your partition mappings:

```
# Partition mapping configuration
# Format: partition: fallback1,fallback2,fallback3

hpc: hpc_1,hpc_2,hpc_3
htc: htc_1,htc_2
```

This means:
- Jobs submitted to `hpc` will be load balanced across `hpc_1`, `hpc_2`, `hpc_3`
- Jobs submitted to `htc` will be load balanced across `htc_1`, `htc_2`
- Jobs submitted to any other partition (e.g., `gpu`) will keep their original partition

## How It Works

1. User submits a job with `-p hpc`
2. Plugin looks up `hpc` in `PARTITION_MAPPING`
3. Finds target partitions: `{"hpc_1", "hpc_2", "hpc_3"}`
4. Queries load (jobs or nodes) for each target partition via `squeue`
5. Assigns job to the least loaded partition (e.g., `hpc_2`)

## Balancing Methods

### By Job Count (`get_least_loaded_partition_byjob`)
Counts total jobs (pending + running + configuring) per partition.

```bash
squeue -p <partition> -h -t pending,running,configuring | wc -l
```

### By Node Count (`get_least_loaded_partition_bynode`)
Sums nodes allocated to all jobs per partition.

```bash
squeue -p <partition> -h -t pending,running,configuring -o '%D' | awk '{sum+=$1} END {print sum+0}'
```

## squeue Options Reference

| Option | Description |
|--------|-------------|
| `-p <partition>` | Filter by partition name |
| `-h` | Omit header line |
| `-t pending,running,configuring` | Filter by job states |
| `-o '%D'` | Output only node count |
| `wc -l` | Count lines (jobs) |

## Behavior

- Jobs submitted to a mapped partition are load balanced across target partitions
- Jobs submitted to unmapped partitions keep their original partition
- **INACTIVE partitions are skipped** (based on state file from `capacity_check.sh`)
- When all target partitions have 0 load, the first active partition is used
- When all target partitions are INACTIVE, the original partition is kept
- On error querying a partition, it is deprioritized (assigned high count)

## Integration with capacity_check.sh

Both the Lua plugin and `capacity_check.sh` share the same configuration file (`/etc/slurm/partition_config.conf`) for partition mappings. The plugin also reads partition state from `/var/run/slurm/capacity_state.json`, which is maintained by `capacity_check.sh`.

This allows the system to:
- Skip partitions that are INACTIVE due to capacity failures
- Route jobs only to UP partitions
- Provide seamless failover without external intervention
- Automatically power down nodes with CONFIGURING jobs when capacity fails
- Move pending jobs from INACTIVE partitions to fallback partitions

State file format:
```json
{
  "partitions": {
    "hpc": {
      "state": "INACTIVE",
      "reason": "capacity_failure: 120s ago",
      "updated": "2026-02-04T10:30:00+00:00"
    }
  }
}
```

To enable capacity-aware load balancing:
1. Install partition config: `sudo cp partition_config.conf /etc/slurm/partition_config.conf`
2. Configure and run `capacity_check.sh` via cron
3. Ensure the state file path matches in both scripts (`/var/run/slurm/capacity_state.json`)

## Example

```bash
# Configuration in /etc/slurm/partition_config.conf:
# hpc: hpc_1,hpc_2,hpc_3
# htc: htc_1,htc_2

# Scenario 1: Load balance across HPC partitions
# Assume: hpc_1=5 nodes, hpc_2=2 nodes, hpc_3=8 nodes
sbatch -p hpc job1.slurm  # -> hpc_2 (2 nodes, least loaded)
sbatch -p hpc job2.slurm  # -> hpc_2 (still least loaded)

# Scenario 2: Load balance across HTC partitions
# Assume: htc_1=3 nodes, htc_2=1 node
sbatch -p htc job3.slurm  # -> htc_2 (1 node, least loaded)

# Scenario 3: Unmapped partition
sbatch -p gpu job4.slurm  # -> gpu (no mapping, unchanged)

# Scenario 4: All target partitions empty
# Assume: hpc_1=0, hpc_2=0, hpc_3=0
sbatch -p hpc job5.slurm  # -> hpc_1 (first in list)

# Scenario 5: Some partitions INACTIVE (capacity issue)
# Assume: hpc_1=INACTIVE, hpc_2=UP (2 nodes), hpc_3=UP (5 nodes)
sbatch -p hpc job6.slurm  # -> hpc_2 (hpc_1 skipped, hpc_2 least loaded)

# Scenario 6: All target partitions INACTIVE
# Assume: hpc_1=INACTIVE, hpc_2=INACTIVE, hpc_3=INACTIVE
sbatch -p hpc job7.slurm  # -> hpc (original kept)
```

## Troubleshooting

Check the Slurm controller logs for plugin messages:
```bash
sudo journalctl -u slurmctld | grep -i load-balance
```

Example log messages:
```
Load-balance: Assigning job 'myjob' from user 1000: 'hpc' -> 'hpc_2'
Partition 'gpu' has no load-balance mapping, keeping original for user 1000
All target partitions for 'hpc' have 0 allocated nodes, using 'hpc_1'
Partition 'hpc_1' is INACTIVE (capacity issue), skipping
No active target partitions for 'hpc', keeping original for user 1000
```

## Slurm Lua API Reference

- `slurm.log_info(format, ...)` - Log info level message
- `slurm.log_debug(format, ...)` - Log debug level message
- `slurm.log_error(format, ...)` - Log error level message
- `slurm.SUCCESS` - Return value for successful job submission
- `slurm.FAILURE` - Return value to reject job submission
- `io.popen(cmd)` - Execute shell command and read output

**Note:** `slurm.get_partition_info()` is not available in all Slurm versions, so this plugin uses `squeue` via `io.popen()` for compatibility.
