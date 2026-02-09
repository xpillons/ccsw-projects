--[[
    Slurm Job Submit Plugin - Load-Balanced Partition Assignment
    
    This LUA script assigns jobs to partitions based on current job count.
    When a job specifies a partition that has a mapping defined, it load balances
    across the mapped partitions (e.g., "hpc" -> {"hpc_1", "hpc_2", "hpc_3"}).
    Uses squeue to query job counts.

    Installation:
    1. Copy this file to /etc/slurm/job_submit.lua
    2. Copy partition_config.conf to /etc/slurm/partition_config.conf
    3. Add to slurm.conf: JobSubmitPlugins=lua
    4. Restart slurmctld: systemctl restart slurmctld

    Configuration:
    - Edit /etc/slurm/partition_config.conf to define partition mappings
--]]

-- Path to external partition configuration file (shared with capacity_check.sh)
PARTITION_CONFIG_FILE = "/etc/slurm/partition_config.conf"

-- Partition mapping table (loaded from config file)
PARTITION_MAPPING = {}

-- Slurm log levels
SLURM_ERROR = 0
SLURM_INFO = 6
SLURM_DEBUG = 7

-- Path to partition state file maintained by capacity_check.sh
PARTITION_STATE_FILE = "/var/run/slurm/capacity_state.json"

--[[
    Load partition mappings from config file.
    Format: partition: fallback1,fallback2,fallback3
    Lines starting with # are comments, empty lines are ignored.
--]]
function load_partition_config()
    local file = io.open(PARTITION_CONFIG_FILE, "r")
    if file == nil then
        slurm.log_error("Failed to open partition config file: %s", PARTITION_CONFIG_FILE)
        return false
    end
    
    for line in file:lines() do
        -- Remove carriage returns (Windows line endings)
        line = string.gsub(line, "\r", "")
        -- Skip comments and empty lines
        if not string.match(line, "^%s*#") and not string.match(line, "^%s*$") then
            -- Parse "partition: fallback1,fallback2,fallback3"
            local partition, fallbacks = string.match(line, "^%s*([^:]+)%s*:%s*(.+)%s*$")
            if partition and fallbacks then
                partition = string.gsub(partition, "^%s*(.-)%s*$", "%1")  -- trim
                local partitions = {}
                for part in string.gmatch(fallbacks, "([^,]+)") do
                    part = string.gsub(part, "^%s*(.-)%s*$", "%1")  -- trim
                    table.insert(partitions, part)
                end
                if #partitions > 0 then
                    PARTITION_MAPPING[partition] = partitions
                    slurm.log_debug("Loaded partition mapping: %s -> %d targets", partition, #partitions)
                end
            end
        end
    end
    
    file:close()
    slurm.log_info("Loaded partition mappings from %s", PARTITION_CONFIG_FILE)
    return true
end

-- Load partition config at plugin initialization
load_partition_config()

--[[
    Get the list of target partitions for a given partition.
    Returns the mapped partitions if a mapping exists, nil otherwise.
--]]
function get_partition_targets(partition_name)
    if partition_name == nil then
        return nil
    end
    return PARTITION_MAPPING[partition_name]
end

--[[
    Read the partition state file.
    The state file is maintained by capacity_check.sh and tracks partitions
    that are INACTIVE due to capacity failures.
    Returns the file content as a string, or nil if the file doesn't exist or is empty.
    This should be called once per job submission to avoid repeated I/O.
    The content is then passed to is_partition_inactive() for pattern matching.
--]]
function read_partition_state()
    local file = io.open(PARTITION_STATE_FILE, "r")
    if file == nil then
        -- State file doesn't exist, assume all partitions are UP
        return nil
    end
    
    local content = file:read("*a")
    file:close()
    
    if content == nil or content == "" then
        return nil
    end
    
    return content
end

--[[
    Check if a partition is marked as INACTIVE in the cached state content.
    Takes the pre-read state file content to avoid repeated I/O operations.
    Returns true if partition is INACTIVE, false otherwise.
--]]
function is_partition_inactive(partition_name, state_content)
    if state_content == nil then
        -- No state content, assume all partitions are UP
        return false
    end
    
    -- Simple pattern matching to check if partition is in the state file
    -- Looking for: "partition_name": {"state": "INACTIVE"
    local pattern = '"' .. partition_name .. '":%s*{[^}]*"state":%s*"INACTIVE"'
    if string.match(state_content, pattern) then
        slurm.log_debug("Partition '%s' is marked INACTIVE in state file", partition_name)
        return true
    end
    
    return false
end

--[[
    Filter target partitions to only include those that are UP (not INACTIVE).
    Uses the pre-read state content to avoid repeated I/O operations.
    Returns a table of active partitions.
--]]
function get_active_partitions(target_partitions, state_content)
    local active = {}
    for _, partition in ipairs(target_partitions) do
        if not is_partition_inactive(partition, state_content) then
            table.insert(active, partition)
        else
            slurm.log_info("Partition '%s' is INACTIVE (capacity issue), skipping", partition)
        end
    end
    return active
end

--[[
    Get the total job count for a partition using squeue.
    Returns the total number of jobs (pending, running, or configuring) in the partition.
    Configuring state includes jobs waiting for nodes to start.
--]]
function get_partition_job_count(partition_name)
    -- Use full path as PATH may be limited in slurmctld context
    local cmd = string.format("/usr/bin/squeue -p %s -h -t pending,running,configuring 2>/dev/null | wc -l", partition_name)
    local handle = io.popen(cmd)
    
    if handle == nil then
        slurm.log_error("Failed to execute squeue for partition %s", partition_name)
        return 999999  -- Return high count on error to deprioritize
    end
    
    local result = handle:read("*a")
    handle:close()
    
    local total_jobs = tonumber(result) or 0
    slurm.log_debug("Partition '%s': %d total jobs", partition_name, total_jobs)
    return total_jobs
end

--[[
    Get the partition with the least number of total jobs from a list of target partitions.
    Returns the partition name with the lowest job count.
    If all partitions have 0 jobs, returns the first partition in the list.
--]]
function get_least_loaded_partition_byjob(target_partitions, original_partition)
    local min_jobs = nil
    local min_partition = target_partitions[1]
    local all_zero = true
    
    for _, partition in ipairs(target_partitions) do
        local jobs = get_partition_job_count(partition)
        
        if jobs > 0 then
            all_zero = false
        end
        
        if min_jobs == nil or jobs < min_jobs then
            min_jobs = jobs
            min_partition = partition
        end
    end
    
    -- If all partitions have 0 jobs, return first target partition
    if all_zero then
        slurm.log_info("All target partitions for '%s' have 0 jobs, using '%s'", 
                       original_partition or "(default)", min_partition)
        return min_partition
    end
    
    slurm.log_info("Least loaded partition (by job count) for '%s': '%s' with %d total jobs", 
                   original_partition or "(default)", min_partition, min_jobs or 0)
    return min_partition
end

--[[
    Get the total allocated nodes for a partition using squeue.
    Returns the sum of nodes allocated to all jobs (pending, running, or configuring).
--]]
function get_partition_allocated_nodes(partition_name)
    -- Use full path as PATH may be limited in slurmctld context
    local cmd = string.format("/usr/bin/squeue -p %s -h -t pending,running,configuring -o '%%D' 2>/dev/null | awk '{sum+=$1} END {print sum+0}'", partition_name)
    local handle = io.popen(cmd)
    
    if handle == nil then
        slurm.log_error("Failed to execute squeue for partition %s", partition_name)
        return 999999  -- Return high count on error to deprioritize
    end
    
    local result = handle:read("*a")
    handle:close()
    
    local total_nodes = tonumber(result) or 0
    slurm.log_debug("Partition '%s': %d allocated nodes", partition_name, total_nodes)
    return total_nodes
end

--[[
    Get the partition with the least number of allocated nodes from a list of target partitions.
    Returns the partition name with the lowest node allocation.
    If all partitions have 0 nodes, returns the first partition in the list.
--]]
function get_least_loaded_partition_bynode(target_partitions, original_partition)
    local min_nodes = nil
    local min_partition = target_partitions[1]
    local all_zero = true
    
    for _, partition in ipairs(target_partitions) do
        local nodes = get_partition_allocated_nodes(partition)
        
        if nodes > 0 then
            all_zero = false
        end
        
        if min_nodes == nil or nodes < min_nodes then
            min_nodes = nodes
            min_partition = partition
        end
    end
    
    -- If all partitions have 0 allocated nodes, return first target partition
    if all_zero then
        slurm.log_info("All target partitions for '%s' have 0 allocated nodes, using '%s'", 
                       original_partition or "(default)", min_partition)
        return min_partition
    end
    
    slurm.log_info("Least loaded partition (by node count) for '%s': '%s' with %d allocated nodes", 
                   original_partition or "(default)", min_partition, min_nodes or 0)
    return min_partition
end

--[[
    Main job_submit function called by Slurm for each job submission.
    
    Arguments:
        job_desc   - Job descriptor table (modifiable)
        part_list  - List of partitions (modifiable)
        submit_uid - UID of the submitting user
    
    Returns:
        slurm.SUCCESS - Job submission proceeds
        slurm.FAILURE - Job submission is rejected
        slurm.ERROR   - An error occurred
--]]
function slurm_job_submit(job_desc, part_list, submit_uid)
    -- Get the target partitions for the requested partition
    local target_partitions = get_partition_targets(job_desc.partition)
    
    -- If no mapping exists for this partition, keep original and skip load balancing
    if target_partitions == nil then
        slurm.log_info("Partition '%s' has no load-balance mapping, keeping original for user %d", 
                       job_desc.partition or "(default)", submit_uid)
        return slurm.SUCCESS
    end
    
    -- Read the partition state file once for this job submission
    -- This avoids repeated I/O operations when checking multiple partitions
    local state_content = read_partition_state()
    
    -- Filter to only active partitions (not marked INACTIVE in state file)
    local active_partitions = get_active_partitions(target_partitions, state_content)
    
    -- If no active partitions, keep original partition
    if #active_partitions == 0 then
        slurm.log_info("No active target partitions for '%s', keeping original for user %d", 
                       job_desc.partition or "(default)", submit_uid)
        return slurm.SUCCESS
    end
    
    -- Get the least loaded partition by node count from the active target partitions
    local partition = get_least_loaded_partition_bynode(active_partitions, job_desc.partition)
    
    -- Update partition to the least loaded target
    slurm.log_info("Load-balance: Assigning job '%s' from user %d: '%s' -> '%s'", 
                   job_desc.name or "(unnamed)", submit_uid, job_desc.partition, partition)
    job_desc.partition = partition
    
    return slurm.SUCCESS
end

--[[
    Job modify function - called when jobs are modified.
    We don't alter partition assignments on job modifications.
--]]
function slurm_job_modify(job_desc, job_rec, part_list, modify_uid)
    return slurm.SUCCESS
end

slurm.log_info("Load-balanced job submit plugin loaded with partition mappings")
