# External Secrets Operator Setup

External Secrets Operator (ESO) syncs secrets from Bitwarden Secrets Manager to Kubernetes.

## Quick Start

### 1. Install ESO

**Via ArgoCD (recommended):**
```bash
kubectl apply -f ../argocd/applications/external-secrets-operator.yaml
```

**Via Script:**
```bash
./install.sh
```

### 2. Get Bitwarden Access Token

1. Log in to Bitwarden Secrets Manager: https://vault.bitwarden.com
2. Go to Settings → Security → Security Keys
3. Create a new Access Token with access to your secrets
4. Copy the token (you'll only see it once!)

### 3. Get Organization ID

1. In Bitwarden Secrets Manager, go to your organization settings
2. Copy the Organization ID (UUID format)
3. Update `clustersecretstore.yaml`:
   ```yaml
   organizationID: "YOUR_ORGANIZATION_ID"
   ```

### 4. Create Bitwarden Credentials Secret

```bash
kubectl create secret generic bitwarden-credentials \
  --from-literal=token='YOUR_BITWARDEN_ACCESS_TOKEN' \
  -n external-secrets-system
```

### 5. Deploy ClusterSecretStore

```bash
kubectl apply -f clustersecretstore.yaml
```

### 6. Verify Setup

```bash
# Check ESO is running
kubectl get pods -n external-secrets-system

# Check ClusterSecretStore status
kubectl get clustersecretstore

# Should show READY: True
kubectl describe clustersecretstore bitwarden-secrets-manager
```

### 7. Test with Example Secret

First, create a test secret in Bitwarden Secrets Manager:
- Name: `test-secret`
- Value: `hello-from-bitwarden`

Then deploy the test ExternalSecret:
```bash
kubectl apply -f examples/test-externalsecret.yaml

# Check if secret was created
kubectl get externalsecret test-secret -n default
kubectl get secret test-secret -n default

# View the synced value
kubectl get secret test-secret -n default -o jsonpath='{.data.password}' | base64 -d
```

## Using Secrets in Applications

### Pattern 1: Environment Variables

```yaml
# deployment.yaml
env:
- name: API_KEY
  valueFrom:
    secretKeyRef:
      name: sonarr-secrets  # Created by ExternalSecret
      key: SONARR_API_KEY
```

### Pattern 2: Volume Mounts

```yaml
# deployment.yaml
volumes:
- name: secrets
  secret:
    secretName: sonarr-secrets

containers:
- name: app
  volumeMounts:
  - name: secrets
    mountPath: /secrets
    readOnly: true
```

### Pattern 3: envFrom (all keys)

```yaml
# deployment.yaml
envFrom:
- secretRef:
    name: sonarr-secrets
```

## Creating Secrets in Bitwarden

### Organization Structure

```
Bitwarden Secrets Manager
└── Homelab Organization
    └── Projects (optional)
        ├── Infrastructure
        │   ├── traefik-dns-api-key
        │   └── cloudflare-api-token
        ├── Media Services
        │   ├── sonarr-api-key
        │   ├── radarr-api-key
        │   └── prowlarr-api-key
        └── Authentication
            ├── authelia-session-secret
            └── oauth2-client-secret
```

### Naming Convention

Use descriptive names that match your ExternalSecret `remoteRef.key`:

```yaml
# In Bitwarden: "sonarr-api-key"
# In ExternalSecret:
data:
  - secretKey: SONARR_API_KEY
    remoteRef:
      key: sonarr-api-key
```

## ExternalSecret Examples

See `examples/` directory for:
- `test-externalsecret.yaml` - Simple test secret
- `sonarr-secrets.yaml` - Media service secrets

## Common Issues

### ESO pods crash with "failed to append caBundle"

This is a known bug in ESO v0.11.0 with Bitwarden provider. Solutions:
1. Use ESO v0.10.x (downgrade)
2. Wait for ESO v0.12.0 (fix pending)
3. Use alternative secret store (GCP Secret Manager, AWS Secrets Manager)

### ClusterSecretStore shows "READY: False"

```bash
# Check events
kubectl describe clustersecretstore bitwarden-secrets-manager

# Common issues:
# - Invalid access token
# - Wrong organization ID
# - Secret doesn't exist in external-secrets-system namespace
```

### ExternalSecret not syncing

```bash
# Check ExternalSecret status
kubectl describe externalsecret <name> -n <namespace>

# Check ESO logs
kubectl logs -n external-secrets-system deployment/external-secrets -f

# Force refresh
kubectl annotate externalsecret <name> force-sync="$(date +%s)" --overwrite
```

## Migration from direnv/Ansible

**Before (Ansible with direnv):**
```bash
# .envrc
export SONARR_API_KEY="abc123"

# Ansible playbook
env:
- name: SONARR_API_KEY
  value: "{{ lookup('env', 'SONARR_API_KEY') }}"
```

**After (ESO with Bitwarden):**
```bash
# Create in Bitwarden Secrets Manager
# Name: sonarr-api-key
# Value: abc123

# ExternalSecret (in Git)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: sonarr-secrets
spec:
  data:
  - secretKey: SONARR_API_KEY
    remoteRef:
      key: sonarr-api-key

# Helm chart (in Git)
envFrom:
- secretRef:
    name: sonarr-secrets
```

Benefits:
- ✅ No local `.env` files needed
- ✅ Secrets never in Git
- ✅ Automatic rotation/refresh
- ✅ Centralized in Bitwarden
- ✅ Works with GitOps workflow

## Resources

- [ESO Documentation](https://external-secrets.io/)
- [Bitwarden Provider](https://external-secrets.io/latest/provider/bitwarden-secrets-manager/)
- [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/)
