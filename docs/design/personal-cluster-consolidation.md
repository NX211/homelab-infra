# Design: personal cluster consolidation onto blacktalon

Companion to [`cluster-split.md`](cluster-split.md) (ADR-0022). That document moves the
business estate onto new hardware and states the personal cluster "keeps everything it runs
today" across four nodes. This one covers what happens to the personal side once three of
those four nodes are retired.

**Locked decisions (2026-09-07):** `greytalon`, `redtalon` and `yellowtalon` are retired ·
`blacktalon` (R730xd) keeps the personal cluster · it is rebuilt as **Talos on Proxmox**,
not k3s on Ubuntu · the ZFS pool is preserved and owned by Proxmox.

This settles the "personal cluster's future" item left open in `cluster-split.md` §10.

---

## 1. What changes

| | Today | After |
|---|---|---|
| Nodes | 4 (blacktalon + 3× R630) | **1** (blacktalon) |
| Host OS | Ubuntu 24.04, k3s on bare metal | **Proxmox VE**, Talos in VMs |
| Cluster storage | `local-path` per node + ZFS `hostPath` | Proxmox CSI against the ZFS pool |
| Media | ZFS `hostPath` into pods | ZFS pool stays; reaches VMs indirectly (§4) |
| Ingress | Traefik pinned to `yellowtalon` hostPorts | moves — see §5 |

The business cluster is a rebuild-and-delete because its workloads are stateless or
re-seedable (`cluster-split.md` §1). **This one is not.** The personal side is where the
state lives: 113 TB allocated in the ZFS pool and 36 PVCs on nodes that are going away. It
is a data migration wearing a rebuild's clothing, and should be planned as one.

---

## 2. Capacity: it fits

Measured 2026-09-07.

| Node | Installed | Live usage | Requests | Limits |
|---|---|---|---|---|
| **blacktalon** | **125 Gi** | 18.2 Gi | 21.2 Gi | 65.2 Gi |
| greytalon | 62 Gi | 15.6 Gi | 10.4 Gi | 39.0 Gi |
| redtalon | 62 Gi | 20.4 Gi | 6.6 Gi | 19.9 Gi |
| yellowtalon | 62 Gi | 7.7 Gi | 7.7 Gi | 26.9 Gi |
| **Whole cluster** | ~311 Gi | **~62 Gi** | **~46 Gi** | ~151 Gi |

Requests are what the scheduler reserves, and 46 Gi into 125 Gi is 37%. Live usage at 62 Gi
is half the box. Limits exceed capacity in aggregate, but they already do today (151 Gi
against 311 Gi) and the largest single limit — ArgoCD's controller at 6 Gi — leaves with the
business estate anyway.

CPU is not close: 56 threads against roughly 14 cores of live usage.

Budget for the hypervisor on top: Proxmox itself, and **ZFS ARC, which defaults to half of
RAM**. On a 128 TB pool that default would claim ~62 Gi and leave the VMs fighting for the
rest. `zfs_arc_max` has to be set deliberately, not left at the default.

The R730xd has 24 DIMM slots and takes up to 1.5 TB, so more RAM is available if the VM
layout ends up tighter than this suggests.

---

## 3. The PVC migration

`local-path` binds a PVC to the node that first claimed it, so everything on a retired node
has to be moved by hand.

| Node | PVCs | Allocated | Fate |
|---|---|---|---|
| blacktalon | 25 | 267 Gi | stays |
| **greytalon** | **24** | **350 Gi** | **must move** |
| **redtalon** | **10** | **120 Gi** | **must move** |
| **yellowtalon** | **2** | **2 Gi** | **must move** |

**36 volumes, ~472 Gi allocated.** Allocated is not actual — SeaweedFS holds 43 M against a
100 Gi claim — so measure each volume before sizing the destination. The pool has 15.4 TB
free, so space is not the constraint; the work is.

The set includes real state, not caches: Immich's Postgres, Paperless' media, SeaweedFS'
volume and filer stores, Matrix's Synapse data, and tracearr's TimescaleDB.

**Two storage mechanisms are in play and they migrate differently.** 18 charts mount ZFS
datasets directly by `hostPath` (`/blacktalon/apps/<app>`, ~167 G total); 28 use `local-path`
PVCs. The hostPath set does not move at all — those datasets are already on the pool that
survives. Only the PVC set migrates.

---

## 4. Storage after the rebuild: the part that needs deciding

Talos has no ZFS, so Proxmox owns the pool and the VMs reach it indirectly. Two separate
problems, and they do not have the same answer.

**Cluster PVCs** — Proxmox CSI against the ZFS pool, exactly as `cluster-split.md` §2.2
decides for the business cluster. Same driver, same reasoning, and it removes the node-pinned
`local-path` behaviour that makes §3 painful in the first place.

**The 85 TB media library** — this is the open one. It is not per-app PVC data; it is one
large shared tree that a dozen pods mount read-only or read-write, addressed today as
`hostPath: /blacktalon/media/*`. Options, none free:

| Approach | Trade |
|---|---|
| NFS from the Proxmox host into the VMs | Well-trodden with Talos, survives VM rebuilds, adds a network hop and an NFS server to keep alive |
| virtiofs | Closest to today's `hostPath` semantics; needs verifying that the Talos image supports it |
| Pass the HBA through to a storage VM | Returns ZFS to a VM, but then Proxmox cannot use the pool and the CSI story breaks |

Recommendation is NFS unless virtiofs is confirmed working on the pinned Talos image — but
this should be tested before the host is reinstalled, not after.

**Pool headroom is a live concern independent of any of this.** The pool is at **87 %**
(113 TB of 128 TB). ZFS performance degrades meaningfully past ~80 %, and a rebuild is a bad
time to be near the wall.

---

## 5. What has to change in the manifests

**19 charts pin to nodes that will not exist.** `argocd/applications/traefik.yaml` selects
`node-role.kubernetes.io/proxy` (yellowtalon); postgresql, redis, seaweedfs, immich,
paperless, matrix and tracearr pin to greytalon's database role; others name
`kubernetes.io/hostname` directly. On a single node every one of these is either wrong or
redundant, and a pod pinned to a departed node simply does not schedule.

**Ingress moves off yellowtalon.** Traefik binds `hostPort` 80/443 today, so retiring that
node moves the binding to whatever holds the ingress next — a change visible outside the
cluster, because the router's port-forward and any external DNS point at yellowtalon's
address. Worth taking the opportunity to adopt the MetalLB VIP model from
`cluster-split.md` §2.4 rather than reproducing a pinned `hostPort` replica on a VM.

**Plex's hardware transcoding is already a no-op, and this is the moment to notice.** The
chart sets `hwTranscode.enabled: true` and mounts `/dev/dri`, but on blacktalon that device
is the Matrox G200eR2 — the BMC's VGA — and the Xeon E5-2680 v4 has no integrated graphics.
There is no VAAPI device behind that mount and there never was; Plex has been transcoding on
CPU. Nothing is lost by virtualising, and the setting should stop claiming otherwise.

---

## 6. The risk that dominates

Rebuilding blacktalon means **reinstalling the host OS under a 113 TB pool.** ZFS exports and
imports across installs by design, but this is the step where a mistake is unrecoverable and
where 85 TB of media has no second copy.

Nothing else in this document is irreversible. This is.

Treat it as its own gate: confirm the pool exports cleanly, confirm Proxmox imports it, and
have the PVC migration completed and verified *before* touching the host, so the only thing
at stake during the reinstall is the pool itself.

---

## 7. Sequencing

Ordered so that the irreversible step happens last and against the smallest possible surface.

| Phase | Work | Done when |
|---|---|---|
| **A** | Drop the node pinning: remove or rewrite the 19 `nodeSelector`s; move workloads off greytalon/redtalon/yellowtalon onto blacktalon while all four still run | every pod is running on blacktalon; the three R630s are idle |
| **B** | Migrate the 36 PVCs onto blacktalon; verify each application against its data | no PVC is bound to a retiring node; Immich, Paperless, Matrix and tracearr all verified against real data |
| **C** | Move ingress; retire the three R630s | ingress serves from blacktalon; external DNS and port-forwarding updated |
| **D** | Prove the storage path for VMs — NFS or virtiofs — on a throwaway Talos VM against a copy of a dataset | a Talos VM reads and writes the media path at acceptable throughput |
| **E** | Reinstall blacktalon as Proxmox, import the pool, rebuild the cluster as Talos, restore PVCs via Proxmox CSI | the personal estate runs on Talos with the pool intact |

Phases A through C are worth doing regardless — they are the consolidation, and they leave a
working single-node cluster. D and E are the Talos rebuild, and can wait as long as necessary
without blocking anything.

---

## 8. Open, not decided

- **Media path for VMs** — NFS or virtiofs (§4). Needs testing on the pinned Talos image.
- **Pool headroom** — 87 % full. Whether to expand before the rebuild, or accept it.
- **Single-node control plane.** Talos supports it (`allowSchedulingOnControlPlanes`), but
  the personal plane then has no scheduling redundancy at all. That is arguably already true
  with everything pinned to blacktalon, but it becomes structural.
- **GPU.** A discrete GPU would give Plex real hardware transcoding for the first time, and
  would need passing through to whichever VM runs it — contended with any other use.
- **Backups.** Not covered here and not currently covered anywhere. 85 TB with no second copy
  is a standing risk that this rebuild makes newly visible rather than newly real.
