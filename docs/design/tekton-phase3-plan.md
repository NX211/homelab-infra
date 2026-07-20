# Phase 3 plan: generalize the build platform + close Phase 0–2 security holes

Extends [ADR-0017](../../../framework/decisions/0017-tekton-build-platform.md) /
`tekton-build-platform.md`. Two goals, done together so the fixes are uniform:

1. **Generalize** — turn the hand-written per-project bundles (`capturly-builds-*`)
   into an ArgoCD **ApplicationSet over a `build-targets` inventory**, so a new
   (project, channel, tier) is a ~10-line entry, not a copied Argo app + directory.
2. **Harden** — bake the security fixes below into the shared chart, so every
   generated app inherits them (closing holes *once*, not per-snowflake).

The pipelines are already shared (git resolver); only the *namespace bundle* is
hand-written today. Phase 3 templates that bundle and hardens it.

---

## Part A — Security audit (Phase 0–2) and fixes

Severity: **H**igh (fix before more apps / trusted go-live), **M**edium, **L**ow.
"Baked" = enforced by the Phase 3 chart so every app gets it automatically.

| # | Hole | Current state | Fix | Sev | Baked |
|---|---|---|---|---|---|
| H1 | **No pod hardening** on build pods | Only the gVisor RuntimeClass; no `securityContext` | Chart default `podTemplate.securityContext`: `runAsNonRoot`, non-root uid, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`, `seccompProfile:RuntimeDefault`, read-only rootfs where the step allows (writable workspaces stay writable) | H | ✅ |
| H2 | **Untrusted egress exfil** | Untrusted pods allow public :443 (for the clone) → arbitrary PR code can POST anywhere | **Split egress by task**: the `clone` pod gets GitHub :443; the `build/install` pod (arbitrary code) gets **only Verdaccio + DNS**, no public egress. Enforce with Tekton step pod labels + `podSelector` NetworkPolicies (no Cilium needed). Optional deeper: a Tetragon `TracingPolicy` egress allowlist | H | ✅ |
| H3 | **Shared Verdaccio cache across tiers** | After the trusted-Verdaccio change both tiers hit one Verdaccio (emptyDir cache) → a soft untrusted→trusted path (mitigated by lockfile integrity) | Run **two Verdaccio instances** (untrusted-proxy, trusted-proxy) OR keep one but document that npm integrity hashes (frozen lockfile) prevent poisoning. Recommend split for a clean invariant-2 story | M | ✅ (chart picks per-tier registry) |
| H4 | **Over-broad git token** | Trusted clone mints a token from the PaC App (Checks/Contents/Issues/PRs R/W) — more than clone needs | Create a **dedicated build App** with only `Contents:read`; mint the clone token from it. Least-privilege + separation from the webhook App | M | ✅ (chart refs the build App) |
| H5 | **Trigger SA cluster-wide RBAC** | `ClusterRoleBinding` → `tekton-triggers-eventlistener-clusterroles` per namespace (Tekton default) | Keep the (required) cluster interceptor read binding but confirm it grants only interceptor/clustertriggerbinding *read*; everything else stays a namespaced `RoleBinding`. Document the residual | M | ✅ |
| H6 | **Approval gate not verified fail-closed** | MAG installed; the RISK-BUILD-001 fail-closed test hasn't run | Run the test (scale MAG to 0 / issue a reject → release must **block**). Gate trusted go-live on it | H | n/a (test) |
| H7 | **Chains provenance not configured** | Chains controller runs; no keyless signing / SLSA / verify-on-admit | Configure Chains: keyless **Fulcio/Rekor**, `slsa/v2` provenance, OCI storage; add **verify-on-admit** (Kyverno `verifyImages` / policy-controller) so an unsigned/unattested artifact can't be promoted (ADR-0004/0005) | H | partial (cluster-wide config + admit policy) |
| H8 | **One ESO machine account reads all projects** | `d7d98b6a` has read on Workbench, Staging-Capturly, Build Platform, Capturly… → token leak = all secrets | Move to **per-project (or per-tier) machine accounts + per-store credentials**; the build stores use a build-scoped account only | M | ✅ (chart store ref) |
| H9 | **Kata not installed** (untrusted native/NDK) | Only gVisor; untrusted Android would fail under runsc | Install Kata via `kata-deploy` before adding an untrusted native channel; chart selects `runtimeClassName` per channel | M | ✅ (chart per-channel runtime) |
| H10 | **No node isolation** | Untrusted code runs on shared nodes (gVisor-contained) | Optional: taint a **dedicated build node**; chart adds nodeSelector+toleration when set | L | ✅ (opt-in) |
| H11 | **Verdaccio anonymous read of all private pkgs** | Any build-tier pod can pull every `@corey-alan-consulting` package | Accept (= the PR author's own read access) + document; optional per-scope uplink ACL | L | — |

**The point:** H1, H2, H3, H4, H5, H8, H9, H10 are all **structural** — baking them into
the chart means every future app is hardened by construction, and migrating the
current capturly bundles onto the chart retro-fixes them. H6/H7 are trusted-tier
go-live gates handled once, cluster-wide.

---

## Part B — Generalization: ApplicationSet + inventory + chart

### B1. Reusable chart `helm-charts/build-namespace/`
One Helm chart renders a project's tier bundle from values, **hardened by default**.
Conditioned on `tier`:

- **Common:** Namespace (labelled `build.capturly/tier`), pipeline ServiceAccount,
  egress NetworkPolicies (split clone/build per H2), pod securityContext defaults
  (H1), the Verdaccio `.npmrc` ConfigMap, RBAC (H5).
- **untrusted:** zero-secret SA, gVisor/Kata RuntimeClass per channel (H9), PaC
  `Repository` (policy `pull_request`/`ok_to_test`), no cloud identity.
- **trusted:** per-build-OIDC SA (WIF), signing/App-token/webhook ExternalSecrets,
  Tekton Triggers (EventListener/Binding/Template) + ingress + cert, approval gate
  wiring.

### B2. Inventory `build-targets/` (git-files generator)
One small values file per (project, channel, tier), e.g.:
```yaml
# build-targets/capturly/android-trusted.yaml
project: capturly
repo: Corey-Alan-Consulting/capturly.app
channel: android
tier: trusted
runtimeClass: kata           # native/NDK
secretStore: bitwarden-capturly
wifServiceAccount: capturly-android-trusted
approvers: [corey]
host: tekton-trusted.coreyalan.com
```
```yaml
# build-targets/coreyalan/nextjs-untrusted.yaml
project: coreyalan
repo: Corey-Alan-Consulting/coreyalan.com
channel: nextjs
tier: untrusted
runtimeClass: gvisor
```

### B3. `ApplicationSet`
A git-files generator over `build-targets/**/*.yaml` templates one Argo
`Application` per entry (project `business`), sourcing `helm-charts/build-namespace`
with the entry as values. Adding an app = adding a file.

### B4. Migrate + prove
- Convert `capturly-builds-trusted` + `capturly-nextjs-untrusted` to inventory
  entries; **diff the rendered output against the current live manifests**
  (regression gate — must match, plus the new hardening).
- Delete the hand-written Argo apps + `build-targets/capturly-*` dirs.
- **Onboard `coreyalan`** as a new inventory entry to prove one-entry onboarding.

---

## Part C — What stays per-app (can't be templated)

Even generated, each app needs identity + secrets set up once (documented in an
onboarding runbook):

- **WIF binding** in `platform-infra` Terraform (trusted tiers) — the SA→SA grant.
- **Secrets** in the right Bitwarden project (signing keys, per-app tokens).
- **GitHub**: the build App install + (trusted) the tag webhook + host/DNS/cert.

The ApplicationSet removes the k8s boilerplate; these remain a short per-app
checklist.

---

## Part D — Sequencing (each step independently verifiable)

| Step | Work | Verify |
|---|---|---|
| **3a — Split egress (H2)** | Split the untrusted egress by task (clone gets internet; the arbitrary-code `checks` step gets Verdaccio only) | untrusted `checks` pod has no public egress; a test exfil fails |
| **3b — Chart + non-root images + ApplicationSet** | Non-root toolchain images (tools pre-baked) so **H1 `set-security-context`** can be enabled cluster-wide; `helm-charts/build-namespace` + ApplicationSet + inventory; migrate capturly | steps run non-root/drop-caps/seccomp; rendered manifests match live (+ hardening); apps Healthy |
| **3c — Onboard coreyalan** | One inventory entry per tier | app generated + Healthy from a single file |
| **3d — Trusted go-live gates** | H6 fail-closed test; H7 Chains keyless + verify-on-admit | release blocks without approval; artifact has a verified attestation |
| **3e — Blast-radius (opt)** | H8 per-project ESO machine accounts; H4 dedicated build App; H10 build node | leaked build token ≠ all secrets |

---

## Decisions (locked 2026-07-20)

1. **Verdaccio isolation (H3): TWO proxies** — `verdaccio-untrusted` +
   `verdaccio-trusted`, no shared cache. Clean invariant-2. The chart selects the
   per-tier registry in `.npmrc`.
2. **Dedicated build App (H4): YES** — a new GitHub App with **`Contents:read`
   only**, installed on the build repos; the clone token is minted from it (not
   the PaC webhook App). Its key goes in the Build Platform BWS project.
3. **Per-project ESO accounts (H8): TIGHTEN** — a **build-scoped machine account**
   reads only the build projects (Build Platform + per-app signing projects); the
   web/app ESO account stays separate. New `bitwarden-credentials-build` secret;
   the build stores reference it. Documented in the static-token register.
4. **Scope: FULL MATRIX** — `android / nextjs / linux × capturly / coreyalan`,
   both tiers, as inventory entries. Implies per-app setup (WIF, secrets, App
   installs) for each — tracked in the onboarding checklist.

3a closes the live holes; 3b–3c deliver the one-entry model + full matrix; 3d
gates trusted releases; 3e is folded into the above (H4/H8 are now in-scope).

---

## Status (2026-07-20)

- **3a / H2** — ✅ split egress live.
- **3b-1 (non-root images) + 3b-2 (H1 `set-security-context`)** — ✅ merged,
  verified on-cluster (uid 65532, drop-ALL, seccomp).
- **3b-3 (H3 two Verdaccio proxies)** — ✅ merged, verified (per-tier ingress
  isolates the caches).
- **3b-4/5 (chart + inventory + ApplicationSet + migrate)** — this change:
  - `helm-charts/build-namespace/` renders either tier from one values file.
  - `build-targets/<project>/<channel>-<tier>.yaml` inventory
    (capturly `android-trusted`, `nextjs-untrusted`).
  - `argocd/applications/build-targets.yaml` ApplicationSet (git-files generator,
    multi-source values ref).
  - **Regression gate:** `helm template` output diffs spec-for-spec against the
    old hand-written bundles — comment-only deltas plus the intentional additive
    `build.capturly/channel` label on the untrusted namespace. The old Argo apps
    + `build-targets/capturly-*/` dirs are deleted here.

### ⚠️ Migration is an Argo app *rename* (do NOT naive-merge)

The old apps (`capturly-builds-trusted`, `capturly-nextjs-untrusted`) carry
`resources-finalizer.argocd.argoproj.io`. Deleting them via root-apps prune would
**cascade-delete the build namespaces**, then the ApplicationSet recreates them.
The generated app names change (`capturly-android-trusted`,
`capturly-nextjs-untrusted`) but the **namespaces/resources are identical**, so
run the standard orphan-then-adopt sequence at merge:

```sh
# 1. Orphan (don't delete) the old apps' resources before root-apps prunes them.
for app in capturly-builds-trusted capturly-nextjs-untrusted; do
  kubectl -n argocd patch application "$app" --type=json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]'
done
# 2. Merge the PR. root-apps deletes the old Application CRs (resources orphaned),
#    creates the build-targets ApplicationSet, which generates the renamed apps.
# 3. The new apps adopt the existing resources (ServerSideApply); confirm Healthy.
kubectl -n argocd get applications capturly-android-trusted capturly-nextjs-untrusted
```

No build is in flight, so a full delete+recreate is also tolerable (only an empty
gradle-cache PVC is lost) — but orphan-adopt avoids namespace-termination churn.

### Remaining

- **3c** — add coreyalan inventory entries (+ per-app WIF/secrets/App installs).
- **3d** — H6 fail-closed test, H7 Chains keyless provenance + verify-on-admit.
- **3e** — H9 Kata (before any untrusted native channel), H10 build node (opt).
