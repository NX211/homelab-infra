# Runbook: Capturly Android self-hosted ARC runner

Ephemeral, repo-scoped GitHub Actions runners on homelab k8s that build + sign the
Capturly **Android release AAB**. Only the trusted `release-android` workflow
(`runs-on: homelab-android`) uses them; PR/CI Android builds stay GitHub-hosted.
iOS is **not** covered (needs macOS hardware; stays cloud). Rationale:
`framework/decisions/0016-self-hosted-arc-runners.md`.

## Components

| Where | What |
|---|---|
| `argocd/applications/arc-controller.yaml` | ARC controller + CRDs (ns `arc-systems`) |
| `argocd/applications/arc-runners-android.yaml` | `homelab-android` runner scale set (ns `arc-runners`) |
| `argocd/applications/arc-runners-android-config.yaml` | directory app for the extras below |
| `arc-runners-android/externalsecret-github-app.yaml` | GitHub App creds from Bitwarden → `arc-github-app` secret |
| `arc-runners-android/networkpolicy.yaml` | egress lock-down (no lateral movement) |
| `arc-runners-android/build-cache-pvc.yaml` | persistent Gradle + ccache store |
| `apps/capturly-android-runner/Dockerfile` | runner image (`ghcr.io/nx211/capturly-android-runner`) |
| `.github/workflows/build-capturly-android-runner.yml` | builds/pushes the image |

## One-time setup (in order)

1. **GitHub App** (repo-scoped). Create an App on `Corey-Alan-Consulting/capturly.app`
   with permissions **Actions: R/W**, **Administration: R/W**, **Metadata: R**.
   Install it on that repo only. Note the App ID + installation ID; generate a
   private key.
2. **Bitwarden SM** (project Capturly) — create three secrets:
   - `capturly-arc-github-app-id`
   - `capturly-arc-github-app-installation-id`
   - `capturly-arc-github-app-private-key` (the PEM)
3. **Register the OCI Helm repo** with ArgoCD (public, no creds):
   ```
   argocd repo add ghcr.io/actions/actions-runner-controller-charts --type helm --enable-oci
   ```
4. **Storage class** — confirm `build-cache-pvc.yaml` binds on the cluster default
   RWO class; set `storageClassName` explicitly if needed.
5. **Build the runner image** — merge to `main` (or run the workflow) so
   `ghcr.io/nx211/capturly-android-runner:0.1.0` exists before the scale set syncs.
6. **GitHub Environment** `android-release` on capturly.app — add a required
   reviewer and restrict deployment to the `@capturly/mobile@*` tag. This is the
   SOC 2 change-management gate.
7. **Merge the ArgoCD apps.** Sync order is handled by waves: controller (`-2`) →
   config/ESO (`-1`) → runner scale set (`0`).

## Validate (before trusting a real release)

1. Controller healthy: `kubectl -n arc-systems get pods`.
2. Secret materialized: `kubectl -n arc-runners get secret arc-github-app`.
3. Runner registers: GitHub → capturly.app → Settings → Actions → Runners →
   **homelab-android** listener online; `kubectl -n arc-runners get pods`.
4. **Dry run**: `release-android` via `workflow_dispatch` with `runner=homelab-android`.
   Watch it pull the image, hit the build cache, sign, and produce the AAB +
   attestation. (Approve the environment gate when prompted.) To avoid a real Play
   push during validation, temporarily skip the publish step or point it at the
   internal track.
5. Only then cut a real tag.

## Secret rotation

- **GitHub App key** — rotate in the App settings, update
  `capturly-arc-github-app-private-key` in Bitwarden SM. ESO re-syncs within
  `refreshInterval` (1h) or force: `kubectl -n arc-runners annotate externalsecret
  arc-github-app force-sync=$(date +%s) --overwrite`.
- **Android signing keystore** — lives in Bitwarden SM (project Capturly), fetched
  per-run by the workflow; rotate there. Never stored on the runner.
- **BWS access token** — the ESO ClusterSecretStore credential; rotate per the
  platform-infra credential-rotation runbook.

## SOC 2 control notes

- **Trusted execution / separation:** only tag/dispatch events reach this runner;
  no fork PR code. Enforced by `release-android.yml` triggers + the `android-release`
  environment.
- **Least privilege:** repo-scoped App, `minRunners: 0`, ephemeral pods, egress
  NetworkPolicy (blocks RFC1918 → no lateral movement).
- **Provenance:** the workflow emits keyless SLSA build provenance for the AAB.
- **Logging:** runner pod logs are scraped by promtail → Loki; retain per policy.
- **Availability:** releases depend on the homelab. Break-glass = re-run
  `release-android` with `runner=ubuntu-latest`.
- **Audit scope:** self-hosting brings this cluster's physical/network/patching
  controls in-scope. Keep the rack access-controlled and the nodes patched.

## Reusing this for another app

The ARC **controller is cluster-shared** — a second app does not redeploy it. Give
each app its **own** repo-scoped, scale-to-zero scale set on that controller
(per-app isolation beats one shared org runner). To onboard app `foo`:

1. Copy `apps/capturly-android-runner/` → build `foo`'s toolchain image (a Node/
   container app needs a **dind-capable** image; iOS needs a Mac — not here).
2. Copy `argocd/applications/arc-runners-android.yaml` + the `arc-runners-android/`
   directory → new names/namespace, set `runnerScaleSetName: foo-staging`,
   `githubConfigUrl` to `foo`'s repo, and the `capturly-arc-github-app-*` Bitwarden
   keys to `foo`'s App.
3. In `foo`'s CI: for a **container** build, call `deploy-workflows`'
   `build-push-generic` with `runner: foo-staging`; for a bespoke build, set
   `runs-on: foo-staging` directly. GitHub-hosted (`ubuntu-latest`) stays the
   default and the break-glass fallback.

## FQDN egress (optional hardening)

Plain k8s NetworkPolicy can't allowlist by hostname. If the cluster CNI is Cilium,
replace `networkpolicy.yaml` with a `CiliumNetworkPolicy` using `toFQDNs` for
`github.com`, `*.actions.githubusercontent.com`, `*.googleapis.com`,
`*.bitwarden.com`, `registry.npmjs.org`, `dl.google.com`, and the Gradle/Maven
hosts.
