# Slim clone toolchain for the trusted container-build channel (ADR-0020).
# Bakes exactly what the App-token clone step needs — git, openssl (JWT signing),
# python3 (JSON parse), curl (GitHub API), bash — so the step runs non-root under
# Tekton set-security-context (H1) with no runtime `apk add`. Pin by digest in the
# pipeline once pushed.
#
#   docker build -t ghcr.io/nx211/clone-toolchain:0.1.0 build-catalog/images/clone-toolchain
#   docker push ghcr.io/nx211/clone-toolchain:0.1.0      # needs ghcr write:packages
#   # then pin the pushed digest in build-catalog/pipelines/container-build.yaml
FROM alpine:3.24
RUN apk add --no-cache git openssl python3 curl bash \
    && adduser -D -u 1000 build
USER 1000
