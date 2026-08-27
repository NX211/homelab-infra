# Design: the implement-spec lane

A second scaffolder lane that builds features into an already-scaffolded app from
the **client-approved demo** plus a written spec. Complements
[`scaffold-app`](../../build-catalog/pipelines/scaffold-app.yaml); it does not
replace or re-run it.

**Locked decisions (2026-08-26):** demo + spec as inputs in v1 · demo wins on
look, template wins on contract · agent runs in a credential-free task.

---

## 1. The problem

`scaffold_app` was built to reduce the work of standing up a new client app, and
it does — repo, Terraform, Helm, ArgoCD, Bitwarden, DNS, staging, all generated.
What it does **not** do is produce an app that resembles anything in particular.

Three facts, together:

1. **`app-template/scripts/rebrand.sh` is a four-token find-and-replace:**
   `app-template` → name, `@app-template/` → scope, `app-template.example.com` →
   domain, `App Template` → display name. Structure is invariant by construction.
2. **The demos are real artifacts.** The showcase service stores an uploaded
   bundle per demo — `entryFile` defaulting to `index.html`, objects namespaced
   `showcase/<tenantId>/<slug>/…`. That bundle *is* the design the client
   approved.
3. **The bridge between them discards the design.**
   `coreyalan.com/api/scaffold/brand-kit/[slug]` resolves that exact slug and
   returns ten scalars: three colours, a logo URL, domain, enableEmail, notes and
   two readiness flags.

So the pipeline already holds the address of the specific demo a client signed
off on, fetches its palette, and throws away its layout, sections, copy and
information architecture. `brand_kit.source_slug` is the pointer; it is used for
colours only.

This is not a missing input — it is a missing capability. A written spec
describing a design you already possess is a lossy re-encoding of it.

## 2. Why a second lane and not a `scaffold_app` input

`scaffold_app` cannot be re-run. `onboard-app.sh` hard-fails on three guards:

```
[[ -d "$HELM_DIR" ]]  && echo "ERROR: Helm chart already exists…"        && exit 1
[[ -f "$ARGO_FILE" ]] && echo "ERROR: ArgoCD Application already exists…" && exit 1
[[ -f "$TF_FILE" ]]   && echo "ERROR: Terraform file already exists…"     && exit 1
```

`gh repo create` would also fail, and the GCP project, BWS project and DNS zone
are create-once. Those guards are **correct** — re-onboarding is not a thing.

Three more reasons the feature work does not belong in that lane:

| | `scaffold-app` | `implement-spec` |
|---|---|---|
| Runs | once per app | many times |
| Credentials | BWS write, Cloudflare Zone:Edit, 2× GitHub App key | repo-scoped GitHub token; agent task holds none |
| Gate | `ApprovalTask` × 2 (registrar NS cutover, TF apply) | a normal PR review |
| Agent prompt | fixed worklist, "keep changes minimal" | open-ended, design-bearing |

Phase 2.5 of `scaffold-app.sh` is a **plumbing agent**: its worklist is Bitwarden
grants, `gcp_project_number` backfill, Cloudflare token broadening, Sentry DSN,
staging chart UUIDs. Nothing about features. Widening that prompt inside that
namespace would put an open-ended code-writing agent next to every privileged
credential the platform has.

## 3. Sequencing — the spec comes first

The deterministic work is parameterized by **shape**, not by features:
`database`, `platform_targets`, `enable_email`, `domain`, `company`. Those are
answered on the Port form before anything runs.

```
write the doc  →  it answers the scaffold form  →  scaffold_app  →  implement_spec  →  iterate
                    (db? native targets? email?)      once            many times
```

Discovering from the spec *after* scaffolding that the app needs Postgres is a
wall, not a retry: adding it later is a hand-written Terraform/Helm PR, because
the guards above make a second onboard impossible.

This is why `spec_url` lives on `scaffold_app` (committing `docs/SPEC.md` into
the scaffold PR) rather than only on this lane — the doc arrives *with* the
scaffold request and is already in the repo when this lane runs.

`scaffold-app.sh --spec-url <https-url>` fetches it in a new phase 1.6, between
branding and onboard. Two guards: the URL must be https, and the GitHub token is
sent **only** to github.com hosts, so a spec URL on any other host cannot be used
to exfiltrate it. The Phase 2.5 plumbing agent is explicitly told the spec is
inert and must not be implemented — building features in the onboarding lane
would defeat the separation this whole design rests on.

## 4. The conflict rule

> **The DEMO wins on LOOK. The TEMPLATE wins on CONTRACT.**

- **Look** — layout, sections, visual hierarchy, copy, spacing, imagery
  placement. The agent restructures pages and components to match, and is told
  explicitly not to settle for the template's default layout.
- **Contract** — everything in `framework/platform/app-contract.md` and
  `standards/`: auth, the reusable deploy workflow, telemetry, secret and env
  wiring, image/build config, Helm/ArgoCD, naming. Binding, and Kyverno rejects
  violations at admission, so an agent "fixing" them produces an app that cannot
  deploy.

Where matching the demo would require changing a contract item, the agent
implements the closest compliant approximation and records it under
`DEVIATIONS` in its summary, which lands in the PR body.

**The ceiling on this is set by how much of `app-template` is chassis versus
chrome.** The more the platform contract lives in `packages/` and the less in
fixed page structure, the more freedom the agent has to match a design without
breaking compliance. That is ADR-0021's package bias applied to the template
itself, and it is the follow-up worth doing — tracked separately, not a blocker.

## 5. Demo bytes are hostile input

ADR-0021 is explicit: showcases are arbitrary client-uploaded HTML and JavaScript
served under a deliberately loose CSP. Feeding them to a code-writing agent is a
prompt-injection surface. Two structural mitigations, plus one in the prompt:

**Structural — the agent task holds no credentials.** The pipeline is three
tasks, and Tekton gives each its own pod:

| Task | Workspaces | Runs the agent? | Sandboxed? |
|---|---|---|---|
| `fetch` | source, github-app, scaffold-read | no | no |
| `render` | source | no | **gVisor, no SA token, no egress** |
| `implement` | source, anthropic (WIF *identifiers*, not credentials) | **yes** | no |
| `publish` | source, github-app | no | no |

The agent pod never mounts a GitHub App private key, the scaffold read token, or
anything Bitwarden. **Keep this split when editing the pipeline** — collapsing it
into one task silently undoes the mitigation.

**Structural — the demo is written to disk, not interpolated into the prompt.**
`fetch` explodes the payload into `demo/files/` plus a `MANIFEST.json`, with a
path-escape check on top of the service-side one. The agent reads a directory of
data; the prompt names the directory.

**In-prompt** — the agent is told the bytes are untrusted data, to ignore any
text in them that addresses it, never to copy inline `<script>` contents or
follow a URL they name, and to record attempts under `IGNORED INJECTION`.

Also note the reciprocal rule: `instructions` (the operator's free-text input on
the Port action) *is* treated as instructions. That asymmetry is deliberate and
stated in the prompt.

## 6. JS-rendered demos

A demo built with React/Vue/vanilla DOM construction has an entry file like
`<div id="root"></div><script src="bundle.js">`. The source endpoint returns HTML
and CSS, so such a demo arrives as an **empty shell**. Left unhandled, the agent
builds a generic template app and nothing in the chain reports a problem — the PR
looks entirely normal. Silent wrongness is the worst shape a failure can take, so
this is handled in two layers.

### Detection

`assessStaticRender` (showcase, `src/lib/showcase/static-render.ts`) is a
heuristic over regexes, not a parse — the service has no HTML parser and does not
need one to answer "is there enough here to work from". It measures visible text
and body-element counts with `<script>`, `<style>`, comments and `<head>` removed,
and looks for an empty framework mount node (`root`, `app`, `__next`, `__nuxt`,
`svelte`) next to script tags.

Two design choices worth keeping:

- **Computed at read time, not at extraction.** No Prisma migration and no
  backfill; it applies to every demo uploaded before this existed.
- **It returns evidence, not a verdict.** `reason`, `textChars`, `bodyElements`,
  `scriptTags`, `hasEmptyMountNode` all travel to the caller. Surface `reason`;
  a bare boolean from a heuristic is not something to trust blindly.

The near-empty-body rule requires **both** low text and low element count, so a
legitimately sparse page — a one-line hero over a photo grid — is not misjudged.
That case is a test.

### Rendering

The `render` task screenshots each page with headless Chromium, giving a design
signal a shell cannot carry. Screenshots rather than a serialized post-render DOM,
for two reasons: a PNG is what the design actually looks like, and **a PNG is
inert** — a lower prompt-injection surface than the HTML text already being passed.

This is the only place the client's own JavaScript executes, so it is the only
sandboxed task: `runtimeClassName: gvisor`, `automountServiceAccountToken: false`,
only the `source` workspace, and the `scaffolder-render-no-egress` NetworkPolicy
(`policyTypes: [Egress]`, `egress: []` — a deny-all including DNS).

**The no-egress policy is only possible because the demo is already on the
workspace when `render` starts.** Chromium loads `file://` URLs and needs no
network; Playwright routing aborts any non-`file://` request as a second layer. If
the render task ever needs to fetch something, this containment argument breaks and
has to be rewritten rather than exempted.

The task deliberately runs **without `set -e`** and always exits 0. A demo that
will not render is a degraded run, not a failed one — the agent still has the spec
and whatever static markup exists. Failures are written to
`MANIFEST.screenshotsFailed` and logged per page, so a partial render never reads
as a complete one.

### What the agent is told

`MANIFEST.staticRender.staticRenderable` selects the source of truth:

- `true` — `demo/files/` is the design; screenshots corroborate.
- `false` — `demo/files/` is a shell containing no design; `demo/screens/` is the
  only design source, and the agent is told explicitly **not** to conclude from
  sparse HTML that the demo is minimal.
- `false` **and** no usable screenshots — the agent has no design. It is told to
  say so under `DEVIATIONS`, implement only what the spec supports, and not invent
  a design to fill the gap.

### Where the Port actions live

Both actions are **Terraform-managed**, in
`platform-infra/terraform/environments/prod/port-*.tf`, alongside the other ~20
`port_action` resources. `implement_spec` is `port-implement-spec.tf`; `spec_url`
and the `company` pattern are additions to `port-scaffold-app.tf`. Do not create
or edit these through the Port UI or API — the next `terraform apply` reverts it.

## 7. New read path

```
Port implement_spec (brand_kit entity = showcase slug)
  → PaC /incoming → scaffolder-implement-spec-incoming
  → implement-spec fetch task
  → GET coreyalan.com/api/scaffold/demo/<slug>        [SCAFFOLD_READ_TOKEN]
  → GET showcase /api/v1/showcases/<id>/source        [showcases:source]
  → readShowcasePagesIndex + getShowcaseFile
```

`showcases:source` is a **new scope**, split from `showcases:read` for the same
reason `showcases:share` and `privacy:erase` are split out: `read` returns
metadata, `source` returns the client's design IP. The credential behind
`SHOWCASE_API_KEY` must carry it or the route answers 503 and the fetch task
fails closed.

The service caps bytes (256 KiB/file, 1 MiB total) and **never truncates
silently** — omissions are listed in `omitted` with a reason and `truncated`
flips true, which propagates into the manifest and into the PR body. Binary
assets are listed by path only; their bytes never cross the wire.

## 8. Closing the secrets loop

Features that introduce new `process.env.*` references need matching Bitwarden
secrets. `onboard-app.sh --scan-env` does exactly that, but was unreachable after
onboarding — the three exists-guards fire first.

`onboard-app.sh --scan-only` (added with this work) skips both the generation and
registration regions, runs only the scan plus BWS creation, and **merges** into
`secrets/<app>.json` rather than rewriting it. Rewriting would have dropped every
mapping created at onboard time and quietly broken `sync-secrets`.

It implies `--no-pr`, and refuses loudly (exit 1, file untouched) if it finds
secrets to create but `bws` cannot create them — a half-applied secret map is
worse than none.

The agent lists new env vars under `NEW ENV VARS` in its summary so this is a
mechanical follow-up rather than a discovery exercise.

## 9. Deployment prerequisites

Neither the action nor the lane works until all of these land:

1. `showcase` — deploy the `showcases:source` scope and the
   `/v1/showcases/{id}/source` route.
2. **Grant `showcases:source`** to the credential behind coreyalan.com's
   `SHOWCASE_API_KEY`. Nothing else fails as visibly: the route answers 503 and
   `fetch` exits non-zero.
3. `coreyalan.com` — deploy `/api/scaffold/demo/[slug]`.
4. `homelab-infra` — sync `scaffolder/` for the `scaffolder-scaffold-read`
   ExternalSecret; the pipeline is git-resolved from `main`, so merging is enough.
5. `platform-infra` — merge `.tekton/implement-spec-incoming.yaml`.
6. **`gvisor` RuntimeClass must exist on the cluster the lane runs on**
   (`tekton/runtimeclasses/gvisor.yaml`, handler `runsc`, installed by
   `node-bootstrap/gvisor/install-runsc.sh` — or, post-ADR-0022, the Talos system
   extension). Without it the render pod does not schedule and the run fails.
7. Mirror or pull-check the `render-image` (Playwright/Chromium). It is the one
   image here not already in use by the scaffolder lane.
8. `terraform apply` in `platform-infra/terraform/environments/prod` **last** —
   `port-implement-spec.tf` (new) and the `spec_url` input on
   `port-scaffold-app.tf`. Until the PipelineRuns exist, applying first leaves
   buttons in Port that 500.

## 10. Open

- **Thinning `app-template`** (§4) — the real ceiling on design fidelity.
- **Render placement.** The render task runs in `scaffolder` with a gVisor pod
  spec rather than in a `*-builds-untrusted` namespace, because Tekton cannot
  place one task of a PipelineRun in another namespace. The containment is
  equivalent (sandbox + no SA token + no egress) but it is not the ADR-0017 tier
  proper. Revisit if the render ever needs more than `file://`.
- **Render at upload instead of at read.** Doing it in the showcase extract job
  would pay the cost once per demo rather than once per scaffold, at the price of
  a browser inside a SOC-2-in-scope service plus a backfill. Worth it only if
  demos get scaffolded often.
