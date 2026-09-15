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

## Deploy — LIVE since L3.3 (2026-07-28)

The Metacontroller CompositeController is retired; this Promise, applied by the
`kratix-promises` ArgoCD app, is the **sole** Tenant driver. Drift coverage
comes from `kratix/config/drift-reconcile.yaml` — a 15-minute CronJob that
labels every Tenant for manual reconciliation, replacing Metacontroller's 300s
resync (that is why `kratix-managed-hosting-<tenant>-reconcile-*` Jobs fire
continuously in steady state). The onboarding workflow's committed `Tenant`
CRs apply unchanged (same CRD) and flow through Kratix.

**Schema duplication warning:** `spec.api` embeds a copy of
`provisioning/tenant-crd.yaml`. Any schema change must land in BOTH files,
kept semantically identical, or the two appliers fight (PR #1064 fixed the
last divergence).
