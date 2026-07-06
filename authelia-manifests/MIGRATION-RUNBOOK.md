# Authelia config → GitOps (template-filter) migration runbook

> **STATUS (done in this PR):** the config has already been transformed,
> `authelia validate-config`-verified **clean**, and committed into
> `configmap-config.yaml`. All 6 core secrets + the 5 OIDC client-secret hashes
> are externalized to ESO-mounted `/secrets/*` files (no secret material in the
> public repo). SMTP uses `submission://` (port 587). **Your only remaining
> steps are the backup + merge + verify below (Steps 6–7).** Steps 1–5 are the
> record of how the body was produced.

Brings the out-of-band `authelia-config` **Secret** under GitOps as a
`ConfigMap` (`authelia-configuration`), with all secrets injected at load time
by Authelia's `template` filter from the ESO-mounted `/secrets/*` files. Also
lands multi-domain SSO (`authoritah.tv`), WebAuthn, and SMTP.

**Everything below was pre-verified** (see the PR): every externalized secret's
ESO value matches the current inline value **except `session.secret`** (differs
→ one-time re-login for active users, which is fine). `db.password` matches, so
Authelia will not fail to connect.

Prereqs: `login.authoritah.tv` DNS A record exists and the portal route (PR #486)
is live, so the `.tv` cookie's `authelia_url` resolves.

---

## Step 1 — Dump your current config

```
kubectl -n default get secret authelia-config -o jsonpath='{.data.configuration\.yml}' | base64 -d > authelia.yml
cp authelia.yml authelia.yml.bak   # keep a pristine copy
```

## Step 2 — Externalize the 6 secrets (replace inline value with the ref)

Edit `authelia.yml`. **No raw secret stays in the file.**

| Field | Replace the inline value with |
|---|---|
| `session.secret` (⚠️ **multi-line** — replace BOTH lines) | `{{ secret "/secrets/core/session-secret" }}` |
| `storage.encryption_key` | `{{ secret "/secrets/core/encryption-key" }}` |
| `identity_validation.reset_password.jwt_secret` | `{{ secret "/secrets/core/jwt-secret" }}` |
| `identity_providers.oidc.hmac_secret` | `{{ secret "/secrets/oidc/oidc-hmac-secret" }}` |
| `storage.postgres.password` | `{{ secret "/secrets/database/database-password" }}` |

For the **OIDC signing key**, replace the whole inline `key: |` PEM block
(`-----BEGIN…-----` … `-----END…-----`) with:

```yaml
        jwks:
          - key_id: 'Authoritah'
            algorithm: 'RS256'
            use: 'sig'
            key: |
              {{- fileContent "/secrets/oidc-keys/jwks-key.pem" | nindent 14 }}
```
(Match `nindent` to your indentation — the PEM content sits ~14 spaces in. Keep
`key_id`/`algorithm`/`use` exactly as they already are.)

> OIDC **client-secret hashes** (`$argon2id$…`) stay inline — they are one-way
> verifiers, not reversible secrets.

## Step 3 — Add the new blocks

**`.tv` session cookie** — in `session.cookies:`, right after the `authoritah_com_auth` entry:
```yaml
    - name: 'authoritah_tv_auth'
      domain: 'authoritah.tv'
      authelia_url: 'https://login.authoritah.tv'
      same_site: 'lax'
      inactivity: '5 minutes'
      expiration: '1 hour'
      remember_me: '1 month'
```

**`*.authoritah.tv` API bypass** — in `access_control.rules:`, next to the `*.authoritah.com` bypass:
```yaml
  - domain: "*.authoritah.tv"
    policy: bypass
    resources:
      - "^/api/.*$"
      - "^/identity/.*$"
      - "^/triggers/.*$"
```

**WebAuthn** — add as a new top-level block (e.g. just before `notifier:`):
```yaml
webauthn:
  disable: false
  display_name: 'Authoritah'
  attestation_conveyance_preference: 'indirect'
  timeout: '60s'
```

**SMTP** — replace the entire `notifier:` block with:
```yaml
notifier:
  disable_startup_check: true
  smtp:
    address: 'submissions://{{ secret "/secrets/smtp/host" }}:{{ secret "/secrets/smtp/port" }}'
    timeout: 5s
    username: '{{ secret "/secrets/smtp/user" }}'
    password: '{{ secret "/secrets/smtp/password" }}'
    sender: 'Authoritah Login <{{ secret "/secrets/smtp/user" }}>'
    subject: '[Authoritah] {title}'
    disable_require_tls: false
    disable_html_emails: false
```
> Scheme `submissions://` assumes port **465**. If `email_port` is **587**, use
> `submission://` instead.

## Step 4 — Validate (structure) BEFORE cutover

The `/secrets/*` mounts don't exist yet, so validate **without** the filter
(the `{{ secret }}` refs are treated as literal strings — this checks YAML +
schema, which is what can lock you out):

```
kubectl -n default exec -i statefulset/authelia -- sh -c 'cat > /tmp/v.yml && authelia validate-config --config /tmp/v.yml; rc=$?; rm -f /tmp/v.yml; exit $rc' < authelia.yml
```
Fix anything it reports. Do **not** proceed until it's clean.

## Step 5 — Put the validated body into the ConfigMap + commit

Replace the `__REPLACE_WITH_TRANSFORMED_CONFIGURATION_YML__` placeholder in
`authelia-manifests/configmap-config.yaml` with your validated `authelia.yml`
(indented 4 spaces under `configuration.yml: |`), then commit to this branch.

## Step 6 — Back up the live secret, then cut over

```
# BACKUP (rollback lifeline)
kubectl -n default get secret authelia-config -o yaml > authelia-config.secret.bak.yaml

# Merge the PR → Argo applies ConfigMap + SMTP ExternalSecret + statefulset together.
# Watch the roll:
kubectl -n default rollout status statefulset/authelia --timeout=180s
kubectl -n default logs statefulset/authelia --tail=40
```

## Step 7 — Verify
- Authelia pod Ready; logs show config loaded, no "secret" / "file not found" errors.
- Log in at `https://login.authoritah.com` **and** hit a `.tv` service → redirects to `https://login.authoritah.tv` and authenticates.
- OIDC app login (e.g. Immich) still works (proves the JWKS `fileContent` resolved).
- (After SMTP) trigger a password-reset email to confirm mail sends.

## Rollback (if anything's wrong)
```
kubectl -n default apply -f authelia-config.secret.bak.yaml       # restore the Secret
# revert the statefulset config volume back to: secret / secretName: authelia-config
git revert <this-merge> && push   # or flip the volume in authelia-manifests/statefulset.yaml
```

## Cleanup (after a day of stability)
```
kubectl -n default delete secret authelia-config   # the old manual secret, now unused
```

## Not included here (separate, tracked)
- **encryption_key rotation** — it's currently the dummy `e3b0c44…`. Fixing it
  re-encrypts the DB (`authelia storage encryption change-key`); do it as its own
  step or TOTP secrets break.
- **grafana / tailscale OIDC clients** — need their redirect URIs.
