# Talos Kubernetes GitOps Implementation Plan

## Installation Order & Dependencies

### Phase 1: Foundation Setup (Week 1-2)

#### 1.1 Repository Structure Creation
```bash
# Create the complete directory structure
mkdir -p clusters/{non-prod,prod}/{talos-config,infra,apps}
mkdir -p clusters/non-prod/infra/{external-dns,metallb,traefik,longhorn,minio,gitops}
mkdir -p clusters/prod/infra/{external-dns,metallb,traefik,longhorn,minio,gitops}
mkdir -p clusters/non-prod/apps/ephemeral
mkdir -p scripts docs
```

#### 1.2 Talos Cluster Bootstrap
**Dependencies**: None
**Order**: 1st
```bash
# Bootstrap non-prod (interactive)
# - Sets talosctl endpoints to first control-plane
# - Bootstraps etcd once on that node
# - Nodes auto-join after configs are applied (no `talosctl join`)
# - Generates kubeconfig at clusters/non-prod/talos-config/kubeconfig
# - Waits for all nodes to register and become Ready, then runs talosctl health
./scripts/bootstrap-cluster.sh non-prod

# Bootstrap prod when ready
./scripts/bootstrap-cluster.sh prod
```

Notes:
- Endpoints are configured in talosconfig before bootstrap per Talos docs.
- Per-node network patches are generated and saved under `clusters/<env>/talos-config/[hostname]-network-patch.yaml`.
- Kubeconfig is written to `clusters/<env>/talos-config/kubeconfig`.

### Phase 2: Core Infrastructure - Non-Prod (Week 2-3)

#### 2.1 ExternalDNS
**Dependencies**: Cluster ready, Internal DNS server
**Order**: 1st in infra
**Why first**: DNS automation is foundational for all other services

```yaml
# clusters/non-prod/infra/external-dns/
├── namespace.yaml
├── external-dns-deployment.yaml
├── rbac.yaml
└── secret.yaml (DNS server credentials)
```

#### 2.2 MetalLB (Load Balancer)
**Dependencies**: ExternalDNS
**Order**: 2nd in infra
**Why**: Provides LoadBalancer service type needed by other services

```yaml
# clusters/non-prod/infra/metallb/
├── namespace.yaml
├── metallb-system.yaml
└── ipaddresspool.yaml (192.168.0.100-192.168.0.150)
```

#### 2.3 Longhorn (Storage)
**Dependencies**: MetalLB
**Order**: 3rd in infra
**Why**: Storage is required by Traefik for ACME certificate persistence

```yaml
# clusters/non-prod/infra/longhorn/
├── namespace.yaml
├── longhorn-system.yaml
├── storageclass-v2.yaml (default)
└── ingress.yaml
```

**Post-install**: Verify secondary disk (/dev/sdb) is available and formatted

#### 2.4 Traefik (Ingress Controller with Let's Encrypt)
**Dependencies**: MetalLB, Longhorn
**Order**: 4th in infra
**Why**: Needs LoadBalancer IP from MetalLB and storage from Longhorn for ACME certificates

```yaml
# clusters/non-prod/infra/traefik/
├── namespace.yaml
├── traefik-deployment.yaml (with Cloudflare DNS challenge)
├── traefik-service.yaml (type: LoadBalancer)
├── traefik-config.yaml (ACME + Cloudflare settings)
├── traefik-pvc.yaml (for ACME certificate storage)
└── middleware.yaml
```

**Note**: Traefik handles Let's Encrypt certificates directly via Cloudflare DNS challenge - no cert-manager needed

#### 2.5 MinIO (S3 Storage)
**Dependencies**: Longhorn (for PVCs), MetalLB (for service)
**Order**: 5th in infra
**Why**: Needs storage and load balancer

```yaml
# clusters/non-prod/infra/minio/
├── namespace.yaml
├── minio-deployment.yaml
├── minio-service.yaml
├── minio-pvc.yaml (third disk /dev/sdc)
└── minio-ingress.yaml
```

#### 2.6 HashiCorp Vault (Secret Management)
**Dependencies**: Longhorn (for persistence), MetalLB (for service)
**Order**: 6th in infra
**Why**: Centralized secret management for all applications and infrastructure

```yaml
# clusters/non-prod/infra/vault/
├── namespace.yaml
├── vault-deployment.yaml
├── vault-service.yaml
├── vault-pvc.yaml (for data persistence)
├── vault-config.yaml
├── vault-ingress.yaml
├── vault-rbac.yaml
└── external-secrets-operator.yaml
```

**Post-install**: 
- Initialize Vault with unseal keys
- Configure authentication methods (Kubernetes, OIDC)
- Set up secret engines (KV v2, PKI)
- Deploy External Secrets Operator for K8s integration

### Phase 3: GitOps Infrastructure - Non-Prod (Week 3-4)

#### 3.1 ArgoCD (GitOps Operator)
**Dependencies**: Longhorn (for persistence), Traefik (for UI access)
**Order**: 7th in infra

```yaml
# clusters/non-prod/infra/gitops/argocd/
├── namespace.yaml
├── argocd-install.yaml
├── argocd-ingress.yaml
├── argocd-projects.yaml
└── applications/
    ├── infra-apps.yaml
    └── user-apps.yaml
```

#### 3.2 Kubernetes Agent (Monitoring)
**Dependencies**: ArgoCD
**Order**: 8th in infra

```yaml
# clusters/non-prod/infra/gitops/k8s-agent/
├── namespace.yaml
├── agent-deployment.yaml
├── rbac.yaml
└── configmap.yaml
```

### Phase 4: Automation Setup (Week 4-5)

#### 4.1 CI/CD Pipeline Configuration
```yaml
# .github/workflows/ or .gitlab-ci.yml
├── feature-branch.yml      # Ephemeral environment creation
├── dev-deployment.yml      # Non-prod permanent deployment
├── prod-deployment.yml     # Production deployment
└── cleanup.yml            # Ephemeral environment cleanup
```

#### 4.2 Ephemeral Environment Scripts
```bash
# scripts/
├── bootstrap-cluster.sh
├── create-ephemeral-env.sh
├── cleanup-ephemeral-env.sh
├── promote-to-dev.sh
└── promote-to-prod.sh
```

### Phase 5: Production Cluster Setup (Week 5-6)

#### 5.1 Replicate Infrastructure Stack
- Follow same order as non-prod (2.1 → 2.6 → 3.1 → 3.2)
- Use production-specific configurations
- Different IP ranges, domains, and security settings

#### 5.2 Production-Specific Configurations
```yaml
# clusters/prod/infra/metallb/ipaddresspool.yaml
# IP range: 10.0.2.100-10.0.2.150

# clusters/prod/infra/traefik/
# Production domain configurations

# clusters/prod/infra/longhorn/
# Production storage classes and policies
```

### Phase 6: Testing & Validation (Week 6-7)

#### 6.1 End-to-End Testing
1. Create feature branch → verify ephemeral environment
2. Merge to dev → verify non-prod deployment + cleanup
3. Merge to main → verify prod deployment
4. Test rollback procedures
5. Validate monitoring and alerting

#### 6.2 Documentation Completion
- Operational runbooks
- Troubleshooting guides
- Security procedures
- Backup/restore procedures

## Critical Dependencies & Notes

### Disk Configuration
- **Primary disk**: OS and container storage
- **Secondary disk (/dev/sdb)**: Longhorn block storage
- **Third disk (/dev/sdc)**: MinIO object storage

### Network Requirements
- **Non-prod LoadBalancer range**: 192.168.0.100-192.168.0.150
- **Prod LoadBalancer range**: 10.0.2.100-10.0.2.150
- **DNS integration**: Must point to internal DNS server
- **Ingress domains**: 
  - Non-prod: `*.nonprod.internal`
  - Prod: `*.prod.internal` or production domains

### Security Considerations
- All secrets managed via sealed-secrets or external-secrets
- RBAC configured for least privilege
- Network policies for namespace isolation
- Regular security scanning and updates

### Monitoring Stack (Optional Phase 7)
If monitoring is required:
1. **Prometheus** (metrics)
2. **Grafana** (visualization)  
3. **Loki** (logging)
4. **AlertManager** (notifications)

## Success Criteria

### Phase Completion Checkpoints
- [ ] Both clusters bootstrapped and accessible
- [ ] All infrastructure components deployed and healthy
- [ ] GitOps workflows functional (feature → dev → prod)
- [ ] Ephemeral environments create/destroy automatically
- [ ] DNS updates working for all environments
- [ ] Storage and networking fully operational
- [ ] Monitoring and alerting configured
- [ ] Documentation complete and tested

### Operational Readiness
- [ ] Team trained on GitOps workflows
- [ ] Runbooks tested and validated
- [ ] Disaster recovery procedures verified
- [ ] Security policies implemented and audited
- [ ] Performance baselines established
