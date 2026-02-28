# Authelia Helm Chart

Authentication and authorization server for the homelab.

## Overview

Authelia provides:
- **SSO (Single Sign-On)** via OIDC/OAuth2
- **Two-factor authentication** (TOTP)
- **Access control** for applications behind Traefik
- **Session management** with Redis
- **User management** via file-based backend

## Prerequisites

### 1. Required Secrets in Bitwarden

The following secrets must exist in Bitwarden Secrets Manager:

**Database:**
- `authelia-database` - Database name
- `authelia-database-user` - Database username
- `authelia-database-password` - Database password

**Core Secrets:**
- `authelia-jwt-secret` - JWT secret for password reset
- `authelia-session-secret` - Session encryption secret
- `authelia-encryption-key` - Storage encryption key
- `authelia-session-default-name` - Default session cookie name
- `authelia-session-project-tld-name` - Project TLD session cookie name

**OIDC:**
- `authelia-oidc-hmac-secret` - OIDC HMAC secret
- `authelia-oidc-gitea-client-secret` - Gitea OIDC client secret
- `gitea-oidc-client-id` - Gitea OIDC client ID

**Users:**
- `authelia-user-1-username` - First user's username
- `authelia-user-1-display-name` - First user's display name
- `authelia-user-1-password` - First user's hashed password (argon2id)
- `authelia-user-1-email` - First user's email
- `authelia-user-2-username` - Second user's username
- `authelia-user-2-display-name` - Second user's display name
- `authelia-user-2-password` - Second user's hashed password (argon2id)
- `authelia-user-2-email` - Second user's email

### 2. OIDC Private Key

**Important:** The OIDC private key secret must be created manually:

```bash
# The secret authelia-oidc-keys must contain a 'private-key' field
# This is the RSA private key for signing JWT tokens
kubectl create secret generic authelia-oidc-keys \
  --from-file=private-key=/path/to/private-key.pem \
  -n default
```

### 3. Dependencies

- PostgreSQL (postgres-rw service)
- Redis (redis service)
- Traefik (for IngressRoute)
- External Secrets Operator (for Bitwarden integration)

## Configuration

### Access Control Rules

By default, Authelia requires two-factor authentication for all services. Rules are configured in `values.yaml`:

```yaml
accessControl:
  defaultPolicy: two_factor
  rules:
    # Bypass authentication for API endpoints
    - domain: "*.authoritah.com"
      policy: bypass
      resources:
        - "^/api/.*$"

    # Require 2FA + admin group for Traefik dashboard
    - domain: "api.authoritah.com"
      policy: two_factor
      subject:
        - "group:admin"
```

### OIDC Clients

OIDC clients are configured in the ConfigMap. Currently configured:
- **Gitea** - Code repository with SSO

To add more OIDC clients, update `values.yaml` and the `configmap-config.yaml` template.

## Protecting Services with Authelia

To protect a service with Authelia authentication:

1. **Add access control rule** in `values.yaml`:
   ```yaml
   accessControl:
     rules:
       - domain: "myapp.authoritah.com"
         policy: two_factor
         subject:
           - "group:admin"  # Optional: restrict to specific groups
   ```

2. **Update the IngressRoute** to use Authelia middleware:
   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: IngressRoute
   metadata:
     name: myapp
   spec:
     entryPoints:
       - websecure
     routes:
     - match: Host(`myapp.authoritah.com`)
       kind: Rule
       middlewares:
         - name: authelia-forwardauth  # Add this middleware
       services:
       - name: myapp
         port: 8080
     tls:
       certResolver: dnschallenge
   ```

## Generating Password Hashes

User passwords must be hashed with argon2id. Use the Authelia CLI:

```bash
# Run in Authelia pod
kubectl exec -it authelia-0 -n default -- authelia crypto hash generate argon2 --password 'your-password'
```

Or using Docker:

```bash
docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'your-password'
```

## Deployment

1. **Ensure all secrets exist** in Bitwarden

2. **Create OIDC private key secret**:
   ```bash
   kubectl create secret generic authelia-oidc-keys \
     --from-file=private-key=/path/to/private-key.pem \
     -n default
   ```

3. **Deploy via ArgoCD**:
   ```bash
   kubectl apply -f argocd/applications/authelia.yaml
   ```

4. **Verify deployment**:
   ```bash
   kubectl get pods -n default -l app=authelia
   kubectl logs -n default authelia-0
   ```

5. **Access Authelia**:
   - URL: https://login.authoritah.com
   - Login with credentials from Bitwarden secrets

## Monitoring

Prometheus metrics are available at:
- Endpoint: `/metrics`
- Port: `9959`

Metrics are automatically scraped if Prometheus is configured to discover pods with annotation `prometheus.io/scrape: "true"`.

## Troubleshooting

### Authentication Loop

If you get stuck in an authentication loop:
1. Check Authelia logs: `kubectl logs -n default authelia-0`
2. Verify IngressRoute middleware is configured correctly
3. Ensure the domain is in Authelia's access control rules

### OIDC Client Issues

If OIDC authentication fails:
1. Verify client secret matches in both Authelia and the client app
2. Check redirect URIs match exactly
3. Review Authelia logs for OIDC-specific errors

### Database Connection

If Authelia can't connect to PostgreSQL:
```bash
# Check PostgreSQL service
kubectl get service postgres-rw -n default

# Check database secret
kubectl get secret authelia-database -n default -o yaml
```

## Files

- `Chart.yaml` - Chart metadata
- `values.yaml` - Configuration values
- `templates/statefulset.yaml` - Main Authelia deployment
- `templates/service.yaml` - Service definition
- `templates/configmap-config.yaml` - Authelia configuration file
- `templates/externalsecrets.yaml` - Bitwarden secret sync
- `templates/ingressroute.yaml` - Traefik routing
- `templates/middleware.yaml` - ForwardAuth middleware for other services
- `templates/priorityclass.yaml` - Pod priority

## References

- [Authelia Documentation](https://www.authelia.com/docs/)
- [Traefik ForwardAuth](https://doc.traefik.io/traefik/middlewares/http/forwardauth/)
- [OIDC Configuration](https://www.authelia.com/configuration/identity-providers/oidc/)
