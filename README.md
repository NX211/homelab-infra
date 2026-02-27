# Homelab Infrastructure

GitOps repository for k3s homelab cluster managed by ArgoCD.

## Cluster Details

- **Platform:** k3s on bare metal
- **Nodes:**
  - blacktalon (control plane, ZFS storage)
  - greytalon (database/storage node)
  - redtalon (general workload node)
- **Ingress:** Traefik
- **GitOps:** ArgoCD
- **DNS:** CoreDNS with split-horizon for internal domains

## Structure

```
homelab-infra/
├── README.md
├── bootstrap/              # Initial cluster setup scripts
│   └── install-argocd.sh
├── argocd/                 # ArgoCD configuration
│   ├── install.yaml       # ArgoCD installation manifest
│   └── applications/      # Application definitions
│       ├── argocd.yaml   # ArgoCD manages itself
│       └── traefik.yaml  # Traefik ingress controller
├── traefik/               # Traefik configuration reference
│   └── values.yaml
├── external-secrets-operator/  # External Secrets Operator with Bitwarden
│   ├── clustersecretstore.yaml
│   └── examples/
└── helm-charts/           # Custom Helm charts
    ├── argocd/           # ArgoCD wrapper chart
    ├── sonarr/           # Sonarr service
    ├── radarr/           # Radarr service
    └── prowlarr/         # Prowlarr service
```

## Bootstrap Process

**Choose your path:**

- **[BOOTSTRAP_EXISTING_TRAEFIK.md](BOOTSTRAP_EXISTING_TRAEFIK.md)** - If Traefik is already running (deployed via Ansible)
- **[BOOTSTRAP.md](BOOTSTRAP.md)** - If deploying everything from scratch

### Quick Start (Existing Traefik)

```bash
# 1. Install ArgoCD
cd bootstrap
./install-argocd.sh

# 2. Deploy ArgoCD IngressRoute (Traefik already running!)
kubectl apply -f argocd/traefik/ingressroute.yaml

# 3. Access ArgoCD immediately at:
# https://cd.authoritah.com
```

See **BOOTSTRAP_EXISTING_TRAEFIK.md** for complete steps.

This will:
- Create argocd namespace
- Install ArgoCD
- Configure initial admin password
- Wait for ArgoCD to be ready

### 2. Configure Git Repository

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Port-forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Login and change password
argocd login localhost:8080
argocd account update-password
```

### 3. Connect Git Repository

```bash
# Add your Gitea repo
argocd repo add https://gitea.authoritah.com/youruser/homelab-infra \
  --username your-username \
  --password your-token
```

### 4. Deploy Core Applications

```bash
# Deploy ArgoCD Application (ArgoCD manages itself)
kubectl apply -f argocd/applications/argocd.yaml

# Deploy Traefik
kubectl apply -f argocd/applications/traefik.yaml
```

### 5. Deploy Services

Once core infrastructure is running, deploy your services:

```bash
kubectl apply -f argocd/applications/
```

## Adding New Applications

### Using Public Helm Charts

Create an Application pointing to the official chart:

```yaml
# argocd/applications/app-name.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: app-name
    targetRevision: "1.0.0"
    helm:
      values: |
        # Your values here
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Using Custom Helm Charts

1. Create chart in `helm-charts/app-name/`
2. Create Application pointing to this repo

```yaml
# argocd/applications/app-name.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-name
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://gitea.authoritah.com/youruser/homelab-infra
    targetRevision: HEAD
    path: helm-charts/app-name
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Secrets Management

**External Secrets Operator + Bitwarden Secrets Manager**

All secrets are stored in Bitwarden Secrets Manager and synced to Kubernetes via ESO:
- ✅ **Single source of truth** - All secrets in Bitwarden
- ✅ **No manual kubectl** - Only ONE bootstrap secret needed
- ✅ **Automatic sync** - ESO pulls from Bitwarden every hour
- ✅ **No secrets in Git** - ExternalSecret manifests only reference secret names
- ✅ **Easy rotation** - Update in Bitwarden, ESO syncs automatically

**Quick Links:**
- [Secrets Summary](docs/SECRETS_SUMMARY.md) - Quick overview
- [Bitwarden Setup Guide](docs/BITWARDEN_SECRETS.md) - Detailed instructions
- [ESO Documentation](external-secrets-operator/README.md) - Complete setup

## Migration from Ansible

This repo will gradually replace the Ansible playbooks in `workbench/` for application deployment:

- **Ansible handles:** Infrastructure (k3s install, storage setup, node config)
- **ArgoCD handles:** Application lifecycle (services, ingress, etc.)

See [Migration Guide](docs/MIGRATION.md) for converting Ansible roles to Helm charts.

## Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Helm Documentation](https://helm.sh/docs/)
