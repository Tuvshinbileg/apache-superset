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
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-auto}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

# Health check endpoints
HEALTH_ENDPOINT="/health"
API_ENDPOINT="/api/v1/health"

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

# Function to send alert
send_alert() {
    local subject="$1"
    local message="$2"
    
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
    fi
    
    log_error "$subject"
    log_error "$message"
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
        if docker ps | grep -q superset; then
            echo "docker-compose"
            return
        fi
    fi
    
    echo "unknown"
}

# Function to check Kubernetes deployment
check_kubernetes() {
    local namespace="${NAMESPACE:-superset}"
    local all_healthy=true
    
    log_info "Checking Kubernetes deployment in namespace: $namespace"
    echo ""
    
    # Check if namespace exists
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        send_alert "Superset Health Check Failed" "Namespace $namespace not found"
        return 1
    fi
    
    # Check pods
    log_info "Checking pods..."
    local total_pods=$(kubectl get pods -n "$namespace" --no-headers | wc -l)
    local running_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Running --no-headers | wc -l)
    local pending_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Pending --no-headers | wc -l)
    local failed_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase=Failed --no-headers | wc -l)
    
    echo "  Total pods: $total_pods"
    echo "  Running: $running_pods"
    if [ $pending_pods -gt 0 ]; then
        log_warning "Pending: $pending_pods"
        all_healthy=false
    fi
    if [ $failed_pods -gt 0 ]; then
        log_error "Failed: $failed_pods"
        all_healthy=false
    fi
    echo ""
    
    # Check specific deployments
    log_info "Checking deployments..."
    for deployment in $(kubectl get deployments -n "$namespace" -o jsonpath='{.items[*].metadata.name}'); do
        local desired=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}')
        local ready=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}')
        
        if [ -z "$ready" ]; then
            ready=0
        fi
        
        if [ "$ready" -eq "$desired" ]; then
            log_success "$deployment: $ready/$desired pods ready"
        else
            log_error "$deployment: $ready/$desired pods ready"
            all_healthy=false
        fi
    done
    echo ""
    
    # Check services
    log_info "Checking services..."
    local superset_svc=$(kubectl get svc -n "$namespace" -l app.kubernetes.io/name=superset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$superset_svc" ]; then
        log_success "Superset service: $superset_svc"
        
        # Try to access health endpoint via port-forward
        local port=$(kubectl get svc "$superset_svc" -n "$namespace" -o jsonpath='{.spec.ports[0].port}')
        log_info "Testing health endpoint..."
        
        # Create temporary port-forward in background
        kubectl port-forward -n "$namespace" "svc/$superset_svc" 18088:$port >/dev/null 2>&1 &
        local pf_pid=$!
        sleep 2
        
        if curl -f -s http://localhost:18088/health >/dev/null 2>&1; then
            log_success "Health endpoint responding"
        else
            log_error "Health endpoint not responding"
            all_healthy=false
        fi
        
        # Cleanup port-forward
        kill $pf_pid 2>/dev/null || true
    else
        log_error "Superset service not found"
        all_healthy=false
    fi
    echo ""
    
    # Check ingress
    log_info "Checking ingress..."
    local ingress=$(kubectl get ingress -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$ingress" ]; then
        local host=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.spec.rules[0].host}')
        log_success "Ingress: $ingress (host: $host)"
        
        if [ -n "$host" ]; then
            if curl -f -s -k "https://$host/health" >/dev/null 2>&1; then
                log_success "External health endpoint responding"
            else
                log_warning "External health endpoint not responding (may require authentication)"
            fi
        fi
    else
        log_info "No ingress configured"
    fi
    echo ""
    
    # Overall status
    if [ "$all_healthy" = true ]; then
        log_success "All Kubernetes components are healthy ✓"
        return 0
    else
        send_alert "Superset Health Check Failed" "Some Kubernetes components are unhealthy. Check the logs for details."
        return 1
    fi
}

# Function to check Docker Compose deployment
check_docker_compose() {
    local compose_file="${COMPOSE_FILE:-docker-compose.prod.yml}"
    local all_healthy=true
    
    log_info "Checking Docker Compose deployment"
    echo ""
    
    # Check if compose file exists
    if [ ! -f "$compose_file" ]; then
        compose_file="docker-compose.yml"
    fi
    
    # Check container status
    log_info "Checking containers..."
    
    for container in superset_app superset_worker superset_worker_beat superset_postgres superset_redis; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
            
            if [ "$status" = "healthy" ] || [ "$status" = "unknown" ]; then
                log_success "$container: running ($status)"
            else
                log_error "$container: unhealthy ($status)"
                all_healthy=false
            fi
        else
            log_error "$container: not running"
            all_healthy=false
        fi
    done
    echo ""
    
    # Check Superset health endpoint
    log_info "Checking Superset health endpoint..."
    
    if curl -f -s http://localhost:8088/health >/dev/null 2>&1; then
        log_success "Health endpoint responding"
    else
        log_error "Health endpoint not responding"
        all_healthy=false
    fi
    echo ""
    
    # Check database connectivity
    log_info "Checking database connectivity..."
    
    if docker exec superset_postgres pg_isready -U superset >/dev/null 2>&1; then
        log_success "PostgreSQL is ready"
    else
        log_error "PostgreSQL is not ready"
        all_healthy=false
    fi
    echo ""
    
    # Check Redis connectivity
    log_info "Checking Redis connectivity..."
    
    if docker exec superset_redis redis-cli ping >/dev/null 2>&1; then
        log_success "Redis is responding"
    else
        log_error "Redis is not responding"
        all_healthy=false
    fi
    echo ""
    
    # Check Celery workers
    log_info "Checking Celery workers..."
    
    if docker exec superset_worker celery -A superset.tasks.celery_app:app inspect ping >/dev/null 2>&1; then
        log_success "Celery workers responding"
    else
        log_warning "Celery workers not responding"
    fi
    echo ""
    
    # Overall status
    if [ "$all_healthy" = true ]; then
        log_success "All Docker Compose components are healthy ✓"
        return 0
    else
        send_alert "Superset Health Check Failed" "Some Docker Compose components are unhealthy. Check the logs for details."
        return 1
    fi
}

# Function to perform detailed health check
detailed_health_check() {
    local url="$1"
    
    log_info "Performing detailed health check..."
    
    # Check main health endpoint
    local health_response=$(curl -s "$url/health" 2>/dev/null)
    if echo "$health_response" | grep -q "ok"; then
        log_success "Main health check: OK"
    else
        log_error "Main health check: Failed"
        return 1
    fi
    
    # Check API health endpoint
    local api_health=$(curl -s "$url/api/v1/health" 2>/dev/null)
    if [ -n "$api_health" ]; then
        log_success "API health check: OK"
    else
        log_warning "API health check: Failed (may require authentication)"
    fi
}

# Function to watch health continuously
watch_health() {
    log_info "Starting continuous health monitoring (interval: ${CHECK_INTERVAL}s)"
    log_info "Press Ctrl+C to stop"
    echo ""
    
    local detected_type=$(detect_deployment_type)
    
    while true; do
        echo "==================== $(date) ===================="
        
        case $detected_type in
            kubernetes)
                check_kubernetes
                ;;
            docker-compose)
                check_docker_compose
                ;;
            *)
                log_error "Unknown deployment type"
                exit 1
                ;;
        esac
        
        echo ""
        log_info "Next check in ${CHECK_INTERVAL} seconds..."
        echo ""
        
        sleep "$CHECK_INTERVAL"
    done
}

# Function to show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Health check script for Apache Superset deployment

OPTIONS:
    -t, --type <type>            Deployment type: kubernetes, docker-compose, auto (default: auto)
    -w, --watch                  Continuous monitoring mode
    -i, --interval <seconds>     Check interval for watch mode (default: 60)
    -e, --email <address>        Email address for alerts
    -h, --help                   Show this help message

EXAMPLES:
    # Single health check with auto-detection
    $0

    # Check Kubernetes deployment
    $0 -t kubernetes

    # Continuous monitoring
    $0 --watch

    # Continuous monitoring with custom interval
    $0 --watch --interval 30

    # With email alerts
    $0 --watch --email admin@example.com

ENVIRONMENT VARIABLES:
    DEPLOYMENT_TYPE     kubernetes, docker-compose, or auto
    CHECK_INTERVAL      Check interval in seconds
    ALERT_EMAIL         Email address for alerts
    NAMESPACE           Kubernetes namespace (default: superset)
    COMPOSE_FILE        Docker Compose file path

EXIT CODES:
    0 - All checks passed
    1 - One or more checks failed

EOF
}

# Parse command line arguments
WATCH_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            DEPLOYMENT_TYPE="$2"
            shift 2
            ;;
        -w|--watch)
            WATCH_MODE=true
            shift
            ;;
        -i|--interval)
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        -e|--email)
            ALERT_EMAIL="$2"
            shift 2
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
    echo "║          Apache Superset Health Check Script             ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    local detected_type=$(detect_deployment_type)
    log_info "Detected deployment type: $detected_type"
    echo ""
    
    if [ "$detected_type" = "unknown" ]; then
        log_error "Could not detect deployment type"
        log_info "Please specify deployment type with -t option"
        exit 1
    fi
    
    if [ "$WATCH_MODE" = true ]; then
        watch_health
    else
        case $detected_type in
            kubernetes)
                check_kubernetes
                exit $?
                ;;
            docker-compose)
                check_docker_compose
                exit $?
                ;;
        esac
    fi
}

# Run main function
main
