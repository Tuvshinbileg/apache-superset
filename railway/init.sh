#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

echo "🚂 Initializing Superset for Railway..."

# Wait for PostgreSQL to be ready
if [ -n "$DATABASE_URL" ]; then
    echo "⏳ Waiting for database to be ready..."
    
    # Extract host and port from DATABASE_URL
    DB_HOST=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    DB_PORT=$(echo "$DATABASE_URL" | sed -n 's/.*:\([0-9]*\)\/.*/\1/p')
    
    if [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ]; then
        # Wait up to 60 seconds for database
        for i in {1..60}; do
            if pg_isready -h "$DB_HOST" -p "$DB_PORT" > /dev/null 2>&1; then
                echo "✅ Database is ready!"
                break
            fi
            echo "   Waiting for database... ($i/60)"
            sleep 1
        done
    fi
fi

# Initialize/upgrade database schema
echo "📊 Running database migrations..."
superset db upgrade

# Create admin user if it doesn't exist
echo "👤 Setting up admin user..."
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

superset fab create-admin \
    --username admin \
    --firstname Admin \
    --lastname User \
    --email "${ADMIN_EMAIL:-admin@superset.com}" \
    --password "$ADMIN_PASSWORD" 2>&1 | grep -v "already exists" || echo "✅ Admin user ready"

# Initialize Superset (roles, permissions, etc.)
echo "🔧 Initializing Superset..."
superset init

# Load examples if requested
if [ "$SUPERSET_LOAD_EXAMPLES" = "yes" ] || [ "$SUPERSET_LOAD_EXAMPLES" = "true" ]; then
    echo "📦 Loading example data..."
    superset load_examples
fi

echo "✅ Superset initialization complete!"
echo ""
echo "🎉 You can now access Superset at your Railway URL"
echo "📝 Default credentials:"
echo "   Username: admin"
echo "   Password: $ADMIN_PASSWORD"
echo ""
echo "⚠️  IMPORTANT: Change the admin password immediately!"
