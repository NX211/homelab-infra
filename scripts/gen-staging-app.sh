#!/usr/bin/env bash
#
# gen-staging-app.sh — THE generator for the staging half of an app (homelab-infra):
# the staging-apps/<name>/ chart wrapper, the argocd staging-<name> Application,
# and the three rosters a staging app must be on. "Build once, deploy many" —
# staging runs the SAME prod image with a different config.
#
# One generator on purpose. Until 2026-10-27 platform-infra's onboard-app.sh
# carried its own copy of this logic and the two had drifted: this one emitted
# no probes (the homepage got SSR-rendered on every kubelet tick), no migration
# image, no env/secrets wiring and no CoreDNS entry, while that one never
# registered the smoke suite. onboard-app.sh now calls this script.
#
# Callers:
#   - platform-infra scripts/onboard-app.sh (CLI and scaffold lanes) with --no-pr;
#     the scaffold pipeline's prepare step then commits and opens the PR.
#   - by hand: ./scripts/gen-staging-app.sh ... (opens a PR unless --no-pr).
#
# Writes:
#   staging-apps/<name>/{Chart.yaml,values.yaml}
#   argocd/applications/staging-<name>.yaml
#   ar-token-refresher/refresher.yaml      SECRETS += gcr-pull-secret-<name>
#   coredns/configmap.yaml                 NodeHosts += staging.<domain>
#   .github/workflows/staging-track.yml    SMOKE_REPOS / SMOKE_URLS += <name>
#
# Left for a reviewer (cannot be derived): the staging Bitwarden project id, the
# per-secret UUIDs under externalSecrets.secrets, and the one-time
# bitwarden-staging-<name>-credentials bootstrap secret.
#
# Usage:
#   ./scripts/gen-staging-app.sh --name <slug> --domain <domain> \
#     [--company <display>] [--gcp-project <id>] [--ar-repo <id>] \
#     [--github-repo <org/repo>] [--health-path /api/health] \
#     [--next-cache-path /app/apps/web/.next/cache] [--database] \
#     [--repo-root <path>] [--no-pr]
set -euo pipefail

NAME="" DOMAIN="" COMPANY="" GCP_PROJECT="" AR_REPO="" GITHUB_REPO=""
HEALTH_PATH="/api/health" NEXT_CACHE_PATH="" DATABASE=false REPO_ROOT="." OPEN_PR=true
while [ $# -gt 0 ]; do
  case "$1" in
    --name)            NAME="$2"; shift 2;;
    --domain)          DOMAIN="$2"; shift 2;;
    --company)         COMPANY="$2"; shift 2;;
    --gcp-project)     GCP_PROJECT="$2"; shift 2;;
    --ar-repo)         AR_REPO="$2"; shift 2;;
    --github-repo)     GITHUB_REPO="$2"; shift 2;;
    --health-path)     HEALTH_PATH="$2"; shift 2;;
    --next-cache-path) NEXT_CACHE_PATH="$2"; shift 2;;
    --database)        DATABASE=true; shift;;
    --repo-root)       REPO_ROOT="$2"; shift 2;;
    --no-pr)           OPEN_PR=false; shift;;
    -h|--help)         grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done
[ -n "$NAME" ]   || { echo "--name is required" >&2; exit 1; }
[ -n "$DOMAIN" ] || { echo "--domain is required" >&2; exit 1; }
printf '%s' "$NAME" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "bad --name: $NAME" >&2; exit 1; }
case "$HEALTH_PATH" in /*) ;; *) echo "--health-path must start with /" >&2; exit 1;; esac
[ "$HEALTH_PATH" != "/" ] || { echo "--health-path must not be / (the SSR homepage)" >&2; exit 1; }
COMPANY="${COMPANY:-$DOMAIN}"
GCP_PROJECT="${GCP_PROJECT:-$NAME}"
AR_REPO="${AR_REPO:-$NAME}"
# The app repo carries the staging smoke suite. Every existing app repo is
# named after its domain (coreyalan.com, capturly.app, ...); pass --github-repo
# when the repo breaks that convention (jlshaw.link vs jlshawconsulting.com).
GITHUB_REPO="${GITHUB_REPO:-Corey-Alan-Consulting/${DOMAIN}}"

# The staging dir/app slug must equal the app NAME: gitops-trigger's
# staging.appMap values (set by onboard-app.sh) key digest bumps to
# staging-apps/<name>.
IMAGE_BASE="us-central1-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/${NAME}-web"
STAGING_ORG_ID="4650c1c8-8d22-4073-8a7d-b3cf011d5ff2" # constant across staging apps
# Read the subchart version from the chart itself — a hardcoded constant went
# stale (0.7.2 vs 0.8.1) and broke ArgoCD dependency builds for new apps.
CHART_VER="$(awk '/^version:/ {print $2; exit}' "${REPO_ROOT}/charts/staging-app/Chart.yaml" | tr -d '"')"
[ -n "$CHART_VER" ] || { echo "could not read charts/staging-app version" >&2; exit 1; }
DIR="${REPO_ROOT}/staging-apps/${NAME}"
APP_FILE="${REPO_ROOT}/argocd/applications/staging-${NAME}.yaml"

if [ -e "$DIR" ] || [ -e "$APP_FILE" ]; then
  echo "staging for ${NAME} already exists (${DIR} or ${APP_FILE}); refusing to overwrite" >&2
  exit 3
fi

echo "=== gen-staging: ${NAME}  (host=staging.${DOMAIN}, db=${DATABASE}, health=${HEALTH_PATH}) ==="
mkdir -p "$DIR"

# --- Chart.yaml --------------------------------------------------------------
cat > "${DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: ${NAME}-staging
description: ${COMPANY} - Staging Environment
type: application
version: 1.0.0
appVersion: "0.1.0"
keywords:
  - ${NAME}
  - nextjs
  - staging
maintainers:
  - name: Homelab Admin
dependencies:
  - name: staging-app
    version: "${CHART_VER}"
    repository: "file://../../charts/staging-app"
EOF

# --- values.yaml -------------------------------------------------------------
if $DATABASE; then
  DB_BLOCK="  database:
    enabled: true
    superuser:
      create: false # shares the postgres-superuser-staging secret
    userKey: \"\"     # fill: staging BWS UUID for DB_USER
    passwordKey: \"\" # fill: staging BWS UUID for DB_PASSWORD
    nameKey: \"\"     # fill: staging BWS UUID for DB_NAME
  migration:
    enabled: true
    repository: ${IMAGE_BASE}-migrate
    digest: \"\" # Updated by CI/CD"
else
  DB_BLOCK="  database:
    enabled: false
  migration:
    enabled: false"
fi

{
cat <<EOF
# ${COMPANY} - Staging Values (build once, deploy many: same image as prod).
# Fill the Bitwarden project + secret UUIDs before first sync.
staging-app:
  appName: ${NAME}
  appLabel: ${NAME}
  fullnameOverride: ${NAME}-staging
  replicaCount: 1
  deploymentAnnotations:
    reloader.stakater.com/auto: "true"
  bitwarden:
    projectID: "" # fill: staging BWS project UUID for ${NAME}
    organizationID: "${STAGING_ORG_ID}"
    credentialsSecret: bitwarden-staging-${NAME}-credentials
${DB_BLOCK}
EOF
# The chart default (/app/.next/cache) suits a single-app repo. A monorepo
# standalone build (app-template: apps/web) writes the cache under the workspace
# path; mounting beside it makes image optimisation re-encode on every request.
if [ -n "$NEXT_CACHE_PATH" ]; then
  printf '  nextCachePath: %s\n' "$NEXT_CACHE_PATH"
fi
cat <<EOF
  image:
    repository: ${IMAGE_BASE}
    pullPolicy: IfNotPresent
    digest: "" # Seeded empty; CI's gitops-staging-update.yml fills it from the first prod build
  imagePullSecrets:
    - name: gcr-pull-secret-${NAME}
  gcrPullSecret:
    bitwardenKey: "" # keyless via WIF (ar-token-refresher); ESO does not manage this pull secret
    secretName: gcr-pull-secret-${NAME}
  service:
    type: ClusterIP
    port: 3000
  ingress:
    enabled: true
    host: staging.${DOMAIN}
    clusterIssuer: letsencrypt-prod
    # On-LAN/in-cluster by default; the allowlist-reconciler unions reviewer IPs
    # at runtime from Bitwarden (STAGING_BASE_ALLOWLIST_CIDR stays out of git).
    ipAllowList:
      enabled: true
      sourceRange:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
      reconcilerManaged: true
      # Must equal the StagingSite.infraAppName in the admin UI for review access.
      appName: ${NAME}
  env:
    - name: NODE_ENV
      value: production
    - name: APP_URL
      value: https://staging.${DOMAIN}
    - name: NEXT_PUBLIC_APP_URL
      value: https://staging.${DOMAIN}
    - name: NEXT_PUBLIC_SENTRY_ENVIRONMENT
      value: staging
  envFrom:
    - secretRef:
        name: ${NAME}-staging-secrets
  # Mirror platform-infra secrets/${NAME}.json with STAGING BWS UUIDs once the
  # project exists.
  externalSecrets:
    enabled: true
    secretName: ${NAME}-staging-secrets
    refreshInterval: 1h
    secrets: []
  # Probes, in the staging-app chart's shape (a bare \`path\`). Emitted explicitly
  # because apps pin and vendor the chart. Never \`/\`: that is the marketing
  # homepage, server-rendered on every kubelet tick.
  livenessProbe:
    enabled: true
    path: ${HEALTH_PATH}
    port: 3000
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    enabled: true
    path: ${HEALTH_PATH}
    port: 3000
    initialDelaySeconds: 10
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 3
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 768Mi
EOF
} > "${DIR}/values.yaml"

# --- argocd/applications/staging-<name>.yaml ---------------------------------
mkdir -p "$(dirname "$APP_FILE")"
cat > "$APP_FILE" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  # Name follows the \`staging-<name>\` convention so staging-promote.yml, the
  # gitops-trigger STAGING_APP_MAP and the PR branch naming all line up.
  name: staging-${NAME}
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: ${NAME}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/NX211/homelab-infra.git
    targetRevision: HEAD
    path: staging-apps/${NAME}
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  # The allowlist-reconciler owns this Middleware's sourceRange (base ∪ reviewer
  # IPs); ignore it so selfHeal won't revert runtime writes.
  ignoreDifferences:
    - group: traefik.io
      kind: Middleware
      name: ${NAME}-staging-ipallowlist
      namespace: staging
      jsonPointers:
        - /spec/ipAllowList/sourceRange
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

echo "  wrote ${DIR}/{Chart.yaml,values.yaml}"
echo "  wrote ${APP_FILE}"

# --- rosters -----------------------------------------------------------------
# Register the pull secret with the ar-token-refresher. It is the only writer of
# gcr-pull-secret-<name>; a missing entry means every staging pull 403s
# (gatherbee ImagePullBackOff, 2026-09).
REFRESHER="${REPO_ROOT}/ar-token-refresher/refresher.yaml"
if ! grep -qE "gcr-pull-secret-${NAME}([ \"]|\$)" "$REFRESHER"; then
  sed -i.bak "s/^\(    SECRETS=\"[^\"]*\)\"/\1 gcr-pull-secret-${NAME}\"/" "$REFRESHER"
  rm -f "${REFRESHER}.bak"
  grep -qE "gcr-pull-secret-${NAME}([ \"]|\$)" "$REFRESHER" || { echo "ERROR: failed to add gcr-pull-secret-${NAME} to refresher SECRETS" >&2; exit 1; }
  echo "  updated ar-token-refresher/refresher.yaml (SECRETS += gcr-pull-secret-${NAME})"
fi

# Split-horizon DNS: NodeHosts must map the staging host to Traefik's ClusterIP
# or cert-manager's HTTP-01 self-check resolves the WAN IP and dies on hairpin
# NAT (gatherbee cert pending, 2026-09). Appended after the last staging entry,
# reusing its IP.
COREDNS_CM="${REPO_ROOT}/coredns/configmap.yaml"
python3 - "$COREDNS_CM" "staging.${DOMAIN}" <<'PY'
import re, sys
f, host = sys.argv[1:3]
s = open(f).read()
if re.search(r'^\s+\S+ %s$' % re.escape(host), s, flags=re.M):
    sys.exit(0)  # already mapped
entries = list(re.finditer(r'^(    (10\.[0-9.]+) staging\.[^\n]+)$', s, flags=re.M))
if not entries:
    sys.exit('no existing staging NodeHosts entries found in %s' % f)
last = entries[-1]
s = s[:last.end()] + '\n    %s %s' % (last.group(2), host) + s[last.end():]
open(f, 'w').write(s)
print('  updated coredns/configmap.yaml (NodeHosts += %s)' % host)
PY

# Register the app with the staging smoke suite — without SMOKE_REPOS/SMOKE_URLS
# entries the staging-track finalizer treats the app as "no smoke tests" and
# silently skips it forever. Idempotent per map; a missing map WARNs.
TRACK="${REPO_ROOT}/.github/workflows/staging-track.yml"
add_smoke_entry() { # add_smoke_entry <map-name> <value>
  local map="$1" value="$2"
  local marker="declare -A ${map}=("
  local entry="            [\"${NAME}\"]=\"${value}\""
  if [ ! -f "$TRACK" ] || ! grep -qF "$marker" "$TRACK"; then
    echo "  WARN: '${marker}' not found in .github/workflows/staging-track.yml — add [\"${NAME}\"]=\"${value}\" to ${map} manually." >&2
    return 0
  fi
  if grep -qF "[\"${NAME}\"]=\"${value}\"" "$TRACK"; then
    return 0 # already registered
  fi
  # Insert before the map's closing ")" unless the key already exists in it.
  awk -v marker="$marker" -v key="[\"${NAME}\"]" -v entry="$entry" '
    { line = $0 }
    index(line, marker) { inmap = 1; present = 0 }
    inmap && index(line, key) { present = 1 }
    inmap && line ~ /^[[:space:]]*\)[[:space:]]*$/ {
      if (!present) print entry
      inmap = 0
    }
    { print line }
  ' "$TRACK" > "${TRACK}.tmp" && mv "${TRACK}.tmp" "$TRACK"
  if grep -qF "[\"${NAME}\"]=\"${value}\"" "$TRACK"; then
    echo "  updated .github/workflows/staging-track.yml (${map} += ${NAME})"
  else
    echo "  WARN: failed to add ${NAME} to ${map} in staging-track.yml — add it manually." >&2
  fi
}
add_smoke_entry SMOKE_REPOS "$GITHUB_REPO"
add_smoke_entry SMOKE_URLS "https://staging.${DOMAIN}"

echo "  REQUIRED before first sync: create the staging Bitwarden project + machine-account token, then on the staging cluster:"
echo "    kubectl -n external-secrets-system create secret generic bitwarden-staging-${NAME}-credentials --from-literal=token=<BWS access token>"

# --- optional PR -------------------------------------------------------------
if $OPEN_PR; then
  BRANCH="scaffold/staging-${NAME}"
  git -C "$REPO_ROOT" checkout -b "$BRANCH"
  git -C "$REPO_ROOT" add "staging-apps/${NAME}" "argocd/applications/staging-${NAME}.yaml" \
    "ar-token-refresher/refresher.yaml" "coredns/configmap.yaml" ".github/workflows/staging-track.yml"
  git -C "$REPO_ROOT" commit -q -m "feat(staging): add ${NAME} staging environment"
  git -C "$REPO_ROOT" push -u origin "$BRANCH"
  gh pr create --repo NX211/homelab-infra \
    --title "feat(staging): add ${NAME} staging environment" \
    --body "Staging half of ${COMPANY}: the same prod image, deployed at \`staging.${DOMAIN}\`.

**Before first sync:**
- Create the staging Bitwarden project and put its id in \`bitwarden.projectID\`; fill \`externalSecrets.secrets\` with the staging UUIDs.
- Bootstrap \`bitwarden-staging-${NAME}-credentials\` in \`external-secrets-system\`.
- Confirm \`ipAllowList.appName\` (\`${NAME}\`) equals the \`StagingSite.infraAppName\` in the admin UI.
- \`image.digest\` seeds empty; gitops-staging-update fills it from the first prod build." || echo "  (gh pr create skipped/failed — files are committed on ${BRANCH})"
fi
