# OpenStack Automatic Backup

Automated backup solution for OpenStack instances and volumes using GitHub Actions.

## Features

- **Automatic backups** for instances (boot-from-image) and volumes
- **Smart detection** of boot-from-volume vs boot-from-image instances
- **Multi-region support** (runs backups across multiple OpenStack regions)
- **Configurable retention** with automatic cleanup of old backups
- **GitHub Actions integration** with Job Summary reports
- **Robust error handling** with status checks before backup operations

## Quick Start

### 1. Use this template

Click **"Use this template"** to create a new repository from this template.

### 2. Configure GitHub Secrets

Go to **Settings** → **Secrets and variables** → **Actions** → **Secrets** and add:

| Secret | Description |
|--------|-------------|
| `OS_USERNAME` | OpenStack username |
| `OS_PASSWORD` | OpenStack password |
| `OS_PROJECT_NAME` | OpenStack project name |

### 3. Configure GitHub Variables

Go to **Settings** → **Secrets and variables** → **Actions** → **Variables** and add:

| Variable | Description | Example |
|----------|-------------|---------|
| `OS_AUTH_URL` | OpenStack authentication URL | `https://api.example.cloud/identity` |
| `OS_USER_DOMAIN_NAME` | User domain name | `Default` |
| `OS_PROJECT_DOMAIN_NAME` | Project domain name | `default` |
| `OS_IDENTITY_API_VERSION` | Identity API version | `3` |
| `RETENTION_DAYS` | Days to retain backups (optional) | `14` |

### 4. Configure regions

Edit `.github/workflows/openstack-backup.yml` to set your regions:

```yaml
strategy:
  matrix:
    region: [dc3-a, dc4-a]  # Change to your regions
```

### 5. Tag resources for backup

#### For boot-from-image instances:
```bash
openstack server set --property autoBackup='true' <instance-name-or-id>
```

#### For volumes (including boot volumes):
```bash
openstack volume set --property autoBackup='true' <volume-name-or-id>
```

## How it works

| Resource Type | Backup Method |
|---------------|---------------|
| **Boot-from-image instance** | `openstack server backup create` (creates image snapshot) |
| **Boot-from-volume instance** | Skipped (backup the volume directly) |
| **Volume** | `openstack volume backup create --force` |

### Backup naming convention

- Instances: `autoBackup_<timestamp>_<instance-name>`
- Volumes: `autoBackup_<timestamp>_<volume-name>`
- Volumes without name: `autoBackup_<timestamp>_<attached-instance>_vol`

## Configuration

### Retention

Backups older than the retention period are automatically deleted. Configure via:

1. **GitHub Variable** `RETENTION_DAYS` (recommended)
2. **Manual trigger** input when running workflow
3. **Default**: 14 days

### Schedule

By default, backups run daily at 2:00 AM UTC. Edit the cron in `.github/workflows/openstack-backup.yml`:

```yaml
schedule:
  - cron: '0 2 * * *'  # Daily at 2:00 AM UTC
```

## Manual Trigger

1. Go to **Actions** → **OpenStack Automatic Backup**
2. Click **Run workflow**
3. Optionally set `retention_days`
4. Click **Run workflow**

## Tagging Resources via Horizon Dashboard

### Instances
1. Navigate to **Project** → **Compute** → **Instances**
2. Click the dropdown arrow → **Update Metadata**
3. Add property `autoBackup` with value `true`
4. Click **Save**

### Volumes
1. Navigate to **Project** → **Volumes** → **Volumes**
2. Click the dropdown arrow → **Update Metadata**
3. Add property `autoBackup` with value `true`
4. Click **Save**

## Job Summary

After each run, a summary is generated in the GitHub Actions UI showing:
- Number of instances/volumes backed up
- Number of old backups deleted
- Any errors encountered
- Region and retention settings

## Requirements

- OpenStack cloud with Cinder backup service enabled
- GitHub Actions runner with internet access to OpenStack API

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

This license requires you to:
- Include a copy of the license in any redistribution
- State significant changes made to the software
- Retain all copyright, patent, trademark, and attribution notices

## Credits

Originally based on [houtknots/Openstack-Automatic-Snapshot](https://github.com/houtknots/Openstack-Automatic-Snapshot)
