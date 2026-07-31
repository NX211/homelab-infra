# Generic web/nextjs build toolchain (Node 22 + pnpm), used as the step image for
# the nextjs-build `web-ci` task across projects. Tools are PRE-BAKED so steps run
# WITHOUT root at runtime (no `corepack enable`, which writes to /usr/local) —
# required once set-security-context (H1) forces runAsNonRoot on all steps.
#
# node:22-bookworm (full, not slim) includes git + python3/make/g++ for any deps
# with native (node-gyp) builds. pnpm is installed globally and is world-readable,
# so an arbitrary non-root uid can run it.
FROM node:22-bookworm

# keytar (native) links against libsecret at build time; node:bookworm ships
# pkg-config but not the libsecret dev headers, so the offline node-gyp build
# fails with "Package libsecret-1 was not found". Provide them.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsecret-1-dev \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@9.15.9 node-gyp \
    && npm cache clean --force \
    && chmod -R a+rX /usr/local/lib/node_modules

# `prisma generate` (workspace postinstalls, e.g. packages/database) bundles the
# query engine, which it fetches from binaries.prisma.sh at generate time —
# blocked in the sandbox. Bake the engine for the consumers' Prisma version and
# point generate at it via PRISMA_QUERY_ENGINE_LIBRARY so it runs offline. Keep
# PRISMA_VERSION in lockstep with capturly's prisma (packages/database).
ENV PRISMA_VERSION=5.22.0 \
    PRISMA_CLI_QUERY_ENGINE_TYPE=library
RUN npm install -g "@prisma/engines@${PRISMA_VERSION}" \
    && mkdir -p /opt/prisma \
    && cp "$(find / -name 'libquery_engine-*.so.node' 2>/dev/null | head -1)" /opt/prisma/libquery_engine.so.node \
    && chmod -R a+rX /opt/prisma \
    && npm cache clean --force
ENV PRISMA_QUERY_ENGINE_LIBRARY=/opt/prisma/libquery_engine.so.node

# --- Offline native-build support (untrusted sandbox: egress = Verdaccio only) ---
# The web-ci `checks` pod can reach ONLY the npm proxy, so any dependency that
# fetches a binary at install time fails (observed: keytar, electron). Pre-bake
# those inputs here, where the network IS available, so postinstall/node-gyp
# resolve entirely offline. Made world-readable for the arbitrary non-root uid.

# node-gyp headers for THIS image's Node version, so native modules (e.g. keytar)
# build from source offline instead of fetching headers from nodejs.org. python3/
# make/g++ already ship in node:22-bookworm.
ENV npm_config_devdir=/opt/node-gyp
RUN node-gyp install --devdir=/opt/node-gyp \
    && chmod -R a+rX /opt/node-gyp

# electron ships a large runtime binary the web lint/type-check/build/test never
# executes, downloaded from a CDN the sandbox can't reach; skip that download.
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1
