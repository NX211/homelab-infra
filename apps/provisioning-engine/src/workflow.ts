// provisionTenant — the durable reconcile saga (ADR-0019, L1).
//
// A Restate workflow keyed by the opaque provisioningId. `run` drives each
// island via ctx.run() (durable, idempotent, retried-with-backoff by Restate),
// and publishes per-island state that the `status` shared handler exposes — the
// webhook polls that to fill Tenant.status. Restate replaces the atlas
// engine.ts + Pub/Sub worker + StepAttempt log; the island handlers are unchanged.
//
// NOTE (design decision to lock in Phase 2b): `run` executes once per key, which
// is right for the first provision. For *drift re-reconcile* (the 300s resync),
// switch this to a Restate Virtual Object with a repeatable `reconcile` handler,
// or invoke a fresh workflow per run keyed by runId. The stub webhook already
// tolerates re-submits, so this scaffold proves spine→Restate end-to-end.
import * as restate from '@restatedev/restate-sdk';
import { PrismaClient } from '@prisma/client';
import { ISLAND_ORDER, type IslandReconciler, type TenantSpec } from './types.js';
import { spineIsland } from './islands/spine.js';

const store = new PrismaClient();
const logger = {
  info: (msg: string, meta?: unknown) => console.log(JSON.stringify({ level: 'info', msg, meta })),
  error: (msg: string, meta?: unknown) => console.error(JSON.stringify({ level: 'error', msg, meta })),
};

// Registered islands. dns/email/app/staging land in later phases (dns = 2b).
const islands: IslandReconciler[] = [spineIsland];

interface Condition {
  island: string;
  status: 'Pending' | 'Running' | 'OK' | 'Skipped' | 'Failed';
  detail?: string;
  lastError?: string;
  lastTransitionTime: string;
}

export const provisionTenant = restate.workflow({
  name: 'provisionTenant',
  handlers: {
    run: async (ctx: restate.WorkflowContext, spec: TenantSpec) => {
      const trigger = spec.decommissioned ? 'TEARDOWN' : 'API';
      const conditions: Condition[] = [];
      const now = () => new Date().toISOString();
      const publish = async () => ctx.set('conditions', conditions);

      await ctx.set('phase', 'Provisioning');

      for (const system of ISLAND_ORDER) {
        const island = islands.find((i) => i.system === system);
        // Not ported yet — honest Pending, not a silent skip (atlas §engine).
        if (!island) {
          conditions.push({ island: system, status: 'Pending', detail: 'no reconciler yet', lastTransitionTime: now() });
          await publish();
          continue;
        }
        if (!island.desired(spec, trigger)) {
          conditions.push({ island: system, status: 'Skipped', lastTransitionTime: now() });
          await publish();
          continue;
        }
        try {
          // Durable step: journaled + retried with backoff by Restate. Islands
          // are idempotent, so replay/retry is safe.
          const outcome = await ctx.run(system, () =>
            island.reconcile({ spec, provisioning: null, trigger, store, logger }),
          );
          conditions.push({ island: system, status: outcome.status === 'OK' ? 'OK' : 'Skipped', detail: outcome.detail, lastTransitionTime: now() });
        } catch (err) {
          conditions.push({ island: system, status: 'Failed', lastError: String(err), lastTransitionTime: now() });
        }
        await publish();
      }

      const failed = conditions.some((c) => c.status === 'Failed');
      await ctx.set('phase', spec.decommissioned ? 'Decommissioned' : failed ? 'Failed' : 'Live');
      return { ok: !failed };
    },

    // Read-only handler the webhook polls (WorkflowSharedContext runs concurrently).
    status: restate.handlers.workflow.shared(async (ctx: restate.WorkflowSharedContext) => ({
      phase: (await ctx.get<string>('phase')) ?? 'Pending',
      conditions: (await ctx.get<Condition[]>('conditions')) ?? [],
    })),
  },
});
