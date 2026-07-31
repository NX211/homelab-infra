# Node bootstrap: Kata Containers (kata)

The Tekton build platform uses `runtimeClassName: kata` for **native/NDK**
channels that gVisor's userspace kernel can't run — the **Android** builds, both
the trusted release (`android-build`) and the untrusted branch check
(`android-pr`). k3s does **not** auto-detect kata, so each node that schedules
those pods needs the kata binaries + a containerd runtime entry. This is
node-level (**not GitOps**); the script + steps are tracked here so they're
version-controlled and identical across nodes — mirrors `node-bootstrap/gvisor/`.

> **Why this exists:** the `kata` RuntimeClass
> (`tekton/runtimeclasses/kata.yaml`) was created before the handler was
> installed on any node, so kata pods land on nodes without the runtime and fail
> with `FailedCreatePodSandBox: no runtime for "kata" is configured`. Until this
> runs on the build nodes, **both** the untrusted android build_branch lane and
> the trusted android release build cannot schedule.

## Prerequisite

Each target node needs **KVM** (`/dev/kvm`) — kata's QEMU hypervisor. The
bare-metal homelab nodes have it (kata runs natively, no nested virt). The
installer preflights this and aborts if missing.

## Which nodes?

Every node a kata (android) build pod can land on. With no build-node taint,
that's **all worker nodes** (blacktalon, greytalon, redtalon, yellowtalon) — same
as runsc/gVisor. To dedicate a build node instead, taint+label it and add a
matching nodeSelector/toleration to the android pipeline podTemplates (ask first —
it changes the build-catalog + the `.tekton/android-*.yaml`).

## Install (per node, has sudo)

```bash
# copy install-kata.sh to the node, then:
sudo KATA_RELEASE=latest ./install-kata.sh
```

Pin `KATA_RELEASE` to a dated release (e.g. `3.13.0`) for reproducibility. The
script installs `kata-static` to `/opt/kata`, symlinks `containerd-shim-kata-v2`
onto containerd's PATH, appends the `runtimes.kata` block to the k3s containerd
template (preserving the existing `runsc` block), and restarts k3s.

> ⚠️ It restarts k3s. On the **server** node (blacktalon) that's a brief API
> blip — do it last / during a quiet window. Agent nodes just drain their pods.

## Verify

```bash
kubectl get runtimeclass kata
kubectl run katatest --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata"}}' --command -- sh -c 'uname -a'
kubectl logs katatest    # kata reports its guest-VM kernel -> sandbox works
kubectl delete pod katatest
```

Then re-run an android build_branch (Port → channel=android) or a trusted android
release; the pod should schedule and run under kata.
