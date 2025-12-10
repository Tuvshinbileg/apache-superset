# Apache Superset Deployment Scripts

This directory contains automated deployment and management scripts for Apache Superset production deployments.

## Available Scripts

### 1. `deploy-kubernetes.sh`

Automated deployment script for Kubernetes using Helm.

**Features:**
- Prerequisites validation (kubectl, helm)
- Helm repository management
- Namespace creation
- Values file validation
- Secret key checking
- Dry-run support
- Deployment status monitoring
- Access information display

**Usage:**

```bash
# Basic deployment
./scripts/deployment/deploy-kubernetes.sh

# Custom namespace and values file
./scripts/deployment/deploy-kubernetes.sh -n production -f prod-values.yaml

# Dry-run before deployment
./scripts/deployment/deploy-kubernetes.sh --dry-run

# Full options
./scripts/deployment/deploy-kubernetes.sh \
  --namespace superset \
  --release superset \
  --values superset-values.yaml
```

**Prerequisites:**
- Kubernetes cluster access (kubectl configured)
- Helm 3.x installed
- Values file created (see DEPLOYMENT.md for template)
- Secrets created for database and Redis credentials

### 2. `deploy-docker-compose.sh`

Automated deployment script for Docker Compose (development/testing only).

**Features:**
- Prerequisites validation (Docker, Docker Compose)
- Directory structure creation
- Environment file generation with secure random passwords
- Configuration validation
- Image building and pulling
- Service health checking
- Backup script generation
- Access information display

**Usage:**

```bash
# Basic deployment
./scripts/deployment/deploy-docker-compose.sh

# Custom compose file
./scripts/deployment/deploy-docker-compose.sh -f my-compose.yml

# Build custom images before deploying
./scripts/deployment/deploy-docker-compose.sh --build

# Pull latest images
./scripts/deployment/deploy-docker-compose.sh --pull

# Full options
./scripts/deployment/deploy-docker-compose.sh \
  --file docker-compose.prod.yml \
  --env docker/.env \
  --dir ./deployment \
  --build
```

**⚠️ Warning:** Docker Compose is NOT recommended for production use. Use Kubernetes instead.

### 3. `backup.sh`

Comprehensive backup script supporting both Kubernetes and Docker Compose deployments.

**Features:**
- Auto-detection of deployment type
- Database backup (PostgreSQL)
- Configuration files backup
- Kubernetes resources backup (YAML manifests)
- Docker volumes backup
- Helm values backup
- Compressed archive creation
- Backup verification
- Automatic cleanup of old backups
- Backup listing and statistics

**Usage:**

```bash
# Auto-detect and backup
./scripts/deployment/backup.sh

# Backup Kubernetes deployment
./scripts/deployment/backup.sh -t kubernetes

# Custom backup directory
./scripts/deployment/backup.sh -d /var/backups/superset

# Custom retention period (keep 60 days)
./scripts/deployment/backup.sh -r 60

# List existing backups
./scripts/deployment/backup.sh --list

# Cleanup old backups only
./scripts/deployment/backup.sh --cleanup
```

**Environment Variables:**
- `BACKUP_DIR`: Directory for backups (default: ./backups)
- `RETENTION_DAYS`: Days to retain backups (default: 30)
- `NAMESPACE`: Kubernetes namespace (default: superset)
- `COMPOSE_FILE`: Docker Compose file path

**Backup Contents:**
- Kubernetes: Database dump, K8s resources YAML, Helm values
- Docker Compose: Database dump, configuration files, Docker volumes

### 4. `health-check.sh`

Health monitoring script for production deployments.

**Features:**
- Auto-detection of deployment type
- Comprehensive health checks:
  - Pod/container status
  - Service availability
  - Health endpoints
  - Database connectivity
  - Redis connectivity
  - Celery workers
- Continuous monitoring mode
- Email alerts (optional)
- Detailed status reporting

**Usage:**

```bash
# Single health check
./scripts/deployment/health-check.sh

# Check specific deployment type
./scripts/deployment/health-check.sh -t kubernetes

# Continuous monitoring (every 60 seconds)
./scripts/deployment/health-check.sh --watch

# Custom check interval (30 seconds)
./scripts/deployment/health-check.sh --watch --interval 30

# With email alerts
./scripts/deployment/health-check.sh --watch --email admin@example.com
```

**Exit Codes:**
- `0`: All checks passed
- `1`: One or more checks failed

## Quick Start Guide

### Kubernetes Deployment

1. **Prepare Values File:**

```bash
# Copy template from DEPLOYMENT.md
cp superset-values-template.yaml superset-values.yaml

# Generate secret key
openssl rand -base64 42

# Edit values file with your configuration
vim superset-values.yaml
```

2. **Create Secrets:**

```bash
# Database credentials
kubectl create secret generic superset-db-credentials \
  --from-literal=username=superset_user \
  --from-literal=password=YOUR_DB_PASSWORD \
  --namespace superset

# Redis credentials
kubectl create secret generic superset-redis-credentials \
  --from-literal=password=YOUR_REDIS_PASSWORD \
  --namespace superset
```

3. **Deploy:**

```bash
./scripts/deployment/deploy-kubernetes.sh -f superset-values.yaml
```

4. **Verify:**

```bash
./scripts/deployment/health-check.sh -t kubernetes
```

### Docker Compose Deployment (Development Only)

1. **Deploy:**

```bash
./scripts/deployment/deploy-docker-compose.sh
```

2. **Verify:**

```bash
./scripts/deployment/health-check.sh -t docker-compose
```

## Backup and Recovery

### Regular Backups

Set up a cron job for automated backups:

```bash
# Add to crontab
# Daily backup at 2 AM
0 2 * * * /path/to/scripts/deployment/backup.sh

# Or with custom settings
0 2 * * * BACKUP_DIR=/var/backups/superset RETENTION_DAYS=60 /path/to/scripts/deployment/backup.sh
```

### Restore from Backup

**Kubernetes:**

```bash
# Extract backup
tar -xzf superset_k8s_20240101_120000.tar.gz

# Restore database
kubectl exec -i deployment/superset -n superset -- \
  psql -U superset superset < temp_*/database_*.sql

# Restore Kubernetes resources if needed
kubectl apply -f temp_*/k8s_resources_*.yaml
```

**Docker Compose:**

```bash
# Extract backup
tar -xzf superset_docker_20240101_120000.tar.gz

# Restore database
docker-compose exec -T postgres psql -U superset superset < temp_*/database_*.sql

# Restore volumes
docker run --rm \
  -v superset_home:/volume \
  -v ./temp_*:/backup \
  alpine tar -xzf /backup/volume_*.tar.gz -C /volume
```

## Monitoring

### Continuous Health Monitoring

Run health checks continuously in watch mode:

```bash
# Start monitoring
./scripts/deployment/health-check.sh --watch --interval 60

# With email alerts
./scripts/deployment/health-check.sh \
  --watch \
  --interval 300 \
  --email ops-team@example.com
```

### Integration with Monitoring Systems

The health-check script returns appropriate exit codes for integration with monitoring systems:

```bash
# Nagios/Icinga plugin format
./scripts/deployment/health-check.sh && echo "OK" || echo "CRITICAL"

# Prometheus node_exporter textfile collector
./scripts/deployment/health-check.sh && \
  echo "superset_health 1" > /var/lib/node_exporter/superset.prom || \
  echo "superset_health 0" > /var/lib/node_exporter/superset.prom
```

## Troubleshooting

### Common Issues

1. **Script Permission Denied:**

```bash
chmod +x scripts/deployment/*.sh
```

2. **Kubernetes Connection Failed:**

```bash
# Check kubectl configuration
kubectl cluster-info

# Set correct context
kubectl config use-context your-context
```

3. **Docker Compose Not Found:**

```bash
# Check Docker Compose version
docker compose version

# Or try legacy command
docker-compose version
```

4. **Backup Script Fails:**

```bash
# Check disk space
df -h

# Check permissions
ls -la backups/

# Create backup directory manually
mkdir -p backups
chmod 755 backups
```

### Debug Mode

Add debug output to scripts:

```bash
# Run with bash debug mode
bash -x ./scripts/deployment/deploy-kubernetes.sh

# Or set in script
set -x
```

## Security Notes

1. **Never commit sensitive data:**
   - Keep `.env` files out of version control
   - Store secrets in proper secret management systems
   - Use `.gitignore` for sensitive files

2. **Script permissions:**
   - Scripts should be executable (755)
   - Configuration files should be readable only by owner (600)

3. **Backup security:**
   - Encrypt backups for off-site storage
   - Restrict access to backup directory
   - Regularly test backup restoration

## Additional Resources

- [Main Deployment Guide](../../DEPLOYMENT.md)
- [Kubernetes Documentation](https://superset.apache.org/docs/installation/kubernetes)
- [Docker Compose Setup](https://superset.apache.org/docs/installation/docker-compose)
- [Security Best Practices](https://superset.apache.org/docs/security/securing-superset)

## Support

For issues or questions:
- GitHub Issues: https://github.com/apache/superset/issues
- Slack Community: https://apache-superset.slack.com/
- Documentation: https://superset.apache.org/docs/

---

**Last Updated:** December 2024  
**Compatible with:** Apache Superset 5.0+
