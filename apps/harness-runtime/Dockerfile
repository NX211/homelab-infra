# Runtime image for the implement-spec verification harness (build-catalog/
# pipelines/implement-spec.yaml). One image for every task in that lane:
#   - fetch/implement/publish need node + git + curl + openssl + python3
#   - render + the verifier need headless Chromium
# Node 24 (not the Playwright image's node 22) so the harness matches the
# fleet's `engines: node >=24` — a real build/boot, not an engine-warning
# approximation. Chromium comes from Playwright 1.55.0 so it matches the
# playwright MODULE the fetch task vendors onto the workspace.
FROM node:24-bookworm

# git/curl/openssl are in node:24-bookworm; python3 (the harness's inline
# JSON/parse blocks) and ca-certificates are added explicitly.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Chromium + its OS deps, world-readable so a non-root runtime uid can run it.
# Version-locked to the vendored playwright module (1.55.0); bump both together.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx --yes playwright@1.55.0 install --with-deps chromium \
    && chmod -R a+rX /ms-playwright \
    && rm -rf /var/lib/apt/lists/* ~/.npm
