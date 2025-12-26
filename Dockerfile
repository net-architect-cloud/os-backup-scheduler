FROM python:3.12-slim

LABEL maintainer="Net Architect"
LABEL description="OpenStack Automatic Backup - Automated backup solution for OpenStack instances and volumes"
LABEL org.opencontainers.image.source="https://github.com/net-architect-cloud/os-backup-scheduler"
LABEL org.opencontainers.image.licenses="Apache-2.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    bash \
    coreutils \
    && rm -rf /var/lib/apt/lists/*

# Install OpenStack CLI
RUN pip install --no-cache-dir python-openstackclient

# Create app directory
WORKDIR /app

# Copy the backup script
COPY openstack-backup.sh /app/openstack-backup.sh

# Make script executable
RUN chmod +x /app/openstack-backup.sh

# Set entrypoint
ENTRYPOINT ["/app/openstack-backup.sh"]
