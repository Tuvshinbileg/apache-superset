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

# Deploying Apache Superset on Railway

This guide walks you through deploying Apache Superset on [Railway](https://railway.app/), a modern cloud platform that provides easy deployment with built-in PostgreSQL and Redis support.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Deploy](#quick-deploy)
3. [Manual Deployment](#manual-deployment)
4. [Configuration](#configuration)
5. [Database Setup](#database-setup)
6. [Environment Variables](#environment-variables)
7. [Custom Domain](#custom-domain)
8. [Scaling and Performance](#scaling-and-performance)
9. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Railway Account**: Sign up at [railway.app](https://railway.app/)
- **GitHub Account**: For connecting your repository
- **Railway CLI** (optional): Install with `npm i -g @railway/cli`

---

## Quick Deploy

### Option 1: Deploy from GitHub (Recommended)

1. **Fork this repository** to your GitHub account

2. **Login to Railway**: Go to [railway.app](https://railway.app/) and sign in

3. **Create New Project**:
   - Click "New Project"
   - Select "Deploy from GitHub repo"
   - Choose your forked `apache-superset` repository
   - Select the `main` branch

4. **Add PostgreSQL Database**:
   - In your project dashboard, click "+ New"
   - Select "Database" → "Add PostgreSQL"
   - Railway will automatically provision a PostgreSQL instance

5. **Add Redis**:
   - Click "+ New" again
   - Select "Database" → "Add Redis"
   - Railway will provision a Redis instance

6. **Configure Environment Variables** (see [Environment Variables](#environment-variables) section below)

7. **Deploy**: Railway will automatically build and deploy your application

### Option 2: One-Click Deploy Template

Create a `railway.json` file in your repository root:

```json
{
  "build": {
    "builder": "DOCKERFILE",
    "dockerfilePath": "Dockerfile"
  },
  "deploy": {
    "startCommand": "/app/docker/entrypoints/run-server.sh",
    "healthcheckPath": "/health",
    "healthcheckTimeout": 300,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 10
  }
}
```

Then deploy using the Railway button:

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template)

---

## Manual Deployment

### Step 1: Prepare Your Repository

1. **Create a Production Dockerfile** (`Dockerfile.railway`):

```dockerfile
FROM apache/superset:latest

USER root

# Set environment for Railway
ENV SUPERSET_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    SUPERSET_PORT=8088

# Install production dependencies
RUN . /app/.venv/bin/activate && \
    uv pip install \
    psycopg2-binary \
    redis \
    gevent \
    && playwright install-deps \
    && playwright install chromium

# Copy custom configuration
COPY railway/superset_config.py /app/pythonpath/superset_config.py

USER superset

EXPOSE 8088

CMD ["/app/docker/entrypoints/run-server.sh"]
```

2. **Create Railway Configuration Directory**:

```bash
mkdir -p railway
```

3. **Create Railway-specific Configuration** (`railway/superset_config.py`):

```python
import os
from datetime import timedelta
from redis import Redis
from celery.schedules import crontab

# Railway-specific configuration
SUPERSET_ENV = os.environ.get('SUPERSET_ENV', 'production')

# Security - CRITICAL
SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY')
if not SECRET_KEY:
    raise ValueError("SUPERSET_SECRET_KEY must be set")

# Database Configuration (Railway PostgreSQL)
SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')
if SQLALCHEMY_DATABASE_URI and SQLALCHEMY_DATABASE_URI.startswith('postgres://'):
    # Railway uses postgres:// but SQLAlchemy needs postgresql://
    SQLALCHEMY_DATABASE_URI = SQLALCHEMY_DATABASE_URI.replace('postgres://', 'postgresql://', 1)

# Database connection pool
SQLALCHEMY_ENGINE_OPTIONS = {
    'pool_size': 10,
    'pool_recycle': 3600,
    'pool_pre_ping': True,
    'max_overflow': 20,
}

# Redis Configuration (Railway Redis)
REDIS_URL = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')

# Parse Redis URL for individual components
from urllib.parse import urlparse
redis_url = urlparse(REDIS_URL)
REDIS_HOST = redis_url.hostname or 'localhost'
REDIS_PORT = redis_url.port or 6379
REDIS_PASSWORD = redis_url.password

# Session Configuration
SESSION_SERVER_SIDE = True
SESSION_TYPE = 'redis'
SESSION_REDIS = Redis.from_url(REDIS_URL)
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
    'CACHE_REDIS_URL': REDIS_URL,
}
DATA_CACHE_CONFIG = CACHE_CONFIG
THUMBNAIL_CACHE_CONFIG = CACHE_CONFIG

# Celery Configuration
class CeleryConfig:
    broker_url = REDIS_URL
    imports = (
        'superset.sql_lab',
        'superset.tasks.scheduler',
        'superset.tasks.thumbnails',
        'superset.tasks.cache',
    )
    result_backend = REDIS_URL
    worker_prefetch_multiplier = 1
    task_acks_late = True
    beat_schedule = {
        'reports.scheduler': {
            'task': 'reports.scheduler',
            'schedule': crontab(minute='*', hour='*'),
        },
        'reports.prune_log': {
            'task': 'reports.prune_log',
            'schedule': crontab(minute=0, hour=0),
        },
    }

CELERY_CONFIG = CeleryConfig

# Feature Flags
FEATURE_FLAGS = {
    'ALERT_REPORTS': True,
    'DASHBOARD_NATIVE_FILTERS': True,
    'DASHBOARD_CROSS_FILTERS': True,
    'ENABLE_TEMPLATE_PROCESSING': True,
}

# Webdriver Configuration for Alerts & Reports
WEBDRIVER_BASEURL = os.environ.get('RAILWAY_PUBLIC_DOMAIN', 'http://localhost:8088')
if not WEBDRIVER_BASEURL.startswith('http'):
    WEBDRIVER_BASEURL = f'https://{WEBDRIVER_BASEURL}'
WEBDRIVER_BASEURL_USER_FRIENDLY = WEBDRIVER_BASEURL

# Security Headers
TALISMAN_ENABLED = True
TALISMAN_CONFIG = {
    'force_https': True,
    'force_https_permanent': True,
}

# Logging
import logging
LOG_LEVEL = logging.INFO
ENABLE_TIME_ROTATE = True

# Allow public read access for dashboards (optional)
PUBLIC_ROLE_LIKE = "Gamma"
```

### Step 2: Create Railway Service Files

Create `railway/Procfile`:

```
web: gunicorn -b 0.0.0.0:$PORT -w 4 -k gevent --timeout 300 --limit-request-line 0 --limit-request-field_size 0 "superset.app:create_app()"
worker: celery --app=superset.tasks.celery_app:app worker --pool=prefork -O fair -c 4
beat: celery --app=superset.tasks.celery_app:app beat --pidfile /tmp/celerybeat.pid -l info -s /tmp/celerybeat-schedule
```

### Step 3: Create Init Script

Create `railway/init.sh`:

```bash
#!/bin/bash
set -e

echo "Initializing Superset..."

# Wait for database to be ready
echo "Waiting for database..."
while ! pg_isready -h $(echo $DATABASE_URL | sed 's/.*@\(.*\):\(.*\)\/.*/\1/') -p $(echo $DATABASE_URL | sed 's/.*:\([0-9]*\)\/.*/\1/') > /dev/null 2>&1; do
  sleep 1
done

echo "Database is ready!"

# Initialize database
superset db upgrade

# Create admin user if not exists
superset fab create-admin \
    --username admin \
    --firstname Admin \
    --lastname User \
    --email admin@superset.com \
    --password "${ADMIN_PASSWORD:-admin}" || echo "Admin user already exists"

# Initialize Superset
superset init

echo "Superset initialization complete!"
```

Make it executable:
```bash
chmod +x railway/init.sh
```

### Step 4: Deploy to Railway

#### Using Railway CLI:

```bash
# Install Railway CLI
npm i -g @railway/cli

# Login
railway login

# Create new project
railway init

# Link to your Railway project
railway link

# Add PostgreSQL
railway add --database postgresql

# Add Redis
railway add --database redis

# Set environment variables
railway variables set SUPERSET_SECRET_KEY=$(openssl rand -base64 42)
railway variables set ADMIN_PASSWORD=your_secure_password

# Deploy
railway up
```

#### Using Railway Dashboard:

1. Go to your Railway project
2. Click on your service
3. Go to "Settings" → "Deploy"
4. Set the Dockerfile path to `Dockerfile.railway`
5. Click "Deploy"

---

## Environment Variables

Configure these in Railway Dashboard (Settings → Variables):

### Required Variables:

```bash
# Security (CRITICAL - Generate unique key)
SUPERSET_SECRET_KEY=your_unique_secret_key_here

# Admin User
ADMIN_PASSWORD=your_admin_password

# Database (Auto-configured by Railway PostgreSQL)
DATABASE_URL=${{Postgres.DATABASE_URL}}

# Redis (Auto-configured by Railway Redis)
REDIS_URL=${{Redis.REDIS_URL}}

# Public Domain (Auto-configured by Railway)
RAILWAY_PUBLIC_DOMAIN=${{RAILWAY_PUBLIC_DOMAIN}}
```

### Optional Variables:

```bash
# Application Settings
SUPERSET_ENV=production
SUPERSET_PORT=8088

# Gunicorn Configuration
WEB_CONCURRENCY=4
WORKER_TIMEOUT=300

# Feature Flags
ENABLE_ALERTS_REPORTS=true

# SMTP (for email reports)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
SMTP_MAIL_FROM=superset@yourdomain.com
```

### Generate SECRET_KEY:

```bash
openssl rand -base64 42
```

Or in Python:
```python
import secrets
print(secrets.token_urlsafe(42))
```

---

## Database Setup

Railway automatically provisions PostgreSQL. The `DATABASE_URL` is automatically injected.

### Run Database Migrations:

1. **Using Railway CLI**:

```bash
railway run superset db upgrade
railway run superset init
```

2. **Using Railway Dashboard**:
   - Go to your service
   - Click "Deploy" → "Custom Start Command"
   - Run: `/app/railway/init.sh`

---

## Configuration

### Multiple Services Setup

For production, deploy separate services:

1. **Web Service** (Main App):
   - Start command: `gunicorn -b 0.0.0.0:$PORT -w 4 -k gevent --timeout 300 "superset.app:create_app()"`
   - Expose public URL: Yes

2. **Worker Service** (Celery Worker):
   - Start command: `celery --app=superset.tasks.celery_app:app worker --pool=prefork -O fair -c 4`
   - Expose public URL: No

3. **Beat Service** (Celery Beat Scheduler):
   - Start command: `celery --app=superset.tasks.celery_app:app beat -l info`
   - Expose public URL: No

### Resource Allocation:

Railway automatically scales resources. For better performance:

- **Web Service**: 2GB RAM, 2 vCPU
- **Worker Service**: 2GB RAM, 2 vCPU
- **Beat Service**: 512MB RAM, 1 vCPU

---

## Custom Domain

### Add Custom Domain in Railway:

1. Go to your service in Railway Dashboard
2. Click "Settings" → "Domains"
3. Click "Add Domain"
4. Enter your custom domain (e.g., `superset.yourdomain.com`)
5. Add the provided CNAME record to your DNS provider

Railway automatically provisions SSL certificates via Let's Encrypt.

---

## Scaling and Performance

### Horizontal Scaling:

Railway supports replicas:

1. Go to service settings
2. Enable "Autoscaling"
3. Set min/max replicas

### Performance Optimization:

```bash
# Increase Gunicorn workers
railway variables set WEB_CONCURRENCY=8

# Increase timeout for long-running queries
railway variables set WORKER_TIMEOUT=600

# Enable connection pooling
railway variables set SQLALCHEMY_POOL_SIZE=20
railway variables set SQLALCHEMY_MAX_OVERFLOW=40
```

### Caching:

Redis is already configured. To optimize:

```python
# In superset_config.py
CACHE_DEFAULT_TIMEOUT = 3600  # 1 hour
DATA_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 3600,
}
```

---

## Monitoring and Logs

### View Logs:

**Railway CLI:**
```bash
railway logs
```

**Railway Dashboard:**
- Go to your service
- Click "Deployments" → Select deployment → "Logs"

### Health Checks:

Railway automatically monitors `/health` endpoint.

Manual check:
```bash
curl https://your-app.railway.app/health
```

### Metrics:

Railway provides built-in metrics:
- CPU usage
- Memory usage
- Network I/O
- Request count

Access via: Service → "Metrics"

---

## Troubleshooting

### Common Issues:

#### 1. Application Won't Start

**Check logs:**
```bash
railway logs
```

**Common causes:**
- Missing `SUPERSET_SECRET_KEY`
- Database connection failure
- Out of memory

**Solution:**
```bash
# Verify environment variables
railway variables

# Check database connection
railway run psql $DATABASE_URL
```

#### 2. Database Migrations Failed

**Run migrations manually:**
```bash
railway run superset db upgrade
railway run superset init
```

#### 3. Out of Memory

**Reduce workers:**
```bash
railway variables set WEB_CONCURRENCY=2
```

#### 4. Slow Performance

**Check database connections:**
```bash
# Increase pool size
railway variables set SQLALCHEMY_POOL_SIZE=20
```

**Enable caching:**
```bash
railway variables set ENABLE_CACHE=true
```

#### 5. SSL/HTTPS Issues

Railway automatically provides HTTPS. If issues persist:

1. Check custom domain CNAME records
2. Wait for SSL certificate provisioning (can take up to 24 hours)
3. Clear browser cache

### Debug Mode:

Enable debug logging temporarily:

```bash
railway variables set SUPERSET_LOG_LEVEL=DEBUG
```

**⚠️ Disable in production after debugging!**

---

## Backup and Recovery

### Database Backup:

**Using Railway CLI:**
```bash
# Export database
railway run pg_dump $DATABASE_URL > backup.sql

# Restore database
railway run psql $DATABASE_URL < backup.sql
```

**Using Railway Dashboard:**
1. Go to PostgreSQL service
2. Click "Backups" (if available in your plan)
3. Download backup

### Configuration Backup:

Export environment variables:
```bash
railway variables > railway-env-backup.txt
```

---

## Cost Optimization

### Railway Pricing:

- **Free Tier**: $5 credit/month, limited resources
- **Developer Plan**: $5/month + usage
- **Team Plan**: $20/month + usage

### Optimization Tips:

1. **Use fewer services**: Combine web + worker in development
2. **Scale down when not in use**: Railway's sleep feature
3. **Optimize Docker image**: Use multi-stage builds
4. **Cache dependencies**: Speed up builds

---

## Production Checklist

- [ ] Generate unique `SUPERSET_SECRET_KEY`
- [ ] Set strong `ADMIN_PASSWORD`
- [ ] Configure PostgreSQL database (via Railway)
- [ ] Configure Redis cache (via Railway)
- [ ] Enable HTTPS (automatic with Railway)
- [ ] Set up custom domain
- [ ] Configure email (SMTP) for alerts
- [ ] Set up separate worker service
- [ ] Enable database backups
- [ ] Configure monitoring and alerts
- [ ] Test health endpoints
- [ ] Review security settings
- [ ] Set up CI/CD (GitHub Actions)

---

## Additional Resources

- [Railway Documentation](https://docs.railway.app/)
- [Superset Documentation](https://superset.apache.org/docs/intro)
- [Railway Discord](https://discord.gg/railway)
- [Railway Status](https://status.railway.app/)

---

## Support

- **Railway Issues**: [Railway Support](https://railway.app/help)
- **Superset Issues**: [GitHub Issues](https://github.com/apache/superset/issues)
- **Community**: [Superset Slack](https://apache-superset.slack.com/)

---

**Last Updated**: December 2024  
**Railway Version**: Latest  
**Superset Version**: 5.0+
