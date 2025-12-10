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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-docker/.env}"
DEPLOY_DIR="${DEPLOY_DIR:-$PWD}"

# Function to print colored messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command_exists docker; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command_exists docker-compose && ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

# Function to generate secret key
generate_secret_key() {
    if command_exists openssl; then
        openssl rand -base64 42
    else
        # Fallback to Python
        python3 -c "import secrets; print(secrets.token_urlsafe(42))"
    fi
}

# Function to create directory structure
create_directory_structure() {
    log_info "Creating directory structure..."
    
    mkdir -p "$DEPLOY_DIR"/{config,data,scripts,nginx/ssl,backups}
    
    log_success "Directory structure created"
}

# Function to check environment file
check_env_file() {
    log_info "Checking environment file..."
    
    if [ ! -f "$ENV_FILE" ]; then
        log_warning "Environment file not found: $ENV_FILE"
        log_info "Creating template environment file..."
        
        mkdir -p "$(dirname "$ENV_FILE")"
        
        SECRET_KEY=$(generate_secret_key)
        
        cat > "$ENV_FILE" <<EOF
# Database Configuration
DATABASE_DIALECT=postgresql
DATABASE_USER=superset
DATABASE_PASSWORD=$(generate_secret_key | head -c 16)
DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_DB=superset

# Redis Configuration
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(generate_secret_key | head -c 16)
REDIS_CELERY_DB=0
REDIS_RESULTS_DB=1

# Superset Configuration
SUPERSET_SECRET_KEY=${SECRET_KEY}
SUPERSET_LOAD_EXAMPLES=no
SUPERSET_PORT=8088
SUPERSET_PUBLIC_URL=http://localhost

# PostgreSQL Configuration
POSTGRES_USER=superset
POSTGRES_PASSWORD=$(grep DATABASE_PASSWORD "$ENV_FILE" | cut -d'=' -f2)
POSTGRES_DB=superset

# SMTP Configuration (optional - for alerts and reports)
# SMTP_HOST=smtp.gmail.com
# SMTP_PORT=587
# SMTP_USER=your-email@gmail.com
# SMTP_PASSWORD=your-app-password
# SMTP_MAIL_FROM=superset@example.com
EOF
        
        log_success "Template environment file created: $ENV_FILE"
        log_warning "Please review and update the credentials in $ENV_FILE"
    else
        log_success "Environment file exists: $ENV_FILE"
        
        # Check for placeholder values
        if grep -q "CHANGE_ME" "$ENV_FILE" || grep -q "your-" "$ENV_FILE"; then
            log_warning "⚠️  Environment file contains placeholder values!"
            log_warning "Please update the credentials in $ENV_FILE"
        fi
    fi
}

# Function to check compose file
check_compose_file() {
    log_info "Checking Docker Compose file..."
    
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Docker Compose file not found: $COMPOSE_FILE"
        log_info "Please create a docker-compose.prod.yml file"
        log_info "See DEPLOYMENT.md for a production-ready template"
        exit 1
    fi
    
    log_success "Docker Compose file found: $COMPOSE_FILE"
}

# Function to validate configuration
validate_configuration() {
    log_info "Validating configuration..."
    
    # Check secret key
    SECRET_KEY=$(grep SUPERSET_SECRET_KEY "$ENV_FILE" | cut -d'=' -f2)
    if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" = "CHANGE_ME" ]; then
        log_error "SUPERSET_SECRET_KEY is not set or is a placeholder"
        log_info "Generate one with: openssl rand -base64 42"
        exit 1
    fi
    
    # Check database password
    DB_PASSWORD=$(grep DATABASE_PASSWORD "$ENV_FILE" | cut -d'=' -f2)
    if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "CHANGE_ME" ]; then
        log_error "DATABASE_PASSWORD is not set or is a placeholder"
        exit 1
    fi
    
    log_success "Configuration validated"
}

# Function to pull images
pull_images() {
    log_info "Pulling Docker images..."
    
    if command_exists docker-compose; then
        docker-compose -f "$COMPOSE_FILE" pull
    else
        docker compose -f "$COMPOSE_FILE" pull
    fi
    
    log_success "Images pulled successfully"
}

# Function to build custom images
build_images() {
    log_info "Building custom images..."
    
    if [ -f "Dockerfile.production" ]; then
        log_info "Found Dockerfile.production, building custom image..."
        docker build -f Dockerfile.production -t mycompany/superset:latest .
        log_success "Custom image built successfully"
    else
        log_info "No Dockerfile.production found, skipping custom build"
    fi
}

# Function to start services
start_services() {
    log_info "Starting services..."
    
    if command_exists docker-compose; then
        docker-compose -f "$COMPOSE_FILE" up -d
    else
        docker compose -f "$COMPOSE_FILE" up -d
    fi
    
    log_success "Services started"
}

# Function to check service health
check_health() {
    log_info "Checking service health..."
    
    # Wait for services to be healthy
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -f -s http://localhost:8088/health >/dev/null 2>&1; then
            log_success "Superset is healthy!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_info "Waiting for Superset to be ready... (attempt $attempt/$max_attempts)"
        sleep 10
    done
    
    log_error "Superset failed to become healthy"
    log_info "Check logs with: docker-compose -f $COMPOSE_FILE logs"
    return 1
}

# Function to show service status
show_status() {
    log_info "Service status:"
    echo ""
    
    if command_exists docker-compose; then
        docker-compose -f "$COMPOSE_FILE" ps
    else
        docker compose -f "$COMPOSE_FILE" ps
    fi
}

# Function to show access information
show_access_info() {
    echo ""
    echo "==================== ACCESS INFORMATION ===================="
    echo ""
    echo -e "${GREEN}Superset URL:${NC} http://localhost:8088"
    echo ""
    echo -e "${GREEN}Default Credentials:${NC}"
    echo "Username: admin"
    echo "Password: admin"
    echo -e "${RED}⚠️  CHANGE DEFAULT PASSWORD IMMEDIATELY!${NC}"
    echo ""
    echo "==================== USEFUL COMMANDS ===================="
    echo "View logs:"
    echo "  docker-compose -f $COMPOSE_FILE logs -f"
    echo ""
    echo "View specific service logs:"
    echo "  docker-compose -f $COMPOSE_FILE logs -f superset"
    echo ""
    echo "Access Superset container:"
    echo "  docker-compose -f $COMPOSE_FILE exec superset bash"
    echo ""
    echo "Stop services:"
    echo "  docker-compose -f $COMPOSE_FILE stop"
    echo ""
    echo "Stop and remove services:"
    echo "  docker-compose -f $COMPOSE_FILE down"
    echo ""
    echo "Backup database:"
    echo "  ./scripts/deployment/backup.sh"
    echo "==========================================================="
}

# Function to create backup script
create_backup_script() {
    if [ ! -f "$DEPLOY_DIR/scripts/deployment/backup.sh" ]; then
        log_info "Creating backup script..."
        
        mkdir -p "$DEPLOY_DIR/scripts/deployment"
        
        cat > "$DEPLOY_DIR/scripts/deployment/backup.sh" <<'EOF'
#!/bin/bash
# Quick backup script for Docker Compose deployment

BACKUP_DIR="./backups"
DATE=$(date +%Y%m%d_%H%M%S)
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"

mkdir -p "$BACKUP_DIR"

echo "Backing up Superset database..."
docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump -U superset superset > "$BACKUP_DIR/superset_${DATE}.sql"

echo "Backing up configuration..."
tar -czf "$BACKUP_DIR/config_${DATE}.tar.gz" config/ docker/.env

echo "Backup completed: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*_${DATE}*
EOF
        
        chmod +x "$DEPLOY_DIR/scripts/deployment/backup.sh"
        log_success "Backup script created"
    fi
}

# Function to show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy Apache Superset using Docker Compose

OPTIONS:
    -f, --file <file>              Docker Compose file (default: docker-compose.prod.yml)
    -e, --env <file>              Environment file (default: docker/.env)
    -d, --dir <directory>         Deployment directory (default: current directory)
    -b, --build                   Build custom images before deploying
    -p, --pull                    Pull images before deploying
    -h, --help                    Show this help message

EXAMPLES:
    # Deploy with default settings
    $0

    # Deploy with custom compose file
    $0 -f my-compose.yml

    # Deploy and build custom images
    $0 --build

    # Deploy and pull latest images
    $0 --pull

ENVIRONMENT VARIABLES:
    COMPOSE_FILE    Docker Compose file path
    ENV_FILE        Environment file path
    DEPLOY_DIR      Deployment directory

EOF
}

# Parse command line arguments
BUILD_IMAGES=false
PULL_IMAGES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            COMPOSE_FILE="$2"
            shift 2
            ;;
        -e|--env)
            ENV_FILE="$2"
            shift 2
            ;;
        -d|--dir)
            DEPLOY_DIR="$2"
            shift 2
            ;;
        -b|--build)
            BUILD_IMAGES=true
            shift
            ;;
        -p|--pull)
            PULL_IMAGES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║      Apache Superset Docker Compose Deployment           ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    log_warning "⚠️  Docker Compose is NOT recommended for production!"
    log_warning "⚠️  For production deployments, use Kubernetes instead."
    echo ""
    
    read -p "Continue with Docker Compose deployment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled"
        exit 0
    fi
    
    check_prerequisites
    create_directory_structure
    check_env_file
    check_compose_file
    validate_configuration
    
    if [ "$PULL_IMAGES" = true ]; then
        pull_images
    fi
    
    if [ "$BUILD_IMAGES" = true ]; then
        build_images
    fi
    
    start_services
    
    log_info "Waiting for services to start..."
    sleep 5
    
    show_status
    check_health
    
    create_backup_script
    show_access_info
    
    echo ""
    log_success "Deployment completed successfully! 🎉"
    echo ""
}

# Run main function
main
