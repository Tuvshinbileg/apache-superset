<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->

# Apache Superset Production Deployment Guide

This comprehensive guide covers production deployment of Apache Superset across multiple platforms and environments.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Security Considerations](#security-considerations)
3. [Deployment Options](#deployment-options)
4. [Building Production Docker Image](#building-production-docker-image)
5. [Kubernetes Deployment (Recommended)](#kubernetes-deployment-recommended)
6. [Docker Compose Deployment](#docker-compose-deployment)
7. [Configuration Management](#configuration-management)
8. [Database Setup](#database-setup)
9. [Monitoring and Logging](#monitoring-and-logging)
10. [Backup and Recovery](#backup-and-recovery)
11. [Scaling Considerations](#scaling-considerations)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Infrastructure Requirements

**Minimum Production Requirements:**
- CPU: 4 cores
- RAM: 8GB
- Storage: 50GB (for application and metadata database)
- Network: HTTPS/TLS capable load balancer or reverse proxy

**Recommended Production Requirements:**
- CPU: 8+ cores
- RAM: 16GB+
- Storage: 100GB+ SSD
- High availability setup with multiple replicas

### Software Requirements

- **Kubernetes**: v1.20+ (for K8s deployments)
- **Helm**: v3.0+ (for K8s deployments)
- **Docker**: v20.10+ (for Docker deployments)
- **Docker Compose**: v2.0+ (for Docker Compose deployments)
- **PostgreSQL**: v12+ or **MySQL**: v8.0+ (metadata database)
- **Redis**: v6.0+ (for caching and Celery)

---

## Security Considerations

### Critical Security Settings

#### 1. HTTPS/TLS Configuration (MANDATORY)

**Never run Superset in production without HTTPS.** All network traffic must be encrypted.

- Deploy behind a reverse proxy (Nginx, Traefik, HAProxy) or load balancer (AWS ALB, GCP Load Balancer)
- Enforce TLS 1.2 or higher with strong cipher suites
- Implement HSTS (HTTP Strict Transport Security)

#### 2. SECRET_KEY Management (CRITICAL)

The `SUPERSET_SECRET_KEY` is used to sign session cookies and encrypt sensitive data in the metadata database.

**Generate a unique, cryptographically secure key:**

```bash
openssl rand -base64 42
```

**Store securely using environment variables or secrets management:**

```python
# superset_config.py
import os
SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY')
```

**⚠️ NEVER:**
- Hardcode the key in configuration files
- Commit the key to version control
- Reuse the same key across different environments
- Use default or example keys in production

#### 3. Session Security

**Use server-side sessions with Redis:**

```python
# superset_config.py
from redis import Redis
from datetime import timedelta
import os

# Enable server-side sessions
SESSION_SERVER_SIDE = True
SESSION_TYPE = 'redis'

SESSION_REDIS = Redis(
    host=os.environ.get('REDIS_HOST', 'localhost'),
    port=int(os.environ.get('REDIS_PORT', 6379)),
    password=os.environ.get('REDIS_PASSWORD'),
    db=0,
    ssl=True,
    ssl_cert_reqs='required'
)

SESSION_USE_SIGNER = True

# Session timeout and cookie security
PERMANENT_SESSION_LIFETIME = timedelta(hours=8)
SESSION_COOKIE_SECURE = True      # HTTPS only
SESSION_COOKIE_HTTPONLY = True    # No client-side JavaScript access
SESSION_COOKIE_SAMESITE = 'Lax'   # CSRF protection
```

#### 4. Database Security

```python
# superset_config.py
# Use environment variables for database credentials
SQLALCHEMY_DATABASE_URI = (
    f"{os.environ.get('DB_DIALECT')}://"
    f"{os.environ.get('DB_USER')}:{os.environ.get('DB_PASSWORD')}@"
    f"{os.environ.get('DB_HOST')}:{os.environ.get('DB_PORT')}/"
    f"{os.environ.get('DB_NAME')}"
)

# Enable connection encryption
SQLALCHEMY_ENGINE_OPTIONS = {
    'pool_pre_ping': True,
    'pool_recycle': 3600,
    'connect_args': {
        'sslmode': 'require',  # For PostgreSQL
    }
}
```

---

## Deployment Options

### Comparison Matrix

| Feature | Kubernetes (Helm) | Docker Compose | Bare Metal |
|---------|-------------------|----------------|------------|
| **Production Ready** | ✅ Recommended | ⚠️ Single Host Only | ✅ Yes |
| **High Availability** | ✅ Built-in | ❌ No | ⚠️ Manual Setup |
| **Auto-scaling** | ✅ Yes | ❌ No | ❌ No |
| **Rolling Updates** | ✅ Zero Downtime | ⚠️ Manual | ⚠️ Manual |
| **Complexity** | High | Medium | High |
| **Resource Efficiency** | High | Medium | High |
| **Best For** | Enterprise Production | Development/Testing | Small Deployments |

---

## Building Production Docker Image

### Why Build Your Own Image?

The default `lean` image does not include:
- Database drivers for your metadata database (PostgreSQL/MySQL)
- Database drivers for your data warehouses
- Headless browser for Alerts & Reports
- Custom Python packages

### Production Dockerfile

Create a file named `Dockerfile.production`:

```dockerfile
# Use the lean image as base - change version as needed
FROM apache/superset:latest

# Switch to root to install packages
USER root

# Set environment variable for Playwright
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright-browsers

# Install Python packages using uv into the virtual environment
RUN . /app/.venv/bin/activate && \
    uv pip install \
    # Metadata database driver (choose one)
    psycopg2-binary \
    # OR for MySQL:
    # mysqlclient \
    \
    # Data warehouse drivers (add what you need)
    # PostgreSQL
    psycopg2-binary \
    # MySQL/MariaDB
    mysqlclient \
    # Microsoft SQL Server
    pymssql \
    # Snowflake
    snowflake-sqlalchemy \
    # BigQuery
    sqlalchemy-bigquery \
    # Redshift
    sqlalchemy-redshift \
    # Clickhouse
    clickhouse-sqlalchemy \
    \
    # Authentication packages
    Authlib \
    \
    # File upload support
    openpyxl \
    \
    # Alerts & Reports dependencies
    Pillow \
    playwright \
    && playwright install-deps \
    && PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright-browsers playwright install chromium

# Copy custom configuration if needed
# COPY --chown=superset superset_config.py /app/pythonpath/

# Switch back to superset user
USER superset

# Use the standard entrypoint
CMD ["/app/docker/entrypoints/run-server.sh"]
```

### Build and Push

```bash
# Build the image
docker build -f Dockerfile.production -t mycompany/superset:1.0.0 .

# Tag for latest
docker tag mycompany/superset:1.0.0 mycompany/superset:latest

# Push to registry
docker push mycompany/superset:1.0.0
docker push mycompany/superset:latest
```

---

## Kubernetes Deployment (Recommended)

### Installation Steps

#### 1. Add Helm Repository

```bash
helm repo add superset https://apache.github.io/superset
helm repo update
```

#### 2. Create Values File

Create `superset-values.yaml`:

```yaml
# Image Configuration
image:
  repository: mycompany/superset  # Your custom image
  tag: "1.0.0"
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: registry-credentials  # If using private registry

# Replicas for high availability
replicaCount: 3

# Resource limits
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
  limits:
    cpu: 2000m
    memory: 4Gi

# Security Configuration
extraSecretEnv:
  SUPERSET_SECRET_KEY: "YOUR_GENERATED_SECRET_KEY_HERE"
  
# Database Configuration
postgresql:
  enabled: false  # Use external database in production

# External Database Connection
extraEnv:
  DATABASE_DIALECT: postgresql
  DATABASE_HOST: postgres.example.com
  DATABASE_PORT: "5432"
  DATABASE_DB: superset
  REDIS_HOST: redis.example.com
  REDIS_PORT: "6379"

# Environment variables from secrets
extraEnvRaw:
  - name: DATABASE_USER
    valueFrom:
      secretKeyRef:
        name: superset-db-credentials
        key: username
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: superset-db-credentials
        key: password
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: superset-redis-credentials
        key: password

# Configuration Overrides
configOverrides:
  secret: |
    import os
    from datetime import timedelta
    from redis import Redis
    
    # Secret Key
    SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY')
    
    # Session Configuration
    SESSION_SERVER_SIDE = True
    SESSION_TYPE = 'redis'
    SESSION_REDIS = Redis(
        host=os.environ.get('REDIS_HOST'),
        port=int(os.environ.get('REDIS_PORT')),
        password=os.environ.get('REDIS_PASSWORD'),
        db=0,
        ssl=True,
        ssl_cert_reqs='required'
    )
    SESSION_USE_SIGNER = True
    PERMANENT_SESSION_LIFETIME = timedelta(hours=8)
    
    # Cookie Security
    SESSION_COOKIE_SECURE = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = 'Lax'
    
    # Cache Configuration
    CACHE_CONFIG = {
        'CACHE_TYPE': 'RedisCache',
        'CACHE_DEFAULT_TIMEOUT': 300,
        'CACHE_KEY_PREFIX': 'superset_',
        'CACHE_REDIS_HOST': os.environ.get('REDIS_HOST'),
        'CACHE_REDIS_PORT': int(os.environ.get('REDIS_PORT')),
        'CACHE_REDIS_PASSWORD': os.environ.get('REDIS_PASSWORD'),
        'CACHE_REDIS_DB': 1,
    }
    DATA_CACHE_CONFIG = CACHE_CONFIG
    THUMBNAIL_CACHE_CONFIG = CACHE_CONFIG
    
    # Enable features
    FEATURE_FLAGS = {
        'ALERT_REPORTS': True,
        'DASHBOARD_NATIVE_FILTERS': True,
        'DASHBOARD_CROSS_FILTERS': True,
    }

# Ingress Configuration
ingress:
  enabled: true
  ingressClassName: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - superset.example.com
  tls:
    - secretName: superset-tls
      hosts:
        - superset.example.com

# Worker Configuration
supersetWorker:
  replicaCount: 2
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi

# Celery Beat
supersetCeleryBeat:
  enabled: true

# Init Job
init:
  enabled: true
  createAdmin: true
  adminUser:
    username: admin
    firstname: Admin
    lastname: User
    email: admin@example.com
    password: "CHANGE_ME_IMMEDIATELY"

# Service Account
serviceAccount:
  create: true

# Redis (for development only, use external Redis in production)
redis:
  enabled: false

# PostgreSQL (for development only, use external PostgreSQL in production)
postgresql:
  enabled: false
```

#### 3. Create Secrets

```bash
# Database credentials
kubectl create secret generic superset-db-credentials \
  --from-literal=username=superset_user \
  --from-literal=password=YOUR_DB_PASSWORD

# Redis credentials
kubectl create secret generic superset-redis-credentials \
  --from-literal=password=YOUR_REDIS_PASSWORD

# Registry credentials (if using private registry)
kubectl create secret docker-registry registry-credentials \
  --docker-server=registry.example.com \
  --docker-username=username \
  --docker-password=password
```

#### 4. Deploy

```bash
# Install
helm install superset superset/superset \
  -f superset-values.yaml \
  --namespace superset \
  --create-namespace

# Or upgrade existing deployment
helm upgrade superset superset/superset \
  -f superset-values.yaml \
  --namespace superset
```

#### 5. Verify Deployment

```bash
# Check pods
kubectl get pods -n superset

# Check services
kubectl get svc -n superset

# Check ingress
kubectl get ingress -n superset

# View logs
kubectl logs -f deployment/superset -n superset
```

### Kubernetes Production Best Practices

1. **Use External Databases**: Never use containerized databases for production
2. **Enable Autoscaling**: Use HPA (Horizontal Pod Autoscaler)
3. **Configure Resource Limits**: Set appropriate CPU/memory requests and limits
4. **Use Multiple Replicas**: Deploy at least 3 replicas for high availability
5. **Enable Pod Disruption Budgets**: Ensure availability during updates
6. **Configure Liveness and Readiness Probes**: Monitor pod health
7. **Use Persistent Volumes**: For any local storage needs
8. **Implement Network Policies**: Restrict pod-to-pod communication
9. **Enable Monitoring**: Use Prometheus and Grafana
10. **Set up Log Aggregation**: Use ELK/EFK stack or cloud logging

---

## Docker Compose Deployment

⚠️ **Warning**: Docker Compose is **NOT recommended for production** due to single-host limitations and lack of high availability. Use for development or small-scale deployments only.

### Production-Like Docker Compose Setup

#### 1. Create Directory Structure

```bash
mkdir -p superset-deploy/{config,data,scripts}
cd superset-deploy
```

#### 2. Create Environment File

Create `docker/.env`:

```bash
# Database Configuration
DATABASE_DIALECT=postgresql
DATABASE_USER=superset
DATABASE_PASSWORD=CHANGE_ME
DATABASE_HOST=db
DATABASE_PORT=5432
DATABASE_DB=superset

# Redis Configuration
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_CELERY_DB=0
REDIS_RESULTS_DB=1

# Superset Configuration
SUPERSET_SECRET_KEY=CHANGE_ME_TO_A_LONG_RANDOM_STRING
SUPERSET_LOAD_EXAMPLES=no
SUPERSET_PORT=8088

# PostgreSQL Configuration
POSTGRES_USER=superset
POSTGRES_PASSWORD=CHANGE_ME
POSTGRES_DB=superset
```

#### 3. Create Production Docker Compose File

Create `docker-compose.prod.yml`:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:16
    container_name: superset_postgres
    restart: always
    env_file:
      - docker/.env
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - superset-network

  redis:
    image: redis:7-alpine
    container_name: superset_redis
    restart: always
    command: redis-server --requirepass "${REDIS_PASSWORD:-}"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - superset-network

  superset-init:
    image: mycompany/superset:latest
    container_name: superset_init
    command: ["/app/docker/docker-init.sh"]
    env_file:
      - docker/.env
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ./config:/app/pythonpath
    networks:
      - superset-network

  superset:
    image: mycompany/superset:latest
    container_name: superset_app
    restart: always
    command: ["/app/docker/docker-bootstrap.sh", "app-gunicorn"]
    env_file:
      - docker/.env
    ports:
      - "8088:8088"
    depends_on:
      superset-init:
        condition: service_completed_successfully
    volumes:
      - ./config:/app/pythonpath
      - superset_home:/app/superset_home
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8088/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - superset-network

  superset-worker:
    image: mycompany/superset:latest
    container_name: superset_worker
    restart: always
    command: ["/app/docker/docker-bootstrap.sh", "worker"]
    env_file:
      - docker/.env
    depends_on:
      superset-init:
        condition: service_completed_successfully
    volumes:
      - ./config:/app/pythonpath
      - superset_home:/app/superset_home
    healthcheck:
      test: ["CMD-SHELL", "celery -A superset.tasks.celery_app:app inspect ping -d celery@$$HOSTNAME"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - superset-network

  superset-worker-beat:
    image: mycompany/superset:latest
    container_name: superset_worker_beat
    restart: always
    command: ["/app/docker/docker-bootstrap.sh", "beat"]
    env_file:
      - docker/.env
    depends_on:
      superset-init:
        condition: service_completed_successfully
    volumes:
      - ./config:/app/pythonpath
      - superset_home:/app/superset_home
    networks:
      - superset-network

  nginx:
    image: nginx:alpine
    container_name: superset_nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - superset
    networks:
      - superset-network

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
  superset_home:
    driver: local

networks:
  superset-network:
    driver: bridge
```

#### 4. Deploy

```bash
# Start services
docker-compose -f docker-compose.prod.yml up -d

# View logs
docker-compose -f docker-compose.prod.yml logs -f

# Stop services
docker-compose -f docker-compose.prod.yml down
```

---

## Configuration Management

### Configuration Files

#### Production Configuration Template

Create `config/superset_config_production.py`:

```python
import os
from datetime import timedelta
from redis import Redis
from celery.schedules import crontab

# Basic Flask Configuration
ROW_LIMIT = 5000
SUPERSET_WEBSERVER_PORT = 8088

# Flask App Builder Configuration
APP_NAME = "Superset"
APP_ICON = "/static/assets/images/superset-logo-horiz.png"

# Security Configuration
SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY')
if not SECRET_KEY:
    raise ValueError("SUPERSET_SECRET_KEY environment variable must be set")

# Previous secret key for key rotation
PREVIOUS_SECRET_KEY = os.environ.get('SUPERSET_PREVIOUS_SECRET_KEY')

# Database Configuration
SQLALCHEMY_DATABASE_URI = (
    f"{os.environ.get('DATABASE_DIALECT')}://"
    f"{os.environ.get('DATABASE_USER')}:{os.environ.get('DATABASE_PASSWORD')}@"
    f"{os.environ.get('DATABASE_HOST')}:{os.environ.get('DATABASE_PORT')}/"
    f"{os.environ.get('DATABASE_DB')}"
)

# Database connection pool configuration
SQLALCHEMY_ENGINE_OPTIONS = {
    'pool_size': 10,
    'pool_recycle': 3600,
    'pool_pre_ping': True,
    'max_overflow': 20,
    'connect_args': {
        'connect_timeout': 10,
    }
}

# Prevent SQL Lab from executing too large queries
SQLLAB_TIMEOUT = 300  # 5 minutes
SUPERSET_WEBSERVER_TIMEOUT = 300

# Redis Configuration
REDIS_HOST = os.environ.get('REDIS_HOST', 'redis')
REDIS_PORT = int(os.environ.get('REDIS_PORT', 6379))
REDIS_PASSWORD = os.environ.get('REDIS_PASSWORD')
REDIS_CELERY_DB = int(os.environ.get('REDIS_CELERY_DB', 0))
REDIS_RESULTS_DB = int(os.environ.get('REDIS_RESULTS_DB', 1))

# Session Configuration - Server-side sessions with Redis
SESSION_SERVER_SIDE = True
SESSION_TYPE = 'redis'
SESSION_REDIS = Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_PASSWORD,
    db=0,
    ssl=os.environ.get('REDIS_SSL_ENABLED', 'false').lower() == 'true',
    ssl_cert_reqs='required' if os.environ.get('REDIS_SSL_ENABLED', 'false').lower() == 'true' else None
)
SESSION_USE_SIGNER = True
PERMANENT_SESSION_LIFETIME = timedelta(hours=8)

# Cookie Security Settings
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'

# Cache Configuration
CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_',
    'CACHE_REDIS_HOST': REDIS_HOST,
    'CACHE_REDIS_PORT': REDIS_PORT,
    'CACHE_REDIS_PASSWORD': REDIS_PASSWORD,
    'CACHE_REDIS_DB': REDIS_RESULTS_DB,
}

DATA_CACHE_CONFIG = CACHE_CONFIG
THUMBNAIL_CACHE_CONFIG = CACHE_CONFIG

# Celery Configuration
class CeleryConfig:
    broker_url = f"redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/{REDIS_CELERY_DB}" if REDIS_PASSWORD else f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_CELERY_DB}"
    imports = (
        'superset.sql_lab',
        'superset.tasks.scheduler',
        'superset.tasks.thumbnails',
        'superset.tasks.cache',
    )
    result_backend = f"redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/{REDIS_RESULTS_DB}" if REDIS_PASSWORD else f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_RESULTS_DB}"
    worker_prefetch_multiplier = 1
    task_acks_late = True
    task_annotations = {
        'sql_lab.get_sql_results': {
            'rate_limit': '100/s',
        },
    }
    beat_schedule = {
        'reports.scheduler': {
            'task': 'reports.scheduler',
            'schedule': crontab(minute='*', hour='*'),
        },
        'reports.prune_log': {
            'task': 'reports.prune_log',
            'schedule': crontab(minute=0, hour=0),
        },
        'cache-warmup-hourly': {
            'task': 'cache-warmup',
            'schedule': crontab(minute=0, hour='*'),
            'kwargs': {},
        },
    }

CELERY_CONFIG = CeleryConfig

# Feature Flags
FEATURE_FLAGS = {
    'ALERT_REPORTS': True,
    'DASHBOARD_NATIVE_FILTERS': True,
    'DASHBOARD_CROSS_FILTERS': True,
    'DASHBOARD_RBAC': True,
    'ENABLE_TEMPLATE_PROCESSING': True,
    'EMBEDDED_SUPERSET': False,
}

# Alerts and Reports Configuration
ALERT_REPORTS_NOTIFICATION_DRY_RUN = False
WEBDRIVER_BASEURL = f"http://{os.environ.get('WEBDRIVER_HOST', 'superset')}:{SUPERSET_WEBSERVER_PORT}/"
WEBDRIVER_BASEURL_USER_FRIENDLY = os.environ.get('SUPERSET_PUBLIC_URL', 'https://superset.example.com/')

# Email Configuration (for alerts and reports)
SMTP_HOST = os.environ.get('SMTP_HOST')
SMTP_PORT = int(os.environ.get('SMTP_PORT', 587))
SMTP_STARTTLS = os.environ.get('SMTP_STARTTLS', 'true').lower() == 'true'
SMTP_SSL = os.environ.get('SMTP_SSL', 'false').lower() == 'true'
SMTP_USER = os.environ.get('SMTP_USER')
SMTP_PASSWORD = os.environ.get('SMTP_PASSWORD')
SMTP_MAIL_FROM = os.environ.get('SMTP_MAIL_FROM', 'superset@example.com')

# Logging Configuration
import logging
LOG_LEVEL = logging.INFO
LOG_FORMAT = '%(asctime)s:%(levelname)s:%(name)s:%(message)s'
ENABLE_TIME_ROTATE = True

# Security Headers
TALISMAN_ENABLED = True
TALISMAN_CONFIG = {
    'content_security_policy': {
        'default-src': ["'self'"],
        'img-src': ["'self'", 'data:', 'https:'],
        'worker-src': ["'self'", 'blob:'],
        'connect-src': ["'self'"],
        'object-src': "'none'",
        'style-src': ["'self'", "'unsafe-inline'"],
        'script-src': ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
    },
    'force_https': True,
    'force_https_permanent': True,
}

# Additional Security Settings
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = None
WTF_CSRF_SSL_STRICT = True

# Enable or disable impersonation of logged users
PREVENT_UNSAFE_DB_CONNECTIONS = True

# Rate limiting
RATELIMIT_ENABLED = True
RATELIMIT_STORAGE_URL = f"redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/2" if REDIS_PASSWORD else f"redis://{REDIS_HOST}:{REDIS_PORT}/2"
```

---

## Database Setup

### PostgreSQL (Recommended)

#### 1. Create Database and User

```sql
-- Connect as postgres superuser
CREATE DATABASE superset;
CREATE USER superset_user WITH ENCRYPTED PASSWORD 'your_secure_password';
GRANT ALL PRIVILEGES ON DATABASE superset TO superset_user;

-- Grant schema privileges
\c superset
GRANT ALL ON SCHEMA public TO superset_user;
ALTER DATABASE superset OWNER TO superset_user;
```

#### 2. Enable SSL (Recommended)

Edit `postgresql.conf`:
```
ssl = on
ssl_cert_file = '/path/to/server.crt'
ssl_key_file = '/path/to/server.key'
```

Edit `pg_hba.conf`:
```
hostssl    superset    superset_user    0.0.0.0/0    scram-sha-256
```

### MySQL

#### 1. Create Database and User

```sql
CREATE DATABASE superset CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'superset_user'@'%' IDENTIFIED BY 'your_secure_password';
GRANT ALL PRIVILEGES ON superset.* TO 'superset_user'@'%';
FLUSH PRIVILEGES;
```

#### 2. Enable SSL

Edit `my.cnf`:
```ini
[mysqld]
require_secure_transport=ON
ssl-ca=/path/to/ca.pem
ssl-cert=/path/to/server-cert.pem
ssl-key=/path/to/server-key.pem
```

---

## Monitoring and Logging

### Prometheus Metrics

Enable Prometheus metrics in `superset_config.py`:

```python
from superset.stats_logger import StatsdStatsLogger

STATS_LOGGER = StatsdStatsLogger(host='statsd', port=8125, prefix='superset')
```

### Application Logging

Configure structured logging:

```python
import logging
from pythonjsonlogger import jsonlogger

# JSON formatted logs for better parsing
logHandler = logging.StreamHandler()
formatter = jsonlogger.JsonFormatter()
logHandler.setFormatter(formatter)
logging.getLogger().addHandler(logHandler)
logging.getLogger().setLevel(logging.INFO)
```

### Health Checks

Superset provides a health check endpoint:

```bash
curl http://localhost:8088/health
```

Response:
```json
{"status": "ok"}
```

---

## Backup and Recovery

### Database Backups

#### PostgreSQL Backup

```bash
# Daily backup script
#!/bin/bash
BACKUP_DIR="/backup/superset"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/superset_${DATE}.sql"

pg_dump -h localhost -U superset_user -d superset > $BACKUP_FILE
gzip $BACKUP_FILE

# Keep only last 30 days
find $BACKUP_DIR -name "superset_*.sql.gz" -mtime +30 -delete
```

#### PostgreSQL Restore

```bash
gunzip superset_20240101_120000.sql.gz
psql -h localhost -U superset_user -d superset < superset_20240101_120000.sql
```

### Configuration Backups

Backup your configuration files regularly:

```bash
# Backup script
tar -czf superset-config-$(date +%Y%m%d).tar.gz \
  config/ \
  docker/.env \
  superset-values.yaml
```

### Kubernetes Backups

Use tools like Velero for full cluster backups:

```bash
velero backup create superset-backup \
  --include-namespaces superset \
  --ttl 720h
```

---

## Scaling Considerations

### Horizontal Scaling

#### Kubernetes Auto-scaling

```yaml
# HPA for Superset pods
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: superset-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: superset
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### Vertical Scaling

Adjust resource limits based on your workload:

```yaml
resources:
  requests:
    cpu: 2000m
    memory: 4Gi
  limits:
    cpu: 4000m
    memory: 8Gi
```

### Database Scaling

1. **Connection Pooling**: Use PgBouncer for PostgreSQL
2. **Read Replicas**: Configure read replicas for analytics queries
3. **Database Sharding**: For very large deployments

### Cache Optimization

```python
# Increase cache TTL for static data
DATA_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 3600,  # 1 hour
}

# Use separate Redis instance for high-traffic caches
THUMBNAIL_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_REDIS_HOST': 'redis-thumbnails.example.com',
}
```

---

## Troubleshooting

### Common Issues

#### 1. Superset Won't Start

**Symptoms**: Container crashes or fails to start

**Solutions**:
```bash
# Check logs
kubectl logs deployment/superset -n superset
# or
docker logs superset_app

# Common causes:
# - Missing SECRET_KEY
# - Database connection failure
# - Invalid configuration

# Verify database connection
superset db upgrade
```

#### 2. Database Migration Failures

**Symptoms**: Init container fails, migration errors

**Solutions**:
```bash
# Run migration manually
kubectl exec -it deployment/superset -n superset -- superset db upgrade

# Check current revision
kubectl exec -it deployment/superset -n superset -- superset db current
```

#### 3. Redis Connection Issues

**Symptoms**: Cache errors, Celery worker failures

**Solutions**:
```bash
# Test Redis connection
redis-cli -h redis.example.com -p 6379 -a password ping

# Check Redis logs
kubectl logs deployment/redis -n superset
```

#### 4. Performance Issues

**Symptoms**: Slow dashboard loading, timeouts

**Solutions**:
1. Enable query result caching
2. Increase database connection pool size
3. Scale up Superset replicas
4. Add more Celery workers
5. Optimize database queries

```python
# Performance tuning
SQLALCHEMY_ENGINE_OPTIONS = {
    'pool_size': 20,
    'max_overflow': 40,
}

# Enable aggressive caching
CACHE_DEFAULT_TIMEOUT = 3600
```

#### 5. SSL/TLS Certificate Issues

**Symptoms**: HTTPS not working, certificate warnings

**Solutions**:
```bash
# Verify certificate
openssl s_client -connect superset.example.com:443

# Check Ingress configuration
kubectl describe ingress superset -n superset

# Verify cert-manager
kubectl get certificate -n superset
```

### Debug Mode

Enable debug mode for troubleshooting (NOT for production):

```python
# superset_config.py
DEBUG = True
SUPERSET_LOG_LEVEL = 'DEBUG'
```

### Useful Commands

```bash
# Kubernetes
kubectl get all -n superset
kubectl describe pod superset-xxx -n superset
kubectl logs -f deployment/superset -n superset
kubectl exec -it deployment/superset -n superset -- /bin/bash

# Docker Compose
docker-compose logs -f
docker-compose exec superset bash
docker-compose ps

# Database
superset db upgrade
superset init
superset fab create-admin

# User management
superset fab create-user --role Admin --username admin --firstname Admin --lastname User --email admin@example.com --password admin
```

---

## Additional Resources

### Official Documentation

- [Superset Documentation](https://superset.apache.org/docs/intro)
- [Helm Chart](https://github.com/apache/superset/tree/master/helm/superset)
- [Docker Images](https://hub.docker.com/r/apache/superset)

### Security Resources

- [Securing Superset Guide](https://superset.apache.org/docs/security/securing-superset)
- [OWASP Security Best Practices](https://owasp.org/)

### Community

- [GitHub Repository](https://github.com/apache/superset)
- [Slack Community](https://apache-superset.slack.com/)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/apache-superset)

---

## Quick Deployment Scripts

For automated deployment scripts, see:
- `scripts/deploy-kubernetes.sh` - Kubernetes deployment automation
- `scripts/deploy-docker-compose.sh` - Docker Compose deployment automation
- `scripts/backup.sh` - Automated backup script
- `scripts/health-check.sh` - Health monitoring script

---

**Last Updated**: December 2024  
**Superset Version**: 5.0+

For questions or issues, please refer to the [Apache Superset GitHub repository](https://github.com/apache/superset).
