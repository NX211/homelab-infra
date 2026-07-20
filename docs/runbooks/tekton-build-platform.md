# Runbook: Tekton build platform (Phase 0 — foundation)

Stands up the Tekton build platform on the homelab cluster: the operator (Pipeline
+ Triggers + Results + Chains, **no Dashboard**), Pipelines-as-Code, the
manual-approval-gate, and the gVisor/Kata sandbox RuntimeClasses. Replaces the
never-live ARC stack ([ADR-0016](../../../framework/decisions/0016-self-hosted-arc-runners.md),
superseded). Design: [ADR-0017](../../../framework/decisions/0017-tekton-build-platform.md) +
`docs/design/tekton-build-platform.md`. Per-project builds land in Phase 1.

## Components

| Where | What |
|---|---|
| `argocd/applications/tekton-operator.yaml` | Tekton Operator + CRDs (wave -2) |
| `argocd/applications/tekton-config.yaml` | `TektonConfig` (profile basic, no Dashboard) (wave -1) |
| `argocd/applications/tekton-pac.yaml` | Pipelines-as-Code + ESO GitHub App secret (wave -1) |
| `argocd/applications/tekton-manual-approval-gate.yaml` | `ApprovalTask` operator — interim gate (wave -1) |
| `argocd/applications/tekton-runtimeclasses.yaml` | gvisor + kata RuntimeClasses (wave -2) |
| `tekton/**` | the manifests/kustomize the apps point at |

## One-time setup (in order)

1. **Node runtime prerequisites (NOT GitOps).** The untrusted tier runs under
   gVisor; k3s does not auto-detect runsc, so each node that schedules build pods
   needs the runsc binary + a containerd runtime entry. The tracked installer +
   template live in **`node-bootstrap/gvisor/`** (which nodes, exact steps,
   verification, and the optional full-GitOps DaemonSet/SUC path). A rebuilt node
   silently loses the sandbox until re-run. Kata (for the Android/NDK untrusted
   channel) is added later via `kata-deploy`.
2. **Pin/verify release versions** before first sync:
   - operator `tekton/operator/kustomization.yaml` (v0.78.0 LTS)
   - PaC `tekton/pac/kustomization.yaml` (`release.k8s.yaml`, v0.41.1)
   - manual-approval-gate `tekton/manual-approval-gate/kustomization.yaml`
     (**confirm the tag is current** — it was pinned from memory, not verified)
3. **PaC GitHub App** (new, replaces the retired ARC app). Create a GitHub App on
   the org (installed on `Corey-Alan-Consulting/capturly.app`), private ("only on
   this account"), webhook **Active**:
   - Repository perms: **Checks R/W · Contents R/W · Issues R/W · Metadata R ·
     Pull requests R/W**
   - Organization perms: **Members R · Plan R**
   - Events: **Check run · Check suite · Commit comment · Issue comment ·
     Pull request** (add **Push** only for push-triggered runs)
   - **Webhook URL** = `https://tekton-pac.coreyalan.com` (the PaC controller
     IngressRoute; the record is code-managed in platform-infra Cloudflare).
   - **Callback URL / Setup URL** = leave blank; **Request user authorization
     (OAuth)** = unchecked. PaC uses the installation token, not user OAuth.
   - **Webhook secret** = the value of `TEKTON_PAC_WEBHOOK_SECRET` in the Build
     Platform Bitwarden project (`bws secret get
     640f7095-4f6a-44b1-8ed1-b48d011e811f`) — already created + wired into ESO.
   Then generate a private key (.pem) and note the App ID + Installation ID.
4. **Bitwarden (Build Platform project)** — the webhook secret is already created
   and referenced. Create the remaining two and paste their UUIDs into
   `tekton/pac/externalsecret-pac-github-app.yaml`:
   - `PAC_APP_ID` ← GitHub App ID
   - `PAC_APP_PRIVATE_KEY` ← the private key (PEM)
   Also grant the ESO machine account (`bitwarden-credentials`) read access to the
   Build Platform project, and add `VERDACCIO_NPM_TOKEN` there for the proxy.
5. **Merge the branch.** ArgoCD's app-of-apps (`root-apps`) picks up the new
   Application CRs. Sync order is wave-driven: operator/runtimeclasses (-2) →
   config/pac/mag (-1).

## Validate (Phase 0)

1. Operator healthy: `kubectl -n tekton-operator get pods`.
2. TektonConfig ready: `kubectl get tektonconfig config -o jsonpath='{.status.conditions}'`.
3. Components up, **no dashboard**: `kubectl -n tekton-pipelines get pods` shows
   pipelines/triggers/results/chains controllers; `kubectl get deploy -A | grep -i
   dashboard` returns nothing.
4. PaC controller up + secret materialized: `kubectl -n pipelines-as-code get pods`;
   `kubectl -n pipelines-as-code get secret pipelines-as-code-secret`.
5. Sandbox ready: `kubectl get runtimeclass gvisor kata`; schedule a throwaway pod
   with `runtimeClassName: gvisor` (and `kata`) and confirm it runs.
6. Approval-gate controller up: `kubectl get pods -A | grep manual-approval`.
7. Smoke: a hello-world `PipelineRun` completes and (once Chains keyless is wired in
   Phase 1) produces an attestation.

## Gates carried into Phase 1

- **Fail-closed approval test (blocking, RISK-BUILD-001).** Scale the
  manual-approval-gate controller to zero (or issue a reject) and confirm a release
  pipeline **blocks** rather than proceeds — the evidence that converts the
  Tech-Preview acceptance into a verified control. If it does not fail closed,
  switch to the hybrid GitHub-Environment gate.
- **Chains keyless signing** (Fulcio/Rekor + SLSA provenance) is configured with the
  trusted Android pipeline — see design §5 and `/docs/chains/sigstore/#keyless-signing-mode`.

## Notes

- No web UI: the Dashboard is intentionally not installed; use `tkn`/`opc` + Loki.
  Release approvals are actioned via CLI (design §10).
- If a first sync is blocked by the `business` AppProject on a cluster kind an
  upstream release bundles, add that kind to
  `business-plane/appproject.yaml` `clusterResourceWhitelist` (Argo names it).
