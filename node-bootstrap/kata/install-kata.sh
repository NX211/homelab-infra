#!/usr/bin/env bash
# Install Kata Containers (kata-static) and register it as a k3s containerd
# runtime, so pods with runtimeClassName: kata can schedule on this node — the
# Tekton untrusted native/NDK channel (Android). Run as a user with sudo on
# EVERY node that will schedule kata build pods.
#
# NOT GitOps: this touches node binaries + /var/lib/rancher/k3s and restarts k3s.
# Tracked here only so the steps are version-controlled + identical across nodes.
# Idempotent — safe to re-run (e.g. after a node rebuild). Requires KVM
# (/dev/kvm) — bare-metal homelab nodes have it (kata runs natively, no nested virt).
set -euo pipefail

# Pin a dated kata release for reproducibility (https://github.com/kata-containers/kata-containers/releases).
# "latest" is convenient but unpinned — set e.g. 3.13.0 for prod repeatability.
KATA_RELEASE="${KATA_RELEASE:-latest}"

echo "== 0/3 preflight: KVM present =="
[ -e /dev/kvm ] || { echo "ERROR: /dev/kvm missing — kata's QEMU hypervisor needs it"; exit 1; }

echo "== 1/3 install kata-static + shim =="
case "$(uname -m)" in
  x86_64)  KARCH=amd64 ;;
  aarch64) KARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
if [ "$KATA_RELEASE" = latest ]; then
  KATA_RELEASE="$(curl -sfL https://api.github.com/repos/kata-containers/kata-containers/releases/latest \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')"
fi
# Resolve the kata-static asset from the release API — the compression format
# changed across releases (.tar.xz on <=3.20, .tar.zst on >=3.28), so hardcoding
# the extension breaks. Match kata-static-<ver>-<arch>.tar.{zst,xz} for this arch.
url="$(curl -sfL "https://api.github.com/repos/kata-containers/kata-containers/releases/tags/${KATA_RELEASE}" \
  | python3 -c 'import sys,json,re;d=json.load(sys.stdin);arch=sys.argv[1];u=[a["browser_download_url"] for a in d.get("assets",[]) if re.fullmatch(rf"kata-static-[^/]*-{arch}\.tar\.(zst|xz)",a["name"])];print(u[0] if u else "")' "$KARCH")"
[ -n "$url" ] || { echo "ERROR: no kata-static asset for ${KATA_RELEASE}/${KARCH}"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
fname="${url##*/}"
echo "downloading $url"
curl -sfL "$url" -o "$fname"
case "$fname" in                                                          # extracts ./opt/kata/...
  *.tar.zst) sudo tar --zstd -xf "$fname" -C / ;;   # kata >= 3.28 (nodes have GNU tar --zstd + zstd)
  *.tar.xz)  sudo tar -xf "$fname" -C / ;;          # kata <= 3.20
  *) echo "ERROR: unknown asset format: $fname"; exit 1 ;;
esac
sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2  # on containerd PATH
cd /

echo "== 2/3 register the runtime in k3s containerd (detect containerd 1.x vs 2.x) =="
cdir=/var/lib/rancher/k3s/agent/etc/containerd
if [ -f "$cdir/config-v3.toml" ]; then
  tmpl="$cdir/config-v3.toml.tmpl"; plugin='io.containerd.cri.v1.runtime'   # containerd 2.x
else
  tmpl="$cdir/config.toml.tmpl";     plugin='io.containerd.grpc.v1.cri'     # containerd 1.x
fi
block=$(printf '[plugins."%s".containerd.runtimes.kata]\n  runtime_type = "io.containerd.kata.v2"\n  [plugins."%s".containerd.runtimes.kata.options]\n    ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration.toml"\n' "$plugin" "$plugin")
if [ -f "$tmpl" ]; then
  # Preserve existing customizations (e.g. the runsc block); append kata only if missing.
  if ! sudo grep -q 'runtimes.kata' "$tmpl"; then
    printf '\n%s\n' "$block" | sudo tee -a "$tmpl" >/dev/null
  fi
else
  # k3s renders config from this tmpl; {{ template "base" . }} keeps k3s's base.
  printf '{{ template "base" . }}\n\n%s\n' "$block" | sudo tee "$tmpl" >/dev/null
fi
echo "wrote/updated: $tmpl (plugin: $plugin)"

echo "== 3/3 restart k3s to re-render containerd config =="
# Restart whichever unit is active (server runs k3s, agents k3s-agent).
if systemctl is-active --quiet k3s; then
  sudo systemctl restart k3s          # server node (blacktalon) — brief API blip
elif systemctl is-active --quiet k3s-agent; then
  sudo systemctl restart k3s-agent    # agent node
else
  echo "WARN: neither k3s nor k3s-agent is active — restart the k3s unit manually."
fi

echo "== done. verify: sudo grep -A3 runtimes.kata ${cdir}/config*.toml =="
