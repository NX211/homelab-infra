# ar-token-refresher — keyless Artifact Registry image pull

Replaces the per-app `gcr-pull-secret-*` credentials (currently the
`homelab-staging-reader` GCP **SA keys** synced from Bitwarden via ESO) with
short-lived tokens minted through **Workload Identity Federation** — no key
material on the cluster or in Bitwarden.

## How it works

1. The CronJob pod gets a **projected k3s ServiceAccount token** whose audience
   is the GCP WIF provider.
2. It exchanges that token at Google STS for a federated token, then impersonates
   the keyless `homelab-ar-puller@platform-infra-prod` SA (AR reader on all five
   projects) for a ~60-min Artifact Registry access token.
3. It writes that token into the five `gcr-pull-secret-*` dockerconfigjson
   secrets in `staging`. One token covers every `us-central1-docker.pkg.dev`
   repo. Runs every 30 min.

GCP side (pool, provider, puller SA, bindings):
`platform-infra/terraform/environments/prod/homelab-wif.tf`. The subject
`system:serviceaccount:ar-pull-system:ar-token-refresher` must match on both
sides.

## ⚠️ Not yet cut over — this needs live verification first

This ran no live test. Before deleting the SA keys or re-enforcing the org
policy, verify on the cluster:

1. **Apply the GCP side** (merge the platform-infra PR so the pool/provider/SA
   exist).
2. **Deploy this** (ArgoCD syncs it) and trigger the first run:
   ```
   kubectl -n ar-pull-system create job --from=cronjob/ar-token-refresher bootstrap
   kubectl -n ar-pull-system logs job/bootstrap
   ```
   Expect `refreshed staging: gcr-pull-secret-...`. The most likely failure is
   the **WIF audience** — if STS rejects the token, confirm the projected-token
   audience, the script's `AUDIENCE`, and the provider's expected audience all
   match, and that `attribute_condition` on the provider matches the subject.
3. **Confirm a keyless pull:** roll one staging deployment and check the image
   pulls using the refreshed secret (e.g. `kubectl -n staging rollout restart
   deploy/<app>` and watch events).

## Cutover (only after the above passes)

1. Point the staging apps' `gcrPullSecret` at these refresher-managed secrets
   (they already use the same names — just stop ESO from also writing them, so
   the two don't fight; remove the `gcrPullSecret.bitwardenKey` wiring per app).
2. Delete the `homelab-staging-reader` SA keys in each project.
3. Re-enforce the ban: `gcloud resource-manager org-policies delete
   iam.disableServiceAccountKeyCreation --project=<jl-shaw-486618|dispatchr-social>`.

## Rollback

The old ESO-synced pull secrets still work until step 1 of cutover. If the
refresher misbehaves, re-enable ESO for the pull secret and the keys keep
working (they aren't deleted until cutover step 2).

## JWKS rotation

The provider trusts the cluster's SA signing key via an inline JWKS
(`k3s-jwks.json` in platform-infra). If k3s rotates its signing key, refresh
that file or federation stops. Stable across normal ops on the single-node
cluster.
