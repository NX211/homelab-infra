// Island reconciler interface — ported verbatim from atlas
// (packages/core/src/provisioning/types.ts, ADR-0014/0015) so the atlas island
// handlers drop in unchanged. The store is a structural subset of the Prisma
// client (ADR-0015); any real PrismaClient is assignable.
import type { PrismaClient } from '@prisma/client';

export const ISLAND_ORDER = ['spine', 'dns', 'email', 'app', 'staging'] as const;
export type IslandSystem = (typeof ISLAND_ORDER)[number];

export type ProvisioningTrigger = 'API' | 'SCHEDULE' | 'TEARDOWN';

// Only the delegates the islands touch (ADR-0015 structural-subset store).
export type ProvisioningStore = Pick<
  PrismaClient,
  'tenantSpec' | 'provisioning' | 'provisioningRun' | 'provisioningStepAttempt'
>;

// The desired state (subset of the atlas TenantSpec — enough for spine+dns).
export interface TenantSpec {
  email: string;
  userId?: string | null;
  invoiceNinjaId?: string | null;
  domain?: string | null;
  provisionEmail?: boolean;
  appName?: string | null;
  githubRepo?: string | null;
  stagingBaseUrl?: string | null;
  decommissioned?: boolean;
}

export interface Logger {
  info(msg: string, meta?: unknown): void;
  error(msg: string, meta?: unknown): void;
}

export interface IslandContext {
  readonly spec: TenantSpec;
  readonly provisioning: unknown | null;
  readonly trigger: ProvisioningTrigger;
  readonly store: ProvisioningStore;
  readonly logger: Logger;
}

export interface IslandOutcome {
  readonly status: 'OK' | 'SKIPPED';
  readonly detail?: string;
}

export interface IslandReconciler {
  readonly system: IslandSystem;
  desired(spec: TenantSpec, trigger: ProvisioningTrigger): boolean;
  reconcile(ctx: IslandContext): Promise<IslandOutcome>;
}
