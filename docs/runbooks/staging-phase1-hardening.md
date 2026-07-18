# Runbook: Staging Phase 1 — cluster hardening (audit-first)

Brings the staging K3s cluster toward prod's SOC 2 posture **without enforcing
anything yet**, and establishes a **business/personal isolation boundary** so the
personal self-hosted services can't reach or starve the business (build) plane.
Everything here is Audit/observe or safe-by-construction. Plan of record:
`framework/platform/staging-build-platform.md` (Phase 1). Merge → deploy →
**audit the actual cluster in policy-reporter** → fine-tune → then graduate to
Enforce.

## What this deploys

| Component | Mode | ArgoCD app |
|---|---|---|
| Kyverno engine | — | `kyverno` (chart 3.8.2) |
| Pod Security + best-practice policies | **Audit**, cluster-wide | `kyverno-policies` (3.8.2) |
| Policy Reporter (+ UI) | audit dashboard | `policy-reporter` (3.8.1) |
| Business supply-chain policies (registry allowlist, cosign verify) | **Audit**, `plane: business` only | `kyverno-policies-business` |
| Tetragon | **observe** | `tetragon` (helm.cilium.io 1.7.0) |
| Business plane (namespaces, default-deny ingress, AppProject, PriorityClass) | enforced (safe) | `business-plane` |

## The isolation model (personal ⇏ business)

- **Namespace boundary.** `arc-systems` + `arc-runners` are labeled `plane: business`.
  Extend the label to any other business namespace to bring it inside the boundary.
- **Network.** K3s runs a NetworkPolicy controller, so `default-deny-ingress` in the
  business namespaces **enforces**: no personal pod can open a connection into a
  business namespace. Only cluster monitoring is allowed in (metrics scrape).
- **GitOps.** The `business` ArgoCD AppProject restricts business apps to business
  namespaces + the pinned repos — a personal manifest can't target a business ns.
  *Action:* set `project: business` on `arc-controller`, `arc-runners-android`,
  `arc-runners-android-config`.
- **Scheduling.** `business-critical` PriorityClass so a noisy personal service can
  never preempt a build. *Action:* set `priorityClassName: business-critical` on the
  ARC controller + scale-set pods. Optional hardening: taint a node
  `plane=business:NoSchedule` and add the matching toleration/nodeSelector for true
  hardware isolation.

## Audit → Enforce workflow

1. Sync the apps; open **policy-reporter UI** (internal/Tailscale only).
2. Expect **many** violations from the personal services (privileged, run-as-root,
   hostPath, `:latest`) — that's the point of Audit; they stay out of scope.
3. Confirm the **business namespaces** are clean (or become clean after the
   fine-tunes below).
4. Graduate per policy, business namespaces first: set `validationFailureAction:
   Enforce` (or move the namespace into an enforce cohort). Never enforce
   cluster-wide in one step.

## Required before enforcing `verify-image-signatures-business`

The runner image must be **cosign-signed** or the (Audit) verify policy will flag
it. Add keyless signing to `.github/workflows/build-capturly-android-runner.yml`
(the runner-image build, on the `feat/capturly-android-arc-runner` branch / #557):

```yaml
permissions:
  contents: read
  packages: write
  id-token: write            # keyless Cosign
# after Build & push (give it `id: build`):
- uses: sigstore/cosign-installer@v3
- run: cosign sign --yes "${IMAGE}@${DIGEST}"
  env:
    IMAGE: ${{ env.IMAGE }}
    DIGEST: ${{ steps.build.outputs.digest }}
```

The policy's keyless `subject` already matches this repo's workflow identity.

## Fine-tunes to do against the live cluster (before Enforce)

- **Monitoring namespace name** in `business-plane/networkpolicies.yaml`
  (`allow-monitoring-ingress`) — set it to wherever kube-prometheus-stack runs, or
  metrics scraping of the business namespaces will be denied.
- **Runner egress** (the policy from #557) currently allows DNS + public 443 but
  blocks RFC1918 — the ARC listener also needs the **Kubernetes API**. Add an egress
  allow for the API server's address/port (control-plane IP or the service CIDR) or
  the listener can't create runner pods. Tighten to FQDN egress only if you add
  Cilium (K3s' built-in controller does not do FQDN policies).
- **PriorityClass / project** wiring on the ARC apps (see isolation model).

## SOC 2 control map (Phase 1)

| TSC | Control | Here |
|---|---|---|
| CC6.6 | Network security | default-deny ingress (business ns), Tetragon |
| CC6.8 | Malicious code / admission | Kyverno PSS + supply-chain policies (Audit) |
| CC7.1 | Vuln / change mgmt | pinned chart versions; image scanning is Phase 2 |
| CC7.2 | Monitoring | Tetragon events → Loki; policy-reporter |
| CC6.1/6.8 | Isolation / least-privilege | `business` AppProject, PriorityClass, PSS labels |

## Validation

- `helm template` renders kyverno / kyverno-policies / policy-reporter / tetragon
  at the pinned versions; ArgoCD apps + policy manifests YAML-validated.
- Cluster-side: sync order is wave-driven (business-plane -6 → kyverno -5 →
  policies/tetragon -4 → reporters/business-policies -3). Confirm each app Healthy,
  then work the policy-reporter audit.
