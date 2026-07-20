# build-namespace

One Helm chart that renders a single Tekton build-tier bundle — namespace,
identity, egress, secrets, triggers — from a small values file, **hardened by
default**. The `build-targets` ApplicationSet
(`argocd/applications/build-targets.yaml`) templates one Argo `Application` per
inventory file, so **onboarding a build channel = adding one file**.

See `docs/design/tekton-phase3-plan.md` for the security rationale (H1–H11) and
`docs/design/tekton-build-platform.md` for the platform design.

## Inventory layout

```
build-targets/<project>/<channel>-<tier>.yaml
```

`namespace` → `<project>-builds-<tier>`, pipeline SA → `<project>-<channel>-<tier>`
(override only to preserve a legacy name).

## Tiers

| | untrusted | trusted |
|---|---|---|
| SA | zero-secret, no cloud identity | per-build OIDC (WIF) |
| trigger | PaC `Repository` (fork PRs gated by `/ok-to-test`) | Tekton Triggers (tag push → EventListener) |
| egress | split by task — `checks` (arbitrary PR code) reaches **Verdaccio only**; `clone` reaches public :443 | public :443 + k8s API + Verdaccio |
| secrets | none | build App token (Contents:read), webhook HMAC, signing keys, WIF cred config |
| npm | `verdaccio-untrusted` | `verdaccio-trusted` (no shared cache) |

Hardening common to both is baked in: per-tier namespace isolation, Verdaccio-only
npm (no token in pod), least-privilege trigger RBAC. Cluster-wide pod hardening
(runAsNonRoot / drop-ALL / seccomp) comes from the `set-security-context`
TektonConfig flag; the sandbox RuntimeClass is set on the PipelineRun by
PaC/Triggers.

## Minimal untrusted entry

```yaml
project: coreyalan
channel: nextjs
tier: untrusted
repo: Corey-Alan-Consulting/coreyalan.com
pac:
  policy:
    pull_request: [coreyalan-maintainers]
    ok_to_test: [coreyalan-maintainers]
```

## Per-app prerequisites (not templated — see Part C of the plan)

- **WIF binding** in platform-infra Terraform (trusted): SA → target SA grant.
- **Secrets** in the right Bitwarden project; UUIDs referenced from the entry.
- **GitHub**: build App install; (trusted) tag webhook + public host/DNS/cert.

## Verify a change before merge

```bash
helm template t helm-charts/build-namespace -f build-targets/<project>/<c>-<tier>.yaml
```
