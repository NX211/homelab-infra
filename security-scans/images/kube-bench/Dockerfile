# kube-bench built from a pinned upstream commit: k3s-cis-1.11 (the newest k3s
# profile) is on main but not yet in a release. The binary and cfg/ come from the
# same commit, so the evidence names one exact benchmark source.
#
# Ubuntu rather than the upstream Alpine image: the k3s checks read k3s's startup
# arguments from the node's journal, and an Alpine image has no journalctl that
# can read it. Without one, those checks print a passing default instead.
FROM docker.io/library/golang:1.26.5@sha256:705e964a93a2fd2e75c7d59bb7d781b57e30f12293ffde5175c69229e18fb678 AS build
ARG KUBE_BENCH_COMMIT=e278a5915a982f2756026de6e2f9ca77077ef9f9
ADD --checksum=sha256:88a07d82f1b444448e2653798852d42e223262540423723f3cc3a867a95eba83 \
    https://github.com/aquasecurity/kube-bench/archive/${KUBE_BENCH_COMMIT}.tar.gz /tmp/src.tgz
WORKDIR /src
RUN tar -xzf /tmp/src.tgz --strip-components=1 \
 && CGO_ENABLED=0 go build -trimpath \
      -ldflags "-X github.com/aquasecurity/kube-bench/cmd.KubeBenchVersion=${KUBE_BENCH_COMMIT}" \
      -o /out/kube-bench . \
 && cp -r cfg /out/cfg

FROM docker.io/library/ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b
ARG KUBE_BENCH_COMMIT=e278a5915a982f2756026de6e2f9ca77077ef9f9
ARG KUBECTL_VERSION=v1.35.9
# The policies checks run kubectl with the pod's service account.
ADD --checksum=sha256:3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb \
    https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl /usr/local/bin/kubectl
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd procps jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && chmod 0755 /usr/local/bin/kubectl \
 && echo "${KUBE_BENCH_COMMIT}" > /etc/kube-bench-commit
COPY --from=build /out/kube-bench /usr/local/bin/kube-bench
COPY --from=build /out/cfg /opt/kube-bench/cfg
# Shadows /usr/bin/journalctl for the checks only (see the script).
COPY journalctl /usr/local/bin/journalctl
WORKDIR /opt/kube-bench
