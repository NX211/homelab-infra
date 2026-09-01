#!/usr/bin/env bash
#
# gen-staging-app.sh — generate the staging half of a new app (homelab-infra):
# the staging-apps/<prod-app>/ chart wrapper + the argocd staging-<prod-app>
# Application. "Build once, deploy many" — staging runs the SAME prod image, a
# different config. Called by the scaffolder lane after onboarding; opens a PR.
#
# Naming (matches the existing staging apps):
#   prod-app  = <domain> with dots -> dashes   (myapp.io -> myapp-io)
#   dir       = staging-apps/<prod-app>/
#   Argo app  = staging-<prod-app>   (staging-promote.yml parses this exactly)
#   host      = staging.<domain>
#
# Some values can't be derived and are emitted as PLACEHOLDER for a reviewer to
# fill at the final gate (they need a human/first-run action):
#   - bitwarden.projectID          — create a per-app staging BWS project
#   - bitwarden.credentialsSecret  — one-time ESO bootstrap secret in
#                                    external-secrets-system (scoped to that project)
#   - image.digest                 — seeded empty; CI's gitops-staging-update fills it
#   - ipAllowList.appName          — must equal the StagingSite.infraAppName in the admin UI
#
# Usage:
#   ./scripts/gen-staging-app.sh --name <slug> --domain <domain> --company <display> \
#     [--gcp-project <id>] [--database] [--repo-root <path>] [--no-pr]
set -euo pipefail

NAME="" DOMAIN="" COMPANY="" GCP_PROJECT="" DATABASE=false REPO_ROOT="." OPEN_PR=true
while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2;;
    --domain)      DOMAIN="$2"; shift 2;;
    --company)     COMPANY="$2"; shift 2;;
    --gcp-project) GCP_PROJECT="$2"; shift 2;;
    --database)    DATABASE=true; shift;;
    --repo-root)   REPO_ROOT="$2"; shift 2;;
    --no-pr)       OPEN_PR=false; shift;;
    -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done
[ -n "$NAME" ]    || { echo "--name is required" >&2; exit 1; }
[ -n "$DOMAIN" ]  || { echo "--domain is required" >&2; exit 1; }
[ -n "$COMPANY" ] || { echo "--company is required" >&2; exit 1; }
GCP_PROJECT="${GCP_PROJECT:-$NAME}"

# The staging dir/app slug must equal the app NAME: gitops-trigger's
# staging.appMap values (set by onboard-app.sh) key digest bumps to
# staging-apps/<name>. Every legacy app's name equals its domain slug, so this
# changes nothing for them; reggiesbbq (name != domain slug) surfaced the split.
PROD_APP="$NAME"
IMAGE_REPO="us-central1-docker.pkg.dev/${GCP_PROJECT}/${GCP_PROJECT}/${NAME}-web"
STAGING_ORG_ID="4650c1c8-8d22-4073-8a7d-b3cf011d5ff2"      # constant across staging apps
# Read the subchart version from the chart itself — a hardcoded constant went
# stale (0.7.2 vs 0.8.1) and broke ArgoCD dependency builds for new apps.
CHART_VER="$(awk '/^version:/ {print $2; exit}' "${REPO_ROOT}/charts/staging-app/Chart.yaml")"
[ -n "$CHART_VER" ] || { echo "could not read charts/staging-app version" >&2; exit 1; }
DIR="${REPO_ROOT}/staging-apps/${PROD_APP}"
APP_FILE="${REPO_ROOT}/argocd/applications/staging-${PROD_APP}.yaml"

echo "=== gen-staging: ${PROD_APP}  (host=staging.${DOMAIN}, db=${DATABASE}) ==="
mkdir -p "$DIR"

# --- Chart.yaml --------------------------------------------------------------
cat > "${DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: ${PROD_APP}-staging
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
  DB_BLOCK=$'  database:\n    enabled: true\n    superuser:\n      create: false # uses the shared postgres-superuser-staging secret\n  migration:\n    enabled: true'
else
  DB_BLOCK=$'  database:\n    enabled: false\n  migration:\n    enabled: false'
fi

cat > "${DIR}/values.yaml" <<EOF
# ${COMPANY} - Staging Values
# Build once, deploy many: same image as prod, different config.

staging-app:
  appName: ${NAME}
  appLabel: ${COMPANY}
  fullnameOverride: ${PROD_APP}-staging
  replicaCount: 1
  # Per-app Bitwarden staging store (least privilege). TODO(scaffold): create a
  # staging BWS project for this app and put its id here; bootstrap the
  # credentialsSecret (a BWS access token scoped to that project) as a K8s secret
  # in external-secrets-system — one-time, same pattern as the other staging apps.
  bitwarden:
    projectID: "PLACEHOLDER-create-staging-bws-project"
    organizationID: "${STAGING_ORG_ID}"
    credentialsSecret: bitwarden-staging-${NAME}-credentials
${DB_BLOCK}
  image:
    repository: ${IMAGE_REPO}
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
      # TODO(scaffold): appName MUST equal the StagingSite.infraAppName entered in
      # the admin UI for review-access to resolve. Defaulted to the prod-app name.
      appName: ${PROD_APP}
  env:
    - name: NODE_ENV
      value: production
    - name: APP_ENV
      value: staging
EOF

# --- argocd/applications/staging-<prod-app>.yaml -----------------------------
mkdir -p "$(dirname "$APP_FILE")"
cat > "$APP_FILE" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  # Name follows the \`staging-<prod-app-name>\` convention so staging-promote.yml
  # (\`ARGO_APP="staging-\${APP_NAME}"\`), the gitops-trigger STAGING_APP_MAP, and the
  # PR branch naming all line up without per-app special cases.
  name: staging-${PROD_APP}
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: ${PROD_APP}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/NX211/homelab-infra.git
    targetRevision: HEAD
    path: staging-apps/${PROD_APP}
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  # The allowlist-reconciler owns this Middleware's sourceRange (base ∪ reviewer
  # IPs); ignore it so selfHeal won't revert runtime writes.
  ignoreDifferences:
    - group: traefik.io
      kind: Middleware
      name: ${PROD_APP}-staging-ipallowlist
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

# --- optional PR -------------------------------------------------------------
if $OPEN_PR; then
  BRANCH="scaffold/staging-${PROD_APP}"
  git -C "$REPO_ROOT" checkout -b "$BRANCH"
  git -C "$REPO_ROOT" add "staging-apps/${PROD_APP}" "argocd/applications/staging-${PROD_APP}.yaml"
  git -C "$REPO_ROOT" commit -q -m "feat(staging): add ${PROD_APP} staging environment

Generated by gen-staging-app.sh (scaffolder lane). Runs the same prod image as
staging.${DOMAIN}. Reviewer TODOs before first deploy: create the staging BWS
project + credentialsSecret bootstrap, and confirm ipAllowList.appName matches
the StagingSite.infraAppName in the admin UI."
  git -C "$REPO_ROOT" push -u origin "$BRANCH"
  gh pr create --repo NX211/homelab-infra \
    --title "feat(staging): add ${PROD_APP} staging environment" \
    --body "Staging half of the ${COMPANY} scaffold. Same prod image, deployed at \`staging.${DOMAIN}\`.

**Reviewer TODOs before first deploy** (flagged inline):
- Create a per-app **staging Bitwarden project** → put its id in \`bitwarden.projectID\`.
- Bootstrap \`bitwarden-staging-${NAME}-credentials\` (BWS token scoped to that project) in \`external-secrets-system\`.
- Confirm \`ipAllowList.appName\` (\`${PROD_APP}\`) equals the \`StagingSite.infraAppName\` in the admin UI.
- \`image.digest\` seeds empty; CI's gitops-staging-update fills it from the first prod build." || echo "  (gh pr create skipped/failed — files are committed on ${BRANCH})"
fi
