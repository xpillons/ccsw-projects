#!/bin/bash
MONEO_ROOT=/opt/azurehpc/tools/Moneo
log_file=/var/log/slurmd/moneo_epilog.log
# If Mone is not present, exit silently
if [ ! -d $MONEO_ROOT ]; then
    echo "Moneo not present, exiting silently" >> "$log_file"
    exit 0
fi

# need to create the directory for the job updater script to work
mkdir -pv /tmp/moneo-worker
$MONEO_ROOT/src/worker/jobIdUpdate.sh  "None" > "$log_file" 2>&1

exit 0


