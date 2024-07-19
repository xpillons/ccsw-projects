#!/bin/bash
job_id="$SLURM_JOB_ID"
job_name="$SLURM_JOB_NAME"

MONEO_ROOT=/opt/azurehpc/tools/Moneo
log_file=/var/log/slurmd/moneo_prolog.log

if [ -z "$job_name" ]; then
    job_name='slurm_job'
fi

# If Mone is not present, exit silently
if [ ! -d $MONEO_ROOT ]; then
    echo "Moneo not present, exiting silently" >> "$log_file"
    exit 0
fi

# need to create the directory for the job updater script to work
mkdir -pv /tmp/moneo-worker
# Need to run as sudo to allow monitoring agent to be killed
sudo $MONEO_ROOT/src/worker/jobIdUpdate.sh "${job_name}_${job_id}" > "$log_file" 2>&1

exit 0
