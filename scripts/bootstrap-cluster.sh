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

# Debug mode (export DEBUG=1 to enable)
if [[ -n "$DEBUG" ]]; then
  set -x
  export TALOS_LOG_LEVEL=debug
fi



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

# Ensure talosctl uses the generated config in this directory
export TALOSCONFIG="$CONFIG_DIR/talosconfig"

# Generate base Talos configuration if it doesn't exist
if [[ ! -f "controlplane.yaml" || ! -f "worker.yaml" ]]; then
    log "Generating base Talos configuration for $CLUSTER_NAME..."
    talosctl gen config "$CLUSTER_NAME" "$API_SERVER"
    success "Base configuration generated."
else
    warning "Base configuration already exists. Skipping generation."
fi

log "Handing off to Python script for node discovery and provisioning..."

# Auto-detect previously provisioned nodes and offer to reuse
REUSE=false
if [[ -f "$CONFIG_DIR/provisioned_nodes.json" ]]; then
    EXISTING_ALL=( $(jq -r '.nodes[].ip_address' "$CONFIG_DIR/provisioned_nodes.json") )
    READY_COUNT=0
    for ip in "${EXISTING_ALL[@]}"; do
        if talosctl --talosconfig "$CONFIG_DIR/talosconfig" get machineconfig -e "$ip" -n "$ip" -o json >/dev/null 2>&1; then
            READY_COUNT=$((READY_COUNT+1))
        fi
    done
    if [[ $READY_COUNT -gt 0 ]]; then
        read -r -p "Detected $READY_COUNT previously provisioned node(s). Reuse and skip provisioning? [Y/n]: " ans
        if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
            REUSE=true
            success "Reusing previously provisioned nodes; skipping provisioning step."
        fi
    fi
fi

if [[ "$REUSE" != "true" ]]; then
    python3 "$SCRIPT_DIR/provision.py" "$ENVIRONMENT"
    warning "All discovered nodes have been configured and are rebooting."
    read -p "Please verify that all nodes are online with their static IPs, then press [Enter] to continue..."
fi

# If available, restrict joins to provisioned nodes from this run
PROVISIONED_FILE="$CONFIG_DIR/provisioned_nodes.json"
PROV_CONTROL_PLANES=()
PROV_WORKERS=()
if [[ -f "$PROVISIONED_FILE" ]]; then
    # macOS ships Bash 3.2 which lacks 'mapfile'. Use jq + command substitution instead.
    PROV_CONTROL_PLANES=( $(jq -r '.nodes[] | select(.type=="control-plane") | .ip_address' "$PROVISIONED_FILE") )
    PROV_WORKERS=( $(jq -r '.nodes[] | select(.type=="worker") | .ip_address' "$PROVISIONED_FILE") )
fi

# Determine bootstrap control-plane IP dynamically if needed
BOOTSTRAP_IP="$CONTROL_PLANE_IP"
if [[ ${#PROV_CONTROL_PLANES[@]} -gt 0 ]]; then
    found=0
    for ip in "${PROV_CONTROL_PLANES[@]}"; do
        if [[ "$ip" == "$CONTROL_PLANE_IP" ]]; then
            found=1; break
        fi
    done
    if [[ $found -eq 0 ]]; then
        BOOTSTRAP_IP="${PROV_CONTROL_PLANES[0]}"
        warning "Configured CONTROL_PLANE_IP ($CONTROL_PLANE_IP) not provisioned in this run; bootstrapping on $BOOTSTRAP_IP instead."
    fi
fi

# Bootstrap the cluster
log "Setting talosctl endpoints to $BOOTSTRAP_IP..."
if talosctl --talosconfig "$CONFIG_DIR/talosconfig" config endpoints "$BOOTSTRAP_IP" >/dev/null 2>&1; then
  success "Endpoints set in talosconfig."
else
  warning "Failed to set endpoints; continuing with explicit --endpoints."
fi
 
log "Bootstrapping cluster on control plane node: $BOOTSTRAP_IP..."
BOOTSTRAP_TMP_LOG=$(mktemp -t talos-bootstrap.XXXXXX)
if talosctl --talosconfig "$CONFIG_DIR/talosconfig" bootstrap --nodes "$BOOTSTRAP_IP" --endpoints "$BOOTSTRAP_IP" \
  >"$BOOTSTRAP_TMP_LOG" 2>&1; then
  BOOTSTRAP_OUT=$(cat "$BOOTSTRAP_TMP_LOG")
  success "Bootstrap command issued to $BOOTSTRAP_IP."
  if [[ -n "$BOOTSTRAP_OUT" ]]; then
    log "Bootstrap output:\n$BOOTSTRAP_OUT"
  fi
else
  BOOTSTRAP_OUT=$(cat "$BOOTSTRAP_TMP_LOG")
  if echo "$BOOTSTRAP_OUT" | grep -Eqi "already bootstrapped|bootstrap( is)? already (completed|done)"; then
    warning "Cluster already bootstrapped; continuing."
  else
    # Try to see if control plane is effectively up by fetching kubeconfig
    warning "Bootstrap returned non-zero. Probing API by attempting kubeconfig fetch..."
    if talosctl --talosconfig "$CONFIG_DIR/talosconfig" kubeconfig --nodes "$BOOTSTRAP_IP" --endpoints "$BOOTSTRAP_IP" \
      >/dev/null 2>&1; then
      success "Kubeconfig fetch succeeded; assuming cluster is already bootstrapped."
    else
      error "Failed to bootstrap cluster. Output:\n$BOOTSTRAP_OUT"
      rm -f "$BOOTSTRAP_TMP_LOG"
      exit 1
    fi
  fi
fi
rm -f "$BOOTSTRAP_TMP_LOG"

# Wait for bootstrap node Talos API to be reachable and prompt for confirmation
WAIT_INTERVAL=${WAIT_INTERVAL:-5}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-900}
log "Waiting for bootstrap node ($BOOTSTRAP_IP) Talos API to become reachable..."
start_ts=$(date +%s)
while true; do
  if talosctl --talosconfig "$CONFIG_DIR/talosconfig" get machineconfig -e "$BOOTSTRAP_IP" -n "$BOOTSTRAP_IP" -o json >/dev/null 2>&1; then
    success "Bootstrap node Talos API is reachable."
    break
  fi
  now=$(date +%s)
  if [[ $((now - start_ts)) -ge $WAIT_TIMEOUT ]]; then
    warning "Timed out waiting for bootstrap node Talos API."
    break
  fi
  sleep "$WAIT_INTERVAL"
done
read -p "Confirm control plane node $BOOTSTRAP_IP is Ready (kube-apiserver running). Press [Enter] to continue..."

# As per Talos docs, no explicit join command is needed. Allow time for nodes to auto-join.
echo
log "Nodes will auto-join once their configs are applied."
echo "Expected nodes (from config/provisioned list) should appear after control plane is up."
read -p "Press [Enter] once ALL nodes have joined the cluster successfully (you may verify via node consoles or talosctl)." 

# Generate kubeconfig at the end
log "Generating kubeconfig..."
talosctl --talosconfig "$CONFIG_DIR/talosconfig" kubeconfig --nodes "$BOOTSTRAP_IP" --endpoints "$BOOTSTRAP_IP" || {
    error "Failed to generate kubeconfig."
    exit 1
}
success "Kubeconfig generated."
export KUBECONFIG="$CONFIG_DIR/kubeconfig"

# Step 11 from docs: Check Cluster Health
log "Checking Talos cluster health (Step 11)..."
if talosctl --nodes "$BOOTSTRAP_IP" --talosconfig "$CONFIG_DIR/talosconfig" health; then
  success "Talos cluster health check passed."
else
  warning "Talos cluster health check reported issues. Investigate above output."
fi

log "Verifying Kubernetes node registration..."
kubectl get nodes -o wide

success "Cluster '$ENVIRONMENT' bootstrapped successfully!"
