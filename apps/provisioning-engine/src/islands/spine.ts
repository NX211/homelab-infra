// The spine island — ported verbatim from atlas
// (packages/core/src/provisioning/islands/spine.ts). Births/repairs the
// email-keyed Provisioning row (its id is the opaque provisioningId) and keeps
// the business soft references in sync. Always desired; safe to run twice —
// which is exactly what a Restate ctx.run() durable step needs.
import type { IslandReconciler } from '../types.js';

export const spineIsland: IslandReconciler = {
  system: 'spine',
  desired: () => true,
  reconcile: async ({ spec, store }) => {
    await store.provisioning.upsert({
      where: { email: spec.email },
      update: {
        userId: spec.userId ?? undefined,
        invoiceNinjaId: spec.invoiceNinjaId ?? undefined,
      },
      create: {
        email: spec.email,
        userId: spec.userId ?? null,
        invoiceNinjaId: spec.invoiceNinjaId ?? null,
        status: 'INITIATED',
      },
    });
    return { status: 'OK', detail: 'spine ensured' };
  },
};
