# Design: Tekton build platform (two-tier trusted/untrusted)

Implementation plan for [ADR-0017](../../../framework/decisions/0017-tekton-build-platform.md).
Supersedes the per-app ARC pattern ([ADR-0016](../../../framework/decisions/0016-self-hosted-arc-runners.md));
ARC runs in parallel until Phase 4.

**Locked decisions (2026-07-20):** full Pipelines-as-Code · per-SA OIDC (no Vault) ·
gVisor untrusted tier · full multi-project scope (`android`/`nextjs`/`linux` ×
`capturly`/`coreyalan`, both tiers).

---

## 1. Two axes, two tiers

The whole design separates two things ARC fused into one scale set:

| Axis | Varies by | Mechanism | Reused how |
|---|---|---|---|
| **Toolchain** | channel (android/nextjs/linux) | Tekton `Pipeline`/`Task` in a versioned catalog | referenced by every project via git resolver + params |
| **Identity / trust** | project × tier | per-namespace SA, WIF binding, secrets, netpol | generated per (project, channel, tier) from an inventory |

The **unit of isolation is the trust tier**, not the runner.

### Trust tiers

| | **Untrusted (PR/fork)** | **Trusted (release)** |
|---|---|---|
| Trigger | PaC `pull_request` (fork ⇒ `/ok-to-test` by a maintainer) | PaC protected-tag push |
| Code trust | arbitrary contributor code | maintainer-reviewed, merged |
| Runtime | **gVisor** default; **Kata** for native/NDK channels (android) | standard (trusted); gVisor optional defense-in-depth |
| Identity | zero-secret SA — no OIDC audience, no mounts | per-build SA → projected OIDC token → GCP WIF |
| Secrets | **none** | Android keystore leased via ESO into the signing TaskRun only |
| Egress | registries + git only; deny cloud-metadata, Bitwarden, k8s API, all RFC1918 | above + GCP/WIF + Play + Bitwarden; still deny lateral homelab |
| Cache | ephemeral or read-only warmed; **never written for a trusted read** | own writable cache PVC |
| Publish / sign | **never** | signs, publishes, emits provenance |
| Provenance | n/a (throwaway) | Tekton Chains → Cosign/Fulcio/Rekor; verify-on-admit |
| Gate | none needed (sandboxed, powerless) | in-cluster `ApprovalTask`, N approvers, author≠approver |
| Namespace | `{project}-builds-untrusted` | `{project}-builds-trusted` |
| Pod hardening | rootless, RO rootfs, seccomp RuntimeDefault, drop ALL caps, non-root uid, no-privesc | same hardening |

**Never blur the tiers.** The two hard invariants that keep untrusted execution on owned
compute defensible:
1. **No secret or cloud audience** is ever reachable from the untrusted namespace.
2. **No cache/artifact path** flows untrusted → trusted (cache-poisoning is the classic
   supply-chain hole). Separate PVCs; the trusted tier warms its own.

---

## 2. Data flow

```
                        GitHub (source of truth)
                              │  webhook (PaC GitHub App)
                              ▼
                     Tekton Pipelines-as-Code
             ┌────────────────┴─────────────────┐
   pull_request│                       tag push  │  (PaC policy: maintainers only)
              ▼                                   ▼
   ns: {project}-builds-untrusted        ns: {project}-builds-trusted
   ├ RuntimeClass: gvisor                 ├ per-build SA ─▶ projected OIDC token
   ├ SA: nobody (no audience)             │                └▶ GCP WIF (keyless)
   ├ egress: registries+git only          ├ ESO: keystore (signing TaskRun only)
   └ PipelineRun ─(git resolver)─┐        ├ ApprovalTask ── N approvers ──┐
                                 │        │                                │
        channel catalog  ◀───────┴────────┴─▶  channel catalog            ▼
        (homelab-infra, pinned by revision)    sign ▶ publish ▶ Chains provenance
                                                         │
                                                         ▼  Rekor (transparency)
                                            deploy admission verifies attestation
```

---

## 3. Platform components (ArgoCD, `business` AppProject)

| Component | Purpose | Notes |
|---|---|---|
| Tekton **Pipelines** | Task/Pipeline/*Run engine | pinned release yaml; `ServerSideApply` (large CRDs) |
| Tekton **Pipelines-as-Code** | GitHub-webhook trigger + ACL | needs a PaC **GitHub App** (org-level, installed on specific repos) |
| Tekton **Chains** | keyless SLSA provenance | Cosign keyless via Fulcio/Rekor ([ADR-0005](../../../framework/decisions/0005-zero-secret-ci-wif.md)) |
| Tekton **Results** | run/approval history for evidence | retention ≥ audit window (SOC 2 ~1yr); or ship to Loki |
| ~~Tekton Dashboard~~ | **not deployed** — no web UI (§10) | removes an unauthenticated web surface; CLI + Loki/Results instead |
| **manual-approval-gate** operator | `ApprovalTask` CRD for the release gate | approver list per pipeline; records who/when |
| **gVisor** RuntimeClass | untrusted sandbox | `runsc` installed on worker nodes via containerd — **node bootstrap, not GitOps** |
| **ESO** (existing) | keystore + PaC App key from Bitwarden | trusted namespaces only |
| **ApplicationSet** + `build-targets/` | generate per-project namespaces/RBAC/SA/netpol/PaC Repo/ESO | one inventory entry per (project, channel) |
| **AppProject `business`** (extend) | fence Tekton kinds + new namespaces + catalog repo | see [ADR-0013](../../../framework/decisions/0013-control-plane-business-plane-split.md) plane split |

---

## 4. Channel catalog — the reuse mechanism

Catalog lives in `homelab-infra/build-catalog/` (or `framework`), versioned:

```
build-catalog/
  tasks/     git-clone.yaml  gradle-build.yaml  pnpm-build.yaml  cosign-attest.yaml ...
  pipelines/ android-build.yaml  nextjs-build.yaml  linux-build.yaml
```

Each app repo carries a thin `.tekton/` that resolves the channel by **git resolver**,
pinned to a catalog revision, and passes params:

```yaml
# capturly/.tekton/android-release.yaml  (trusted)
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata: { generateName: android-release- }
spec:
  pipelineRef:
    resolver: git
    params:
      - { name: url,      value: https://github.com/NX211/homelab-infra.git }
      - { name: revision, value: build-catalog-v1 }     # pinned = reviewed change
      - { name: pathInRepo, value: build-catalog/pipelines/android-build.yaml }
  taskRunTemplate:
    serviceAccountName: capturly-android-trusted        # per-build OIDC identity
  params:
    - { name: gitRepo, value: capturly.app }
    - { name: tier,    value: trusted }
```

One `android-build.yaml`; every project consumes it by param. A channel change is a
catalog PR + a revision bump in the consuming repos — a reviewed, versioned event
(change-management friendly).

---

## 5. Identity / PKI (per-SA OIDC)

- One SA per (project, channel, tier). Trusted SAs are bound in a **GCP WIF pool** whose
  provider trusts the cluster's OIDC issuer with attribute conditions on `namespace`,
  `serviceaccount`, and `audience`. The pod's **projected token** (short TTL,
  audience-bound) is the per-build identity — keyless to GCP/Play, consistent with
  [ADR-0005](../../../framework/decisions/0005-zero-secret-ci-wif.md).
- Untrusted SAs have **no** WIF binding and **no** audience — structurally unable to mint
  a cloud token even if compromised.
- Residual static secrets (both Bitwarden SM, both unavoidable — no OIDC path):
  - **PaC GitHub App** private key (webhook/checks auth).
  - **Android signing keystore** (leased into the signing TaskRun, discarded with pod).
- **Documented extensions** (not built): Vault k8s-auth + PKI engine, or SPIFFE/SPIRE
  attested SVIDs — adopt only if ISO 27001 requires formal workload attestation.

---

## 6. Change management gate (SOC 2 core)

Full PaC drops the GitHub Environment reviewer, so the control is rebuilt as four
reinforcing pieces:

1. **PaC trigger policy** — only org members / a named team can start a release Pipeline;
   fork PRs need `/ok-to-test`.
2. **Approval gate** — the release Pipeline blocks before sign/publish until N named
   approvers approve (separation of duties: the tag author cannot self-approve). The
   `ApprovalTask` component (`approvers`, `numberOfApprovalsRequired`; a reject fails the
   run) behaves exactly as needed, but is Red Hat "Technology Preview" maturity in the
   `openshift-pipelines/manual-approval-gate` operator — not GA core Tekton.
   **Decision (2026-07-20): accept it as the interim gate**, on the basis that it fails
   **closed** (a defect blocks releases, never ships unapproved code) and is backed by the
   compensating controls in this section. The **hybrid gate** (trusted-release approval on
   GitHub's Environment reviewer, ADR-0016) is the documented fallback and expected
   audit-time posture. Acceptance is contingent on a Phase-1 fail-closed test + pre-audit
   reassessment, tracked in
   [RISK-BUILD-001](../../../framework/compliance/risks/RISK-BUILD-001-approval-gate-maturity.md).
3. **Evidence retention** — approval events + PipelineRun records to Tekton Results/Loki,
   retained ≥ the audit window.
4. **Tamper-evidence** — Chains provenance anchored in Rekor (append-only); deploy
   admission (`policy-controller`/Kyverno) verifies the attestation, so an unapproved or
   unsigned artifact cannot be promoted ([ADR-0004](../../../framework/decisions/0004-digest-pinned-promotion.md)).

Honest cost: this is a control GitHub gave us for free under ADR-0016. Owning it is the
price of full PaC — call it out to the auditor, don't hide it.

---

## 7. Phased rollout

| Phase | Goal | Exit criteria |
|---|---|---|
| **0 — Foundation** | **Remove the never-live ARC scaffolding (§12);** install Tekton Pipelines + PaC + Chains + Results; gVisor RuntimeClass on nodes; repurpose `business` AppProject; register PaC GitHub App | ARC apps pruned from ArgoCD; a hello-world PipelineRun signs + lands in Rekor; gVisor `RuntimeClass` schedulable |
| **1 — Trusted Android** | port `release-android` to `.tekton/` + `android-build` catalog pipeline; per-SA WIF; keystore ESO; approval gate (interim `ApprovalTask` + fail-closed test, RISK-BUILD-001); Chains provenance | a real tag builds+signs+publishes via Tekton with a verified attestation and a recorded approval |
| **2 — Untrusted tier** | `nextjs` PR builds: PaC `pull_request` → gVisor, zero-secret, egress-locked | a fork PR compiles+tests in the sandbox; proves it cannot reach secrets/metadata/RFC1918 |
| **3 — Catalog + multi-project** | git-resolver catalog for all channels; `ApplicationSet` over `build-targets`; onboard `coreyalan` | adding a (project, channel) is a single inventory PR that reconciles clean |

> ARC decommission is **not a phase** — it never reached production, so its scaffolding is
> deleted in Phase 0 (§12), not migrated off at the end.

---

## 8. Risks & open questions

- **~~gVisor + native/NDK syscalls~~ (resolved 2026-07-20):** tiered runtimes — gVisor
  default, **Kata** for native/NDK channels (untrusted Android). Kata gives full syscall
  compat *and* a stronger VM boundary; runs natively on bare metal (no nested virt).
  Two RuntimeClasses to maintain; validate Kata scheduling + boot overhead in Phase 2.
- **~~Sigstore: public vs self-hosted~~ (resolved 2026-07-20):** **public Sigstore
  keyless** (Fulcio/Rekor), consistent with [ADR-0005](../../../framework/decisions/0005-zero-secret-ci-wif.md).
  Public log holds signing identity + digest + SLSA metadata (no artifacts/secrets);
  private repo names + commit SHAs become publicly queryable — an accepted org tradeoff.
  GCP-KMS cosign / self-hosted Rekor remain the private fallback if that ever changes.
- **Evidence retention window** — confirm Results/Loki retention meets the SOC 2 / ISO
  27001 requirement (assume ~1 year) before relying on it as the control record.
- **`runsc` node install** is a non-GitOps bootstrap step — document it in the node
  provisioning runbook so a rebuilt node doesn't silently lose the sandbox.
- **PaC GitHub App scope** — one org-level App installed on the specific repos; confirm
  least-privilege permission set (checks, contents:read, pull_requests).
- **Approver bootstrapping / availability** — N-approver gate must not deadlock releases;
  define the approver group + a documented break-glass (dual-control, logged).
- **Approval-gate maturity (DECIDED 2026-07-20 — accept interim, tracked as risk)** — the
  in-cluster `ApprovalTask` is Red Hat Tech Preview, not GA core Tekton. Accepted as the
  interim gate on a fail-closed basis with compensating controls; hybrid gate (GitHub
  Environment reviewer, ADR-0016) is the documented fallback. Contingent on the Phase-1
  fail-closed test and a pre-audit reassessment. Full treatment:
  [RISK-BUILD-001](../../../framework/compliance/risks/RISK-BUILD-001-approval-gate-maturity.md).

## 10. No web UI — CLI-driven (decided 2026-07-20)

The Tekton **Dashboard is intentionally not deployed.** It ships with no built-in
authentication and would add a web surface + an auth-integration burden for little gain.
Skipping it removes an attack surface entirely; the build platform exposes **no HTTP
ingress** (public or internal). Instead:

- **Run / log inspection** via the `tkn` CLI and the existing **Loki/Grafana** pipeline
  (PipelineRun/TaskRun logs already ship to Loki); run history/metadata via **Tekton
  Results**.
- **Release approvals** actioned via `tkn`/`opc` on the `ApprovalTask` — authenticated to
  the cluster, RBAC-scoped, credentialed, and auditable, with no web surface involved.
- Access to the platform is therefore **cluster-credentialed CLI only** — no Authelia/
  oauth2-proxy integration needed for the build platform.

## 11. API specifics validated against Tekton docs (2026-07-20)

| Mechanism | Confirmed field / behavior | Source |
|---|---|---|
| Channel reuse | `pipelineRef.resolver: git` + `url`/`revision`/`pathInRepo` (or `org`/`repo`/`token`/`scmType`) | [git-resolver](https://tekton.dev/docs/pipelines/git-resolver/) |
| Per-build SA | v1 `spec.taskRunTemplate.serviceAccountName`; per-task `taskRunSpecs[].serviceAccountName` | [pipelineruns](https://tekton.dev/docs/pipelines/pipelineruns/) |
| Sandbox runtime | `spec.taskRunTemplate.podTemplate.runtimeClassName` (+ `securityContext`, `hostNetwork`) | [podtemplates](https://tekton.dev/docs/pipelines/podtemplates/) |
| Provenance | Chains keyless Sigstore signing; `slsa/v1` attestation | [chains](https://tekton.dev/docs/chains/) · [signing](https://tekton.dev/docs/chains/signing/) |
| PaC trigger + fork ACL | `Repository` CR `spec.settings.policy.{pull_request, ok_to_test}`; GitHub App required for `/ok-to-test` | [PaC policy](https://pipelinesascode.com/docs/guide/policy/) · [gitops commands](https://pipelinesascode.com/docs/guide/gitops_commands/) |
| Manual approval | `ApprovalTask` (`approvers`, `numberOfApprovalsRequired`) — **Tech Preview, not GA** | [manual-approval-gate](https://github.com/openshift-pipelines/manual-approval-gate) |

## 12. Supersedes / decommission inventory

This platform replaces the capturly ARC build stack ([ADR-0016](../../../framework/decisions/0016-self-hosted-arc-runners.md))
in full. **ARC never reached production**, so there is no parallel interim: the scaffolding
below is deleted in **Phase 0**, before Tekton carries any real build.

| Path (`homelab-infra` unless noted) | Fate |
|---|---|
| `argocd/applications/arc-controller.yaml` | remove |
| `argocd/applications/arc-runners-android.yaml` | remove |
| `argocd/applications/arc-runners-android-config.yaml` | remove |
| `arc-runners-android/` (externalsecret, networkpolicy, build-cache-pvc) | remove |
| `apps/capturly-android-runner/` (Dockerfile, README) | remove |
| `.github/workflows/build-capturly-android-runner.yml` | remove |
| `docs/runbooks/capturly-android-arc-runner.md` | remove |
| `business-plane/appproject.yaml` | **edit** — replace `arc-systems`/`arc-runners` + ARC chart repo with Tekton namespaces/kinds |
| Bitwarden SM: 3 ARC GitHub App secrets | retire — PaC uses its own GitHub App |
| capturly `.github/workflows/release-android.yml` + **PR #341** | supersede — `.tekton/` (untrusted) + GitHub-gated release dispatch (trusted) |
| `homelab-infra#557` (runner deploy) | close if open |

**Keep (unrelated):** `ar-token-refresher` (keyless Artifact Registry pull via WIF —
complements the zero-secret posture).

---

## 9. Files

### Phase 0 — built on `feat/tekton-build-platform` (2026-07-20)

The platform installs via the **Tekton Operator** (profile `basic` → Pipeline +
Triggers + Results + Chains, **no Dashboard**), with **PaC installed separately**
(the operator does not provision it on vanilla k8s) and the approval-gate + sandbox
RuntimeClasses as their own apps.

```
homelab-infra/
  argocd/applications/tekton-operator.yaml             # operator + CRDs (wave -2)
  argocd/applications/tekton-config.yaml               # TektonConfig, profile basic (wave -1)
  argocd/applications/tekton-pac.yaml                  # Pipelines-as-Code + ESO secret (wave -1)
  argocd/applications/tekton-manual-approval-gate.yaml # ApprovalTask operator (wave -1)
  argocd/applications/tekton-runtimeclasses.yaml       # gvisor + kata (wave -2)
  tekton/
    operator/kustomization.yaml                        # pinned operator release.yaml
    config/tektonconfig.yaml
    pac/kustomization.yaml                              # pinned PaC release.k8s.yaml
    pac/externalsecret-pac-github-app.yaml             # Bitwarden UUIDs = TODO
    manual-approval-gate/kustomization.yaml
    runtimeclasses/{gvisor,kata}.yaml
  business-plane/appproject.yaml                        # edited: Tekton ns/kinds/repos
  docs/runbooks/tekton-build-platform.md
```

### Phase 1+ — still to create

```
homelab-infra/
  argocd/applications/build-platform-appset.yaml   # ApplicationSet over build-targets/
  build-targets/{capturly-android-trusted,capturly-nextjs-untrusted,coreyalan-nextjs-untrusted}.yaml
  build-catalog/pipelines/{android,nextjs,linux}-build.yaml + tasks/
  charts/build-namespace/                          # per-(project,tier): ns, SA, RBAC, netpol, ESO, PaC Repo
capturly/.tekton/{android-release (trusted), nextjs-pr (untrusted)}.yaml
```
