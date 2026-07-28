# managed-hosting Promise (L3.2)

Kratix's platform API for provisioning a client tenant. **Wraps** the Restate
reconcile rather than replacing it (ADR-0018 amendment): `spec.api` is the same
`Tenant` CRD the reconcile loop already uses, and the resource pipeline is a thin
adapter that POSTs the Restate `provisionTenant` reconcile. Kratix owns the API +
scheduling + composition; Restate stays the durable executor; the islands don't
move.

## The pipeline

No custom image to build — the container uses the public `mikefarah/yq` image
(yq + busybox `wget`) and runs the adapter inline: read the Tenant object at
`/kratix/input/object.yaml`, extract `.spec`, and POST it to
`provisionTenant/<name>/reconcile/send` in-cluster. Kratix re-runs it on each
reconciliation, giving the level-triggered drift re-reconcile Metacontroller
provided.

## Deploy — during L3.3, NOT now

Installing this Promise creates `tenants.platform.coreyalan.com` — the **same**
CRD the Metacontroller CompositeController already reconciles. Deploying it now
would **double-drive** every Tenant. Sequence:

1. Kratix Ready + state-store credential live (L3.1).
2. **L3.3:** retire the Metacontroller CompositeController + its Tenant CRD
   ownership, then apply this Promise (via a `kratix-promises` ArgoCD app). Kratix
   becomes the sole Tenant driver; its reconciliation interval replaces the 300s
   Metacontroller resync for drift.
3. The onboarding workflow's committed `Tenant` CRs still apply unchanged (same
   CRD) — they just flow through Kratix now.
