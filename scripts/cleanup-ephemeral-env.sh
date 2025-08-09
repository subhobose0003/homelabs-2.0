#!/bin/bash

# Cleanup Ephemeral Environment Script
# Usage: ./cleanup-ephemeral-env.sh [feature-name|all]

set -e

FEATURE_NAME=$1
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

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

cleanup_feature() {
    local feature=$1
    local sanitized_name=$(echo "$feature" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    local namespace="feature-$sanitized_name"
    
    log "Cleaning up ephemeral environment: $feature"
    log "Namespace: $namespace"
    
    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        warning "Namespace $namespace does not exist, skipping..."
        return
    fi
    
    # Delete namespace (this will delete all resources in it)
    log "Deleting namespace: $namespace"
    kubectl delete namespace "$namespace" --timeout=60s || {
        warning "Failed to delete namespace $namespace"
        return
    }
    
    # Clean up local files
    local ephemeral_dir="$PROJECT_ROOT/clusters/non-prod/apps/ephemeral/$sanitized_name"
    if [[ -d "$ephemeral_dir" ]]; then
        log "Cleaning up local files: $ephemeral_dir"
        rm -rf "$ephemeral_dir"
    fi
    
    success "Ephemeral environment $feature cleaned up successfully"
}

cleanup_all_ephemeral() {
    log "Cleaning up all ephemeral environments..."
    
    # Get all namespaces with type=ephemeral label
    local ephemeral_namespaces
    ephemeral_namespaces=$(kubectl get namespaces -l type=ephemeral -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$ephemeral_namespaces" ]]; then
        log "No ephemeral environments found"
        return
    fi
    
    log "Found ephemeral namespaces: $ephemeral_namespaces"
    
    for namespace in $ephemeral_namespaces; do
        log "Deleting namespace: $namespace"
        kubectl delete namespace "$namespace" --timeout=60s || {
            warning "Failed to delete namespace $namespace"
            continue
        }
        success "Deleted namespace: $namespace"
    done
    
    # Clean up all local ephemeral directories
    local ephemeral_base_dir="$PROJECT_ROOT/clusters/non-prod/apps/ephemeral"
    if [[ -d "$ephemeral_base_dir" ]]; then
        log "Cleaning up all local ephemeral files..."
        find "$ephemeral_base_dir" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} \;
    fi
    
    success "All ephemeral environments cleaned up"
}

cleanup_expired() {
    log "Cleaning up expired ephemeral environments..."
    
    local current_date=$(date +%Y-%m-%d)
    local expired_namespaces
    
    # Get namespaces with TTL annotation that have expired
    expired_namespaces=$(kubectl get namespaces -l type=ephemeral -o json | \
        jq -r --arg current_date "$current_date" \
        '.items[] | select(.metadata.annotations.ttl and .metadata.annotations.ttl < $current_date) | .metadata.name' 2>/dev/null || echo "")
    
    if [[ -z "$expired_namespaces" ]]; then
        log "No expired ephemeral environments found"
        return
    fi
    
    log "Found expired namespaces: $expired_namespaces"
    
    for namespace in $expired_namespaces; do
        log "Deleting expired namespace: $namespace"
        kubectl delete namespace "$namespace" --timeout=60s || {
            warning "Failed to delete namespace $namespace"
            continue
        }
        success "Deleted expired namespace: $namespace"
        
        # Clean up local files
        local feature_name=${namespace#feature-}
        local ephemeral_dir="$PROJECT_ROOT/clusters/non-prod/apps/ephemeral/$feature_name"
        if [[ -d "$ephemeral_dir" ]]; then
            rm -rf "$ephemeral_dir"
        fi
    done
    
    success "Expired ephemeral environments cleaned up"
}

# Main logic
if [[ -z "$FEATURE_NAME" ]]; then
    error "Feature name is required"
    echo "Usage: $0 <feature-name|all|expired>"
    echo ""
    echo "Examples:"
    echo "  $0 user-authentication    # Clean up specific feature"
    echo "  $0 all                    # Clean up all ephemeral environments"
    echo "  $0 expired                # Clean up only expired environments"
    exit 1
fi

case "$FEATURE_NAME" in
    "all")
        cleanup_all_ephemeral
        ;;
    "expired")
        cleanup_expired
        ;;
    *)
        cleanup_feature "$FEATURE_NAME"
        ;;
esac

log "Cleanup completed!"
