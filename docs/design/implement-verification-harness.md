# Design: the implement-spec verification harness

Gate 2 of the phase-2 gap analysis (platform-infra artifact "The Proving
Ground", 2026-09-13). Rebuilds the inner loop of the `implement` stage so the
lane proves its output works before a PR opens. Companion to
[scaffold-implement-lane.md](scaffold-implement-lane.md), which stays the
authority on the lane's credential architecture — nothing here weakens it.

**Locked decisions (2026-09-14):** agent gets a real dev environment + Bash ·
"done" is denied until the repo's own gates pass · verification by a
fresh-context verifier that exercises the RUNNING app · bounded loops with
hard budgets · a failed verification still publishes, as a DRAFT PR with the
defect list — evidence over silence.

## 1. Why

The reggiesbbq retrospective (156 intervention commits) proved the failure
class: the delivered app compiled, deployed Synced, and could not take money,
log an admin in, or receive a real webhook. Root cause: the agent ran with
`--permission-mode acceptEdits`, no Bash, no installed dependencies — it could
never execute anything it wrote, and nothing between it and `gh pr create`
checked. Every mature operator of headless coding agents (Spotify, Replit,
Cognition, OpenHands V1, Cursor) converged on the same countermeasure: an
execution environment plus a verification stage that demands evidence.

## 2. Shape — same pipeline, a rebuilt middle

The four-task split and its credential boundaries are untouched. The
`implement` task becomes four steps sharing the task pod (one scheduling, one
set of mounts, sidecars alive throughout), and `publish` learns to publish
drafts:

```
fetch  ──  render  ──  implement ────────────────────────────────  publish
                        ├─ step 1 setup      (toolchain image)      draft PR
                        ├─ step 2 agent      (toolchain image)      when verify
                        ├─ step 3 gates      (toolchain image)      failed
                        └─ step 4 verify     (render/playwright image)
                        sidecar: postgres:16 (trust auth, localhost)
```

Steps in one Tekton task share the workspace and run sequentially in the same
pod — that is what lets step 4 use the Playwright image (browsers) while the
agent runs on the toolchain image, with the database sidecar alive for both.

## 3. The steps

**setup** — `corepack enable`, `pnpm install --frozen-lockfile`, prisma
generate + `migrate deploy` against the sidecar, seed if `prisma/seed` exists,
`pnpm build` of the UNMODIFIED tree. A baseline that does not build fails the
run HERE, before any tokens burn — "agents guessing in half-built
environments" is the field's top reported failure. Installs `claude-code` and
`gh` once into a workspace prefix so later steps spend nothing. Writes
`.implement/baseline.json` (build ok, test count, lint count) for the gates
step to diff against.

**agent** — the same quoted-heredoc prompt contract as today, plus Bash:
`--permission-mode acceptEdits` stays (edits auto-accepted), and the settings
file we inject allowlists Bash for the repo's own package scripts (`pnpm
test|build|lint|typecheck`, `prisma *`) — enough to self-verify, nothing
host-shaped. Two additions to the harness:

- **Stop hook** (injected via `--settings`, never the repo's own — the repo is
  agent-writable): on stop, run the deterministic gate script; while it fails,
  the hook returns the failure output and denies completion, max 3 denials
  before the run proceeds to step 3 anyway (the gates step is the enforcement;
  the hook is the cheap inner loop).
- **Budgets**: `--max-turns` (default 200) and a task-level `timeout` (default
  75m) as the hard walls. Cost per run lands in the PR body from the
  `claude -p --output-format json` result.

**gates** — deterministic, no LLM: `pnpm build && pnpm lint && pnpm
typecheck && pnpm test` on the modified tree, compared against baseline (a
run may not REDUCE the test count — deleting failing tests is the classic
agent dodge). Failures write `.implement/gates.json` and the run continues —
the verdict travels; it does not vanish.

**verify** — the fresh-context half, on the Playwright image:

1. Boot the app (`pnpm start`, sidecar DB already migrated/seeded), wait for
   the health path.
2. Run a **verifier `claude -p`** — a NEW context that has never seen the
   builder's reasoning (Cognition: the unshared context is WHY it catches ~2
   bugs/PR). It receives the spec, the demo manifest + screenshots, the diff
   stat, and tool access scoped to: Playwright against localhost, read-only
   repo, `psql` read-only. Its brief: exercise what the spec claims — every
   role logs in, the primary user flow end-to-end, forms actually submit,
   empty states render — and emit `.implement/verify.json`:
   `{verdict: pass|fail, findings: [{severity, claim, evidence}], screenshots: [...]}`.
   Evidence is mandatory per finding; assertions without command output or a
   screenshot are discarded by the schema check.
3. One **rework cycle**: on `fail`, re-invoke the builder agent once with
   ONLY the findings list (not the verifier's transcript), then re-run gates +
   verifier. Two verifier failures = park. Never more (Stripe's 2-cycle cap;
   unbounded loops are the $47k failure mode).

**publish** — unchanged mechanics (fresh clone, transplant, minted token) plus:
`--draft` when `verify.json` says fail or is missing, PR body gains a
**Verification** section — gates table, verifier verdict, findings with
evidence, cost, and the run's screenshot inventory (files stay on the run PVC
for now; GCS upload is Gate 6's provenance work). A draft PR with a defect
list beats both silence and a confident broken PR.

## 4. What the agent may now touch

Bash allowlist (injected settings, exact-match on command prefixes): the
repo's `pnpm` scripts, `prisma`, `node scripts/*` within the repo. Explicitly
NOT: `git` (publish owns history), `gh`, `curl`/`wget` (egress discipline),
anything absolute-pathed. The injected settings file also sets
`permissions.deny` on reading `../github-app` paths — defence in depth; the
workspace layout already keeps credentials out of reach (nothing is mounted
in the implement pod, unchanged).

Egress for the implement pod stays as today (public 443): the agent may need
registry access for dependencies it legitimately adds, and the build-platform
Verdaccio route is a Phase-2 tightening (see §7) — not a blocker for the
harness.

## 5. Failure modes and their verdicts

| Condition | Outcome |
|---|---|
| Baseline build fails in setup | Run fails before the agent starts (env bug, not app bug) |
| Agent exhausts turns/timeout | Gates + verify still run on whatever exists; draft PR with partial-work verdict |
| Gates fail after rework cycle | Draft PR, gates table shows red, findings attached |
| Verifier finds defects twice | Draft PR ("parked"), findings with evidence |
| Everything green | Ready-for-review PR, verification section all green |
| App will not boot in verify | Finding of severity `blocker` with the boot log as evidence; draft PR |

The lane still NEVER merges anything.

## 6. Cost

Setup adds ~2–4 min (pnpm install + build; the template's turbo cache helps).
The verifier is a second, cheaper agent session (~10–20% of the builder,
Replit reports ~$0.20/session for the equivalent). The rework cycle at most
doubles the builder. Budget walls make the worst case a known number:
`(2 × builder cap) + (2 × verifier cap)` inside a 75m task timeout.

## 7. Deferred (tracked, not forgotten)

- **Registry-proxy egress for the agent phase** (route installs through the
  build platform's Verdaccio, deny direct 443) — Codex-style two-phase egress.
- **GCS evidence upload + Port `agent_run` provenance** — Gate 6.
- **Spec-conformance auditor with per-REQ verdicts** — needs Gate 3's EARS
  requirement IDs; the verifier's brief gains it then.
- ~~**Computed-style design-fidelity gate vs the demo tokens** — Gate 4.~~
  SHIPPED (2026-09-14): the render task distills `demo/tokens.json` /
  `theme.css` / `style-map.json` / `tree/*.json` from the live DOM (Oklab
  clustering, inline); `build-verify` runs a deterministic fidelity checker
  (`fidelity.cjs`: palette coverage, role colors, fonts, type ratio, radii;
  pass ≥ 80) against the booted app, then up to 5 design-only style rounds —
  accept-only-if-improved, hard-reverted on any write outside the token
  surface (`design-scope` param: `tokens` | gated `layout` tier). Surface
  violations and measured fidelity failures fail the run (draft PR);
  checker errors degrade open, loudly. Repo-side contract:
  app-template `docs/DESIGN.md` + `check-style-surface.mjs` CI gate.
- **Warm per-repo environment images** (Devin snapshots / Cursor Builds) —
  revisit when run frequency justifies the cache infrastructure.

## 8. Rollout

1. This doc.
2. Pipeline changes behind a new `verify` param (default `"true"`; `"false"`
   restores today's blind lane as the escape hatch, and the dry-run param is
   orthogonal).
3. Dogfood: Gate 7's proving run scores the first verified PR against the
   reggiesbbq taxonomy before any client work rides on the lane.

## 9. Implementation notes (2026-09-14, first build)

Deviations from §2–3, all deliberate:

- **One image for every implement step** (the pinned Playwright/noble image:
  node 22, git, corepack, browsers). Tekton cannot loop across steps, and the
  rework cycle needs builder → gates → verifier → builder in one script; the
  per-step image split died to that constraint. Steps are `setup` and
  `build-verify`.
- **Gates are CI-parity, not build**: `lint` + `type-check` +
  `test -- --passWithNoTests`, judged **relative to a baseline** captured from
  the unmodified tree (a fix run on an already-red app still lands; a run may
  never turn a green gate red, nor reduce the test-file count). `pnpm build`
  happens in the verify phase as the boot attempt — the template's own CI
  never builds either (build env is deploy-time), so a failed build is a
  verifier finding, not a hard gate.
- **npm read token is a hard prerequisite for harness mode**: the
  `@corey-alan-consulting` packages are private on npmjs, so `pnpm install`
  needs auth. Operator worklist: create a granular read-only token, store in
  BWS (Build Platform project), add ExternalSecret `scaffolder-npm-read`
  (key `token`), bind the `npm` workspace in
  `platform-infra/.tekton/implement-spec-incoming.yaml`. Until then harness
  runs fail at setup with that exact message; `verify: "false"` (legacy) and
  `dry-run` need none of it.
- **Verifier tamper detection**: the verifier has no edit permissions, and the
  harness hashes the tree (plumbing `write-tree` on a temp index) before and
  after — a changed hash voids the verification with a blocker finding.
- **Verdict travels as `.implement/result.json`** (schema-checked, symlink-
  guarded in publish, same discipline as SUMMARY.md); publish renders the
  Verification section from it and adds `--draft` on any non-pass.
