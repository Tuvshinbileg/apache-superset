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
BACKUP_DIR="${BACKUP_DIR:-./backups}"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-auto}"  # auto, kubernetes, docker-compose

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

# Function to detect deployment type
detect_deployment_type() {
    if [ "$DEPLOYMENT_TYPE" != "auto" ]; then
        echo "$DEPLOYMENT_TYPE"
        return
    fi
    
    # Check for Kubernetes
    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        if kubectl get namespace superset >/dev/null 2>&1; then
            echo "kubernetes"
            return
        fi
    fi
    
    # Check for Docker Compose
    if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
        if [ -f "docker-compose.yml" ] || [ -f "docker-compose.prod.yml" ]; then
            echo "docker-compose"
            return
        fi
    fi
    
    echo "unknown"
}

# Function to create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    log_success "Backup directory ready"
}

# Function to backup Kubernetes deployment
backup_kubernetes() {
    local namespace="${NAMESPACE:-superset}"
    local backup_file="$BACKUP_DIR/superset_k8s_${DATE}.tar.gz"
    local temp_dir="$BACKUP_DIR/temp_${DATE}"
    
    log_info "Starting Kubernetes backup..."
    
    mkdir -p "$temp_dir"
    
    # Backup database from PostgreSQL pod
    log_info "Backing up metadata database..."
    
    # Find PostgreSQL pod
    local pg_pod=$(kubectl get pods -n "$namespace" -l app=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$pg_pod" ]; then
        kubectl exec -n "$namespace" "$pg_pod" -- pg_dump -U superset superset > "$temp_dir/database_${DATE}.sql"
        log_success "Database backup created"
    else
        log_warning "PostgreSQL pod not found in namespace $namespace"
        log_warning "If using external database, backup separately"
    fi
    
    # Backup Kubernetes resources
    log_info "Backing up Kubernetes resources..."
    
    kubectl get all,configmap,secret,pvc,ingress -n "$namespace" -o yaml > "$temp_dir/k8s_resources_${DATE}.yaml"
    
    # Backup Helm values
    if command -v helm >/dev/null 2>&1; then
        log_info "Backing up Helm values..."
        helm get values superset -n "$namespace" > "$temp_dir/helm_values_${DATE}.yaml" 2>/dev/null || true
    fi
    
    # Create tarball
    log_info "Creating compressed backup archive..."
    tar -czf "$backup_file" -C "$BACKUP_DIR" "temp_${DATE}"
    
    # Cleanup temp directory
    rm -rf "$temp_dir"
    
    log_success "Kubernetes backup completed: $backup_file"
    ls -lh "$backup_file"
}

# Function to backup Docker Compose deployment
backup_docker_compose() {
    local compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
    local backup_file="$BACKUP_DIR/superset_docker_${DATE}.tar.gz"
    local temp_dir="$BACKUP_DIR/temp_${DATE}"
    
    log_info "Starting Docker Compose backup..."
    
    mkdir -p "$temp_dir"
    
    # Backup database
    log_info "Backing up metadata database..."
    
    if docker-compose -f "$compose_file" ps | grep -q postgres; then
        docker-compose -f "$compose_file" exec -T postgres pg_dump -U superset superset > "$temp_dir/database_${DATE}.sql"
        log_success "Database backup created"
    elif docker ps | grep -q superset_postgres; then
        docker exec superset_postgres pg_dump -U superset superset > "$temp_dir/database_${DATE}.sql"
        log_success "Database backup created"
    else
        log_warning "PostgreSQL container not found"
    fi
    
    # Backup configuration files
    log_info "Backing up configuration files..."
    
    if [ -d "config" ]; then
        cp -r config "$temp_dir/"
    fi
    
    if [ -f "docker/.env" ]; then
        cp docker/.env "$temp_dir/env_${DATE}"
    fi
    
    if [ -f "$compose_file" ]; then
        cp "$compose_file" "$temp_dir/"
    fi
    
    # Backup Docker volumes
    log_info "Backing up Docker volumes..."
    
    for volume in $(docker volume ls --filter name=superset -q); do
        log_info "Backing up volume: $volume"
        docker run --rm \
            -v "$volume":/volume \
            -v "$temp_dir":/backup \
            alpine tar -czf "/backup/volume_${volume}_${DATE}.tar.gz" -C /volume .
    done
    
    # Create tarball
    log_info "Creating compressed backup archive..."
    tar -czf "$backup_file" -C "$BACKUP_DIR" "temp_${DATE}"
    
    # Cleanup temp directory
    rm -rf "$temp_dir"
    
    log_success "Docker Compose backup completed: $backup_file"
    ls -lh "$backup_file"
}

# Function to cleanup old backups
cleanup_old_backups() {
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    
    local deleted_count=0
    
    # Find and delete old backup files
    while IFS= read -r file; do
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
        log_info "Deleted: $(basename "$file")"
    done < <(find "$BACKUP_DIR" -name "superset_*.tar.gz" -type f -mtime "+$RETENTION_DAYS")
    
    # Also cleanup old SQL dumps
    while IFS= read -r file; do
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
        log_info "Deleted: $(basename "$file")"
    done < <(find "$BACKUP_DIR" -name "*.sql" -type f -mtime "+$RETENTION_DAYS")
    
    if [ $deleted_count -gt 0 ]; then
        log_success "Deleted $deleted_count old backup(s)"
    else
        log_info "No old backups to delete"
    fi
}

# Function to list existing backups
list_backups() {
    log_info "Existing backups:"
    echo ""
    
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -name "superset_*.tar.gz" -type f -exec ls -lh {} \; | awk '{print $9, "(" $5 ")"}'
        
        echo ""
        local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
        log_info "Total backup size: $total_size"
    else
        log_warning "Backup directory not found: $BACKUP_DIR"
    fi
}

# Function to verify backup
verify_backup() {
    local backup_file=$1
    
    log_info "Verifying backup: $backup_file"
    
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Test if tarball is valid
    if tar -tzf "$backup_file" >/dev/null 2>&1; then
        log_success "Backup verification passed"
        return 0
    else
        log_error "Backup verification failed - corrupted archive"
        return 1
    fi
}

# Function to show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Backup Apache Superset deployment (database, configuration, volumes)

OPTIONS:
    -d, --dir <directory>         Backup directory (default: ./backups)
    -t, --type <type>            Deployment type: kubernetes, docker-compose, auto (default: auto)
    -r, --retention <days>       Retention period in days (default: 30)
    -l, --list                   List existing backups
    -c, --cleanup                Cleanup old backups only
    -h, --help                   Show this help message

EXAMPLES:
    # Backup with auto-detection
    $0

    # Backup Kubernetes deployment
    $0 -t kubernetes

    # Backup to custom directory
    $0 -d /var/backups/superset

    # List existing backups
    $0 --list

    # Cleanup old backups
    $0 --cleanup

ENVIRONMENT VARIABLES:
    BACKUP_DIR          Backup directory path
    RETENTION_DAYS      Number of days to retain backups
    DEPLOYMENT_TYPE     kubernetes, docker-compose, or auto
    NAMESPACE           Kubernetes namespace (default: superset)
    COMPOSE_FILE        Docker Compose file path

RESTORE:
    Kubernetes:
        kubectl create namespace superset
        tar -xzf backup_file.tar.gz
        kubectl apply -f temp_*/k8s_resources_*.yaml
        # Restore database manually

    Docker Compose:
        tar -xzf backup_file.tar.gz
        # Restore volumes and configuration
        # Import database with: docker-compose exec -T postgres psql -U superset superset < database.sql

EOF
}

# Parse command line arguments
LIST_ONLY=false
CLEANUP_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -t|--type)
            DEPLOYMENT_TYPE="$2"
            shift 2
            ;;
        -r|--retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -c|--cleanup)
            CLEANUP_ONLY=true
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
    echo "║            Apache Superset Backup Script                 ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ "$LIST_ONLY" = true ]; then
        list_backups
        exit 0
    fi
    
    if [ "$CLEANUP_ONLY" = true ]; then
        cleanup_old_backups
        exit 0
    fi
    
    create_backup_dir
    
    # Detect deployment type
    local detected_type=$(detect_deployment_type)
    log_info "Detected deployment type: $detected_type"
    
    # Perform backup based on deployment type
    case $detected_type in
        kubernetes)
            backup_kubernetes
            ;;
        docker-compose)
            backup_docker_compose
            ;;
        unknown)
            log_error "Could not detect deployment type"
            log_info "Please specify deployment type with -t option"
            exit 1
            ;;
    esac
    
    # Verify the backup
    local latest_backup=$(ls -t "$BACKUP_DIR"/superset_*.tar.gz 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        verify_backup "$latest_backup"
    fi
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Show backup statistics
    echo ""
    list_backups
    
    echo ""
    log_success "Backup completed successfully! 🎉"
    echo ""
}

# Run main function
main
