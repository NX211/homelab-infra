# Node bootstrap: gVisor (runsc)

The Tekton **untrusted build tier** runs arbitrary PR code under gVisor
(`runtimeClassName: gvisor`). k3s does **not** auto-detect runsc (its auto-detect
list is only crun/spin/wasm*), so each node that schedules those pods needs the
runsc binary + a containerd runtime entry. This is node-level (not GitOps); the
script + template are tracked here so the steps are version-controlled and
identical across nodes.

## Which nodes?

Every node an untrusted build pod can land on. With no taints, that's **all
nodes**. To limit it, dedicate a build node instead:

```bash
kubectl taint  node <build-node> build.capturly/tier=untrusted:NoSchedule
kubectl label  node <build-node> build.capturly/runtime=gvisor
# then add a matching nodeSelector + toleration to the untrusted pipeline pods
# (ask before doing this — it changes the build-catalog podTemplates)
```

## Install (per node, has sudo)

```bash
# copy install-runsc.sh to the node, then:
sudo RUNSC_RELEASE=latest ./install-runsc.sh
```

Pin `RUNSC_RELEASE` to a dated release (e.g. `20250910`) for reproducibility.

## Verify

```bash
kubectl get runtimeclass gvisor
kubectl run gvtest --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' --command -- sh -c 'uname -a'
kubectl logs gvtest   # gVisor reports a synthetic kernel -> sandbox works
kubectl delete pod gvtest
```

## Making it fully GitOps (optional, later)

Node bootstrap can be automated + Argo-synced if manual runs become painful:

- **system-upgrade-controller `Plan`** — a CRD that runs a host-privileged Job on
  matching nodes; put the Plan (running this script) in `argocd/applications/`.
- **Privileged installer DaemonSet** — mounts the host FS, installs runsc, writes
  the tmpl, drains/reboots. More invasive.

Both are heavier than a 4-node homelab needs today; the tracked script is the
pragmatic middle ground (version-controlled *how*, manual *apply*).

## Kata (later)

The untrusted **Android/NDK** channel needs Kata, not gVisor (gVisor can't run
some native syscalls). Kata has an official `kata-deploy` DaemonSet (GitOps-able)
— add it when that channel lands (design §1/§8).
