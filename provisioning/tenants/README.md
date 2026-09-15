# tenants/

Each `<name>.yaml` here is a `Tenant` CR. The `tenants` ArgoCD app syncs this
directory into the cluster, where the Kratix managed-hosting Promise + the
Restate reconcile enact it. Two kinds of file live here:

- **Workflow-generated** — created by the onboarding workflow
  (`provisionOnboarding` in provisioning-engine) and committed via a
  short-lived GitHub App token. Do not edit by hand: re-onboarding a client
  overwrites the file.
- **Island-managed (hand-authored)** — tenants whose app predates the platform
  (`jlshaw.yaml`, `coreyalan.yaml`): hand-written CRs carrying an `islands:`
  allowlist. These ARE edited by hand via PR — credential rotation in
  particular (below).

To **decommission** a client, set `spec.decommissioned: true` in its CR (which
runs the teardown/compensation saga) and only then remove the file. Deleting the
file alone does nothing: the `tenants` app is `prune:false`, so ArgoCD leaves the
live CR in place.

## Rotating a showcase credential

Plaintext never enters the control plane: the CR carries only credential ids +
sha256 hashes, and the declared set is authoritative — removing an entry
revokes it in the showcase service on the next reconcile.

1. **Mint**: `KEY=$(openssl rand -hex 32)` is the new API key;
   `printf '%s' "$KEY" | shasum -a 256` is its hash.
2. **Add** a second entry to `spec.showcaseCredentials` in the tenant's CR via
   PR (`- id: cred-<tenant>-<n>` / `hash: <sha256>`). Both keys accept after
   the next reconcile (the drift cron fires within 15 minutes).
3. **Cut over** the tenant app: update the key at its secret source and roll
   out (for jlshaw: `SHOWCASE_API_KEY` in BWS, synced via platform-infra
   `secrets/jlshaw.json` -> GSM -> ESO), then verify the app works.
4. **Remove** the old entry from the CR via PR — the engine revokes it.

The legacy single pair (`showcaseCredentialId`/`showcaseCredentialHash`) still
projects and merges with the list; prefer the list for anything new.
