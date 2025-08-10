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

# --- Configuration ---
CONFIG_FILE="$SCRIPT_DIR/bootstrap-config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# --- Main Script ---

# Validate environment and tools
if ! command -v talosctl &> /dev/null; then error "talosctl is not installed." && exit 1; fi
if ! command -v kubectl &> /dev/null; then error "kubectl is not installed." && exit 1; fi
if ! command -v jq &> /dev/null; then error "jq is not installed. It is required for parsing discovery data." && exit 1; fi

log "Starting dynamic bootstrap for $ENVIRONMENT cluster..."

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

log "Base configuration is ready."
read -p "Press [Enter] to begin node discovery..."

# Discover and provision nodes
NODE_COUNT=$((${#CONTROL_PLANE_MAP[@]} + ${#WORKER_MAP[@]}))
PROVISIONED_COUNT=0
log "Ready to provision $NODE_COUNT nodes. Boot your VMs now."
log "Starting node discovery..."

talosctl discover --nodes 127.0.0.1:50000 | \
while read -r line; do
    NODE_IP=$(echo "$line" | jq -r .address)
    MAC_ADDR=$(echo "$line" | jq -r .hardwareAddr | tr '[:lower:]' '[:upper:]')
    INTERFACE=$(echo "$line" | jq -r .interfaces[0].name)

    log "Discovered node at $NODE_IP with MAC $MAC_ADDR on interface $INTERFACE"

    # Determine node type and get its config
    if [[ -v "CONTROL_PLANE_MAP[$MAC_ADDR]" ]]; then
        IFS=';' read -r HOSTNAME STATIC_IP <<< "${CONTROL_PLANE_MAP[$MAC_ADDR]}"
        BASE_CONFIG="controlplane.yaml"
        NODE_TYPE="Control Plane"
    elif [[ -v "WORKER_MAP[$MAC_ADDR]" ]]; then
        IFS=';' read -r HOSTNAME STATIC_IP <<< "${WORKER_MAP[$MAC_ADDR]}"
        BASE_CONFIG="worker.yaml"
        NODE_TYPE="Worker"
    else
        error "Discovered node with unknown MAC $MAC_ADDR. Skipping."
        continue
    fi

    log "Identified as $NODE_TYPE node: $HOSTNAME ($STATIC_IP)"
    GENERATED_CONFIG="${HOSTNAME}.yaml"

    # Create configuration patch
    CONFIG_PATCH=$(cat <<-EOF
- op: add
  path: /machine/network/hostname
  value: ${HOSTNAME}
- op: add
  path: /machine/network/interfaces
  value:
    - interface: ${INTERFACE}
      dhcp: false
      addresses:
        - ${STATIC_IP}/${IP_CIDR}
      routes:
        - network: 0.0.0.0/0
          gateway: ${GATEWAY_IP}
- op: add
  path: /machine/network/nameservers
  value: [${DNS_SERVERS[0]}, ${DNS_SERVERS[1]}]
- op: add
  path: /machine/time/servers
  value: [${NTP_SERVERS[0]}, ${NTP_SERVERS[1]}]
- op: add
  path: /machine/install/diskSelector
  value:
    size: "< 50GB"
EOF
)

    # Generate final config file
    talosctl gen patch "$GENERATED_CONFIG" "$BASE_CONFIG" --patch "$CONFIG_PATCH" > /dev/null
    success "Generated patched config: $GENERATED_CONFIG"

    # Apply the configuration
    log "Applying configuration to $HOSTNAME ($NODE_IP)..."
    if talosctl apply-config --insecure --nodes "$NODE_IP" --file "$GENERATED_CONFIG"; then
        success "Applied config to $HOSTNAME. Node will reboot with static IP $STATIC_IP."
        rm "$GENERATED_CONFIG"

        # Increment counter and check if all nodes are provisioned
        PROVISIONED_COUNT=$((PROVISIONED_COUNT + 1))
        if (( PROVISIONED_COUNT == NODE_COUNT )); then
            success "All $NODE_COUNT nodes have been provisioned."
            break
        fi
    else
        error "Failed to apply config to $HOSTNAME ($NODE_IP). Please check the node and retry."
    fi
done

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

# Join other control plane nodes
log "Joining other control plane nodes to the cluster..."
for mac in "${!CONTROL_PLANE_MAP[@]}"; do
    IFS=';' read -r _hostname static_ip <<< "${CONTROL_PLANE_MAP[$mac]}"
    if [[ "$static_ip" != "$CONTROL_PLANE_IP" ]]; then
        log "Joining control plane node $static_ip..."
        talosctl --nodes "$static_ip" join --endpoints "$CONTROL_PLANE_IP" || error "Failed to join control plane node $static_ip."
    fi
done

# Join worker nodes
log "Joining worker nodes to the cluster..."
for mac in "${!WORKER_MAP[@]}"; do
    IFS=';' read -r _hostname static_ip <<< "${WORKER_MAP[$mac]}"
    log "Joining worker node $static_ip..."
    talosctl --nodes "$static_ip" join --endpoints "$CONTROL_PLANE_IP" || error "Failed to join worker node $static_ip."
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
