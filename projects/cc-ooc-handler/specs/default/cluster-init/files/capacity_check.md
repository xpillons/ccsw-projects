# Capacity Check Script for Slurm with CycleCloud

A bash script to detect and handle out-of-capacity partitions in Slurm with CycleCloud.

## Overview

This script monitors Azure capacity and automatically:
1. Sets partitions to INACTIVE when capacity failures are detected
2. Restores partitions to UP when capacity becomes available
3. Maintains a state file for integration with the job submit Lua plugin
4. Powers down nodes with CONFIGURING jobs to trigger requeueing
5. Moves pending jobs from INACTIVE partitions to fallback partitions

## Requirements

- `azslurm` CLI tool (from CycleCloud Slurm integration) OR CycleCloud REST API access
- `jq` for JSON parsing
- `curl` (for REST API method)
- `scontrol` and `squeue` (Slurm commands)

## Features

### Capacity Detection
- Two methods available: `azslurm buckets` command or CycleCloud REST API
- The `last_capacity_failure` field indicates capacity issues (number of seconds since last failure)
- Each node array maps to a single VM size
- Logs nodearray name, VM type, and capacity failure status for each nodearray

### Capacity Status Retrieval Methods

The script supports two pluggable methods for retrieving capacity status:

**1. CycleCloud REST API (default):**
- Uses credentials from `/opt/azurehpc/slurm/autoscale.json`
- Queries the cluster status endpoint directly
- Converts `lastCapacityFailure` of `-1.0` to `null` (no failure)

**2. azslurm buckets:**
```bash
azslurm buckets --output-columns nodearray,vm_size,last_capacity_failure --output-format json
```

To switch methods, change the function call in `main()` from `get_capacity_status_rest` to `get_capacity_status`.

### Partition State Management
- If a partition has a capacity failure, set its state to INACTIVE
- If a partition is INACTIVE and `last_capacity_failure` is null (capacity restored), set its state to UP
- Only restores partitions that were marked INACTIVE by this script (preserves manual admin changes)

### State File
- Maintains partition state in `/var/run/slurm/capacity_state.json`
- Tracks which partitions are INACTIVE due to capacity failures
- Records timestamp and reason for each state change
- Used by `job_submit_round_robin.lua` to route jobs to UP partitions only

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

### Pending Job Migration
- After updating partition states, check all INACTIVE partitions with fallback mappings
- Power down nodes with CONFIGURING jobs to trigger job requeueing
- Move pending jobs to the first available UP fallback partition
- Fallback partitions are defined in an external configuration file

### CONFIGURING Job Handling
- Jobs in CONFIGURING state are waiting for cloud nodes to power up
- When a partition is INACTIVE due to capacity failure, these nodes won't start
- The script uses `power_down_force` to immediately release these nodes
- This triggers job requeueing, making jobs eligible for migration to fallback partitions

## Configuration

### Partition Mapping Configuration

Partition mappings are defined in `/etc/slurm/partition_config.conf`, which is shared with the `job_submit_round_robin.lua` plugin:

```
# Partition mapping configuration
# Format: partition: fallback1,fallback2,fallback3

hpc: hpc,htc,gpu
htc: htc,hpc,gpu
gpu: gpu,hpc,htc
```

This means:
- Jobs in INACTIVE `hpc` partition will move to `hpc`, `htc`, or `gpu` (first available UP)
- Jobs in INACTIVE `htc` partition will move to `htc`, `hpc`, or `gpu` (first available UP)

To install the configuration file:
```bash
sudo cp partition_config.conf /etc/slurm/partition_config.conf
```

### State File Location

State file location (can be customized in the script):
```bash
STATE_FILE="/var/run/slurm/capacity_state.json"
```

## Commands Used

Query capacity failures:
```bash
azslurm buckets --output-columns nodearray,vm_size,last_capacity_failure --output-format json
```

Set partition state to INACTIVE:
```bash
scontrol update PartitionName=<partition> State=INACTIVE
```

Set partition state to UP:
```bash
scontrol update PartitionName=<partition> State=UP
```

Move pending job to fallback partition:
```bash
scontrol update jobid=<jobid> partition=<fallback>
```

Get pending jobs in a partition:
```bash
squeue -p <partition> -t PENDING -h -o "%i"
```

Get nodes with CONFIGURING jobs:
```bash
squeue -p <partition> -t CONFIGURING -h -o "%N"
```

Power down a node to trigger job requeue:
```bash
scontrol update nodename=<node> state=power_down_force reason="capacity_failure"
```

## Integration with Job Submit Plugin

The state file is read by `job_submit_round_robin.lua` to:
- Skip INACTIVE partitions when load balancing
- Route new jobs only to UP partitions
- Provide seamless failover without waiting for pending job migration

## Usage

Run manually:
```bash
./capacity_check.sh
```

### Setting up the Cron Job

1. Open the crontab editor:
   ```bash
   sudo crontab -e
   ```

2. Add the following line to run every 5 minutes:
   ```bash
   */5 * * * * /opt/azurehpc/slurm/capacity_check.sh >> /var/log/capacity_check.log 2>&1
   ```

3. Save and exit the editor.

4. Verify the cron job is installed:
   ```bash
   sudo crontab -l
   ```

### Alternative: Systemd Timer

For more control, use a systemd timer instead of cron:

1. Create the service file `/etc/systemd/system/capacity-check.service`:
   ```ini
   [Unit]
   Description=Slurm Capacity Check
   After=slurmctld.service

   [Service]
   Type=oneshot
   ExecStart=/opt/azurehpc/slurm/capacity_check.sh
   StandardOutput=append:/var/log/capacity_check.log
   StandardError=append:/var/log/capacity_check.log
   ```

2. Create the timer file `/etc/systemd/system/capacity-check.timer`:
   ```ini
   [Unit]
   Description=Run Slurm Capacity Check every 5 minutes

   [Timer]
   OnBootSec=1min
   OnUnitActiveSec=5min

   [Install]
   WantedBy=timers.target
   ```

3. Enable and start the timer:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable capacity-check.timer
   sudo systemctl start capacity-check.timer
   ```

4. Check timer status:
   ```bash
   sudo systemctl list-timers capacity-check.timer
   ```

## Logging

The script outputs timestamped log messages including:
- Capacity failure detection
- Partition state changes (INACTIVE/UP)
- State file updates
- Job migrations
- Errors

### Log Rotation

To prevent the log file from growing indefinitely, configure logrotate to manage `/var/log/capacity_check.log`.

1. Copy the provided template file or create the logrotate configuration:
   ```bash
   sudo cp capacity_check.logrotate /etc/logrotate.d/capacity_check
   ```

   Or create `/etc/logrotate.d/capacity_check` manually:
   ```
   /var/log/capacity_check.log {
       size 100M
       rotate 5
       compress
       delaycompress
       missingok
       notifempty
       copytruncate
   }
   ```

2. Save the file and verify the configuration:
   ```bash
   sudo logrotate -d /etc/logrotate.d/capacity_check
   ```

3. Test the rotation manually (optional):
   ```bash
   sudo logrotate -f /etc/logrotate.d/capacity_check
   ```

Configuration options explained:
- `size 100M`: Rotate when log reaches 100MB
- `rotate 5`: Keep up to 5 rotated files
- `compress`: Compress rotated files with gzip
- `delaycompress`: Delay compression of the most recent rotated file
- `missingok`: Don't error if the log file is missing
- `notifempty`: Don't rotate if the log file is empty
- `copytruncate`: Truncate the original log file after creating a copy (avoids restarting the service)
