#!/bin/bash

# Create Ephemeral Environment Script
# Usage: ./create-ephemeral-env.sh <feature-name>

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

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1${NC}"
}

# Validate input
if [[ -z "$FEATURE_NAME" ]]; then
    error "Feature name is required"
    echo "Usage: $0 <feature-name>"
    exit 1
fi

# Sanitize feature name (remove special characters, convert to lowercase)
SANITIZED_NAME=$(echo "$FEATURE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
NAMESPACE="feature-$SANITIZED_NAME"
DOMAIN="$SANITIZED_NAME.nonprod.internal"

log "Creating ephemeral environment for feature: $FEATURE_NAME"
log "Namespace: $NAMESPACE"
log "Domain: $DOMAIN"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

# Create namespace
log "Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Label namespace for identification and cleanup
kubectl label namespace "$NAMESPACE" type=ephemeral feature="$SANITIZED_NAME" created-by=gitops --overwrite

# Set TTL for automatic cleanup (7 days)
EXPIRY_DATE=$(date -d "+7 days" +%Y-%m-%d)
kubectl annotate namespace "$NAMESPACE" ttl="$EXPIRY_DATE" --overwrite

# Create ephemeral environment directory
EPHEMERAL_DIR="$PROJECT_ROOT/clusters/non-prod/apps/ephemeral/$SANITIZED_NAME"
mkdir -p "$EPHEMERAL_DIR"

# Create basic application manifest template
cat > "$EPHEMERAL_DIR/application.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SANITIZED_NAME-app
  namespace: $NAMESPACE
  labels:
    app: $SANITIZED_NAME
    environment: ephemeral
    feature: $SANITIZED_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $SANITIZED_NAME
  template:
    metadata:
      labels:
        app: $SANITIZED_NAME
        environment: ephemeral
        feature: $SANITIZED_NAME
    spec:
      containers:
      - name: app
        image: nginx:alpine  # Replace with your application image
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
        env:
        - name: ENVIRONMENT
          value: "ephemeral"
        - name: FEATURE_NAME
          value: "$FEATURE_NAME"
---
apiVersion: v1
kind: Service
metadata:
  name: $SANITIZED_NAME-service
  namespace: $NAMESPACE
  labels:
    app: $SANITIZED_NAME
    environment: ephemeral
spec:
  selector:
    app: $SANITIZED_NAME
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $SANITIZED_NAME-ingress
  namespace: $NAMESPACE
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    external-dns.alpha.kubernetes.io/hostname: $DOMAIN
  labels:
    app: $SANITIZED_NAME
    environment: ephemeral
spec:
  tls:
  - hosts:
    - $DOMAIN
    secretName: $SANITIZED_NAME-tls
  rules:
  - host: $DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $SANITIZED_NAME-service
            port:
              number: 80
EOF

# Apply the manifests
log "Deploying application to ephemeral environment..."
kubectl apply -f "$EPHEMERAL_DIR/application.yaml"

# Wait for deployment to be ready
log "Waiting for deployment to be ready..."
kubectl -n "$NAMESPACE" rollout status deployment/"$SANITIZED_NAME-app" --timeout=300s

# Get service information
log "Getting service information..."
kubectl -n "$NAMESPACE" get all

success "Ephemeral environment created successfully!"
log "Environment Details:"
echo "  Feature: $FEATURE_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Domain: https://$DOMAIN"
echo "  Expiry: $EXPIRY_DATE"
echo ""
log "The environment will be automatically cleaned up after 7 days"
log "To manually clean up: ./cleanup-ephemeral-env.sh $SANITIZED_NAME"

# Create cleanup reminder
cat > "$EPHEMERAL_DIR/cleanup-info.txt" << EOF
Ephemeral Environment: $FEATURE_NAME
Namespace: $NAMESPACE
Domain: $DOMAIN
Created: $(date)
Expires: $EXPIRY_DATE
Cleanup Command: ./scripts/cleanup-ephemeral-env.sh $SANITIZED_NAME
EOF

success "Environment ready at: https://$DOMAIN"
