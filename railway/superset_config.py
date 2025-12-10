# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

import os
from datetime import timedelta
from redis import Redis
from celery.schedules import crontab

# Railway-specific configuration for Apache Superset
SUPERSET_ENV = os.environ.get('SUPERSET_ENV', 'production')

# Security Configuration - CRITICAL
SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY')
if not SECRET_KEY:
    raise ValueError("SUPERSET_SECRET_KEY environment variable must be set")

# Previous secret key for key rotation (optional)
PREVIOUS_SECRET_KEY = os.environ.get('SUPERSET_PREVIOUS_SECRET_KEY')

# Database Configuration - Railway PostgreSQL
SQLALCHEMY_DATABASE_URI = os.environ.get('DATABASE_URL')
if SQLALCHEMY_DATABASE_URI:
    # Railway uses postgres:// but SQLAlchemy needs postgresql://
    if SQLALCHEMY_DATABASE_URI.startswith('postgres://'):
        SQLALCHEMY_DATABASE_URI = SQLALCHEMY_DATABASE_URI.replace(
            'postgres://', 'postgresql://', 1
        )

# Database connection pool configuration
SQLALCHEMY_ENGINE_OPTIONS = {
    'pool_size': int(os.environ.get('SQLALCHEMY_POOL_SIZE', '10')),
    'pool_recycle': 3600,
    'pool_pre_ping': True,
    'max_overflow': int(os.environ.get('SQLALCHEMY_MAX_OVERFLOW', '20')),
    'connect_args': {
        'connect_timeout': 10,
    }
}

# Prevent SQL Lab from executing too large queries
SQLLAB_TIMEOUT = int(os.environ.get('SQLLAB_TIMEOUT', '300'))
SUPERSET_WEBSERVER_TIMEOUT = int(os.environ.get('WORKER_TIMEOUT', '300'))

# Redis Configuration - Railway Redis
REDIS_URL = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')

# Parse Redis URL for individual components
from urllib.parse import urlparse
redis_url = urlparse(REDIS_URL)
REDIS_HOST = redis_url.hostname or 'localhost'
REDIS_PORT = redis_url.port or 6379
REDIS_PASSWORD = redis_url.password

# Session Configuration - Server-side sessions with Redis
SESSION_SERVER_SIDE = True
SESSION_TYPE = 'redis'
SESSION_REDIS = Redis.from_url(REDIS_URL)
SESSION_USE_SIGNER = True
PERMANENT_SESSION_LIFETIME = timedelta(
    hours=int(os.environ.get('SESSION_LIFETIME_HOURS', '8'))
)

# Cookie Security Settings
SESSION_COOKIE_SECURE = os.environ.get('SESSION_COOKIE_SECURE', 'true').lower() == 'true'
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = os.environ.get('SESSION_COOKIE_SAMESITE', 'Lax')

# Cache Configuration
CACHE_DEFAULT_TIMEOUT = int(os.environ.get('CACHE_DEFAULT_TIMEOUT', '300'))

CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': CACHE_DEFAULT_TIMEOUT,
    'CACHE_KEY_PREFIX': 'superset_',
    'CACHE_REDIS_URL': REDIS_URL,
}

DATA_CACHE_CONFIG = CACHE_CONFIG.copy()
THUMBNAIL_CACHE_CONFIG = CACHE_CONFIG.copy()

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
    }

CELERY_CONFIG = CeleryConfig

# Feature Flags
FEATURE_FLAGS = {
    'ALERT_REPORTS': os.environ.get('ENABLE_ALERTS_REPORTS', 'true').lower() == 'true',
    'DASHBOARD_NATIVE_FILTERS': True,
    'DASHBOARD_CROSS_FILTERS': True,
    'DASHBOARD_RBAC': True,
    'ENABLE_TEMPLATE_PROCESSING': True,
    'EMBEDDED_SUPERSET': os.environ.get('ENABLE_EMBEDDED', 'false').lower() == 'true',
}

# Webdriver Configuration for Alerts & Reports
# Railway provides RAILWAY_PUBLIC_DOMAIN
railway_domain = os.environ.get('RAILWAY_PUBLIC_DOMAIN', os.environ.get('RAILWAY_STATIC_URL', ''))
if railway_domain:
    if not railway_domain.startswith('http'):
        WEBDRIVER_BASEURL = f'https://{railway_domain}/'
    else:
        WEBDRIVER_BASEURL = railway_domain if railway_domain.endswith('/') else f'{railway_domain}/'
else:
    WEBDRIVER_BASEURL = 'http://localhost:8088/'

WEBDRIVER_BASEURL_USER_FRIENDLY = WEBDRIVER_BASEURL

# Email Configuration for Alerts & Reports
SMTP_HOST = os.environ.get('SMTP_HOST')
SMTP_PORT = int(os.environ.get('SMTP_PORT', '587'))
SMTP_STARTTLS = os.environ.get('SMTP_STARTTLS', 'true').lower() == 'true'
SMTP_SSL = os.environ.get('SMTP_SSL', 'false').lower() == 'true'
SMTP_USER = os.environ.get('SMTP_USER')
SMTP_PASSWORD = os.environ.get('SMTP_PASSWORD')
SMTP_MAIL_FROM = os.environ.get('SMTP_MAIL_FROM', 'superset@example.com')

# Logging Configuration
import logging

log_level_str = os.environ.get('SUPERSET_LOG_LEVEL', 'INFO')
LOG_LEVEL = getattr(logging, log_level_str.upper(), logging.INFO)
LOG_FORMAT = '%(asctime)s:%(levelname)s:%(name)s:%(message)s'
ENABLE_TIME_ROTATE = True

# Security Headers - Using Talisman
TALISMAN_ENABLED = os.environ.get('TALISMAN_ENABLED', 'true').lower() == 'true'

if TALISMAN_ENABLED:
    TALISMAN_CONFIG = {
        'content_security_policy': {
            'default-src': ["'self'"],
            'img-src': ["'self'", 'data:', 'https:', 'blob:'],
            'worker-src': ["'self'", 'blob:'],
            'connect-src': ["'self'", 'https://api.mapbox.com'],
            'object-src': "'none'",
            'style-src': ["'self'", "'unsafe-inline'"],
            'script-src': ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
        },
        'force_https': True,
        'force_https_permanent': True,
    }

# CSRF Protection
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = None
WTF_CSRF_SSL_STRICT = True

# Prevent unsafe database connections
PREVENT_UNSAFE_DB_CONNECTIONS = os.environ.get('PREVENT_UNSAFE_DB_CONNECTIONS', 'true').lower() == 'true'

# Rate limiting
RATELIMIT_ENABLED = os.environ.get('RATELIMIT_ENABLED', 'true').lower() == 'true'
if RATELIMIT_ENABLED:
    RATELIMIT_STORAGE_URL = REDIS_URL

# Flask-AppBuilder configuration
APP_NAME = os.environ.get('APP_NAME', 'Superset')
APP_ICON = '/static/assets/images/superset-logo-horiz.png'

# Public role for read-only access (optional)
PUBLIC_ROLE_LIKE = os.environ.get('PUBLIC_ROLE_LIKE', None)

# Row limit for SQL Lab
ROW_LIMIT = int(os.environ.get('ROW_LIMIT', '5000'))
SQLLAB_CTAS_NO_LIMIT = os.environ.get('SQLLAB_CTAS_NO_LIMIT', 'false').lower() == 'true'

# Additional Flask configuration
SEND_FILE_MAX_AGE_DEFAULT = 31536000  # 1 year
COMPRESS_REGISTER = False  # Disable if using Nginx compression

# Health check endpoint
HEALTH_CHECK_ENDPOINT = '/health'
