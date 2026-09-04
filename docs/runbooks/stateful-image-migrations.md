# Runbook: stateful image migrations

Covers the three image updates that are **not** a plain tag bump, because they
change an on-disk data format, a volume layout, or a container entrypoint.
Everything else in the update pass is a pure version bump and needs no runbook.

| Migration | Data risk | Needs a window? |
|---|---|---|
| Karakeep Chrome → `karakeep-chrome` | none | no |
| Tracearr `1.5.0` → `2.2.3` | schema migration, automatic | short |
| Paperless PostgreSQL `17` → `18` | **dump/restore required** | yes |

> [!IMPORTANT]
> `paperless`, `tracearr` and `karakeeper` all run with ArgoCD
> `automated: {prune: true, selfHeal: true}`. Merging to `main` rolls them
> within a sync cycle. For the Paperless migration you **must** take the dump
> *before* the merge, or pause the app first — see below.

---

## 1. Karakeep Chrome image

No data migration. Karakeep now ships its own tested Chrome image; the previous
`gcr.io/zenika-hub/alpine-chrome` is unmaintained, and its GCP project has
billing disabled, so even Renovate could not look it up
(`Failed to look up docker package gcr.io/zenika-hub/alpine-chrome: no-result`).

The chart also had to drop three arguments. The new entrypoint starts Chrome on
an internal port and forwards container port `9222`; passing
`--remote-debugging-address` / `--remote-debugging-port` fights that forwarding
and breaks the browser. The entrypoint supplies `--no-sandbox` itself.

```diff
- image: gcr.io/zenika-hub/alpine-chrome:124
+ image: ghcr.io/karakeep-app/karakeep-chrome:151.0.7922.47-r1
  args:
-   - --no-sandbox
    - --disable-gpu
    - --disable-dev-shm-usage
-   - --remote-debugging-address=0.0.0.0
-   - --remote-debugging-port=9222
    - --hide-scrollbars
+   - --disable-blink-features=AutomationControlled
+   - --window-size=1440,900
```

Verify after sync:

```bash
kubectl -n default rollout status deploy/karakeeper-chrome
kubectl -n default logs deploy/karakeeper-chrome --tail=20
# DevTools endpoint should answer from inside the cluster:
kubectl -n default exec deploy/karakeeper -- wget -qO- http://karakeeper-chrome:9222/json/version
```

Then re-crawl one bookmark in the Karakeep UI and confirm a screenshot/preview
is produced.

---

## 2. Tracearr 1.5.0 → 2.2.3

Tracearr 2.x migrates the database heavily on first boot. Upstream reports the
migration is automatic, shows progress instead of looking hung, and a failed
migration cannot boot-loop the server. A 1.5 backup restores cleanly onto 2.x,
which is the escape hatch.

No configuration change is required — the environment variables are unchanged
between 1.5.0 and 2.2.3.

**Before merging**, take a backup:

```bash
# Preferred: Tracearr's own backup (writes to the backups PVC)
#   Tracearr UI -> Settings -> Backups -> Create backup

# Or dump the bundled TimescaleDB directly:
kubectl -n default exec sts/tracearr-timescale -- \
  env PGPASSWORD="$(kubectl -n default get secret tracearr-secrets \
      -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" \
  pg_dump -U tracearr -d tracearr -Fc > tracearr-1.5.0.dump
ls -lh tracearr-1.5.0.dump
```

After merge, watch the migration:

```bash
kubectl -n default rollout status deploy/tracearr --timeout=15m
kubectl -n default logs -f deploy/tracearr
```

Expect stats to shift after the upgrade: 2.x counts every file rather than a
title's first file, and merges duplicate identities, so totals move as the old
double-counting goes away. That is the fix, not a regression.

**Rollback:** set the tag back to `1.5.0`, then restore the dump.

---

## 3. Paperless PostgreSQL 17 → 18

This is the one that needs care, for two independent reasons.

**Reason 1 — data format.** PostgreSQL will not start a major version on the
previous major's data directory. A dump/restore (or `pg_upgrade`) is mandatory.
Paperless documents using the exporter/importer, or the standard PostgreSQL
upgrade path.

**Reason 2 — the volume moved.** The official `postgres:18` image relocated
`PGDATA` and its declared volume:

| | `postgres:17` | `postgres:18` |
|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data` | `/var/lib/postgresql/18/docker` |
| `VOLUME` | `/var/lib/postgresql/data` | `/var/lib/postgresql` |

The chart previously mounted the PVC at `/var/lib/postgresql/data`. Left alone,
`postgres:18` would write its cluster to `/var/lib/postgresql/18/docker` — a
path **inside the container's ephemeral layer, not on the PVC** — and the
database would silently vanish on the next restart. This PR moves the mount to
`/var/lib/postgresql`, matching upstream paperless-ngx compose.

### Procedure

Namespace `default`. Deployments `paperless`, `paperless-ai`, `paperlessdb`;
PVC `paperless-postgres-data`.

**Step 1 — stop ArgoCD from syncing mid-migration.**

```bash
kubectl -n argocd patch application paperless --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

**Step 2 — stop the writers (Postgres stays up).**

```bash
kubectl -n default scale deploy/paperless deploy/paperless-ai --replicas=0
kubectl -n default rollout status deploy/paperless --timeout=5m
```

**Step 3 — dump from PostgreSQL 17.**

```bash
kubectl -n default exec deploy/paperlessdb -- sh -c \
  'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > paperless-pg17.sql

# Sanity-check before going any further:
ls -lh paperless-pg17.sql
tail -3 paperless-pg17.sql          # should end with "PostgreSQL database dump complete"
grep -c "CREATE TABLE" paperless-pg17.sql
```

Do not continue unless the dump looks complete. Copy it somewhere off-cluster.

**Step 4 — stop Postgres and discard the old volume.**

```bash
kubectl -n default scale deploy/paperlessdb --replicas=0
kubectl -n default delete pvc paperless-postgres-data
```

The `local-path` provisioner reclaims on delete, so this removes the PG17 data
directory. That is intended — the dump from step 3 is now the only copy.

**Step 5 — merge the PR, then sync.**

```bash
kubectl -n argocd patch application paperless --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
argocd app sync paperless        # or wait for the auto-sync cycle
kubectl -n default rollout status deploy/paperlessdb --timeout=10m
```

A fresh PVC is provisioned and `postgres:18` runs `initdb`, creating the
database and role from `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD`
(supplied by the `paperless-db-secrets` ExternalSecret). Confirm:

```bash
kubectl -n default exec deploy/paperlessdb -- \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'select version();'
```

**Step 6 — restore.**

```bash
kubectl -n default exec -i deploy/paperlessdb -- sh -c \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < paperless-pg17.sql
```

**Step 7 — bring Paperless back.**

```bash
kubectl -n default scale deploy/paperless --replicas=1
kubectl -n default scale deploy/paperless-ai --replicas=1
kubectl -n default rollout status deploy/paperless --timeout=10m
```

Verify in the UI that the document count matches what it was before, and that
search returns results. The documents themselves live on the `paperless-media`
PVC and are never touched by this procedure — only the metadata database is
rebuilt.

**Rollback:** revert the PR (restores `postgres:17` and the
`/var/lib/postgresql/data` mount), delete the PVC again, sync, and restore the
same `paperless-pg17.sql` dump into the recreated PG17 instance.

---

## Pins deliberately held back

These have newer tags available. They are **not** stale — each is pinned to
match what upstream ships, and moving ahead of upstream is the risk.

| Pin | Held at | Why |
|---|---|---|
| `ghcr.io/immich-app/postgres` | `16-vectorchord0.4.3-pgvectors0.2.0` | Immich v3.1.0's own compose pins the same vectorchord/pgvectors pair. The newer tag also carries `pgvectors0.3.0`; a vector-extension mismatch can break search indexes. Move when Immich moves. |
| `timescale/timescaledb-ha` | `pg18.1-ts2.25.0` (digest-pinned) | Tracearr's own Helm chart pins this exact tag **and** digest. Track Tracearr, not TimescaleDB releases. |
| `getmeili/meilisearch` | `v1.43.1` | Karakeep's compose pins `v1.41.0`; we are already ahead. Meilisearch cannot be downgraded, and a newer binary refuses to open an older `data.ms` without a one-time `--upgrade-db` launch. |
| `postgres:16-alpine` (db-init Jobs) | `16-alpine` | These are `psql` clients for the gitea/matrix PreSync Jobs. They intentionally match the CloudNativePG server major (PG 16), not the newest client. |

Renovate is configured to leave these alone — see the `packageRules` in
`renovate.json`.
