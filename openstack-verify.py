#!/usr/bin/env python3
"""
OpenStack Backup Verification Script

Verifies backup completion, detects stuck/failed backups, and cleans up
temporary resources left by async backup mode. Single authenticated session
via openstacksdk — no per-command subprocess overhead.

Repository: https://github.com/net-architect-cloud/os-backup-scheduler
License: Apache-2.0
"""

import datetime
import os
import sys

import openstack
import openstack.exceptions


############################################################################
#  Configuration
############################################################################

REGION_NAME  = os.environ.get('OS_REGION_NAME', 'unknown')
SUMMARY_FILE = os.environ.get('GITHUB_STEP_SUMMARY', '/dev/null')
OUTPUT_FILE  = os.environ.get('GITHUB_OUTPUT', '/dev/null')


############################################################################
#  Helpers
############################################################################

def summary(*lines: str):
    """Append lines to GitHub Step Summary."""
    with open(SUMMARY_FILE, 'a') as f:
        for line in lines:
            f.write(line + '\n')


def set_output(key: str, value):
    with open(OUTPUT_FILE, 'a') as f:
        f.write(f"{key}={value}\n")


def get_connection() -> openstack.connection.Connection:
    required = ['OS_AUTH_URL', 'OS_USERNAME', 'OS_PASSWORD', 'OS_PROJECT_NAME']
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        print(f"Error: Missing required environment variables: {' '.join(missing)}")
        print("Required: OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME")
        print("Optional: OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME, OS_REGION_NAME, OS_IDENTITY_API_VERSION")
        sys.exit(1)

    conn = openstack.connect(
        auth_url=os.environ['OS_AUTH_URL'],
        username=os.environ['OS_USERNAME'],
        password=os.environ['OS_PASSWORD'],
        project_name=os.environ['OS_PROJECT_NAME'],
        user_domain_name=os.environ.get('OS_USER_DOMAIN_NAME', 'Default'),
        project_domain_name=os.environ.get('OS_PROJECT_DOMAIN_NAME', 'default'),
        identity_api_version=os.environ.get('OS_IDENTITY_API_VERSION', '3'),
        region_name=os.environ.get('OS_REGION_NAME'),
    )

    print("Verifying OpenStack connectivity...")
    try:
        conn.authorize()
    except openstack.exceptions.SDKException as e:
        print(f"Error: Failed to authenticate with OpenStack: {e}")
        sys.exit(1)
    print("Authentication successful.")
    return conn


def _parse_date(ts: str) -> str:
    """Return YYYY-MM-DD from an ISO timestamp string."""
    return (ts or '')[:10]


############################################################################
#  Instance backup verification
############################################################################

def check_instance_backups(all_images: list, today: str) -> dict:
    print('-' * 40)
    print("Checking instance backups!")

    summary("### Instance Backups (Images) - Today", "")

    counts = dict(active=0, stuck=0, error=0, stuck_old=0)

    images = all_images

    for image in images:
        name = image.name or ''
        if not name.startswith('autoBackup'):
            continue

        status = image.status or ''
        created_at = getattr(image, 'created_at', '') or ''
        is_today = _parse_date(created_at) == today

        if is_today:
            if status == 'active':
                counts['active'] += 1
                summary(f"- ✅ **{name}**: {status}")
            elif status in ('queued', 'saving'):
                counts['stuck'] += 1
                print(f"⚠️  STUCK: {name} - Status: {status}")
                summary(f"- ⚠️ **{name}**: {status} (stuck)")
            else:
                counts['error'] += 1
                print(f"❌ ERROR: {name} - Status: {status} - Created: {created_at}")
                summary(f"- ❌ **{name}**: {status}")
        else:
            if status in ('queued', 'saving'):
                counts['stuck_old'] += 1

    summary(
        "",
        f"**Summary:** ✅ Active: {counts['active']} | ⚠️ Stuck: {counts['stuck']} | ❌ Error: {counts['error']}",
        "",
    )

    if counts['stuck_old'] > 0:
        summary("### ⚠️ Old Instance Backups Still Processing", "")
        print()
        print("=========================================")
        print("🔴 OLD INSTANCE BACKUPS STUCK")
        print("=========================================")
        for image in images:
            name = image.name or ''
            if not name.startswith('autoBackup'):
                continue
            created_at = getattr(image, 'created_at', '') or ''
            if _parse_date(created_at) == today:
                continue
            status = image.status or ''
            if status in ('queued', 'saving'):
                print(f"🔴 OLD BACKUP: {name} - Status: {status} - Created: {created_at}")
                summary(f"- 🔴 **{name}**: {status} (created: {created_at})")
        print("=========================================")
        print()
        summary("")

    return counts


############################################################################
#  Volume backup verification
############################################################################

def check_volume_backups(all_backups: list, today: str) -> dict:
    print('-' * 40)
    print("Checking volume backups!")

    summary("### Volume Backups", "")

    counts = dict(available=0, stuck=0, error=0, stuck_old=0)

    if all_backups is None:
        summary("- ℹ️ No volume backup service available in this region", "")
        return counts
    if not all_backups:
        summary("- ℹ️ No volume backups found in this region", "")
        return counts
    backups = all_backups

    for backup in backups:
        name = backup.name or ''
        if not name.startswith('autoBackup'):
            continue

        status = backup.status or ''
        created_at = getattr(backup, 'created_at', '') or ''
        is_today = _parse_date(created_at) == today

        if is_today:
            if status == 'available':
                counts['available'] += 1
                summary(f"- ✅ **{name}**: {status}")
            elif status in ('creating', 'backing-up'):
                counts['stuck'] += 1
                print(f"⚠️  STUCK: {name} - Status: {status}")
                summary(f"- ⚠️ **{name}**: {status} (stuck)")
            else:
                counts['error'] += 1
                print(f"❌ ERROR: {name} - Status: {status} - Created: {created_at}")
                summary(f"- ❌ **{name}**: {status}")
        else:
            if status in ('creating', 'backing-up'):
                counts['stuck_old'] += 1

    summary(
        "",
        f"**Summary:** ✅ Available: {counts['available']} | ⚠️ Stuck: {counts['stuck']} | ❌ Error: {counts['error']}",
        "",
    )

    if counts['stuck_old'] > 0:
        summary("### 🔴 Old Volume Backups Still Processing", "")
        print()
        print("=========================================")
        print("🔴 OLD VOLUME BACKUPS STUCK")
        print("=========================================")
        for backup in backups:
            name = backup.name or ''
            if not name.startswith('autoBackup'):
                continue
            created_at = getattr(backup, 'created_at', '') or ''
            if _parse_date(created_at) == today:
                continue
            status = backup.status or ''
            if status in ('creating', 'backing-up'):
                print(f"🔴 OLD BACKUP: {name} - Status: {status} - Created: {created_at}")
                summary(f"- 🔴 **{name}**: {status} (created: {created_at})")
        print("=========================================")
        print()
        summary("")

    return counts


############################################################################
#  Source volume health check
############################################################################

def check_source_volumes(all_volumes: list) -> int:
    print('-' * 40)
    print("Checking source volumes!")

    summary("### Source Volumes Status", "")

    stuck = 0

    if all_volumes is None:
        summary("- ℹ️ No volume service available in this region", "")
        return 0

    tagged = [v for v in all_volumes if (v.metadata or {}).get('autoBackup') == 'true']

    if not tagged:
        summary("- ✅ No tagged volumes found in this region", "")
        return 0

    for vol in tagged:
        name = vol.name or vol.id[:8]
        status = vol.status or ''
        if status in ('creating', 'backing-up', 'deleting', 'restoring-backup'):
            stuck += 1
            print(f"⚠️  STUCK SOURCE VOLUME: {name} - Status: {status}")
            summary(f"- ⚠️ **{name}**: {status} (source volume stuck)")

    if stuck > 0:
        summary("", f"**⚠️ Warning:** {stuck} source volume(s) stuck in unstable state")
    else:
        summary("- ✅ All source volumes are in stable state")
    summary("")

    return stuck


############################################################################
#  Temporary resource cleanup
############################################################################

def cleanup_temp_resources(conn, all_volumes: list, all_backups: list) -> dict:
    print('-' * 40)
    print("Cleaning up temporary resources!")

    summary("### 🧹 Temporary Resources Cleanup", "")

    counts = dict(volumes=0, snapshots=0, errors=0)

    # Temp volumes (temp_vol_*)
    print("Checking for temporary volumes to cleanup...")
    for vol in (all_volumes or []):
        name = vol.name or ''
        if not name.startswith('temp_vol_'):
            continue

        status = vol.status or ''
        if status == 'available':
            # Safety check: don't delete if a backup is still being created from this volume.
            # If we can't list backups (service unavailable), skip deletion to be safe.
            if all_backups is None:
                print(f"Skipping temp volume (cannot verify backup status): {name} ({vol.id})")
                summary(f"- ⏳ Temp volume skipped (backup service unavailable): {name}")
                continue
            backup_in_progress = any(
                b.volume_id == vol.id and b.status in ('creating', 'backing-up')
                for b in all_backups
            )
            if backup_in_progress:
                print(f"Skipping temp volume (backup still in progress): {name} ({vol.id})")
                summary(f"- ⏳ Temp volume backup still in progress: {name}")
                continue

            print(f"Cleaning up temporary volume: {name} ({vol.id})")
            try:
                conn.block_storage.delete_volume(vol.id, ignore_missing=True)
                counts['volumes'] += 1
                summary(f"- 🗑️ Deleted temp volume: {name}")
            except Exception as e:
                counts['errors'] += 1
                print(f"Warning: Failed to delete temp volume {name}: {e}")
                summary(f"- ❌ Failed to delete temp volume: {name}")
        elif status in ('in-use', 'creating'):
            print(f"Skipping temporary volume (still in use): {name} - Status: {status}")
            summary(f"- ⏳ Temp volume still in use: {name} ({status})")

    # Temp snapshots (temp_snap_*)
    print("Checking for temporary snapshots to cleanup...")
    try:
        all_snapshots = list(conn.block_storage.snapshots(details=True))
    except openstack.exceptions.EndpointNotFound:
        all_snapshots = None

    for snap in (all_snapshots or []):
        name = snap.name or ''
        if not name.startswith('temp_snap_'):
            continue

        status = snap.status or ''
        if status == 'available':
            print(f"Cleaning up temporary snapshot: {name} ({snap.id})")
            try:
                conn.block_storage.delete_snapshot(snap.id, ignore_missing=True)
                counts['snapshots'] += 1
                summary(f"- 🗑️ Deleted temp snapshot: {name}")
            except Exception as e:
                counts['errors'] += 1
                print(f"Warning: Failed to delete temp snapshot {name}: {e}")
                summary(f"- ❌ Failed to delete temp snapshot: {name}")
        elif status in ('creating', 'deleting'):
            print(f"Skipping temporary snapshot (busy): {name} - Status: {status}")
            summary(f"- ⏳ Temp snapshot busy: {name} ({status})")

    if counts['volumes'] > 0 or counts['snapshots'] > 0:
        summary(f"**Cleanup:** 🗑️ {counts['volumes']} temp volume(s), {counts['snapshots']} temp snapshot(s) deleted")
    else:
        summary("- ✅ No temporary resources to cleanup")

    if counts['errors'] > 0:
        summary(f"**⚠️ Warning:** {counts['errors']} cleanup error(s)")

    summary("")
    return counts


############################################################################
#  Entry point
############################################################################

def main():
    today = datetime.date.today().isoformat()

    summary(
        f"## Backup Verification Report - Region: {REGION_NAME}",
        "",
        f"**Verification Time:** {datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}",
        "",
    )

    conn = get_connection()

    # Fetch shared resource lists once — passed to functions to avoid duplicate API calls.
    # None means the service endpoint is unavailable; [] means available but empty.
    all_images  = list(conn.image.images(visibility='private'))

    try:
        all_volumes = list(conn.block_storage.volumes(details=True))
    except openstack.exceptions.EndpointNotFound:
        all_volumes = None

    try:
        all_backups = list(conn.block_storage.backups(details=True))
    except openstack.exceptions.EndpointNotFound:
        all_backups = None

    img  = check_instance_backups(all_images, today)
    vol  = check_volume_backups(all_backups, today)
    stuck_source = check_source_volumes(all_volumes)
    temp = cleanup_temp_resources(conn, all_volumes, all_backups)

    # ---- console summary ----
    total_stuck   = img['stuck'] + vol['stuck'] + stuck_source + img['stuck_old'] + vol['stuck_old']
    total_error   = img['error'] + vol['error']
    total_success = img['active'] + vol['available']

    print('-' * 40)
    print("SUMMARY")
    print('-' * 40)
    print(f"Active instance backups:  {img['active']}")
    print(f"Available volume backups: {vol['available']}")
    print(f"Stuck (today):            {img['stuck'] + vol['stuck']}")
    print(f"Stuck (old):              {img['stuck_old'] + vol['stuck_old']}")
    print(f"Stuck source volumes:     {stuck_source}")
    print(f"Errors:                   {total_error}")
    print(f"Temp volumes cleaned:     {temp['volumes']}")
    print(f"Temp snapshots cleaned:   {temp['snapshots']}")
    print('-' * 40)

    # ---- GitHub Actions outputs ----
    set_output('stuck_count', total_stuck)
    set_output('error_count', total_error)
    set_output('success_count', total_success)
    set_output('stuck_source_volumes', stuck_source)
    set_output('stuck_old_backups', img['stuck_old'] + vol['stuck_old'])

    summary("---")

    if total_error > 0:
        summary(f"❌ **CRITICAL:** {total_error} backup(s) failed")
        print(f"Finished with {total_error} error(s)!")
        sys.exit(1)
    elif total_stuck > 0:
        stuck_old_total = img['stuck_old'] + vol['stuck_old']
        if stuck_old_total > 0:
            summary(f"🔴 **CRITICAL:** {stuck_old_total} old backup(s) still stuck in processing state")
        if stuck_source > 0:
            summary(f"⚠️ **WARNING:** {total_stuck} item(s) stuck (including {stuck_source} source volume(s)) and require attention")
        else:
            summary(f"⚠️ **WARNING:** {total_stuck} backup(s) are stuck and require attention")
        print(f"Finished with {total_stuck} stuck resource(s)!")
        sys.exit(1)
    elif total_success == 0:
        summary("⚠️ **WARNING:** No backups found for today")
        print("Warning: No backups found for today!")
        sys.exit(1)
    else:
        summary(f"✅ **SUCCESS:** All {total_success} backup(s) completed successfully")
        print("Finished successfully!")


if __name__ == '__main__':
    main()
