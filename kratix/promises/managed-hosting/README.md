# managed-hosting Promise (L3.2)

Kratix's platform API for provisioning a client tenant. **Wraps** the Restate
reconcile rather than replacing it (ADR-0018 amendment): `spec.api` is the same
`Tenant` CRD the reconcile loop already uses, and the resource pipeline is a
thin adapter that POSTs the Restate `provisionTenant` reconcile. Kratix owns the
API + scheduling + composition; Restate stays the durable executor; the islands
don't move.

## Pieces

- `promise.yaml` — the Promise (embeds the `Tenant` CRD + the reconcile pipeline).
- `pipeline/` — the adapter: `reconcile.sh` reads `/kratix/input/object.yaml` and
  POSTs `provisionTenant/<name>/reconcile/send` in-cluster; `Dockerfile` builds it
  (`alpine + curl + yq`, non-root).

## Build the adapter image (needed before deploy)

```
docker build -t ghcr.io/corey-alan-consulting/kratix-tenant-adapter:v0.1.0 pipeline/
docker push  ghcr.io/corey-alan-consulting/kratix-tenant-adapter:v0.1.0
```

(Or wire it into a CI build. The Promise references this tag.)

## Deploy — during L3.3, NOT now

Installing this Promise creates `tenants.platform.coreyalan.com` — the **same**
CRD the Metacontroller CompositeController already reconciles. Deploying it now
would **double-drive** every Tenant. So the sequence is:

1. Kratix Ready + state-store credential live (L3.1).
2. Build + push the adapter image (above).
3. **L3.3:** retire the Metacontroller CompositeController + its Tenant CRD
   ownership, then apply this Promise (via a `kratix-promises` ArgoCD app). Kratix
   becomes the sole Tenant driver; its reconciliation interval replaces the 300s
   Metacontroller resync for drift.
4. Point the onboarding workflow's GitOps commit at Kratix `Tenant` resources
   (unchanged CRD, so the committed manifests still apply).
