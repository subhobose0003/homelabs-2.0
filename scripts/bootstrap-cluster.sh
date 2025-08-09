#!/bin/bash

# Bootstrap Talos Kubernetes Cluster Script
# Usage: ./bootstrap-cluster.sh [non-prod|prod]

set -e

ENVIRONMENT=${1:-non-prod}
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

log "Bootstrapping $ENVIRONMENT cluster..."

# Set environment-specific variables
API_SERVER="https://$ENVIRONMENT-api.homelabs.in:6443"

if [[ "$ENVIRONMENT" == "non-prod" ]]; then
    CLUSTER_NAME="homelab-nonprod"
    CONTROL_PLANE_IP="10.0.1.10"
    IP_RANGE="10.0.1.x"
else
    CLUSTER_NAME="homelab-prod"
    CONTROL_PLANE_IP="10.0.2.10"
    IP_RANGE="10.0.2.x"
fi

# Check if talosctl is installed
if ! command -v talosctl &> /dev/null; then
    error "talosctl is not installed. Please install it first."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed. Please install it first."
    exit 1
fi

# Create talos-config directory if it doesn't exist
mkdir -p "$PROJECT_ROOT/clusters/$ENVIRONMENT/talos-config"
cd "$PROJECT_ROOT/clusters/$ENVIRONMENT/talos-config"

# Generate Talos configuration if it doesn't exist
if [[ ! -f "controlplane.yaml" ]]; then
    log "Generating Talos configuration for $CLUSTER_NAME..."
    talosctl gen config "$CLUSTER_NAME" "$API_SERVER"
    success "Talos configuration generated"
else
    warning "Talos configuration already exists, skipping generation"
fi

# Apply configuration to control plane nodes
log "Applying configuration to control plane nodes..."
# Note: Adjust IP addresses based on your actual node IPs
CONTROL_PLANE_NODES=("$CONTROL_PLANE_IP" "10.0.${ENVIRONMENT == 'non-prod' ? '1' : '2'}.11" "10.0.${ENVIRONMENT == 'non-prod' ? '1' : '2'}.12")

for node in "${CONTROL_PLANE_NODES[@]}"; do
    log "Applying config to control plane node: $node"
    talosctl apply-config --insecure --nodes "$node" --file controlplane.yaml || {
        warning "Failed to apply config to $node, continuing..."
    }
done

# Bootstrap the cluster (only on the first control plane node)
log "Bootstrapping cluster on $CONTROL_PLANE_IP..."
talosctl bootstrap --nodes "$CONTROL_PLANE_IP" || {
    error "Failed to bootstrap cluster"
    exit 1
}

# Wait for cluster to be ready
log "Waiting for cluster to be ready..."
sleep 30

# Generate kubeconfig
log "Generating kubeconfig..."
talosctl kubeconfig --nodes "$CONTROL_PLANE_IP" || {
    error "Failed to generate kubeconfig"
    exit 1
}

# Wait for nodes to be ready
log "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s || {
    warning "Some nodes may not be ready yet"
}

# Apply worker node configuration
log "Applying configuration to worker nodes..."
WORKER_NODES=("10.0.${ENVIRONMENT == 'non-prod' ? '1' : '2'}.20" "10.0.${ENVIRONMENT == 'non-prod' ? '1' : '2'}.21" "10.0.${ENVIRONMENT == 'non-prod' ? '1' : '2'}.22")

for node in "${WORKER_NODES[@]}"; do
    log "Applying config to worker node: $node"
    talosctl apply-config --insecure --nodes "$node" --file worker.yaml || {
        warning "Failed to apply config to $node, continuing..."
    }
done

# Verify cluster status
log "Verifying cluster status..."
kubectl get nodes -o wide
kubectl get pods -A

success "Cluster $ENVIRONMENT bootstrapped successfully!"
log "Cluster API: $API_SERVER"
log "Control Plane IP: $CONTROL_PLANE_IP"
log "IP Range: $IP_RANGE"

# Save cluster info
cat > cluster-info.txt << EOF
Cluster: $CLUSTER_NAME
Environment: $ENVIRONMENT
API Server: $API_SERVER
Control Plane IP: $CONTROL_PLANE_IP
IP Range: $IP_RANGE
Bootstrap Date: $(date)
EOF

success "Cluster information saved to cluster-info.txt"
log "Next steps:"
echo "  1. Deploy infrastructure stack: kubectl apply -k ../infra/"
echo "  2. Set up ArgoCD: kubectl apply -f ../infra/gitops/"
echo "  3. Configure DNS records for *.${ENVIRONMENT}.internal"
