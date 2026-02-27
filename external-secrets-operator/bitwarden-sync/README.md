# Bitwarden to Kubernetes Secret Sync

This setup syncs secrets from Bitwarden Secrets Manager to Kubernetes, then uses External Secrets Operator to distribute them to applications.

## Architecture

```
Bitwarden (source of truth)
    ↓
CronJob (bws sync every 15min)
    ↓
secrets-vault namespace (k8s secrets)
    ↓
ESO (Kubernetes provider)
    ↓
Application secrets
```

## Setup Steps

### 1. Deploy the sync infrastructure

```bash
# Create namespace and RBAC
kubectl apply -f external-secrets-operator/bitwarden-sync/namespace.yaml
kubectl apply -f external-secrets-operator/bitwarden-sync/rbac.yaml

# Create Bitwarden credentials secret
kubectl create secret generic bitwarden-credentials \
  --from-literal=token='YOUR_BITWARDEN_ACCESS_TOKEN' \
  -n secrets-vault

# Deploy sync script and CronJob
kubectl apply -f external-secrets-operator/bitwarden-sync/sync-script.yaml
kubectl apply -f external-secrets-operator/bitwarden-sync/cronjob.yaml
```

### 2. Run initial sync

```bash
# Trigger a manual sync job
kubectl create job --from=cronjob/bitwarden-sync bitwarden-sync-manual -n secrets-vault

# Watch the job
kubectl logs -f job/bitwarden-sync-manual -n secrets-vault

# Verify secrets were synced
kubectl get secrets -n secrets-vault
```

### 3. Deploy ClusterSecretStore

```bash
# Apply ESO RBAC (allows ESO to read from secrets-vault)
kubectl apply -f external-secrets-operator/eso-rbac.yaml

# Deploy Kubernetes backend ClusterSecretStore
kubectl apply -f external-secrets-operator/clustersecretstore-kubernetes.yaml

# Verify it's ready
kubectl get clustersecretstore kubernetes-backend
```

### 4. Create ExternalSecrets for your apps

See `external-secrets-operator/examples/traefik-externalsecret.yaml` for an example.

```bash
# Apply example
kubectl apply -f external-secrets-operator/examples/traefik-externalsecret.yaml

# Verify secret was created
kubectl get secret traefik-secrets -n default
```

## How to Add New Secrets

1. **Add secret to Bitwarden Secrets Manager**
   - Go to https://vault.bitwarden.com
   - Add to your project

2. **Wait for sync** (or trigger manually)
   ```bash
   kubectl create job --from=cronjob/bitwarden-sync sync-now -n secrets-vault
   ```

3. **Secret appears in secrets-vault namespace**
   - Name is lowercase version of Bitwarden key
   - Underscores converted to hyphens

4. **Reference in ExternalSecret**
   ```yaml
   data:
     - secretKey: my-app-secret
       remoteRef:
         key: my-bitwarden-secret-name
         property: value
   ```

## Troubleshooting

### Check sync job logs
```bash
kubectl logs -n secrets-vault -l app=bitwarden-sync --tail=100
```

### Manually trigger sync
```bash
kubectl create job --from=cronjob/bitwarden-sync sync-manual-$(date +%s) -n secrets-vault
```

### Verify ClusterSecretStore
```bash
kubectl describe clustersecretstore kubernetes-backend
```

### Check ExternalSecret status
```bash
kubectl describe externalsecret traefik-secrets -n default
```

## Benefits

- ✅ Bitwarden as single source of truth
- ✅ Automatic sync every 15 minutes
- ✅ No SDK server complexity
- ✅ Proven pattern (similar to production)
- ✅ Easy to troubleshoot
