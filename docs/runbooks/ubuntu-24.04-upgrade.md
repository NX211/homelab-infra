# Runbook: Ubuntu 24.04 node upgrades (staging k3s)

Brings every staging node onto Ubuntu 24.04.5 / kernel 6.8. Standard support for
22.04 ends April 2027. One node at a time; never two nodes down at once.

| Node | Before | Action | Pinned state (local-path, can't move) |
|---|---|---|---|
| yellowtalon (.240, edge/proxy) | 24.04.4 | point update + reboot | traefik-acme (**ingress blips**), verdaccio ×2, jellyfin-watchstate |
| redtalon (.230, apps/compute) | 22.04.5, 5.15 | `do-release-upgrade` (minimized image, no `screen`) | gitea, mongodb rs0, restate, provisioning-db, build caches |
| greytalon (.210, database) | 22.04.5, 5.15 | `do-release-upgrade` | **postgres-1** (Authelia, Gitea, staging apps), matrix-postgres, redis, seaweedfs filer+volume, immich, paperless, mariadb; ZFS pool `greytalon` |
| blacktalon (.250, control plane) | 24.04.5 | none | — |

k3s is not an apt package, so the OS upgrade doesn't touch it. The SUC plans
(`system-upgrade/agent-plan`, `server-plan`) only manage k3s versions.

Drain only moves stateless pods. Pods with local-path volumes stay Pending until
their node returns, so each node's pinned services above are **down for the whole
window** (~15 min for a point update, ~45–90 min for a release upgrade).

## Pre-flight (all nodes, verified 2026-11-24)

- Third-party apt sources: `docker.list`, `tailscale.list` (`jammy`). `do-release-upgrade` comments them out. Re-enable them afterwards (step 5).
- Container runtimes live in `/usr/local/bin` (`runsc`, `containerd-shim-kata-v2`, `containerd-shim-runsc-v1`). apt doesn't touch them.
- Builds run kaniko as root inside Kata or gVisor rather than rootless user namespaces, so 24.04's `kernel.apparmor_restrict_unprivileged_userns=1` (already active on blacktalon and yellowtalon) doesn't affect them.
- Huntress is a script install (not dpkg) running as systemd units. Check it after each reboot.
- `GRUB_TIMEOUT=0`, hidden menu: if the new kernel won't boot, you need a **local console** to pick 5.15 from GRUB. Have one available for red and grey.
- **No CNPG backups exist** (no `barmanObjectStore`, no ScheduledBackup). Take the dumps in step 1 before red and grey.
- greytalon ZFS: 2.1.5 → 2.2.x imports the pool unchanged. **Do not run `zpool upgrade`** afterwards, or the pool can't be imported by the 22.04 kernel if you need to roll back.

## Per node

Commands marked **[you]** need your sudo password on the node. The others run from blacktalon.

### 1. Database dumps (red and grey only)

Kept root-only on blacktalon and deleted once the node is verified:

```bash
ssh blacktalon 'sudo install -d -m 0700 /root/pre-noble
for c in default/postgres matrix/matrix-postgres provisioning/provisioning-db; do
  ns=${c%/*}; n=${c#*/}
  sudo kubectl -n $ns exec $n-1 -c postgres -- pg_dumpall -U postgres | gzip | sudo tee /root/pre-noble/$n-$(date +%F).sql.gz >/dev/null
done; sudo chmod 0600 /root/pre-noble/*
for f in $(sudo ls /root/pre-noble); do echo "$f: $(sudo zcat /root/pre-noble/$f | grep -c "cluster dump complete") complete"; done'
```

Each file must report `1 complete`. On 2026-11-24 the three dumps were ~3.7 MB
compressed: postgres (11 DBs, 614 tables), matrix-postgres (3 DBs), provisioning-db.

For greytalon, also dump the non-CNPG databases it hosts: `immich-postgres`,
`paperlessdb` (container `postgres`, `pg_dumpall`), `mariadb-0`
(`mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --all-databases --single-transaction`,
evaluated inside the pod) and `tracearr-timescale-0`. tracearr is ~90 MB and a
plain `pg_dumpall` over `kubectl exec` got cut off mid-stream, so dump it with
`pg_dump -Fc tracearr` plus `pg_dumpall --globals-only`, and check the file
with a full `pg_restore -f /dev/null`, not just `pg_restore -l`.

### 2. Cordon and drain

```bash
ssh blacktalon 'sudo kubectl cordon <node> && sudo kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m'
```

### 3. Patch to latest 22.04/24.04 and reboot [you]

```bash
ssh -t <node> 'sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::=--force-confold full-upgrade -y && sudo reboot'
```

**yellowtalon stops here**: wait for it to come back, then go to step 6.
(Done 2026-11-24: 24.04.5, kernel 6.8.0-151, Kata and gVisor smoke pods passed,
~25 min of ingress downtime including drain.)

### 4. Release upgrade [you] (red and grey)

In your own terminal, inside `screen` so a dropped SSH session doesn't kill it.
The upgrader also opens a fallback sshd on port 1022.

```bash
ssh -t <node>
command -v screen || sudo apt install -y screen   # redtalon is a minimized image without it
sudo screen -S noble do-release-upgrade
```

Prompts:
- Modified config files (e.g. `sshd_config`, `/etc/default/grub`): **keep the installed version** (`N`).
- Restart services automatically: **Yes**.
- "Remove obsolete packages": press `d` to see the list. Answer **N** if it includes `docker-ce`, `containerd.io`, `tailscale` or anything ZFS. Otherwise Y.
- Reboot at the end: **Yes**.

### 5. Re-enable third-party repos [you] (red and grey)

**Only after the node has rebooted into 24.04** (`lsb_release -ds` says 24.04).
Run on 22.04, it points Docker at noble and `apt full-upgrade` installs noble
packages on jammy. `do-release-upgrade` then refuses to start because updates
are pending. If that happens, `sed -i s/noble/jammy/g` both files, `apt update`,
`full-upgrade` back to the jammy builds and reboot (this happened on redtalon
on 2026-11-24).

The upgrader doesn't comment the third-party sources out; it renames them to
`*.list.distUpgrade`. Restore them for noble:

```bash
ssh -t <node> 'cd /etc/apt/sources.list.d && for f in docker tailscale; do sudo sh -c "sed s/jammy/noble/g $f.list.distUpgrade > $f.list" && sudo rm $f.list.distUpgrade; done && sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::=--force-confold full-upgrade -y && apt list --upgradable 2>/dev/null | grep -v Listing'
```

### 6. Verify, then uncordon

```bash
ssh <node> 'lsb_release -ds; uname -r; systemctl is-active k3s-agent huntress-agent huntress-updater tailscaled; zpool status -x 2>/dev/null'
ssh blacktalon 'sudo kubectl get node <node> -o wide && sudo kubectl uncordon <node>'
```

Then:
- pods pinned to the node are Running; every ExternalSecret and Argo app is healthy
- a throwaway Kata and gVisor pod schedules on the node (`nodeName: <node>`, `runtimeClassName: kata` / `gvisor`, `busybox true`)
- Huntress shows the node with a new OS version and a fresh Last Seen
- no new alerts in Alertmanager

After grey and red are verified, delete `/root/pre-noble` on blacktalon.

redtalon done 2026-11-24: 24.04.5, kernel 6.8.0-151, Docker/containerd on
noble builds, Kata and gVisor smoke pods passed, all pinned pods back.
`systemd-networkd-wait-online` fails at boot (2 min delay) because netplan
enables DHCP on the unplugged `eno2`–`eno4`. That predates the upgrade. The fix
is `optional: true` on those NICs.

greytalon done 2026-11-25: 24.04.5, kernel 6.8.0-151, ZFS 2.1.5 → 2.2.2 with
the pool imported unchanged (no `zpool upgrade`), Kata and gVisor smoke pods
passed, CNPG clusters healthy. It has the same `eno2`–`eno4` netplan issue.
Staging cron jobs that ran while postgres-1 was down failed. Their Argo apps
show Degraded until the next successful run, and `KubeJobFailed` fires until
the failed Jobs are deleted.

## Rollback

The release upgrade can't be undone in place. If the node won't boot, pick the
5.15 kernel from GRUB at the console. If userland is broken, restore from the
step-1 dumps onto a rebuilt node. Volume data in `/opt/local-path-provisioner`
and on ZFS isn't touched by the upgrade.
