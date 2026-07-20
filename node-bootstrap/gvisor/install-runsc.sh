#!/usr/bin/env bash
# Install gVisor (runsc) and register it as a k3s containerd runtime, so pods with
# runtimeClassName: gvisor can schedule on this node. Run as a user with sudo on
# EVERY node that will schedule untrusted build pods (Tekton untrusted tier).
#
# NOT GitOps: this touches node binaries + /var/lib/rancher/k3s and restarts k3s.
# It is tracked here only so the steps are version-controlled + identical across
# nodes. Idempotent — safe to re-run (e.g. after a node rebuild).
set -euo pipefail

# Pin a dated gVisor release for reproducibility (https://github.com/google/gvisor/releases).
# "latest" is convenient but unpinned — set a date like 20250910 for prod repeatability.
RUNSC_RELEASE="${RUNSC_RELEASE:-latest}"

echo "== 1/3 install runsc + shim =="
ARCH="$(uname -m)"
URL="https://storage.googleapis.com/gvisor/releases/release/${RUNSC_RELEASE}/${ARCH}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
for f in runsc containerd-shim-runsc-v1; do
  wget -q "${URL}/${f}" "${URL}/${f}.sha512"
done
sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
chmod a+rx runsc containerd-shim-runsc-v1
sudo mv runsc containerd-shim-runsc-v1 /usr/local/bin/   # must be on k3s containerd's PATH
cd /

echo "== 2/3 register the runtime in k3s containerd (detect containerd 1.x vs 2.x) =="
cdir=/var/lib/rancher/k3s/agent/etc/containerd
if [ -f "$cdir/config-v3.toml" ]; then
  tmpl="$cdir/config-v3.toml.tmpl"; plugin='io.containerd.cri.v1.runtime'   # containerd 2.x
else
  tmpl="$cdir/config.toml.tmpl";     plugin='io.containerd.grpc.v1.cri'     # containerd 1.x
fi
block=$(printf '[plugins."%s".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' "$plugin")
if [ -f "$tmpl" ]; then
  # Preserve any existing customizations; append runsc only if missing.
  if ! sudo grep -q 'runtimes.runsc' "$tmpl"; then
    printf '\n%s\n' "$block" | sudo tee -a "$tmpl" >/dev/null
  fi
else
  # k3s renders config from this tmpl; {{ template "base" . }} keeps k3s's
  # auto-generated base (crun/spin/wasm* runtimes) and we add runsc.
  printf '{{ template "base" . }}\n\n%s\n' "$block" | sudo tee "$tmpl" >/dev/null
fi
echo "wrote/updated: $tmpl (plugin: $plugin)"

echo "== 3/3 restart k3s to re-render containerd config =="
if systemctl list-unit-files 2>/dev/null | grep -q '^k3s\.service'; then
  sudo systemctl restart k3s          # server node (e.g. blacktalon)
else
  sudo systemctl restart k3s-agent    # agent node
fi

echo "== done. verify: sudo grep -A2 runsc ${cdir}/config*.toml =="
