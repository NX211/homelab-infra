# allowlist-reconciler

In-cluster reconciler for the staging review-access feature. Keeps each app's
Traefik `ipAllowList` Middleware in sync with coreyalan.com's desired state so a
client's reviewers get their IP allowlisted automatically (no GitOps commit per
IP). See `docs/staging-access/PLAN.md` in the coreyalan.com repo for the design.

## How it works

1. **Discovery** — lists base ConfigMaps labeled
   `allowlist.coreyalan.com/managed=true` in the `staging` namespace. Each one
   (rendered by the `staging-app` chart) carries `{ app, middleware,
   baseSourceRange, enabled }`.
2. **Pull** — for each app, `GET /api/internal/staging-allowlist?app=<app>` on
   coreyalan.com (Bearer `STAGING_INTERNAL_API_TOKEN`), then **verifies the HMAC
   signature** (`STAGING_ALLOWLIST_HMAC_SECRET`) before trusting the payload.
3. **Merge + apply** — writes `base ∪ reviewerIPs` (deduped, sorted) into the
   one Middleware via a `merge-patch`. Traefik chains `ipAllowList` with AND, so
   the union must live in a single middleware. Reviewer CIDRs are re-validated
   as public single hosts (defense-in-depth; `0.0.0.0/0` can never be applied).
   Skips the patch when already in sync.
4. **Ack** — `POST /api/internal/staging-allowlist/ack` so coreyalan flips the
   reviewer's grant to ACTIVE (their page unlocks) and records the applied
   version/hash.

Triggers: a 20s poll loop **plus** a push webhook (`POST /reconcile`, Bearer
`RECONCILER_WEBHOOK_TOKEN`) that coreyalan calls on every change for near-instant
apply. Fail-safe: any error leaves the Middleware at its last value — failures
only ever *block* reviewers, never widen access.

## Why Argo doesn't fight it

The chart creates the Middleware (so Argo owns its existence) but each staging
app's Argo `Application` sets `ignoreDifferences` on
`/spec/ipAllowList/sourceRange`, so `selfHeal` won't revert the reconciler's
writes. Base ranges stay in git (the chart values → base ConfigMap), keeping the
static policy declarative and auditable.

## Config (env)

| Env | Purpose |
|---|---|
| `COREYALAN_BASE_URL` | e.g. `https://coreyalan.com` |
| `STAGING_INTERNAL_API_TOKEN` | Bearer for the internal desired-state + ack APIs |
| `STAGING_ALLOWLIST_HMAC_SECRET` | verifies the desired-state signature |
| `RECONCILER_WEBHOOK_TOKEN` | verifies inbound `POST /reconcile` pushes |
| `NAMESPACE` | default `staging` |
| `LABEL_SELECTOR` | default `allowlist.coreyalan.com/managed=true` |
| `POLL_INTERVAL_MS` | default `20000` |
| `PORT` | default `8080` |

Secrets come from Bitwarden via External Secrets (see
`../../allowlist-reconciler/externalsecret.yaml`). RBAC is least-privilege:
`get/list/watch` ConfigMaps and `get/list/update/patch` Traefik Middlewares in
`staging` only.

## Build & publish the image

This repo is otherwise YAML-only; the source lives here for cohesion. Build and
push to the same Artifact Registry the staging apps use, then set the digest in
`allowlist-reconciler/deployment.yaml`:

```bash
IMG=us-central1-docker.pkg.dev/corey-alan-prod/coreyalan/allowlist-reconciler
docker build -t "$IMG:0.1.0" apps/allowlist-reconciler
docker push "$IMG:0.1.0"
```

> Wiring this into CI (a build workflow on changes under `apps/allowlist-reconciler/`)
> is a follow-up — confirm the target registry/project first.

## Run locally (dry, outside the cluster)

Requires a kubeconfig-equivalent; intended to run in-cluster. For a quick syntax
check: `node --check src/index.mjs`.
