# Traefik Helm Chart

Traefik ingress controller for k3s homelab cluster with Let's Encrypt DNS challenge via Dreamhost.

## Features

- **DaemonSet deployment** on nodes with `node-role.kubernetes.io/proxy=true` label
- **Let's Encrypt** wildcard certificates via Dreamhost DNS challenge
- **HTTP/3** support
- **Automatic HTTPS** redirect from HTTP
- **Built-in middlewares:**
  - default-headers (security headers, HSTS)
  - global-rate-limit
  - compression
  - circuit-breaker
  - inflight-limit
  - retry
  - internal-only (IP allowlist)
  - auth-rate-limit
- **Traefik dashboard** at `dashboard.authoritah.com` (internal only)
- **Prometheus metrics** enabled

## Prerequisites

1. **Node labeling:**
   ```bash
   kubectl label node <node-name> node-role.kubernetes.io/proxy=true
   ```

2. **Dreamhost API token secret** (if not already exists):
   ```bash
   kubectl create secret generic traefik-secrets \
     --from-literal=dreamhost-token='YOUR_DREAMHOST_API_TOKEN' \
     -n default
   ```

## Installation via ArgoCD

```bash
# Deploy the Traefik Application
kubectl apply -f ../../argocd/applications/traefik.yaml

# Watch the sync
argocd app get traefik
```

## Migration from Ansible

### Before Migration

The current Traefik is deployed via Ansible in the `workbench` repo. To transition:

1. **Verify the Helm chart works** (test in separate namespace first if desired)
2. **Ensure secrets exist:**
   ```bash
   kubectl get secret traefik-secrets -n default
   ```
3. **Check node labels:**
   ```bash
   kubectl get nodes -l node-role.kubernetes.io/proxy=true
   ```

### Migration Steps

1. **Deploy via ArgoCD** (ArgoCD will update the existing resources):
   ```bash
   kubectl apply -f ../../argocd/applications/traefik.yaml
   ```

2. **Verify** the deployment:
   ```bash
   kubectl get daemonset traefik -n default
   kubectl get pods -n default | grep traefik
   kubectl get svc traefik -n default
   ```

3. **Test** that ingress still works:
   ```bash
   curl -k https://cd.authoritah.com
   ```

4. **Remove from Ansible** once verified (update `site.yml` and `workbench` playbooks)

### Rollback Plan

If something goes wrong:

```bash
# Delete the ArgoCD Application
kubectl delete application traefik -n argocd

# Redeploy via Ansible
cd ~/Projects/workbench
ansible-playbook -i inventory site.yml --tags traefik
```

## Configuration

Edit `values.yaml` to customize:
- Certificate email
- Resource limits
- Rate limiting
- Middleware settings
- Dashboard access

Changes are automatically synced by ArgoCD.

## Dashboard Access

Access the Traefik dashboard at: `https://dashboard.authoritah.com`

**Note:** Dashboard is restricted to internal networks only via the `internal-only` middleware.

## Troubleshooting

### Check Traefik logs
```bash
kubectl logs -n default -l app.kubernetes.io/name=traefik
```

### Verify certificates
```bash
kubectl exec -n default <traefik-pod> -- ls -la /data/
```

### Check IngressRoutes
```bash
kubectl get ingressroute -A
```

### Test DNS challenge
```bash
# Check Dreamhost token is accessible
kubectl get secret traefik-secrets -n default -o jsonpath='{.data.dreamhost-token}' | base64 -d
```

## Middlewares Usage

Apply middlewares to your IngressRoutes:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`app.authoritah.com`)
      services:
        - name: my-app
          port: 80
      middlewares:
        - name: default-headers  # Security headers
        - name: compression      # Gzip compression
        - name: retry            # Automatic retries
  tls:
    certResolver: dnschallenge
```

## Resources

- [Official Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Let's Encrypt DNS Challenge](https://doc.traefik.io/traefik/https/acme/#dnschallenge)
