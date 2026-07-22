# Generic web/nextjs build toolchain (Node 22 + pnpm), used as the step image for
# the nextjs-build `web-ci` task across projects. Tools are PRE-BAKED so steps run
# WITHOUT root at runtime (no `corepack enable`, which writes to /usr/local) —
# required once set-security-context (H1) forces runAsNonRoot on all steps.
#
# node:22-bookworm (full, not slim) includes git + python3/make/g++ for any deps
# with native (node-gyp) builds. pnpm is installed globally and is world-readable,
# so an arbitrary non-root uid can run it.
FROM node:26-bookworm

RUN npm install -g pnpm@9.15.9 \
    && npm cache clean --force \
    && chmod -R a+rX /usr/local/lib/node_modules
