# GitOps Talos Kubernetes Homelab

A complete GitOps-driven Kubernetes infrastructure using Talos Linux with automated deployment pipelines.

## Architecture Overview

- **Non-Prod Cluster**: 3 master + 3 worker nodes (IP range: 192.168.0.x)
- **Prod Cluster**: 3 master + 3 worker nodes (IP range: 10.0.2.x)
- **GitOps Workflow**: Feature branches → Dev → Production with automated environments

## Infrastructure Stack

1. **ExternalDNS** - DNS automation with internal DNS server
2. **MetalLB** - LoadBalancer services for bare-metal
3. **Longhorn** - Distributed block storage (v2 default storage class)
4. **Traefik** - Ingress controller with Let's Encrypt via Cloudflare
5. **MinIO** - S3-compatible object storage
6. **HashiCorp Vault** - Centralized secret management
7. **ArgoCD** - GitOps continuous deployment
8. **K8s Agent** - Cluster monitoring and management

## Repository Structure

```
homelabs/
├── clusters/
│   ├── non-prod/
│   │   ├── talos-config/          # Talos cluster configuration
│   │   ├── infra/                 # Infrastructure components
│   │   │   ├── external-dns/
│   │   │   ├── metallb/
│   │   │   ├── longhorn/
│   │   │   ├── traefik/
│   │   │   ├── minio/
│   │   │   ├── vault/
│   │   │   └── gitops/
│   │   └── apps/
│   │       └── ephemeral/         # Feature branch environments
│   └── prod/
│       ├── talos-config/
│       ├── infra/                 # Same structure as non-prod
│       └── apps/
├── scripts/                       # Automation scripts
├── docs/                          # Documentation
└── README.md
```

## Getting Started

1. **Phase 1**: Bootstrap Talos clusters (scripted, endpoints set automatically)
2. **Phase 2**: Deploy infrastructure stack (non-prod first)
3. **Phase 3**: Set up GitOps automation
4. **Phase 4**: Replicate to production
5. **Phase 5**: Configure CI/CD pipelines

## Documentation

- [GitOps Strategy](docs/gitops-strategy.md)
- [Implementation Plan](docs/implementation-plan.md)
- [Branching Strategy](docs/branching-strategy.md)

## Quick Commands

```bash
# Bootstrap non-prod cluster (interactive)
# - Sets talosctl endpoints to first control-plane
# - Bootstraps etcd once
# - Prompts to confirm control-plane readiness and node joins
# - Generates kubeconfig at clusters/non-prod/talos-config/kubeconfig
# - Waits for all nodes to register and become Ready, then runs talosctl health
./scripts/bootstrap-cluster.sh non-prod

# Deploy infrastructure
kubectl apply -k clusters/non-prod/infra/

# Create ephemeral environment
./scripts/create-ephemeral-env.sh feature-name

# Cleanup ephemeral environments
./scripts/cleanup-ephemeral-env.sh
```

### Bootstrap Notes

- Nodes auto-join after their configs are applied; there is no `talosctl join`.
- Endpoints are configured in talosconfig prior to bootstrap.
- Kubeconfig is written to `clusters/<env>/talos-config/kubeconfig`.
- Per-node network patches are saved to `clusters/<env>/talos-config/[hostname]-network-patch.yaml`.
- Timeouts can be tuned via environment variables:
  - `WAIT_TIMEOUT` (default 900s) and `WAIT_INTERVAL` (default 5s) for node registration.
  - `K8S_READY_TIMEOUT_SECS` (default 600s) for node Ready condition.

## Monitoring

- **ArgoCD UI**: https://argocd.nonprod.internal
- **Longhorn UI**: https://longhorn.nonprod.internal
- **Vault UI**: https://vault.nonprod.internal
- **MinIO Console**: https://minio.nonprod.internal

## Security

- All secrets managed via HashiCorp Vault
- TLS certificates automated via Let's Encrypt
- Network policies for namespace isolation
- RBAC with least privilege principles
