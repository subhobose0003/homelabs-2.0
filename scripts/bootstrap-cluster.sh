#!/usr/bin/env bash

# Bootstrap Talos Kubernetes Cluster Script (Dynamic Provisioning)
# Usage: ./bootstrap-cluster.sh [non-prod|prod]

set -e

ENVIRONMENT=${1:-non-prod}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Helper Functions ---
# Must be defined before config is sourced
log() { echo -e "\033[0;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"; }
success() { echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1\033[0m"; }
warning() { echo -e "\033[1;33m[$(date +'%Y-%m-%d %H:%M:%S')] ⚠ $1\033[0m"; }
error() { echo -e "\033[0;31m[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1\033[0m"; }



# --- Main Script ---

# Validate environment and tools
if ! command -v talosctl &> /dev/null; then error "talosctl is not installed." && exit 1; fi
if ! command -v kubectl &> /dev/null; then error "kubectl is not installed." && exit 1; fi
if ! command -v jq &> /dev/null; then error "jq is not installed. It is required for parsing config.json." && exit 1; fi

# --- Configuration ---
log "Loading configuration from scripts/config.json..."
JSON_CONFIG_FILE="$SCRIPT_DIR/config.json"
if [[ ! -f "$JSON_CONFIG_FILE" ]]; then
    error "Configuration file not found: $JSON_CONFIG_FILE"
    exit 1
fi

# Parse config values using jq
CLUSTER_NAME=$(jq -r ".environments[\"$ENVIRONMENT\"].cluster_name" "$JSON_CONFIG_FILE")
API_SERVER=$(jq -r ".environments[\"$ENVIRONMENT\"].api_server" "$JSON_CONFIG_FILE")
CONTROL_PLANE_IP=$(jq -r ".environments[\"$ENVIRONMENT\"].control_plane_ip" "$JSON_CONFIG_FILE")

if [[ -z "$CLUSTER_NAME" || -z "$API_SERVER" || -z "$CONTROL_PLANE_IP" ]]; then
    error "Failed to parse critical configuration from $JSON_CONFIG_FILE for environment '$ENVIRONMENT'."
    exit 1
fi

log "Starting dynamic bootstrap for $ENVIRONMENT cluster ($CLUSTER_NAME)..."

CONFIG_DIR="$PROJECT_ROOT/clusters/$ENVIRONMENT/talos-config"
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

# Generate base Talos configuration if it doesn't exist
if [[ ! -f "controlplane.yaml" || ! -f "worker.yaml" ]]; then
    log "Generating base Talos configuration for $CLUSTER_NAME..."
    talosctl gen config "$CLUSTER_NAME" "$API_SERVER"
    success "Base configuration generated."
else
    warning "Base configuration already exists. Skipping generation."
fi

log "Handing off to Python script for node discovery and provisioning..."
python3 "$SCRIPT_DIR/provision.py" "$ENVIRONMENT"

warning "All discovered nodes have been configured and are rebooting."
read -p "Please verify that all nodes are online with their static IPs, then press [Enter] to continue..."

# Bootstrap the cluster
log "Bootstrapping cluster on the first control plane node: $CONTROL_PLANE_IP..."
talosctl bootstrap --nodes "$CONTROL_PLANE_IP" || {
    error "Failed to bootstrap cluster."
    exit 1
}

success "Bootstrap command issued to $CONTROL_PLANE_IP."

log "Generating kubeconfig..."
talosctl kubeconfig --nodes "$CONTROL_PLANE_IP" || {
    error "Failed to generate kubeconfig."
    exit 1
}
success "Kubeconfig generated."

# The python script handles provisioning, but the bash script still needs to join the nodes.
# We need to get the list of IPs from the config file.

# Join other control plane nodes
log "Joining other control plane nodes to the cluster..."
CONTROL_PLANE_IPS=$(jq -r ".environments[\"$ENVIRONMENT\"].nodes | to_entries[] | select(.value.type == \"control-plane\") | .value.ip_address" "$JSON_CONFIG_FILE")
for ip in $CONTROL_PLANE_IPS; do
    if [[ "$ip" != "$CONTROL_PLANE_IP" ]]; then
        log "Joining control plane node $ip..."
        talosctl --nodes "$ip" join --endpoints "$CONTROL_PLANE_IP" || error "Failed to join control plane node $ip."
    fi
done

# Join worker nodes
log "Joining worker nodes to the cluster..."
WORKER_IPS=$(jq -r ".environments[\"$ENVIRONMENT\"].nodes | to_entries[] | select(.value.type == \"worker\") | .value.ip_address" "$JSON_CONFIG_FILE")
for ip in $WORKER_IPS; do
    log "Joining worker node $ip..."
    talosctl --nodes "$ip" join --endpoints "$CONTROL_PLANE_IP" || error "Failed to join worker node $ip."
done

log "All nodes have been instructed to join the cluster."
read -p "Press [Enter] to wait for all nodes to become ready..."

# Final verification
log "Waiting for all nodes to become ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=5m || {
    warning "Timed out waiting for all nodes to be ready. Check cluster status manually."
}

log "Verifying cluster status..."
kubectl get nodes -o wide

success "Cluster '$ENVIRONMENT' bootstrapped successfully!"
