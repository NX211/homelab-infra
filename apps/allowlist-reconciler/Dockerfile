# Distroless: no shell, runs as nonroot, read-only-rootfs friendly. The base
# image's entrypoint is `node`, so CMD is just the script path.
# debian13 base: debian12's libssl3 3.0.18 carries CVE-2026-31789 (critical)
# with no rebuilt distroless image available; node 20 is also past EOL.
FROM gcr.io/distroless/nodejs22-debian13:nonroot

WORKDIR /app
COPY package.json ./
COPY src ./src

ENV NODE_ENV=production
EXPOSE 8080
USER nonroot

CMD ["src/index.mjs"]
