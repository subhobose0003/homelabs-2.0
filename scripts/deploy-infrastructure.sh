#!/bin/bash

# Deploy Infrastructure Stack Script
# Usage: ./deploy-infrastructure.sh [non-prod|prod] [component|all]

set -e

ENVIRONMENT=${1:-non-prod}
COMPONENT=${2:-all}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠ $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1${NC}"
}

# Validate environment
if [[ "$ENVIRONMENT" != "non-prod" && "$ENVIRONMENT" != "prod" ]]; then
    error "Invalid environment. Use 'non-prod' or 'prod'"
    exit 1
fi

# Infrastructure components in deployment order
COMPONENTS=(
    "external-dns"
    "metallb"
    "longhorn"
    "traefik"
    "minio"
    "vault"
    "gitops"
)

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

deploy_component() {
    local comp=$1
    local infra_path="$PROJECT_ROOT/clusters/$ENVIRONMENT/infra/$comp"
    
    if [[ ! -d "$infra_path" ]]; then
        warning "Component directory not found: $infra_path"
        return 1
    fi
    
    log "Deploying $comp to $ENVIRONMENT cluster..."
    
    # Apply all YAML files in the component directory
    if ls "$infra_path"/*.yaml 1> /dev/null 2>&1; then
        kubectl apply -f "$infra_path/" || {
            error "Failed to deploy $comp"
            return 1
        }
        
        # Wait for deployment to be ready (if applicable)
        case $comp in
            "external-dns")
                kubectl -n external-dns rollout status deployment/external-dns --timeout=300s || warning "External DNS deployment timeout"
                ;;
            "metallb")
                log "MetalLB installed, waiting for speaker pods..."
                kubectl -n metallb-system wait --for=condition=ready pod -l component=speaker --timeout=300s || warning "MetalLB speaker timeout"
                ;;
            "longhorn")
                log "Longhorn installed, waiting for manager pods..."
                kubectl -n longhorn-system wait --for=condition=ready pod -l app=longhorn-manager --timeout=600s || warning "Longhorn manager timeout"
                ;;
            "traefik")
                kubectl -n traefik-system rollout status deployment/traefik --timeout=300s || warning "Traefik deployment timeout"
                ;;
            "minio")
                kubectl -n minio rollout status deployment/minio --timeout=300s || warning "MinIO deployment timeout"
                ;;
            "vault")
                kubectl -n vault rollout status deployment/vault --timeout=300s || warning "Vault deployment timeout"
                ;;
            "gitops")
                kubectl -n argocd rollout status deployment/argocd-server --timeout=300s || warning "ArgoCD server timeout"
                ;;
        esac
        
        success "$comp deployed successfully"
    else
        warning "No YAML files found in $infra_path"
    fi
}

wait_for_component() {
    local comp=$1
    log "Waiting for $comp to be fully ready..."
    
    case $comp in
        "external-dns")
            kubectl -n external-dns wait --for=condition=available deployment/external-dns --timeout=300s
            ;;
        "metallb")
            kubectl -n metallb-system wait --for=condition=ready pod -l app=metallb --timeout=300s
            ;;
        "longhorn")
            # Wait for Longhorn to be fully operational
            sleep 60
            kubectl -n longhorn-system get pods
            ;;
        "traefik")
            kubectl -n traefik-system wait --for=condition=available deployment/traefik --timeout=300s
            ;;
        "minio")
            kubectl -n minio wait --for=condition=available deployment/minio --timeout=300s
            ;;
        "vault")
            kubectl -n vault wait --for=condition=available deployment/vault --timeout=300s
            ;;
        "gitops")
            kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s
            ;;
    esac
}

# Main deployment logic
log "Starting infrastructure deployment for $ENVIRONMENT environment"

if [[ "$COMPONENT" == "all" ]]; then
    log "Deploying all infrastructure components in order..."
    
    for comp in "${COMPONENTS[@]}"; do
        deploy_component "$comp"
        
        # Add delay between components to ensure proper startup
        if [[ "$comp" != "gitops" ]]; then
            log "Waiting 30 seconds before next component..."
            sleep 30
        fi
    done
    
    log "Verifying all deployments..."
    for comp in "${COMPONENTS[@]}"; do
        wait_for_component "$comp"
    done
    
else
    # Deploy specific component
    if [[ " ${COMPONENTS[*]} " =~ " $COMPONENT " ]]; then
        deploy_component "$COMPONENT"
        wait_for_component "$COMPONENT"
    else
        error "Invalid component: $COMPONENT"
        echo "Available components: ${COMPONENTS[*]}"
        exit 1
    fi
fi

# Post-deployment verification
log "Running post-deployment verification..."

# Check all namespaces
kubectl get namespaces

# Check all pods
kubectl get pods -A | grep -E "(external-dns|metallb|longhorn|traefik|minio|vault|argocd)"

# Check services with LoadBalancer type
kubectl get services -A --field-selector spec.type=LoadBalancer

success "Infrastructure deployment completed for $ENVIRONMENT!"

# Print access URLs
log "Access URLs:"
echo "  Traefik Dashboard: https://traefik.$ENVIRONMENT.internal"
echo "  Longhorn UI: https://longhorn.$ENVIRONMENT.internal"
echo "  MinIO Console: https://minio.$ENVIRONMENT.internal"
echo "  Vault UI: https://vault.$ENVIRONMENT.internal"
echo "  ArgoCD UI: https://argocd.$ENVIRONMENT.internal"

log "Next steps:"
echo "  1. Initialize Vault: kubectl exec -n vault vault-0 -- vault operator init"
echo "  2. Unseal Vault with the generated keys"
echo "  3. Configure Vault authentication and secret engines"
echo "  4. Update DNS records to point to LoadBalancer IPs"
echo "  5. Verify all services are accessible via their domains"
