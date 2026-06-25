# Distroless: no shell, runs as nonroot, read-only-rootfs friendly. The base
# image's entrypoint is `node`, so CMD is just the script path.
FROM gcr.io/distroless/nodejs20-debian12:nonroot

WORKDIR /app
COPY package.json ./
COPY src ./src

ENV NODE_ENV=production
EXPOSE 8080
USER nonroot

CMD ["src/index.mjs"]
