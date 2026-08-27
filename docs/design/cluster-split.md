# Design: two-cluster plane split

Implementation plan for [ADR-0022](../../../framework/decisions/0022-two-cluster-plane-split.md).
Promotes the `plane: business` label boundary ([ADR-0013](../../../framework/decisions/0013-control-plane-business-plane-split.md),
[ADR-0017](../../../framework/decisions/0017-tekton-build-platform.md)) to a cluster edge.

**Locked decisions (2026-08-26):** new business cluster only, personal k3s untouched ·
Talos Linux on Proxmox via CAPMOX · two GitOps repos · evidence store on a
business-cluster SeaweedFS · no Harbor · Gitea stays personal-plane.

---

## 1. What moves, what stays

The existing four-node k3s cluster (`blacktalon`, `yellowtalon`, `redtalon`, `greytalon`)
keeps everything it runs today **except** the business and staging estates, which are
rebuilt on the new cluster. Nothing is migrated in place — the business workloads are
stateless or trivially re-seeded, which is exactly why this side moves and the media side
does not.

| Component | Today | After |
|---|---|---|
| Media stack (Plex, Jellyfin, \*arr, Tdarr, SABnzbd, Transmission) | k3s | **k3s, untouched** |
| Immich, Paperless, Karakeeper, Kavita, Matrix, Homer, IT-Tools | k3s | **k3s, untouched** |
| Gitea | k3s (`redtalon`) | **k3s** — gains the mirror + registry roles (§7) |
| Authelia, Traefik, CoreDNS, cert-manager, CNPG, Redis, SeaweedFS | k3s | **k3s** — plus a second instance of each on Talos |
| Tekton (operator, config, PaC, MAG, RuntimeClasses) | k3s | **Talos** |
| `*-builds-{trusted,untrusted}`, `build-catalog/`, `build-targets/` | k3s | **Talos** |
| `build-registry-proxy` (Verdaccio, Maven, Prisma mirrors) | k3s | **Talos** |
| ARC (`arc-systems`, `arc-runners`) | k3s | **Talos** |
| `staging-apps/*` (6 charts) + `staging` namespace | k3s | **Talos** |
| Kratix, Restate, Metacontroller, provisioning engine, scaffolder | k3s | **Talos** |
| Port exporters (`port-k8s-exporter`, `port-ocean-argocd`) | k3s | **Talos** |
| kube-prometheus-stack, Loki, Grafana | k3s | **both** — separate instances, no cross-plane scrape |
| Tetragon, Trivy Operator, Kyverno, policy-reporter | k3s | **both** |

The migration is therefore a **rebuild on the new cluster followed by a delete on the old
one**, not a live move. The only stateful business-side items are the staging databases
(re-seeded by the existing `db-init` jobs) and Tekton Results history (accept the reset, or
export first — see Phase 4).

---

## 2. Topology

```
                    Proxmox host(s)
                    ├── talos-cp-{1..3}      control plane
                    └── talos-worker-{1..N}  workers (gVisor + Kata extensions)
                              ▲
                              │ CAPMOX (cluster-api-provider-proxmox)
                              │
                    management cluster ── kind (bootstrap) ─▶ pivoted onto talos-cp
```

**Talos node images** are built through the Image Factory with the system extensions baked
into the installer, replacing `node-bootstrap/`:

| Was | Becomes |
|---|---|
| `node-bootstrap/gvisor/install-runsc.sh` | `siderolabs/gvisor` system extension |
| `node-bootstrap/kata/install-kata.sh` | `siderolabs/kata-containers` system extension |

The `RuntimeClass` objects in `tekton/runtimeclasses/` stay as they are — they reference
handlers (`runsc`, `kata`) that the extensions register. This removes the non-GitOps
bootstrap prerequisite ADR-0017 recorded as an accepted cost.

**Kata note:** ADR-0017 chose Kata for native/NDK channels partly because bare-metal nodes
run it without nested virtualisation. On Proxmox VMs that no longer holds — the VMs need
nested virt enabled on the Proxmox host (`kvm_intel.nested=1` / `kvm_amd.nested=1`, CPU
type `host`). Verify this before committing the Android channel to the new cluster; it is a
Phase 1 gate, not an afterthought.

**Sizing:** the untrusted tier is the workload that actually needs headroom (parallel PR
builds under gVisor). Start with 3 control plane + 2 workers and treat worker count as the
scaling knob.

---

## 3. The dependency-direction rule, made concrete

> The business plane may depend on nothing in the personal plane. The reverse is permitted.

| Service | Personal (k3s) | Business (Talos) | Notes |
|---|---|---|---|
| ArgoCD | existing, `cd.authoritah.com` | new instance, own hostname | **No hub-and-spoke.** A hub with credentials to both clusters rebuilds the blast radius the split breaks. |
| External Secrets | existing `ClusterSecretStore` | new install | **Separate Bitwarden machine account per cluster**, scoped to that cluster's projects only. |
| cert-manager | existing | new install | Both HTTP-01; each cluster's ingress must be reachable for its own domains. |
| Traefik | `yellowtalon` hostPorts | new ingress on Talos | Second address in CoreDNS (§3.1). |
| PostgreSQL | existing CNPG | new CNPG | Staging databases move off the shared `postgres-rw`. This is the co-tenancy the split exists to end. |
| SeaweedFS | `s3.authoritah.com` | new instance | Business instance backs staging app storage *and* the evidence store (§5). |
| Monitoring | existing stack | own stack | Business metrics/logs never land in the personal stack. |
| Authelia | existing, personal SSO | **not deployed** | Business surfaces use oauth2-proxy + Google OIDC per [ADR-0018](../../../framework/decisions/0018-control-plane-target-stack.md). Sharing Authelia would violate the rule. |
| Gitea | existing | **not deployed** | §7. |

### 3.1 CoreDNS

`coredns/configmap.yaml` currently points every hostname — personal `.tv` media and
`staging.capturly.app` alike — at `10.43.5.100`. It splits by plane:

- `authoritah.{com,io,tv,click,photo}` → personal Traefik
- `staging.*` (`staging.coreyalan.com`, `staging.showcase.coreyalan.com`,
  `staging.jlshawconsulting.com`, `staging.dispatchr.social`, `staging.capturly.app`,
  `staging.blue-skysolutions.com`) → business Traefik
- `live.capturly.app`, `wss.live.capturly.app`, `turn.live.capturly.app` → decide per §1;
  `capturly-live` is a business workload and should follow the staging entries.

Each cluster keeps its own CoreDNS with its own rewrites. cert-manager HTTP-01 self-checks
depend on this being right — an entry pointing at the wrong cluster fails issuance rather
than failing quietly.

### 3.2 Checking the rule

The rule is only useful if a violation is visible. Two mechanisms:

- The business cluster's egress NetworkPolicies already deny RFC1918 for the untrusted
  tier (ADR-0017). Extend a default-deny-egress-to-homelab-subnet posture to the rest of
  the business namespaces, so a workload reaching for `postgres-rw.default.svc` or
  `s3.authoritah.com` fails at connect time rather than silently succeeding.
- A Kyverno policy requiring `plane: business` on every namespace in the business cluster,
  so the §8 labelling gap cannot recur.

---

## 4. Repo split

`homelab-infra` becomes two repositories. Proposed division:

| Business repo | Personal repo (`homelab-infra`) |
|---|---|
| `tekton/`, `build-catalog/`, `build-targets/`, `build-registry-proxy/` | `helm-charts/*` (media, Immich, Paperless, Matrix, Gitea, …) |
| `staging/`, `staging-apps/` | `argocd/applications/*` for the personal set |
| `business-plane/`, `kyverno-policies-business/` | `kyverno-policies.yaml`, `authelia-manifests/`, `monitoring-manifests/` |
| `kratix/`, `provisioning/`, `scaffolder/`, `port-*` | `traefik/`, `traefik-manifests/`, `coredns/`, `multus/` |
| `allowlist-reconciler/`, `ar-token-refresher/` | `secrets/`, `bootstrap/`, `node-bootstrap/` (retire) |
| its own `argocd/`, `bootstrap/`, `charts/` | `scripts/`, `docs/` |

Shared-by-copy: `charts/` base charts and `renovate.json` are duplicated rather than
cross-referenced, so neither repo depends on the other.

Use `git filter-repo` per path set to preserve history on both sides. The `.github/workflows/`
split needs care: `gitops-staging-update.yml` and `staging-promote.yml` follow the staging
estate into the business repo, which means the `GITOPS_APP_ID`, `GITOPS_APP_PRIVATE_KEY`,
`ARGOCD_API_TOKEN` and `ARGOCD_SERVER_URL` secrets are re-created there and
`STAGING_GITHUB_REPO` in `gitops-trigger`'s values (platform-infra) is re-pointed. **This is
the one change that can break the promotion path — do it in Phase 4, after the new ArgoCD
is healthy, and keep the old workflow disabled rather than deleted until a promotion has
succeeded end to end.**

The exposure this closes: `build-catalog/` is pulled into the **trusted** build tier by git
resolver from the same repository as the personal media charts.

---

## 5. Evidence pipeline

### 5.1 Generate — kube-apiserver audit policy

Set declaratively in the Talos machine config, rendered by the CAPMOX template:

```yaml
cluster:
  apiServer:
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      omitStages: ["RequestReceived"]
      rules:
        # Drop the high-volume control-plane chatter first — otherwise it is 90% of the log.
        - level: None
          users: ["system:kube-scheduler", "system:kube-controller-manager", "system:apiserver"]
          verbs: ["get", "list", "watch"]
        - level: None
          resources:
            - group: "coordination.k8s.io"
              resources: ["leases"]
            - group: ""
              resources: ["events", "endpoints"]
        - level: None
          nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/version", "/metrics"]

        # The rules an assessor actually reads.
        - level: RequestResponse
          resources:
            - group: ""
              resources: ["secrets", "serviceaccounts/token"]
            - group: "rbac.authorization.k8s.io"
              resources: ["*"]
        - level: RequestResponse
          resources:
            - group: ""
              resources: ["pods/exec", "pods/attach", "pods/portforward"]

        # Everything else that changes state.
        - level: Metadata
          verbs: ["create", "update", "patch", "delete", "deletecollection"]
        - level: Metadata
```

**Verify at implementation:** the on-node path Talos writes the audit log to (expected under
`/var/log/audit/kube/`) and the rotation flags it sets. Confirm with `talosctl` on the first
control-plane node before wiring the collector, rather than assuming the path.

### 5.2 Ship — Grafana Alloy

The business cluster uses **Alloy**, not Promtail. Promtail is end-of-life; there is no
reason to stand up a retired agent on a new cluster. The personal cluster's existing
`promtail` app can migrate on its own schedule.

The audit log is a **host file on control-plane nodes**, so pod discovery will never find
it. It needs a DaemonSet with control-plane tolerations, a host mount of the audit
directory, and a `local.file_match` → `loki.source.file` → `loki.write` chain that stamps a
distinguishing label (e.g. `job="kube-audit"`) for the retention rule below.

Also worth routing into the same store while Alloy is being configured: **ArgoCD sync
events**, which are Kubernetes Events and expire in an hour by default. They are the
"who deployed what, when" half of the change-management trail that GitHub PRs do not cover.

### 5.3 Retain — Loki on business SeaweedFS

The current Loki (`argocd/applications/loki.yaml`) is `retention_period: 30d`,
`storage.type: filesystem`, `replication_factor: 1` on a 50Gi `local-path` PVC. The business
cluster's instance changes three things: S3 storage against the business SeaweedFS, a
365-day stream for the audit job, and a bucket that the `bucket-init-job` creates alongside
the staging buckets.

```yaml
loki:
  storage:
    type: s3
    s3:
      endpoint: <business seaweedfs s3 service>
      s3forcepathstyle: true
      # credentials via ESO from the seaweedfs-s3-config identity
  limits_config:
    retention_period: 720h          # 30d default for application logs
    retention_stream:
      - selector: '{job="kube-audit"}'
        priority: 1
        period: 8760h               # 365d — ADR-0017 audit-window requirement
  compactor:
    retention_enabled: true
```

**Known weakness, carried as accepted interim risk in ADR-0022.** The SeaweedFS chart
defaults to `replication: 000` (single copy) and there is no object-lock equivalent, so on
one Proxmox host the audit store has neither redundancy nor tamper-evidence. Two follow-ups,
neither blocking the split:

1. Raise SeaweedFS replication once there is more than one volume server.
2. Add a scheduled copy of the `kube-audit` stream to a GCS bucket with a retention policy.
   That is what makes "these records cannot be altered" answerable.

### 5.4 Evidence coverage after this work

| Layer | Source | Status after |
|---|---|---|
| Control-plane API actions | kube-apiserver audit → Alloy → Loki | **new** |
| Node OS / machine | Talos API (`talosctl logs`), `machine.logging.destinations` | **new** |
| Runtime behaviour | Tetragon | existing |
| Admission decisions | Kyverno PolicyReports + policy-reporter | existing |
| Vulnerabilities | Trivy Operator | existing |
| Build provenance | Tekton Chains → Fulcio/Rekor | per ADR-0017 |
| Build / approval history | Tekton Results | **verify deployed + retention** |
| Deploy history | ArgoCD events → Loki | **new** (§5.2) |
| Change management | GitHub PR + branch protection | existing |
| Retention & immutability | Loki 365d on SeaweedFS | **partial** — see §5.3 |

**Falco is deliberately not adopted** — it overlaps Tetragon at the syscall layer and adds
a second thing to tune and evidence for no new coverage.

---

## 6. Registry

Staging keeps pulling the **same GCP Artifact Registry digest prod pulls**
([ADR-0004](../../../framework/decisions/0004-digest-pinned-promotion.md),
[ADR-0006](../../../framework/decisions/0006-build-once-deploy-many.md)). Harbor is not
introduced: it overlaps Artifact Registry on storage, RBAC and scanning, duplicates Trivy
Operator, and putting a second registry in the promotion path creates a system whose failure
mode is "staging validated an image that is not the one prod runs."

- **Spegel** — stateless DaemonSet, node-to-node image sharing keyed by digest. Removes
  repeated WAN pulls on reschedule and rebuild. No storage, no database, no effect on digest
  identity. Deploy with the cluster.
- **Zot** — one deployment plus a PVC, OCI-native, so Cosign signatures and Chains
  attestations replicate intact as OCI artifacts. Add **only if** offline rebuild becomes a
  real requirement.
- **Harbor** — trigger-gated on the same pattern ADR-0018 uses for Kratix and Port: adopt
  when managed-hosting is productized and per-tenant registry RBAC and quotas are genuinely
  needed.

---

## 7. Gitea

Stays on the personal cluster, `authoritah.io`, where it already runs. Three roles:

1. **Pull-mirror DR of GitHub.** Gitea's native pull mirrors fetch branches, tags and LFS on
   a schedule. Mirrors are pull-based, so no business system depends on Gitea and rule §3
   holds; recovery from a GitHub outage is a deliberate manual re-point. Mirrors carry git
   only — pair with `gickup` for breadth across repos and `github-backup` for issue/PR
   metadata, which is the part a mirror silently omits.
2. **Personal-plane forge.** `workbench`, `workbench_roles`, dotfiles, `homer-icons`,
   scripts, notes — anything that should not live in a business-audited GitHub org.
   Gitea Actions (act_runner) is sufficient CI for these.
3. **Internal package registry.** Helm charts and generic artifacts.

**Not** the business forge. The toolchain is GitHub-coupled by design (PaC GitHub App,
Tekton Triggers GitHub interceptor, ARC, `gitops-trigger` GitHub App JWT), and branch
protection is the separation-of-duties control ADR-0018 depends on.

**Not** a Verdaccio replacement. The hidden uplink token in `build-registry-proxy/` is
precisely what lets untrusted pods install private packages with no credential of their own;
Gitea's npm registry does not reproduce that property.

Because Gitea now carries DR value, **it needs its own backup and a tested restore** — a
mirror of a lost upstream is worth exactly what its own durability is worth. It currently
has neither.

**Deliberately deferred:** hosting the Kratix `GitStateStore` (`Corey-Alan-Consulting/kratix-state`)
or the rendered-manifest repos on Gitea. It would make the staging loop fully local, but it
puts Gitea in the business reconcile path — a new in-scope system to evidence, and a
violation of §3. Revisit only if GitHub API dependency in the reconcile path actually bites.

---

## 8. Phase 0 — policy fixes that ship first

These are defects found while designing the split. They are worth fixing on the current
cluster immediately; they do not wait for new hardware.

1. **`staging` is not in the business plane.** `staging/namespace.yaml` carries
   `environment: staging` only. Every NetworkPolicy and namespace-scoped Kyverno policy
   selects on `plane: business`, so the entire staging estate is currently outside the
   boundary meant to fence it. Add the label — and add a Kyverno policy requiring it, so the
   gap cannot silently recur.
2. **`restrict-image-registries-business` would reject the staging images.** It allows
   `ghcr.io/nx211/*` and `ghcr.io/actions/*`; the staging apps pull from
   `us-central1-docker.pkg.dev`. Adding the label in (1) without fixing this **will block
   staging deploys** — do them in the same change.
3. **`verify-image-signatures-business` will not match Tekton Chains artifacts.** Its
   attestor pins `subject: https://github.com/NX211/homelab-infra/.github/workflows/*` with
   the GitHub Actions issuer. Chains signs under the build ServiceAccount's projected OIDC
   identity. With `failurePolicy: Ignore`, a non-matching image is admitted silently rather
   than rejected. Add a second attestor entry for the Chains identity before the Tekton
   channels start publishing.
4. **Loki retention is 30d against a ~1yr requirement** (§5.3). Applies to the current
   cluster too, for as long as it hosts the build platform.

---

## 9. Phased rollout

| Phase | Work | Done when |
|---|---|---|
| **0** | The §8 policy fixes, on the current cluster | staging is in-plane, registry + signature policies match reality, no PolicyReport regressions |
| **1** | Proxmox prep + CAPMOX management cluster; Talos image with gVisor/Kata extensions; **verify nested virt for Kata** | `talosctl` reaches a booted cluster; a pod runs under each RuntimeClass |
| **2** | Business-cluster platform: ArgoCD, ESO (new Bitwarden machine account), cert-manager, Traefik, CNPG, SeaweedFS, Kyverno, Tetragon, Trivy, monitoring + Alloy | new ArgoCD healthy; a test IngressRoute issues a certificate |
| **3** | Audit pipeline: machine-config audit policy, Alloy host scrape, Loki S3 + 365d stream, ArgoCD events | `{job="kube-audit"}` queryable in the business Grafana; an `exec` into a pod appears with `RequestResponse` |
| **4** | Repo split (`git filter-repo`), business ArgoCD re-pointed, CI secrets re-created, `STAGING_GITHUB_REPO` re-pointed | a full build → staging → promote cycle succeeds end to end on the new repo |
| **5** | Move Tekton + build namespaces + registry proxies + ARC; move `staging-apps`; move Kratix/Restate/Metacontroller/provisioning; register the second Kratix `Destination` | untrusted and trusted builds both run on Talos; staging serves on the new Traefik |
| **6** | CoreDNS split; delete the business estate from k3s; retire `node-bootstrap/`; Gitea mirror + backup | no `plane: business` namespace remains on k3s; mirrors current; a Gitea restore has been tested |

Phase 4 is the only irreversible-feeling step. Keep the old workflows disabled rather than
deleted until a promotion has succeeded end to end on the new repo.

---

## 10. Open, not decided

- **Personal cluster's future.** Left on k3s deliberately. Whether it eventually becomes
  Talos-on-Proxmox is a separate decision; nothing here forecloses it.
- **HA.** Neither cluster gains it. A single Proxmox host means the business control plane
  has a single physical failure domain regardless of three control-plane VMs.
- **Tekton Results history.** Reset on migration, or exported first — decide in Phase 5.
  If any of it is audit evidence, it must be exported.
- **`capturly-live`** (coturn/signaling/web) — business workload on personal DNS entries
  today. Confirm it follows the staging estate in Phase 5.
- **Offsite audit copy.** The GCS mirror of the `kube-audit` stream (§5.3) is the treatment
  for the accepted evidence-durability risk. Not scheduled.
