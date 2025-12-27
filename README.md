# ☁️ OpenStack Automatic Backup

Automated backup solution for OpenStack instances and volumes using GitHub Actions.

## ✨ Features

- 💾 **Automatic backups** for instances (boot-from-image) and volumes
- 🔍 **Smart detection** of boot-from-volume vs boot-from-image instances
- 🌍 **Multi-region support** (runs backups across multiple OpenStack regions)
- 🗑️ **Configurable retention** with automatic cleanup of old backups
- 📊 **GitHub Actions integration** with Job Summary reports
- 🛡️ **Robust error handling** with status checks before backup operations

## 🚀 Quick Start

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

## ⚙️ How it works

| Resource Type | Backup Method |
|---------------|---------------|
| **Boot-from-image instance** | `openstack server backup create` (creates image snapshot) |
| **Boot-from-volume instance** | Skipped (backup the volume directly) |
| **Volume** | `openstack volume backup create --force` |

### Backup naming convention

- Instances: `autoBackup_<timestamp>_<instance-name>`
- Volumes: `autoBackup_<timestamp>_<volume-name>`
- Volumes without name: `autoBackup_<timestamp>_<attached-instance>_vol`

## 🔧 Configuration

### Retention

Backups older than the retention period are automatically deleted. Configure via:

1. **GitHub Variable** `RETENTION_DAYS` (recommended)
2. **Manual trigger** input when running workflow
3. **Default**: 14 days

### Enable scheduled runs

This repository is a **template**. The backup workflow is **manual-only** by default to avoid running without configuration.

To enable daily scheduled runs, edit `.github/workflows/openstack-backup.yml` and add a `schedule` trigger, for example:

```yaml
on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2:00 AM UTC
  workflow_dispatch:
```

### Schedule

Once enabled, backups can run on a schedule using a cron in `.github/workflows/openstack-backup.yml`:

```yaml
schedule:
  - cron: '0 2 * * *'  # Daily at 2:00 AM UTC
```

## ▶️ Manual Trigger

1. Go to **Actions** → **OpenStack Automatic Backup**
2. Click **Run workflow**
3. Optionally set `retention_days`
4. Click **Run workflow**

## 🏷️ Tagging Resources via Horizon Dashboard

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

## 📋 Job Summary

After each run, a summary is generated in the GitHub Actions UI showing:
- Number of instances/volumes backed up
- Number of old backups deleted
- Any errors encountered
- Region and retention settings

## 🔔 Notifications

Optional notifications can be configured to alert you on backup success or failure. All notifications are **optional** - they only trigger if the corresponding webhook/token is configured.

### Available notification channels

| Channel | Secret(s) | Variable(s) |
|---------|-----------|-------------|
| Slack | `SLACK_WEBHOOK_URL` | - |
| Discord | `DISCORD_WEBHOOK_URL` | - |
| Microsoft Teams | `TEAMS_WEBHOOK_URL` | - |
| Telegram | `TELEGRAM_BOT_TOKEN` | `TELEGRAM_CHAT_ID` |
| GitHub Issue on failure | - | `CREATE_ISSUE_ON_FAILURE` = `true` |

### Setup instructions

#### Slack
1. Create an [Incoming Webhook](https://api.slack.com/messaging/webhooks) in your Slack workspace
2. Add `SLACK_WEBHOOK_URL` as a GitHub **secret**

#### Discord
1. In your Discord channel, go to **Settings** → **Integrations** → **Webhooks**
2. Create a webhook and copy the URL
3. Add `DISCORD_WEBHOOK_URL` as a GitHub **secret**

#### Microsoft Teams
1. In your Teams channel, click **...** → **Connectors** → **Incoming Webhook**
2. Configure and copy the webhook URL
3. Add `TEAMS_WEBHOOK_URL` as a GitHub **secret**

#### Telegram
1. Create a bot via [@BotFather](https://t.me/botfather) and get the token
2. Get your chat ID (send a message to your bot, then visit `https://api.telegram.org/bot<TOKEN>/getUpdates`)
3. Add `TELEGRAM_BOT_TOKEN` as a GitHub **secret** and `TELEGRAM_CHAT_ID` as a GitHub **variable**

#### GitHub Issue on failure
1. Add `CREATE_ISSUE_ON_FAILURE` = `true` as a GitHub variable
2. An issue will be automatically created when backup fails

## 🐳 Docker / Podman Usage

A container image is available with all dependencies pre-installed. Works with both Docker and Podman.

### Available registries

| Registry | Image |
|----------|-------|
| GitHub Container Registry | `ghcr.io/net-architect-cloud/os-backup-scheduler:latest` |
| Docker Hub | `docker.io/netarchitectcloud/os-backup-scheduler:latest` |
| Quay.io | `quay.io/netarchitect/os-backup-scheduler:latest` |

### Pull the image

```bash
# From GitHub Container Registry (recommended)
docker pull ghcr.io/net-architect-cloud/os-backup-scheduler:latest
podman pull ghcr.io/net-architect-cloud/os-backup-scheduler:latest

# From Docker Hub
docker pull netarchitectcloud/os-backup-scheduler:latest
podman pull docker.io/netarchitectcloud/os-backup-scheduler:latest

# From Quay.io
docker pull quay.io/netarchitect/os-backup-scheduler:latest
podman pull quay.io/netarchitect/os-backup-scheduler:latest
```

### Run manually

```bash
# Docker
docker run --rm \
  -e OS_AUTH_URL="https://api.example.cloud/identity" \
  -e OS_USERNAME="your-username" \
  -e OS_PASSWORD="your-password" \
  -e OS_PROJECT_NAME="your-project" \
  -e OS_USER_DOMAIN_NAME="Default" \
  -e OS_PROJECT_DOMAIN_NAME="default" \
  -e OS_REGION_NAME="region-a" \
  -e OS_IDENTITY_API_VERSION="3" \
  -e RETENTION_DAYS="14" \
  ghcr.io/net-architect-cloud/os-backup-scheduler:latest

# Podman
podman run --rm \
  -e OS_AUTH_URL="https://api.example.cloud/identity" \
  -e OS_USERNAME="your-username" \
  -e OS_PASSWORD="your-password" \
  -e OS_PROJECT_NAME="your-project" \
  -e OS_USER_DOMAIN_NAME="Default" \
  -e OS_PROJECT_DOMAIN_NAME="default" \
  -e OS_REGION_NAME="region-a" \
  -e OS_IDENTITY_API_VERSION="3" \
  -e RETENTION_DAYS="14" \
  ghcr.io/net-architect-cloud/os-backup-scheduler:latest
```

### Build locally

```bash
# Docker
docker build -t os-backup-scheduler .

# Podman
podman build -t os-backup-scheduler .
```

### Use in GitHub Actions with container

```yaml
jobs:
  backup:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/net-architect-cloud/os-backup-scheduler:latest
    steps:
      - name: Run backup
        env:
          OS_AUTH_URL: ${{ vars.OS_AUTH_URL }}
          OS_USERNAME: ${{ secrets.OS_USERNAME }}
          OS_PASSWORD: ${{ secrets.OS_PASSWORD }}
          OS_PROJECT_NAME: ${{ secrets.OS_PROJECT_NAME }}
          OS_USER_DOMAIN_NAME: ${{ vars.OS_USER_DOMAIN_NAME }}
          OS_PROJECT_DOMAIN_NAME: ${{ vars.OS_PROJECT_DOMAIN_NAME }}
          OS_REGION_NAME: ${{ matrix.region }}
          OS_IDENTITY_API_VERSION: ${{ vars.OS_IDENTITY_API_VERSION }}
          RETENTION_DAYS: ${{ vars.RETENTION_DAYS || '14' }}
        run: /app/openstack-backup.sh
```

## 📦 Requirements

- OpenStack cloud with Cinder backup service enabled
- GitHub Actions runner with internet access to OpenStack API (or use Docker image)

## 📄 License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

This license requires you to:
- Include a copy of the license in any redistribution
- State significant changes made to the software
- Retain all copyright, patent, trademark, and attribution notices

## 🙏 Credits

Originally based on [houtknots/Openstack-Automatic-Snapshot](https://github.com/houtknots/Openstack-Automatic-Snapshot)
