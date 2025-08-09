# GitOps Strategy for Talos Kubernetes Clusters

## Overview
This document outlines the complete GitOps strategy for managing two Talos Kubernetes clusters (non-prod and prod) with automated deployment pipelines triggered by Git operations.

## Architecture

### Cluster Configuration
- **Non-Prod Cluster**: 3 master + 3 worker nodes (Talos)
- **Prod Cluster**: 3 master + 3 worker nodes (Talos)

### Infrastructure Components (Per Cluster)
1. **ExternalDNS** - Dynamic DNS updates to internal DNS server
2. **MetalLB** - LoadBalancer service type support
3. **Longhorn** - Block storage from secondary disk (v2 default storage class)
4. **Traefik** - Ingress controller with direct Let's Encrypt via Cloudflare DNS challenge
5. **MinIO** - S3-compatible storage on third disk
6. **HashiCorp Vault** - Centralized secret management with External Secrets Operator
7. **GitOps Runner** - ArgoCD/Flux for continuous deployment
8. **K8s Agent** - Cluster monitoring and management

## Branching Strategy

### Branch Structure
```
main (prod)
├── dev (non-prod permanent)
└── feature/* (ephemeral test environments)
```

### Workflow
1. **Feature Development**
   - Create `feature/feature-name` branch from `dev`
   - Push triggers ephemeral environment creation in non-prod cluster
   - Environment available at `feature-name.nonprod.internal`

2. **Development Integration**
   - Merge `feature/*` → `dev` (after approval)
   - Destroys ephemeral environment
   - Deploys to non-prod permanent environment
   - Feature branch auto-deleted

3. **Production Deployment**
   - Merge `dev` → `main` (after approval)
   - Deploys to prod cluster
   - Available at production domains

## Repository Structure

```
homelabs/
├── clusters/
│   ├── non-prod/
│   │   ├── talos-config/
│   │   ├── infra/
│   │   │   ├── external-dns/
│   │   │   ├── metallb/
│   │   │   ├── traefik/
│   │   │   ├── longhorn/
│   │   │   ├── minio/
│   │   │   └── gitops/
│   │   └── apps/
│   │       └── ephemeral/
│   └── prod/
│       ├── talos-config/
│       ├── infra/
│       │   ├── external-dns/
│       │   ├── metallb/
│       │   ├── traefik/
│       │   ├── longhorn/
│       │   ├── minio/
│       │   └── gitops/
│       └── apps/
├── scripts/
│   ├── bootstrap-cluster.sh
│   ├── create-ephemeral-env.sh
│   └── cleanup-ephemeral-env.sh
└── docs/
    ├── gitops-strategy.md
    └── operational-procedures.md
```

## GitOps Automation Flow

### 1. Feature Branch Creation
```yaml
# GitHub Actions / GitLab CI
on:
  push:
    branches: ['feature/*']
  
jobs:
  create-ephemeral:
    steps:
      - name: Extract feature name
        run: echo "FEATURE_NAME=${GITHUB_REF#refs/heads/feature/}" >> $GITHUB_ENV
      
      - name: Deploy ephemeral environment
        run: |
          # Create namespace: feature-${FEATURE_NAME}
          # Deploy app with ingress: ${FEATURE_NAME}.nonprod.internal
          # Update DNS records
```

### 2. Dev Branch Merge
```yaml
on:
  push:
    branches: ['dev']
  
jobs:
  deploy-nonprod:
    steps:
      - name: Cleanup ephemeral environments
        run: ./scripts/cleanup-ephemeral-env.sh
      
      - name: Deploy to non-prod
        run: |
          # Deploy to non-prod permanent namespace
          # Update ingress to dev.nonprod.internal
```

### 3. Main Branch Merge
```yaml
on:
  push:
    branches: ['main']
  
jobs:
  deploy-prod:
    steps:
      - name: Deploy to production
        run: |
          # Deploy to prod cluster
          # Update production ingress
```

## Implementation Order

### Phase 1: Cluster Bootstrap
1. **Talos Cluster Setup**
   - Generate Talos configurations
   - Bootstrap both clusters
   - Verify cluster connectivity

### Phase 2: Core Infrastructure (Non-Prod First)
1. **MetalLB** - IP address management
2. **Traefik** - Ingress controller
3. **Longhorn** - Storage with v2 default storage class
4. **ExternalDNS** - DNS automation
5. **MinIO** - S3 storage on third disk

### Phase 3: GitOps Infrastructure
1. **ArgoCD/Flux** - GitOps operator
2. **K8s Agent** - Cluster management
3. **CI/CD Pipelines** - Automation workflows

### Phase 4: Repeat for Production
1. Deploy same infrastructure stack to prod cluster
2. Configure production-specific settings
3. Set up cross-cluster monitoring

### Phase 5: Application Deployment Automation
1. Ephemeral environment automation
2. Promotion workflows
3. Rollback procedures

## Security Considerations

### Secrets Management
- Use sealed-secrets or external-secrets operator
- Store sensitive data in HashiCorp Vault or similar
- Rotate certificates automatically via cert-manager

### Network Security
- Network policies for namespace isolation
- mTLS between services where applicable
- Ingress authentication via OAuth2/OIDC

### RBAC
- Least privilege access
- Service account per application
- Regular access reviews

## Monitoring and Observability

### Metrics
- Prometheus for metrics collection
- Grafana for visualization
- AlertManager for notifications

### Logging
- Loki for log aggregation
- Fluent Bit for log forwarding
- Centralized logging dashboard

### Tracing
- Jaeger for distributed tracing
- OpenTelemetry instrumentation

## Disaster Recovery

### Backup Strategy
- Longhorn volume snapshots
- MinIO bucket replication
- Cluster configuration backups
- ETCD snapshots (automated)

### Recovery Procedures
- Cluster rebuild from Talos configs
- Volume restoration from snapshots
- Application state recovery
- DNS failover procedures

## Next Steps

1. Review and approve this strategy
2. Create initial repository structure
3. Begin Phase 1 implementation
4. Set up monitoring for implementation progress
5. Document operational procedures as we build
