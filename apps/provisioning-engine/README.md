# provisioning-engine (ADR-0019 Phase 2a)

The **Restate durable-execution engine** for the tenant provisioning saga — L1 of
the control-plane stack ([ADR-0018](../../../framework/decisions/0018-control-plane-target-stack.md)).
It replaces the atlas `engine.ts` + Pub/Sub worker; the island handlers are ported
unchanged (ADR-0015 injected store).

## What's here (Phase 2a)
- `src/workflow.ts` — the `provisionTenant` Restate workflow, keyed by the opaque
  `provisioningId`. `run` drives each island via `ctx.run()` (durable, retried);
  the `status` shared handler exposes phase + per-island conditions.
- `src/islands/spine.ts` — the **spine** island, ported verbatim from atlas (pure
  Prisma, no SaaS — so Phase 2a needs **no NPM_TOKEN**).
- `src/types.ts`, `prisma/schema.prisma`, `Dockerfile`.

This is a **scaffold** — the code is complete, but unlike the Phase-1 manifests it
can't be dry-run-verified; it needs building + a DB + Restate registration.

## Activation runbook
1. **Control DB** — apply a CloudNativePG cluster (the homelab has the operator) and
   set `DATABASE_URL`. Then `DATABASE_URL=… npx prisma migrate deploy`.
2. **Build the image** — via the Tekton node/linux channel ([ADR-0017](../../../framework/decisions/0017-tekton-build-platform.md))
   or `docker build`, push to the homelab registry. (Add a `.tekton/` PipelineRun
   referencing the appropriate channel — `nextjs-build` is Next.js-shaped, so a
   generic node/linux channel + Dockerfile build task is the better fit.)
3. **Deploy** the engine (Deployment/Service on :9080) with `DATABASE_URL` from ESO.
4. **Register with Restate** — `restate deployments register http://provisioning-engine.provisioning.svc:9080`
   (or the Restate admin API via a one-shot Job).
5. **Point the webhook at Restate** — upgrade `provisioning/webhook.yaml` so the sync
   hook submits `POST <restate-ingress>/provisionTenant/<provisioningId>/run` (fire-
   and-forget) and reads `.../provisionTenant/<provisioningId>/status`, mapping that
   to `Tenant.status`.
6. **Test** — `kubectl -n provisioning apply` a Tenant → spine runs through Restate →
   `Provisioning` row created → `phase: Live`.

## Design decision to lock in Phase 2b
`run` executes **once per key** — correct for first provision, but the 300s **drift
resync** needs re-reconcile. Options: (a) a Restate **Virtual Object** with a
repeatable `reconcile` handler (recommended), or (b) a fresh workflow per run keyed
by `runId`. Decide when porting `dns`.

## Phase 2b
Add the **dns** island (`@corey-alan-consulting/cloudflare` — needs `NPM_TOKEN` for
the restricted scope + Cloudflare creds via ESO) and its `Domain` model.
