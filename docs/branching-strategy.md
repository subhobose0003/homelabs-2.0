# GitOps Branching Strategy

## Branch Structure

```
main (production)
├── dev (non-prod permanent)
└── feature/* (ephemeral test environments)
```

## Workflow Details

### 1. Feature Development
```bash
# Create feature branch from dev
git checkout dev
git pull origin dev
git checkout -b feature/user-authentication

# Work on feature
git add .
git commit -m "feat: add user authentication"
git push origin feature/user-authentication
```

**Automated Actions on Push:**
- Creates ephemeral namespace: `feature-user-authentication`
- Deploys application to non-prod cluster
- Creates ingress: `user-authentication.nonprod.internal`
- Updates DNS record automatically
- Posts deployment URL in PR/MR comments

### 2. Development Integration
```bash
# Create PR/MR: feature/user-authentication → dev
# After approval and merge:
```

**Automated Actions on Merge to Dev:**
- Destroys ephemeral environment `feature-user-authentication`
- Removes temporary DNS records
- Deploys to permanent non-prod environment
- Updates ingress: `dev.nonprod.internal`
- Auto-deletes feature branch
- Triggers integration tests

### 3. Production Deployment
```bash
# Create PR/MR: dev → main
# After approval and merge:
```

**Automated Actions on Merge to Main:**
- Deploys to production cluster
- Updates production ingress
- Triggers production health checks
- Creates deployment tag
- Sends deployment notifications

## Branch Protection Rules

### Main Branch (Production)
- Require pull request reviews (2 reviewers minimum)
- Require status checks to pass
- Require branches to be up to date before merging
- Restrict pushes to administrators only
- Require signed commits

### Dev Branch (Non-Prod)
- Require pull request reviews (1 reviewer minimum)
- Require status checks to pass
- Allow force pushes for administrators

### Feature Branches
- No protection rules (development flexibility)
- Automatic deletion after merge
- Require CI checks to pass before merge

## Environment Mapping

| Branch Pattern | Environment | Cluster | Namespace | Domain |
|---------------|-------------|---------|-----------|---------|
| `main` | Production | prod | `default` | `app.prod.internal` |
| `dev` | Non-Prod Permanent | non-prod | `dev` | `dev.nonprod.internal` |
| `feature/*` | Ephemeral Test | non-prod | `feature-{name}` | `{name}.nonprod.internal` |

## Deployment Triggers

### Feature Branch Push
```yaml
# .github/workflows/feature-deploy.yml
name: Deploy Feature Environment
on:
  push:
    branches: ['feature/*']

jobs:
  deploy-ephemeral:
    runs-on: ubuntu-latest
    steps:
      - name: Extract feature name
        id: feature
        run: |
          FEATURE_NAME=${GITHUB_REF#refs/heads/feature/}
          echo "name=${FEATURE_NAME}" >> $GITHUB_OUTPUT
          echo "namespace=feature-${FEATURE_NAME}" >> $GITHUB_OUTPUT
      
      - name: Deploy to ephemeral environment
        run: |
          # Deploy application with feature-specific config
          kubectl create namespace ${{ steps.feature.outputs.namespace }} --dry-run=client -o yaml | kubectl apply -f -
          helm upgrade --install ${{ steps.feature.outputs.name }} ./charts/app \
            --namespace ${{ steps.feature.outputs.namespace }} \
            --set ingress.host=${{ steps.feature.outputs.name }}.nonprod.internal \
            --set image.tag=${GITHUB_SHA}
```

### Dev Branch Merge
```yaml
# .github/workflows/dev-deploy.yml
name: Deploy to Non-Prod
on:
  push:
    branches: ['dev']

jobs:
  cleanup-ephemeral:
    runs-on: ubuntu-latest
    steps:
      - name: Clean up ephemeral environments
        run: |
          # Find and delete feature namespaces
          kubectl get namespaces -l type=ephemeral -o name | xargs kubectl delete
  
  deploy-dev:
    needs: cleanup-ephemeral
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to dev environment
        run: |
          helm upgrade --install app ./charts/app \
            --namespace dev \
            --set ingress.host=dev.nonprod.internal \
            --set image.tag=${GITHUB_SHA}
```

### Main Branch Merge
```yaml
# .github/workflows/prod-deploy.yml
name: Deploy to Production
on:
  push:
    branches: ['main']

jobs:
  deploy-prod:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Deploy to production
        run: |
          helm upgrade --install app ./charts/app \
            --namespace default \
            --set ingress.host=app.prod.internal \
            --set image.tag=${GITHUB_SHA} \
            --set resources.requests.cpu=500m \
            --set resources.requests.memory=512Mi
```

## Rollback Strategy

### Automatic Rollback Triggers
- Health check failures after deployment
- Error rate above threshold (5% for 5 minutes)
- Response time degradation (>2x baseline)

### Manual Rollback Process
```bash
# Rollback production
git revert <commit-hash>
git push origin main

# Or use Helm rollback
helm rollback app --namespace default
```

## Hotfix Process

For critical production issues:

```bash
# Create hotfix branch from main
git checkout main
git checkout -b hotfix/critical-security-fix

# Make minimal changes
git commit -m "hotfix: patch security vulnerability"
git push origin hotfix/critical-security-fix

# Create PR to main (expedited review)
# After merge, cherry-pick to dev
git checkout dev
git cherry-pick <hotfix-commit>
git push origin dev
```

## Environment Lifecycle

### Ephemeral Environment TTL
- **Default TTL**: 7 days from creation
- **Auto-cleanup**: Daily job removes stale environments
- **Manual extension**: Add label `ttl=extended` for 30 days

### Resource Limits per Environment
```yaml
# Ephemeral environments
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Dev environment
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# Production environment
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```

## Monitoring & Notifications

### Slack/Teams Integration
- Feature environment ready notifications
- Deployment success/failure alerts
- Environment cleanup notifications
- Production deployment approvals

### Metrics Tracking
- Deployment frequency
- Lead time for changes
- Mean time to recovery
- Change failure rate

This branching strategy ensures complete GitOps automation while maintaining proper controls and visibility throughout the development lifecycle.
