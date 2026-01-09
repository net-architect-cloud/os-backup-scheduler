#!/bin/bash
set -euo pipefail

############################################################################
#                                                                          #
#                 OpenStack Automatic Backup Script                        #
#                                                                          #
#  Automated backup solution for OpenStack instances and volumes           #
#  with configurable retention policy.                                     #
#                                                                          #
#  Repository: https://github.com/net-architect-cloud/os-backup-scheduler  #
#  License: Apache-2.0                                                     #
############################################################################

# Specify the amount of days before the backup should be removed
retentionDays="${RETENTION_DAYS:-14}"

# Use snapshot method for volume backups (avoids --force which can get stuck)
# Set to "true" to use snapshot -> volume -> backup method
# Set to "false" to use direct backup with --force
useSnapshotMethod="${USE_SNAPSHOT_METHOD:-true}"

# Timeout for waiting on resources (in seconds)
resourceTimeout="${RESOURCE_TIMEOUT:-1800}"  # 30 minutes default
pollInterval=10  # seconds between status checks

# Counters for summary
instances_backed_up=0
volumes_backed_up=0
instance_backups_deleted=0
volume_backups_deleted=0
snapshots_created=0
snapshots_cleaned=0
temp_volumes_created=0
temp_volumes_cleaned=0
errors=0


###############################
# DO NOT EDIT BELOW THIS LINE #
###############################

# Function to wait for a resource to reach a specific status 
wait_for_status() {
    local resource_type="$1"  # volume, snapshot, backup
    local resource_id="$2"
    local target_status="$3"
    local timeout="$4"
    local elapsed=0
    
    echo "Waiting for ${resource_type} ${resource_id} to reach status '${target_status}'..."
    
    while [ $elapsed -lt $timeout ]; do
        local current_status
        case "$resource_type" in
            "volume")
                current_status=$(openstack volume show "$resource_id" -f value -c status 2>/dev/null || echo "error")
                ;;
            "snapshot")
                current_status=$(openstack volume snapshot show "$resource_id" -f value -c status 2>/dev/null || echo "error")
                ;;
            "backup")
                current_status=$(openstack volume backup show "$resource_id" -f value -c status 2>/dev/null || echo "error")
                ;;
            *)
                echo "Unknown resource type: ${resource_type}"
                return 1
                ;;
        esac
        
        if [ "$current_status" == "$target_status" ]; then
            echo "${resource_type} ${resource_id} reached status '${target_status}'"
            return 0
        elif [ "$current_status" == "error" ] || [ "$current_status" == "error_deleting" ]; then
            echo "Error: ${resource_type} ${resource_id} is in error state: ${current_status}"
            return 1
        fi
        
        sleep $pollInterval
        elapsed=$((elapsed + pollInterval))
    done
    
    echo "Timeout: ${resource_type} ${resource_id} did not reach '${target_status}' within ${timeout}s (current: ${current_status})"
    return 1
}

# Function to cleanup temporary resources
cleanup_temp_resources() {
    local temp_volume_id="$1"
    local temp_snapshot_id="$2"
    
    # Cleanup temporary volume
    if [ -n "$temp_volume_id" ]; then
        echo "Cleaning up temporary volume: ${temp_volume_id}"
        if openstack volume delete "$temp_volume_id" 2>/dev/null; then
            ((temp_volumes_cleaned++)) || true
        else
            echo "Warning: Failed to delete temporary volume ${temp_volume_id}"
        fi
    fi
    
    # Cleanup snapshot
    if [ -n "$temp_snapshot_id" ]; then
        echo "Cleaning up temporary snapshot: ${temp_snapshot_id}"
        if openstack volume snapshot delete "$temp_snapshot_id" 2>/dev/null; then
            ((snapshots_cleaned++)) || true
        else
            echo "Warning: Failed to delete temporary snapshot ${temp_snapshot_id}"
        fi
    fi
}

# Function to create volume backup using snapshot method
create_backup_via_snapshot() {
    local volume_id="$1"
    local volume_name="$2"
    local backup_name="$3"
    
    local temp_snapshot_id=""
    local temp_volume_id=""
    local backup_success=false
    
    # Step 1: Create snapshot of the volume (--force needed for in-use volumes)
    echo "Step 1/5: Creating snapshot of volume ${volume_name}..."
    local snapshot_name="temp_snap_${timestamp}_${volume_name}"
    local snapshot_output
    snapshot_output=$(openstack volume snapshot create --volume "$volume_id" --force -f json "$snapshot_name" 2>&1) || {
        echo "Error: Failed to create snapshot for volume ${volume_name}: ${snapshot_output}"
        return 1
    }
    temp_snapshot_id=$(echo "$snapshot_output" | jq -r '.id')
    ((snapshots_created++)) || true
    echo "Snapshot created: ${temp_snapshot_id}"
    
    # Step 2: Wait for snapshot to be available
    echo "Step 2/5: Waiting for snapshot to be available..."
    if ! wait_for_status "snapshot" "$temp_snapshot_id" "available" "$resourceTimeout"; then
        echo "Error: Snapshot did not become available"
        cleanup_temp_resources "" "$temp_snapshot_id"
        return 1
    fi
    
    # Step 3: Create volume from snapshot
    echo "Step 3/5: Creating temporary volume from snapshot..."
    local temp_volume_name="temp_vol_${timestamp}_${volume_name}"
    local volume_output
    volume_output=$(openstack volume create --snapshot "$temp_snapshot_id" -f json "$temp_volume_name" 2>&1) || {
        echo "Error: Failed to create volume from snapshot: ${volume_output}"
        cleanup_temp_resources "" "$temp_snapshot_id"
        return 1
    }
    temp_volume_id=$(echo "$volume_output" | jq -r '.id')
    ((temp_volumes_created++)) || true
    echo "Temporary volume created: ${temp_volume_id}"
    
    # Step 4: Wait for volume to be available
    echo "Step 4/5: Waiting for temporary volume to be available..."
    if ! wait_for_status "volume" "$temp_volume_id" "available" "$resourceTimeout"; then
        echo "Error: Temporary volume did not become available"
        cleanup_temp_resources "$temp_volume_id" "$temp_snapshot_id"
        return 1
    fi
    
    # Step 5: Create backup from temporary volume (no --force needed)
    echo "Step 5/5: Creating backup from temporary volume..."
    local backup_output
    backup_output=$(openstack volume backup create "$temp_volume_id" --name "$backup_name" -f json 2>&1) && backup_success=true || backup_success=false
    
    if $backup_success; then
        local backup_id
        backup_id=$(echo "$backup_output" | jq -r '.id')
        echo "Backup initiated: ${backup_id}"
        
        # Wait for backup to complete before cleanup
        echo "Waiting for backup to complete before cleanup..."
        if wait_for_status "backup" "$backup_id" "available" "$resourceTimeout"; then
            echo "Backup completed successfully: ${backup_name}"
            cleanup_temp_resources "$temp_volume_id" "$temp_snapshot_id"
            return 0
        else
            echo "Warning: Backup may still be in progress, cleaning up temporary resources anyway"
            cleanup_temp_resources "$temp_volume_id" "$temp_snapshot_id"
            return 0  # Backup was initiated, consider it a success
        fi
    else
        echo "Error: Failed to create backup: ${backup_output}"
        cleanup_temp_resources "$temp_volume_id" "$temp_snapshot_id"
        return 1
    fi
}

# Set Variables
date=$(date +"%Y-%m-%d")
timestamp=$(date +"%Y-%m-%d_%H%M%S")
expireTime="$retentionDays days ago"
epochExpire=$(date --date "$expireTime" +'%s')

# Check required OpenStack environment variables
required_vars=("OS_AUTH_URL" "OS_USERNAME" "OS_PASSWORD" "OS_PROJECT_NAME")
missing_vars=()

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "Error: Missing required environment variables: ${missing_vars[*]}"
    echo "Required variables: OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME"
    echo "Optional variables: OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME, OS_REGION_NAME, OS_IDENTITY_API_VERSION"
    exit 1
fi

# Set default values for optional variables
export OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}"
export OS_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME:-default}"
export OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}"

# Verify OpenStack connectivity
echo "Verifying OpenStack connectivity..."
if ! openstack token issue > /dev/null 2>&1; then
    echo "Error: Failed to authenticate with OpenStack. Please check your credentials."
    exit 1
fi
echo "Authentication successful."

##########################
#    Backup Creation     #
##########################

# Announce backup creation
printf '%s\n' "----------------------------------------"
echo "Creating instance backups!"

# Get all instances and check their properties
while IFS='|' read -r instance instanceName; do
    # Skip empty lines
    [[ -z "$instance" ]] && continue
    
    # Get full instance details (requires separate API call)
    instanceData=$(openstack server show "$instance" -f json)
    properties=$(echo "$instanceData" | jq -r '.properties // {} | tostring')
    imageField=$(echo "$instanceData" | jq -r '.image // ""')
    volumesAttached=$(echo "$instanceData" | jq -r '.volumes_attached // []')
    
    # Check if the autoBackup is set to true (supports JSON format)
    if [[ $properties =~ "autoBackup".*"true" ]]; then
        # Detect boot-from-volume vs boot-from-image
        # Boot-from-volume: image is empty/null and volumes_attached is not empty
        # Boot-from-image: image contains an image name/ID
        
        if [[ "$imageField" == *"booted from volume"* || -z "$imageField" || "$imageField" == "null" ]] && [[ "$volumesAttached" != "[]" ]]; then
            # Boot-from-volume: skip here, the boot volume should have autoBackup metadata and will be handled in volume section
            echo "Skipping instance ${instanceName}: boot-from-volume (backup the volume directly with autoBackup metadata)"
            continue
        else
            # Boot-from-image: create server backup (image snapshot)
            # Check if instance is already being backed up (task_state)
            taskState=$(echo "$instanceData" | jq -r '.["OS-EXT-STS:task_state"] // "None"')
            if [[ "$taskState" != "None" && "$taskState" != "null" && -n "$taskState" ]]; then
                echo "Skipping instance ${instanceName}: instance is busy (task_state: ${taskState})"
                continue
            fi
            echo "Instance ${instanceName} is boot-from-image, creating server backup"
            backupError=$(openstack server backup create "${instance}" --name "autoBackup_${timestamp}_${instanceName}" --type daily --rotate "${retentionDays}" 2>&1) && backupSuccess=true || backupSuccess=false
            if $backupSuccess; then
                ((instances_backed_up++)) || true
            else
                echo "Error: Failed to create backup for instance ${instanceName}: ${backupError}"
                ((errors++)) || true
            fi
        fi
    else
        echo "Skipping instance (no autoBackup metadata): ${instanceName} - ${instance}"
    fi
done < <(openstack server list -f json | jq -r '.[] | [.ID, .Name] | join("|")')

# Announce volume backup creation
printf '%s\n' "----------------------------------------"
echo "Creating volume backups!"

# Get all volumes and check their properties
while IFS='|' read -r volume volumeName; do
    # Skip empty lines
    [[ -z "$volume" ]] && continue
    
    # Get volume details (requires separate API call)
    volumeData=$(openstack volume show "$volume" -f json)
    properties=$(echo "$volumeData" | jq -r '.properties // {} | tostring')
    
    # If volume has no name, try to get attached instance name or use volume ID
    if [[ -z "$volumeName" ]]; then
        attachedTo=$(echo "$volumeData" | jq -r '.attachments[0].server_id // empty')
        if [[ -n "$attachedTo" ]]; then
            # Get instance name
            instanceName=$(openstack server show "$attachedTo" -f value -c name 2>/dev/null || echo "")
            if [[ -n "$instanceName" ]]; then
                volumeName="${instanceName}_vol"
            else
                volumeName="${volume:0:8}"
            fi
        else
            # Use first 8 chars of volume ID
            volumeName="${volume:0:8}"
        fi
    fi
    
    # Check if the autoBackup is set to true (supports JSON format)
    if [[ $properties =~ "autoBackup".*"true" ]]; then
        echo "Creating backup of volume: ${volumeName} - ${volume}"
        # Check if volume is already being backed up or in an unstable state
        volumeStatus=$(echo "$volumeData" | jq -r '.status // "unknown"')
        if [[ "$volumeStatus" == "backing-up" || "$volumeStatus" == "creating" || "$volumeStatus" == "deleting" || "$volumeStatus" == "restoring-backup" ]]; then
            echo "Error: Volume ${volumeName} is in '${volumeStatus}' state - cannot create backup"
            ((errors++)) || true
            continue
        fi
        
        backupName="autoBackup_${timestamp}_${volumeName}"
        
        if [[ "$useSnapshotMethod" == "true" && "$volumeStatus" == "in-use" ]]; then
            # Use snapshot method for attached volumes (avoids --force which can get stuck)
            echo "Using snapshot method for attached volume ${volumeName}"
            if create_backup_via_snapshot "$volume" "$volumeName" "$backupName"; then
                ((volumes_backed_up++)) || true
            else
                echo "Error: Snapshot-based backup failed for volume ${volumeName}"
                ((errors++)) || true
            fi
        elif [[ "$volumeStatus" == "available" ]]; then
            # Direct backup for detached volumes (no --force needed)
            echo "Creating direct backup for detached volume ${volumeName}"
            backupError=$(openstack volume backup create "${volume}" --name "$backupName" 2>&1) && backupSuccess=true || backupSuccess=false
            if $backupSuccess; then
                ((volumes_backed_up++)) || true
            else
                echo "Error: Failed to create backup for volume ${volumeName}: ${backupError}"
                ((errors++)) || true
            fi
        else
            # Fallback to --force method if snapshot method is disabled
            echo "Using --force method for volume ${volumeName} (status: ${volumeStatus})"
            backupError=$(openstack volume backup create "${volume}" --name "$backupName" --force 2>&1) && backupSuccess=true || backupSuccess=false
            if $backupSuccess; then
                ((volumes_backed_up++)) || true
            else
                echo "Error: Failed to create backup for volume ${volumeName}: ${backupError}"
                ((errors++)) || true
            fi
        fi
    else
        echo "Skipping volume (no autoBackup metadata): ${volumeName} - ${volume}"
    fi
done < <(openstack volume list -f json | jq -r '.[] | [.ID, .Name] | join("|")')

##########################
#    Backup Deletion     #
##########################

# Announce backup deletion
printf '%s\n' "----------------------------------------"
echo "Deleting old instance backups!"

# Get all backup images and check their creation date
while IFS='|' read -r image imageName; do
    # Skip empty lines
    [[ -z "$image" ]] && continue
    
    # Skip if not an autoBackup image
    [[ ! "$imageName" =~ ^autoBackup ]] && continue
    
    # Get creation date from image show (not available in list)
    createdAt=$(openstack image show "$image" -f value -c created_at 2>/dev/null) || continue
    
    # Get the epochtimestamp from when the backup was created
    epochCreated=$(date --date "${createdAt}" "+%s" 2>/dev/null) || continue

    # If the backup is older than the above specified in variable expireTime delete the backup
    if [ "$epochCreated" -lt "$epochExpire" ]; then
        echo "Deleting old instance backup: ${imageName} (${image})"
        deleteError=$(openstack image delete "$image" 2>&1) && deleteSuccess=true || deleteSuccess=false
        if $deleteSuccess; then
            ((instance_backups_deleted++)) || true
        else
            echo "Error: Failed to delete instance backup ${image}: ${deleteError}"
            ((errors++)) || true
        fi
    else
        echo "Skipping instance backup: ${imageName}"
    fi
done < <(openstack image list -f json | jq -r '.[] | [.ID, .Name] | join("|")')

# Announce volume backup deletion
printf '%s\n' "----------------------------------------"
echo "Deleting old volume backups!"

# Get all volume backups with their creation date in a single API call
while IFS='|' read -r vbackup vbackupName createdAt; do
    # Skip empty lines
    [[ -z "$vbackup" ]] && continue
    
    # Skip if not an autoBackup
    [[ ! "$vbackupName" =~ ^autoBackup ]] && continue
    
    # Get the epochtimestamp from when the backup was created
    epochCreated=$(date --date "${createdAt}" "+%s" 2>/dev/null) || continue

    # If the backup is older than the above specified in variable expireTime delete the backup
    if [ "$epochCreated" -lt "$epochExpire" ]; then
        echo "Deleting old volume backup: ${vbackupName} (${vbackup})"
        deleteError=$(openstack volume backup delete "$vbackup" 2>&1) && deleteSuccess=true || deleteSuccess=false
        if $deleteSuccess; then
            ((volume_backups_deleted++)) || true
        else
            echo "Error: Failed to delete volume backup ${vbackup}: ${deleteError}"
            ((errors++)) || true
        fi
    else
        echo "Skipping volume backup: ${vbackupName}"
    fi
done < <(openstack volume backup list -f json 2>/dev/null | jq -r '.[] | [.ID, .Name, ."Created At" // .created_at // ""] | join("|")' 2>/dev/null || true)

# Print summary
printf '%s\n' "----------------------------------------"
echo "SUMMARY"
printf '%s\n' "----------------------------------------"
echo "Instances backed up: ${instances_backed_up}"
echo "Volumes backed up:   ${volumes_backed_up}"
echo "Instance backups deleted: ${instance_backups_deleted}"
echo "Volume backups deleted:   ${volume_backups_deleted}"
if [[ "$useSnapshotMethod" == "true" ]]; then
    echo "Snapshots created/cleaned: ${snapshots_created}/${snapshots_cleaned}"
    echo "Temp volumes created/cleaned: ${temp_volumes_created}/${temp_volumes_cleaned}"
fi
echo "Errors: ${errors}"
printf '%s\n' "----------------------------------------"

# Generate GitHub Actions Job Summary if running in CI
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ "$errors" -gt 0 ]; then
        status_icon="❌"
        status_text="Failed"
    else
        status_icon="✅"
        status_text="Success"
    fi
    
    cat >> "$GITHUB_STEP_SUMMARY" <<EOF
## ${status_icon} Backup Report - Region: ${OS_REGION_NAME:-unknown}

| Metric | Count |
|--------|-------|
| 🖥️ Instances backed up | ${instances_backed_up} |
| 💾 Volumes backed up | ${volumes_backed_up} |
| 🗑️ Instance backups deleted | ${instance_backups_deleted} |
| 🗑️ Volume backups deleted | ${volume_backups_deleted} |
| 📸 Snapshots (created/cleaned) | ${snapshots_created}/${snapshots_cleaned} |
| 📦 Temp volumes (created/cleaned) | ${temp_volumes_created}/${temp_volumes_cleaned} |
| ⚠️ Errors | ${errors} |

**Status:** ${status_text}  
**Date:** ${date}  
**Retention:** ${retentionDays} days

---
EOF
fi

if [ "$errors" -gt 0 ]; then
    echo "Finished with ${errors} error(s)!"
    exit 1
else
    echo "Finished successfully!"
    exit 0
fi