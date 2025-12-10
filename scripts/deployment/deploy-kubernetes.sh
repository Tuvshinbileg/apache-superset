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
NAMESPACE="${NAMESPACE:-superset}"
RELEASE_NAME="${RELEASE_NAME:-superset}"
VALUES_FILE="${VALUES_FILE:-superset-values.yaml}"
HELM_REPO="https://apache.github.io/superset"
CHART_NAME="superset/superset"

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
    
    if ! command_exists kubectl; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    if ! command_exists helm; then
        log_error "helm is not installed. Please install helm first."
        exit 1
    fi
    
    # Check kubectl connection
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

# Function to add Helm repository
add_helm_repo() {
    log_info "Adding Superset Helm repository..."
    
    if helm repo list | grep -q "superset"; then
        log_info "Superset repo already exists, updating..."
        helm repo update superset
    else
        helm repo add superset "$HELM_REPO"
        helm repo update
    fi
    
    log_success "Helm repository configured"
}

# Function to create namespace
create_namespace() {
    log_info "Creating namespace: $NAMESPACE"
    
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_info "Namespace $NAMESPACE already exists"
    else
        kubectl create namespace "$NAMESPACE"
        log_success "Namespace $NAMESPACE created"
    fi
}

# Function to validate values file
validate_values_file() {
    if [ ! -f "$VALUES_FILE" ]; then
        log_error "Values file not found: $VALUES_FILE"
        log_info "Please create a values file. Example:"
        cat <<EOF

# Create superset-values.yaml with at least:
image:
  repository: apache/superset
  tag: "latest"

extraSecretEnv:
  SUPERSET_SECRET_KEY: "YOUR_SECRET_KEY_HERE"

postgresql:
  enabled: false

redis:
  enabled: false

extraEnv:
  DATABASE_DIALECT: postgresql
  DATABASE_HOST: your-db-host
  DATABASE_PORT: "5432"
  DATABASE_DB: superset
  REDIS_HOST: your-redis-host
  REDIS_PORT: "6379"
EOF
        exit 1
    fi
    
    log_success "Values file validated: $VALUES_FILE"
}

# Function to check for secret key
check_secret_key() {
    log_info "Checking for SUPERSET_SECRET_KEY in values file..."
    
    if grep -q "SUPERSET_SECRET_KEY.*CHANGE" "$VALUES_FILE" || \
       grep -q "SUPERSET_SECRET_KEY.*YOUR_" "$VALUES_FILE" || \
       grep -q "SUPERSET_SECRET_KEY.*SECRET" "$VALUES_FILE"; then
        log_warning "⚠️  SUPERSET_SECRET_KEY appears to be a placeholder!"
        log_warning "Please generate a secure key with: openssl rand -base64 42"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Function to create secrets
create_secrets() {
    log_info "Checking for required secrets..."
    
    # Check for database credentials
    if ! kubectl get secret superset-db-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
        log_warning "Database credentials secret not found"
        log_info "Create with: kubectl create secret generic superset-db-credentials \\"
        log_info "  --from-literal=username=YOUR_USER \\"
        log_info "  --from-literal=password=YOUR_PASSWORD \\"
        log_info "  --namespace $NAMESPACE"
        
        read -p "Skip secret creation and continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "Database credentials secret exists"
    fi
    
    # Check for Redis credentials
    if ! kubectl get secret superset-redis-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
        log_warning "Redis credentials secret not found (optional)"
    else
        log_success "Redis credentials secret exists"
    fi
}

# Function to perform dry-run
dry_run() {
    log_info "Performing dry-run deployment..."
    
    helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
        -f "$VALUES_FILE" \
        --namespace "$NAMESPACE" \
        --dry-run \
        --debug
    
    if [ $? -eq 0 ]; then
        log_success "Dry-run successful"
    else
        log_error "Dry-run failed"
        exit 1
    fi
}

# Function to deploy Superset
deploy_superset() {
    log_info "Deploying Superset to Kubernetes..."
    log_info "Release: $RELEASE_NAME"
    log_info "Namespace: $NAMESPACE"
    log_info "Values: $VALUES_FILE"
    
    helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
        -f "$VALUES_FILE" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 10m
    
    if [ $? -eq 0 ]; then
        log_success "Superset deployed successfully!"
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Function to check deployment status
check_deployment() {
    log_info "Checking deployment status..."
    
    echo ""
    log_info "Pods:"
    kubectl get pods -n "$NAMESPACE"
    
    echo ""
    log_info "Services:"
    kubectl get svc -n "$NAMESPACE"
    
    echo ""
    log_info "Ingress:"
    kubectl get ingress -n "$NAMESPACE"
    
    echo ""
    
    # Wait for pods to be ready
    log_info "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=superset \
        -n "$NAMESPACE" \
        --timeout=300s
    
    log_success "All pods are ready!"
}

# Function to get access information
get_access_info() {
    log_info "Getting access information..."
    
    echo ""
    echo "==================== ACCESS INFORMATION ===================="
    
    # Get ingress information
    INGRESS_HOST=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null)
    if [ -n "$INGRESS_HOST" ]; then
        echo -e "${GREEN}Superset URL:${NC} https://$INGRESS_HOST"
    else
        # Get LoadBalancer information
        LB_IP=$(kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name=superset -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$LB_IP" ]; then
            echo -e "${GREEN}Superset URL:${NC} http://$LB_IP:8088"
        else
            echo -e "${YELLOW}No external access configured${NC}"
            echo "Use port-forward: kubectl port-forward -n $NAMESPACE svc/superset 8088:8088"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Default Credentials:${NC}"
    echo "Username: admin"
    echo "Password: admin"
    echo -e "${RED}⚠️  CHANGE DEFAULT PASSWORD IMMEDIATELY!${NC}"
    
    echo ""
    echo "==================== USEFUL COMMANDS ===================="
    echo "View logs:"
    echo "  kubectl logs -f deployment/superset -n $NAMESPACE"
    echo ""
    echo "Access pod:"
    echo "  kubectl exec -it deployment/superset -n $NAMESPACE -- /bin/bash"
    echo ""
    echo "Port forward:"
    echo "  kubectl port-forward -n $NAMESPACE svc/superset 8088:8088"
    echo ""
    echo "Uninstall:"
    echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
    echo "==========================================================="
}

# Function to show usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy Apache Superset to Kubernetes using Helm

OPTIONS:
    -n, --namespace <namespace>     Kubernetes namespace (default: superset)
    -r, --release <name>           Helm release name (default: superset)
    -f, --values <file>            Values file (default: superset-values.yaml)
    -d, --dry-run                  Perform dry-run only
    -h, --help                     Show this help message

EXAMPLES:
    # Deploy with default settings
    $0

    # Deploy to custom namespace
    $0 -n my-superset

    # Deploy with custom values file
    $0 -f my-values.yaml

    # Perform dry-run
    $0 -d

ENVIRONMENT VARIABLES:
    NAMESPACE       Kubernetes namespace
    RELEASE_NAME    Helm release name
    VALUES_FILE     Path to values file

EOF
}

# Parse command line arguments
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -f|--values)
            VALUES_FILE="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
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
    echo "║        Apache Superset Kubernetes Deployment             ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    check_prerequisites
    add_helm_repo
    create_namespace
    validate_values_file
    check_secret_key
    create_secrets
    
    if [ "$DRY_RUN" = true ]; then
        dry_run
        log_info "Dry-run completed. No changes were made."
        exit 0
    fi
    
    deploy_superset
    check_deployment
    get_access_info
    
    echo ""
    log_success "Deployment completed successfully! 🎉"
    echo ""
}

# Run main function
main
