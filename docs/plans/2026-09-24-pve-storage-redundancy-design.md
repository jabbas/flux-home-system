# pve.home storage redundancy — design

Status: **revised 2026-09-30. The core problem is unchanged and unaddressed: `rpool` is still a
two-way stripe with zero redundancy.** Several assumptions in the first draft turned out to be
wrong, and the recommended plan has changed materially as a result. All figures below come from
a read-only inspection on 2026-09-30 unless stated otherwise.

## What changed since the first draft (2026-09-24)

Read this section before acting on anything written earlier.

1. **The Thunderbolt position no longer exists.** The first draft assumed the TB enclosure was a
   free NVMe bay, giving four disk positions. It is not. The ACASIS TBU405Pro contains a
   **Plextor PX-AG128M6e** — a 128 GB M.2 **AHCI** SSD, not NVMe — and that drive is now in use
   as the host's swap device. PCIe topology shows no second internal slot in the enclosure.
   **There are three disk positions, not four**, which invalidates the original phase 1.
2. **Consequence: redundancy is no longer achievable immediately.** With one free slot you can
   mirror one vdev. The pool stays non-redundant until the second vdev is removed, and that
   removal requires the pool to shrink below 1.82 T first. The order of the plan is therefore
   reversed — see *Revised recommended path*.
3. **Swap now exists**, 32 GiB on that external SSD, with `vm.swappiness=10` and
   `vm.min_free_kbytes=524288`. It is **88.7 % full**, so it is no longer a safety margin.
4. **Memory was partially addressed and is still over-committed.** The three Talos VMs were
   reduced 16384 → 12288 MiB each. But the first draft counted only VMs; LXC containers add
   another 22.0 GiB of configured memory. KSM is now **off**, so the ~7 GiB it used to reclaim
   is gone.
5. **A second storage path now exists.** An iSCSI class was added (`zfs-iscsi-db`), and the
   `authentik` and `firecrawl` CloudNativePG databases were migrated from NFS datasets to ZFS
   **zvols** under `rpool/k8s-iscsi/v`. The cluster is no longer NFS-only.
6. **The open `volblocksize` question is answered.** `rpool/data` VM zvols are **16K**;
   the new CSI zvols are **8K**. This matters for the raidz padding arithmetic below.
7. **Backups were found to be largely fictional and partly fixed.** `authentik-stack-db` had a
   five-field cron where CNPG requires six, so its weekly backup had never run in 22 days — the
   trailing `1` was parsed as *January*, not *Monday*. Fixed. `firecrawl` had no backup
   configuration at all. Added. Still **no `barmanObjectStore` or WAL archiving anywhere**, so
   there is no off-site copy and no PITR.
8. **A data-loss path was found and disarmed.** The `ibakery` CNPG cluster is Helm-owned and its
   HelmRelease was in a failed-install loop whose default remediation is *uninstall*, which would
   have cascaded Cluster → PVC → PV → ZFS dataset. The release is now suspended and all six
   database PVs were patched to `reclaimPolicy: Retain`.
9. **CPU temperature improved markedly** — 95 °C in the first draft, **74 °C** now, under a
   higher load average. The earlier reading looks like a transient, not dried paste. Repasting
   drops down the priority list.
10. **Write rate is far higher than estimated.** The first draft projected ~84 TB/year per drive.
    Actual: ~6 TB written across both drives in five days. Much of that is attributable to the
    benchmarking and database migrations performed in that window, so do not extrapolate it
    naively — but wear did tick 45 % → 46 % in that time.

## Why this document exists

It started as an evaluation of `garage-operator` for deploying Garage (S3-compatible object
storage) on the cluster. That evaluation concluded Garage does not solve the problem it was
being considered for — see `docs/research/garage-operator-analysis.md`. Working out *where*
Garage data would physically land uncovered a more serious issue, which is what this document
captures.

**The finding: `rpool` is a two-way stripe with zero redundancy, and everything runs on it.**

## Problem statement

`pve.home` is the single physical host for the entire home lab, and also the storage server for
the Kubernetes cluster — over both NFS and iSCSI.

Losing either of the two NVMe drives destroys, simultaneously:

- the Proxmox root filesystem
- all VMs, including the whole Talos control plane (`talos1-3`, VMIDs 401–403)
- all LXC containers
- every Kubernetes PersistentVolume, on both the NFS and iSCSI paths
- Time Machine backups
- Frigate NVR recordings
- every database backup, since all snapshots live on this same pool

Aggravating factor: both drives are **46 % worn** and their power-on hours differ by **five
hours** (19 803 vs 19 808). In a stripe they wear symmetrically, so their failure risk is
*correlated in time*, not independent.

## Current state

### Host

| | |
|---|---|
| Model | Minisforum MS-01 (SMBIOS reports OEM string `Micro Computer (HK) Tech Limited / Venus Series`) |
| Board | Shenzhen Meigao `AHWSA` (CWWK/Topton family) |
| CPU | Intel Core i9-13900H, 14C/20T |
| RAM | 62.4 GiB DDR5 SODIMM, **non-ECC** |
| PVE | pve-manager 9.2.20, kernel 7.0.14-19-pve |
| Uptime at inspection | 6 days 22 h (load average 7.28) |

### `rpool` topology

```
rpool  size 3.62T  alloc 2.47T  free 1.15T  frag 60%  cap 68%  ONLINE
  nvme-eui...3a18-part3   1.82T  alloc 1.23T  ONLINE   <- separate top-level vdev
  nvme-eui...3a36-part3   1.82T  alloc 1.24T  ONLINE   <- separate top-level vdev
```

Two independent top-level `disk` vdevs. **This is a stripe, not a mirror.** No cache, log or
spare vdev.

- `ashift` 12, `compression` lz4, pool compressratio 1.32×
- `autotrim` **off** (default) — freed space is never returned to the SSD FTL
- `autoexpand` off, `failmode` wait
- last scrub 2026-09-13, repaired 0 B in 26 min, 0 errors
- `feature@device_removal` **enabled** (never used) — load-bearing for the revised plan
- `feature@raidz_expansion` **enabled**
- `feature@log_spacemap` active

### NVMe drives

Both identical: KIOXIA EXCERIA PLUS G3 2 TB, firmware `ELFA01.2`, **DRAM-less**, M.2 2280,
512 B formatted LBA (4096 B supported but unused). Vendor-rated endurance ≈ 800 TBW.

| | `nvme0n1` | `nvme1n1` |
|---|---|---|
| Serial | YDBKF0UXZ0EA | YDBKF0VTZ0EA |
| PCI address | `59:00.0` via root port `00:1c.4` | `5a:00.0` via root port `00:1d.0` |
| Link | PCIe 3.0 x4 | **PCIe 3.0 x2** (root port `LnkCap` limit) |
| Percentage Used | **46 %** | **46 %** |
| Data written | 193.6 TB | 189.6 TB |
| Power-on hours | 19 803 | 19 808 |
| Power cycles | 124 | 124 |
| Unsafe shutdowns | **93** | **93** |
| Temperature | 55 °C | 59 °C |
| Available spare | 100 % | 100 % |
| Media/data errors | 0 | 0 |
| Warning/critical temp time | 0 min | 0 min |

Note the discrepancy: 193 TB written is ~24 % of 800 TBW, yet the drive's own counter says
46 %. The gap is write amplification — ZFS copy-on-write on a DRAM-less controller, with
512 B LBA formatting against 4 KiB physical. **Trust the drive's counter.**

The two unsafe-shutdown counters have held at 93 across two deliberate reboots, so recent
shutdowns have been clean.

### M.2 slots — three positions, one free

MS-01 official specification: three M.2 2280 slots — one PCIe 4.0 x4, one PCIe 3.0 x4, one
PCIe 3.0 x2.

| Slot | Spec | Observed | Occupant |
|---|---|---|---|
| 1 ("leftmost") | **PCIe 4.0 x4, CPU** | `00:06.0`, `LnkCap x4 @16GT/s`, **`Width x0`** | **EMPTY** |
| 2 | PCIe 3.0 x4, PCH | `00:1c.4`, x4 @8GT/s (full) | `nvme0n1` |
| 3 | PCIe 3.0 x2, PCH | `00:1d.0`, x2 @8GT/s (full, x2 by design) | `nvme1n1` |

**The free slot is the fastest one** — the only Gen4 x4 link and the only one attached directly
to the CPU. Bus 02 enumerates empty, confirming nothing is installed. Slot-to-port mapping is
inference from Raptor Lake-H topology; it matches the published spec but is confirmed only by
inserting a drive.

`dmidecode -t slot` on this board is **useless** — five entries, all `Available`, all sharing
ID 1 and bus address `00:00.0`. Do not draw conclusions from it.

### The Thunderbolt enclosure — not a disk position

This corrects the central error of the first draft.

| | |
|---|---|
| Enclosure | ACASIS TBU405Pro, Thunderbolt 3, 40 Gb/s, bolt-enrolled `policy: auto` |
| Contents | **Plextor PX-AG128M6e**, 119.2 GiB, M.2 **AHCI** (Marvell 88SS9183) — *not* NVMe |
| Device | `/dev/sde`, driven by the `ahci` driver |
| Link | PCIe 2.0 x2 ≈ 1.0 GB/s, fully negotiated; TB tunnel upstream runs 2.5 GT/s x4 |
| Health | SMART PASSED, 4 241 POH, 0 reallocated, 0 CRC, 0 uncorrectable |
| Telemetry | **no temperature sensor and no usable wear indicator** — not in the smartctl database |
| Current use | `sde1` 32 GiB = host swap (`LABEL=pve-swap`) |
| `sde2` | 87.2 GiB carrying an **orphaned L2ARC label from a foreign pool** (guid `13164…871`, not `rpool`). Dead space. |

**There is no second internal M.2 slot in the enclosure.** The only empty downstream bridge
(`2f:04.0`) advertises `HotPlug+ / Surprise+`, the signature of a Thunderbolt daisy-chain
pass-through, whereas the bridge actually carrying the SSD (`2f:01.0`) advertises `HotPlug−`.
This is inference from PCIe capability bits, not proof — but the evidence points one way.

**However:** host root port `00:07.0` is a **second, entirely unused Thunderbolt port**
(`Width x0`). A second enclosure would therefore add a fourth position. That is the only way to
restore the original phase 1.

### PCIe slot

MS-01 has one PCIe 4.0 x16 physical / **x8 electrical**, half-height single-slot. It is
**occupied** by an ASMedia ASM1164 SATA controller (`01:00.0`, subsystem ID reports
`QNAP Systems 1853`), negotiating x2 @8GT/s — the card itself is only x2 Gen3. Adequate for
four spinning disks, but the slot is spent.

### SATA and the HDDs

**MS-01 has no internal SATA ports and no drive bays** (48 mm chassis). The four 3.5" disks are
in an **external enclosure with its own power supply**, connected through the ASM1164 card. That
makes the HDD set a genuinely separate hardware failure domain from the NVMe — different
enclosure, different PSU — though the same room.

All four remain **completely unused**: `blkid` returns nothing, `lsblk` shows no partitions or
holders, `zdb -l` fails all four labels on all four disks, and `rpool` is the only pool on the
host.

| Device | Model | Serial | POH | SMART notes |
|---|---|---|---|---|
| `sda` | TOSHIBA HDWN160 | 17LSK007FPAE | 59 560 (6.8 y) | 168 reallocated, **186 CRC UDMA** |
| `sdb` | HGST HDN726060ALE614 | K1GW81EB | 57 470 (6.6 y) | 0 reallocated, **44 Offline_Uncorrectable** |
| `sdc` | TOSHIBA HDWN160 | 17TUK034FPAE | 57 694 (6.6 y) | 112 reallocated, 13 CRC |
| `sdd` | HGST HDN726060ALE614 | K1JP5VED | 54 643 (6.2 y) | clean |

All report SMART `PASSED`; both Toshibas show normalised POH value `001`, i.e. at the bottom of
the vendor's life-expectancy scale. **Suitable as a second copy, not as the only copy of
anything.** The CRC count on `sda` indicates a cable or controller-port problem rather than a
platter problem — reseat before use.

### Space consumers on `rpool`

| Dataset | Used | Quota | Belongs on NVMe? |
|---|---|---|---|
| `rpool/timemachine` | **981 G** | 1 T — **43.5 G left** | No |
| `rpool/nvr` (Frigate) | **890 G** | none | No — sequential writes, **can fill the pool** |
| `rpool/home` | 248 G (244 G is `home/backup`) | none | No |
| `rpool/var-lib-vz` | **233 G** | none | No — ISOs, dumps, templates |
| `rpool/data` | 141 G | none | Yes — VM/LXC zvols |
| `rpool/ROOT/pve-1` | 12.2 G | none | Yes |
| `rpool/k8s` | 8.73 G | none | Yes — NFS-backed PVs |
| `rpool/netboot` | 7.50 G | none | Yes |
| `rpool/homeassistant` | 7.82 G | none | Marginal |
| `rpool/k8s-iscsi` | 303 M | none | Yes — zvol-backed PVs |
| `rpool/containerregistry` | 178 M | 50 G | Yes |

**`timemachine` + `nvr` + `home` + `var-lib-vz` = ~2.35 T of the 2.47 T allocated.** Moving them
to the HDD pool drops `rpool` to roughly **350 G**. That figure is what makes the revised plan
work, because `zpool remove` of a 1.23 T vdev requires the remainder to fit on its partner.

Only two datasets have a local quota: `containerregistry` (50 G) and `timemachine` (1 T).
`rpool/nvr` having no quota remains a live hazard — Frigate can fill the pool and take
Kubernetes storage down with it.

### zvols — two different block sizes

| Group | Count | `volblocksize` | Notes |
|---|---|---|---|
| `rpool/data/vm-*` (VM disks) | 12 | **16K** | uniform, no refreservation, lz4 |
| `rpool/k8s-iscsi/v/*` (CSI) | 4 | **8K** | uniform, sparse, lz4 |

The 8K choice for CSI volumes was deliberate: `rpool` is a stripe, not raidz, so small blocks
carry no parity-padding penalty, and the workloads are random-write databases on drives whose
binding constraint is write amplification. **`volblocksize` is immutable per zvol.**

### Snapshots — still almost nothing

Five, all CSI-generated, all on `rpool/k8s` (NFS) datasets:

```
rpool/k8s/authentik-authentik-stack-db-1@snapshot-ce6193ba-...   38.9M
rpool/k8s/ibakery-ibakery-db-1@snapshot-5529fad9-...              80K
rpool/k8s/ibakery-ibakery-db-2@snapshot-fa0d907f-...             304K
rpool/k8s/ibakery-ibakery-db-2@snapshot-ad04386f-...              80K
rpool/k8s/ibakery-ibakery-db-2@snapshot-5fdaf123-...              88K
```

**Zero snapshots** on `rpool/ROOT`, `rpool/data`, `rpool/home`, `rpool/nvr`,
`rpool/timemachine`, `rpool/var-lib-vz` or `rpool/k8s-iscsi`. `zpool history` shows only
transient vzdump snapshots created and destroyed nightly. There is no snapshot policy.

Note the asymmetry: the two databases now on iSCSI have **no snapshot coverage at all**, because
the only snapshots that ever existed were taken on the NFS path.

### Kubernetes storage paths

Both servers run **on this host**; there is no separate NAS.

**NFS** — `nfs-server` on `0.0.0.0:2049`. Exports live in `/etc/exports.d/zfs.exports`, managed
via the ZFS `sharenfs` property by democratic-csi's `zfs-generic-nfs` driver. 23 exports, all to
`*` (any host), most with `no_root_squash`, and the Kubernetes ones with **`async`** — the server
acknowledges writes before they are durable, which is worth remembering when reasoning about
power loss.

**iSCSI** — in-kernel LIO target on `0.0.0.0:3260`, driven over SSH by democratic-csi's
`zfs-generic-iscsi` driver. Four backstores mapping zvols under `rpool/k8s-iscsi/v`. Config
persists in `/etc/rtslib-fb-target/saveconfig.json`, which survives reboots only because
`targetcli`'s `auto_save_on_exit` defaults to true — the driver never calls `saveconfig`. A
systemd drop-in orders `rtslib-fb-targetctl.service` after `zfs-volume-wait.service` and
`zfs.target`, without which LIO restores before the zvol links exist and every LUN silently
vanishes.

**Security note:** every iSCSI target is `no-auth` with `gen-acls` and zero ACLs, on a portal
bound to `0.0.0.0`. Any initiator that can reach port 3260 on any host address gets the LUN.
Acceptable only because the portal is on an internal bridge and the host has no firewall rules —
but it is an explicit trade, not a default worth forgetting.

**Stale exports:** the four pre-migration NFS datasets for `authentik` and `firecrawl` are still
present (~205 MB plus a 38.9 M snapshot) and still exported `rw,no_root_squash,async`, with
their PVs in `Released` state under `Retain`. They are deliberately retained as the migration
rollback path, but they are also four live NFS exports of databases that no longer use them.

### Storage classes

| Class | Provisioner | Reclaim | Binding | In use |
|---|---|---|---|---|
| `zfs-nfs-csi` (default) | nfs | Delete | Immediate | grafana, ibakery, VictoriaMetrics |
| `zfs-nfs-db` | nfs | **Retain** | Immediate | **nothing** |
| `zfs-iscsi-csi` | iscsi | Delete | WaitForFirstConsumer | **nothing** |
| `zfs-iscsi-db` | iscsi | **Retain** | WaitForFirstConsumer | authentik, firecrawl |

Measured difference between the NFS and iSCSI paths, same pool, same host: **15 240 vs 1 989
random-write IOPS at 4 k**, p99 latency **13.8 ms vs 1.08 s**. Sequential write favours NFS by
~24 %. Read figures were ARC-served (98.97 % hit ratio on a 4 GiB file against a 6.25 GiB ARC)
and are not a storage comparison.

One trap worth recording: **POSIX locking is not a differentiator.** Contended `flock()` is
correctly denied on *both* classes. The `nolock` option in the NFS class's `mountOptions` is
inert — NFSv4.1 ignores it and negotiates `local_lock=none`, sending locks to the server.

A second trap: **migrating NFS → iSCSI reduces usable capacity at an unchanged nominal size.**
On the NFS class a PVC's size is effectively measured in ZFS-*compressed* bytes; on ext4 over a
zvol the filesystem sees uncompressed size. 114 MB of authentik data occupied 66 MB of its
512 MiB NFS quota but 137 MB of the equivalent ext4 filesystem. Size volumes accordingly.

### Memory — still the binding constraint

```
MemTotal      65 442 224 kB   62.4 GiB
MemAvailable  19 074 172 kB   18.2 GiB
AnonPages     34 746 124 kB   33.1 GiB
Cached           928 096 kB    0.89 GiB
SwapTotal     33 554 428 kB   32.0 GiB
SwapFree       3 799 028 kB    3.62 GiB   <- 88.7 % of swap consumed
CommitLimit   66 275 540 kB   63.2 GiB
Committed_AS  87 671 212 kB   83.6 GiB   <- 132 % of CommitLimit
```

Configured guest memory:

| | Configured | Actual RSS |
|---|---|---|
| VMs (100, 103, 401–403, 802) | **60.0 GiB** | 30.5 GiB |
| LXC (200, 202, 300, 500, 1000–1002) | **22.0 GiB** | — |
| **Total** | **84.0 GiB** | |
| plus ARC cap | 6.25 GiB | ARC pinned at 6.23 GiB, hit ratio 91.1 % |

**84.0 GiB of configured guests plus a 6.25 GiB ARC on a 62.4 GiB host.** The three Talos VMs
were reduced from 16384 to 12288 MiB each, which removed 12 GiB of commitment, but the LXC side
was never examined: `esp` alone is configured for 8192 MiB while using ~250 MB, and `hassio` is
configured for 16384 MiB while using 3.48 GiB.

**KSM is off** (`run=0`, `pages_sharing` 224 650 is residue). It previously reclaimed ~7 GiB.

The swap being 88.7 % full is the headline: ~28 GiB of guest anonymous memory now lives on an
**externally attached Thunderbolt SSD**. That is both a performance liability and a dependency
on a hot-pluggable device for the working set of production guests.

**Consequences for every option below:** a larger pool needs *more* ARC, and ARC is already
pinned at a cap that leaves it caching metadata and little else. L2ARC would make things worse,
since its headers live in ARC. **Fix memory before growing storage.**

The board has two DDR5 SODIMM slots. Whether the current 64 GiB is 2×32 (no free slot) and
whether 2×48 GiB is supported still needs physical verification.

### Thermals — improved

| Sensor | First draft | Now | Limit |
|---|---|---|---|
| CPU package | **95 °C** | **74 °C** | high/crit 100 °C |
| Cores | 76–95 °C | 65–74 °C | 100 °C |
| `nvme0` composite | 53.9 °C | 55.9 °C | warn 82.8 / crit 84.8 |
| `nvme1` composite | 57.9 °C | 57.9 °C | warn 82.8 / crit 84.8 |

21 °C lower at a *higher* load average. The earlier 95 °C reading now looks like a transient
rather than degraded paste, so **repasting drops well down the priority list**. Both NVMe still
report zero warning and zero critical temperature time.

No temperature sensor exists for `/dev/sde`, the HDDs, or the ASM1164 — the HDD SMART attribute
194 values (40–50 °C) are the only source there.

## Risk summary

| Severity | Issue |
|---|---|
| 🔴 | `rpool` is a stripe. One drive failure destroys host, cluster, all PVs, all backups. |
| 🔴 | Drive wear is **correlated** — 46 % each, five hours apart in power-on time. |
| 🔴 | **No off-site backup of anything.** Every database snapshot is on the pool it protects. No `barmanObjectStore`, no WAL archiving, no PITR. |
| 🔴 | **Swap 88.7 % full**, 84.0 GiB of configured guests on 62.4 GiB, KSM off. ~28 GiB of guest memory resident on an external Thunderbolt SSD. |
| 🟠 | No snapshot policy. Five CSI snapshots on the NFS path; the two iSCSI databases have none. |
| 🟠 | Both NVMe at 46 % wear, DRAM-less, no PLP, 93 unsafe shutdowns, 512 B LBA on 4 KiB media. |
| 🟠 | `rpool/timemachine` at 981 G of a 1 T quota — 43.5 G left before backups start failing. |
| 🟠 | `rpool/nvr` has no quota — Frigate can fill the pool and break Kubernetes storage. |
| 🟡 | Fragmentation 60 % at 68 % capacity; `autotrim` off, so nothing is returned to the SSDs. |
| 🟡 | All four HDDs at 54–59 k hours with reallocated sectors or offline-uncorrectables. |
| 🟡 | iSCSI targets are `no-auth` with zero ACLs on a `0.0.0.0` portal. |
| 🟡 | Four stale NFS exports of migrated databases, still `rw,no_root_squash`. |
| 🟡 | No ECC memory. |
| 🟡 | `apparmor.service` failed (broken Samba profile) — pre-existing, cosmetic. |
| ℹ️ | 87.2 GiB of the swap SSD is dead space holding an orphaned L2ARC label. |
| ℹ️ | 22 TB of HDD spins 24/7 doing nothing. |

## Available positions — three, not four

| Position | Link | Bootable | State |
|---|---|---|---|
| Slot 1 | PCIe 4.0 x4, CPU | yes | **FREE — fastest slot in the machine** |
| Slot 2 | PCIe 3.0 x4, PCH | yes | `nvme0n1` |
| Slot 3 | PCIe 3.0 **x2**, PCH | yes | `nvme1n1` |
| TB enclosure #1 | PCIe 2.0 x2 via TB | **no** | Plextor AHCI SSD, in use as swap, **no spare bay** |
| TB port `00:07.0` | unused | no | a second enclosure would add a fourth position |

The practical consequence is the whole reason this document needed revising: **one free slot
means one mirror.** A stripe of two vdevs is only redundant when *both* vdevs are redundant, so
mirroring vdev A alone leaves the pool as exposed as before — any failure of `nvme1n1` still
loses everything.

## Options

### Option 0 — do nothing

Expected cost: total loss of the lab on the first NVMe failure, with two drives wearing out in
lockstep and no off-site copy of anything.

### Option 1 — slim the pool, then consolidate onto one mirror (recommended)

Uses the three internal positions and requires **two new drives**, but reaches full redundancy
without any downtime and without a second enclosure. The catch is that redundancy arrives
*late*, not immediately — the pool stays exposed until step 3.

The enabling fact is `feature@device_removal = enabled`, which allows a top-level vdev to be
removed from a live pool provided its data fits on the survivors. 1.23 T does not fit on a
1.82 T vdev alongside the 1.24 T already there — hence the bulk data must move first.

### Option 2 — a second Thunderbolt enclosure, mirror both vdevs immediately

Restores the first draft's phase 1. Buy a second TB enclosure (host port `00:07.0` is free) and
an NVMe for it, `zpool attach` to both vdevs, and the pool is redundant in an afternoon with no
data movement.

Trade: one mirror leg runs over a hot-pluggable Thunderbolt tunnel at ~1 GB/s, is not bootable,
and has no thermal telemetry in the case of the existing enclosure. It is a legitimate
*transitional* position — attach now, remove the leg later once the pool has slimmed and slot 2
is free. It is a poor permanent one.

Choose this if reaching redundancy quickly matters more than tidiness, which is a defensible
position given two drives at 46 % wear.

### Option 3 — raidz1 across the three internal slots

3.62 T usable, tolerates one failure, no external dependency. **Requires destroy and restore**:
nothing converts two single-disk vdevs into a raidz vdev, and `raidz_expansion` only extends an
existing raidz. So: full backup of 2.47 T → `zpool destroy` → recreate → restore, with the root
pool offline throughout.

Honest accounting:

- **In favour:** the only way to keep 3.62 T on three drives; mirrors would need four.
- **Against:** unreachable without extended downtime and a Proxmox restore; a resilver must read
  *all* surviving drives and recompute parity, which is the worst possible stress on
  correlated-wear drives; `zpool remove` is permanently unavailable for raidz vdevs, so the
  topology becomes a one-way door.
- **Space amplification, now computable.** At `ashift=12` on 3-wide raidz1: 16 K `volblocksize`
  → 1.5× overhead, 8 K → 1.5×, 4 K → 2.0×. The VM zvols are **16K** and the CSI zvols **8K**, so
  both land in the 1.5× band and beat a mirror's 2.0×. This is the one argument that genuinely
  favours raidz here.

**What still decides against it:** after the bulk datasets move to HDD, `rpool` needs ~350 G.
raidz1 buys 3.62 T instead of 1.82 T — capacity that would sit empty — and charges downtime, a
restore, a worse resilver profile and permanent loss of flexibility. If the four idle HDDs did
not exist, this recommendation would flip.

### Option 4 — raidz2 across four positions

Requires a second TB enclosure *and* destroy-and-restore, and permanently binds a hot-pluggable
device into a parity vdev. Strongest fault tolerance on paper, worst fit for a pool about to
shrink to 350 G.

### Orthogonal and unconditional: the HDD pool

Independent of which option is chosen, the four idle 6 TB disks should become a pool. **This
costs nothing, requires no purchase, and is now a prerequisite** rather than an optional
tidy-up — Option 1 cannot proceed without it.

Prefer **two mirrors (stripe of mirrors, ~10.9 TiB)** over raidz1 (~16 TiB). At 57 k hours a
6 TB raidz1 resilver runs long and hammers all three survivors; a mirror resilver reads only its
partner. Pair so that no mirror contains two suspect drives: `sdd`+`sda` and `sdb`+`sdc`.

Migration targets, in order of benefit: `rpool/nvr` (890 G, sequential writes, and the main
avoidable cause of SSD wear), `rpool/timemachine` (981 G, also fixes the 43.5 G headroom),
`rpool/home/backup` (244 G), `rpool/var-lib-vz` (233 G).

## Revised recommended path

Assumes **two new 4 TB NVMe** with DRAM cache. Every step is online. The ordering differs from
the first draft because the Thunderbolt position no longer exists.

### Phase 0 — memory, before touching storage

Not optional, and not storage work, but it gates everything else. Swap is 88.7 % full and
~28 GiB of guest memory sits on an external SSD. Cheapest levers, in order:

1. Re-enable KSM (`run=1`) — previously reclaimed ~7 GiB.
2. `esp` LXC 8192 → 2048 MiB (uses ~250 MB). Live change, no restart.
3. `hassio` 16384 → 8192 MiB (uses 3.48 GiB). Needs a guest restart.
4. Review the remaining LXC allocations — 22.0 GiB configured in total.

A larger pool needs more ARC, and ARC cannot grow while the host is in this state.

### Phase 1 — the HDD pool and the great migration (no purchase required)

1. Build the HDD pool as two mirrors: `sdd`+`sda`, `sdb`+`sdc`. Reseat `sda`'s cable first — 186
   CRC errors point at the cable or port.
2. `zfs send | zfs recv` the four bulk datasets across. Verify, then destroy the originals.
3. Set a quota on the relocated `nvr` dataset.
4. `rpool` allocation drops **2.47 T → ~350 G**.

At this point nothing is redundant yet, but the pool is small enough for everything that follows,
and the single largest source of avoidable SSD wear is off the NVMe.

### Phase 2 — first mirror

5. Install new drive #1 in **slot 1**. Replicate the partition layout from an existing drive
   (`sgdisk --replicate`): BIOS boot, ESP, ZFS.
6. `proxmox-boot-tool format` and `init` the new ESP; verify with `proxmox-boot-tool status`.
7. `zpool attach rpool <nvme0n1-part3> <slot1-part3>` → vdev A becomes a mirror.

**The pool is still not redundant.** Vdev B (`nvme1n1`) remains a single point of failure for
the entire pool. Do not stop here and believe the problem is solved.

### Phase 3 — remove the second vdev and consolidate

8. `zpool remove rpool <nvme1n1-part3>` → evacuates vdev B onto mirror A. Now possible because
   ~350 G fits comfortably. Let it finish; `zpool status` reports progress.
9. Physically replace `nvme1n1` in slot 2 with new drive #2. Replicate the GPT and initialise its
   ESP as in steps 5–6.
10. `zpool attach rpool <slot1-part3> <slot2-part3>` → three-way mirror.
11. `zpool detach rpool <nvme0n1-part3>` → leaves `mirror(4 TB slot 1, 4 TB slot 2)`.
12. `zpool set autoexpand=on rpool` and `zpool online -e` → 3.62 T usable from one vdev.

### Phase 4 — the things that were missing anyway

13. Snapshot policy (sanoid or zfs-auto-snapshot) covering `rpool/ROOT`, `rpool/data`,
    `rpool/k8s`, **`rpool/k8s-iscsi`** and `rpool/home`. The iSCSI databases currently have no
    snapshot coverage at all.
14. `zfs send` replication `rpool` → HDD pool. This is the first point at which a second copy on
    different media exists.
15. `zpool set autotrim=on` on both pools, or a scheduled `zpool trim`.
16. Off-site backup — see *Out of scope* below. This is the only item that survives the loss of
    the room.

**End state:** a mirror of two new 4 TB drives in the two fastest slots, both bootable with
initialised ESPs. Slot 3 (the x2 link) free. Both worn KIOXIA out of the pool — one as a cold
spare, one for offline copies. Bulk data on spinning disks in a separate enclosure with its own
PSU. Capacity unchanged at 3.62 T.

Nothing in this path requires a reinstall, a restore, or cluster downtime.

### If redundancy is wanted sooner

Insert Option 2 before Phase 1: a second Thunderbolt enclosure plus one NVMe makes both vdevs
mirrored within an afternoon, with no data movement. Phases 1–3 then proceed at leisure, and the
Thunderbolt leg is removed at step 8 instead of `nvme1n1`.

Given two drives at 46 % wear with five hours between their power-on counters, paying for an
enclosure to close the window early is a reasonable trade.

### Why 4 TB rather than 2 TB

During phases 2–3 each mirror is capped by its smaller member, so only 1.82 T of each 4 TB drive
is usable. After step 12, `autoexpand` recovers it and 3.62 T comes from **one** vdev in **two**
slots, leaving slot 3 free. With 2 TB drives the end state would need all three internal slots
permanently occupied.

### Drive selection criteria

1. **DRAM cache — mandatory.** More important than sequential throughput. The current drives'
   46 % wear at 193 TB written is write amplification on a DRAM-less controller under ZFS.
   Buying another DRAM-less drive repeats the mistake.
2. **Different vendor or batch** from the existing pair, to decorrelate failure timing.
3. **4 KiB LBA formatting**, and format to it. The current drives support 4096 B but are running
   512 B, which contributes to the amplification.
4. **Power-loss protection if budget allows**, given 93 unsafe shutdowns. MS-01 ships with a U.2
   conversion plate and officially supports U.2 — a used enterprise U.2 drive (Micron 7450,
   Kioxia CD6) offers PLP and far higher endurance, at the cost of space and heat.

## Critical gotchas

1. **ESP, not just ZFS.** `rpool` lives on partition 3; partition 2 is the ESP, partition 1 is
   BIOS boot. Attaching only the ZFS partition leaves a pool that survives a drive failure but a
   machine that will not boot from the survivor. Replicate the GPT, run
   `proxmox-boot-tool format` + `init` on every new ESP, and verify with
   `proxmox-boot-tool status`. **This is the classic way this operation goes wrong, and it is
   discovered during an outage.**
2. **Attach partitions, not whole disks.** `zpool attach rpool nvme0n1p3 nvme2n1p3`, never
   `nvme2n1`.
3. **`zpool remove` is the only irreversible step**, and in the revised plan it is now on the
   critical path rather than an optional tidy-up. It leaves a permanent *indirect vdev mapping*
   that consumes RAM for the life of the pool — and RAM is this host's scarcest resource. At
   ~350 G the mapping is small, but it is not free. Confirm `feature@device_removal` is still
   `enabled` and that allocation fits the survivor *before* starting.
4. **Ordering in phase 3.** Detaching before attaching, or skipping `autoexpand`, leaves a
   1.82 T pool despite two 4 TB drives. Verify with `zpool list` after step 12.
5. **Fit a heatsink to the new drive in slot 1** — it is a Gen4 link next to the CPU, and the box
   shipped with only one heatsink.
6. **Memory before capacity.** A larger pool with swap at 88.7 % and KSM off yields a slower
   system, not a faster one.
7. **The iSCSI path has its own fragility.** LIO config persistence depends on `targetcli`'s
   `auto_save_on_exit` default; the ordering of `rtslib-fb-targetctl` after the ZFS targets is
   enforced by a local drop-in with a measured margin of only **2.75 s**; and
   `/sys/block/*/queue/discard_max_bytes` was 0 until `emulate_tpws` was enabled, because this
   kernel's LIO emits VPD page B0h with a 44-byte declared length while Linux requires ≥ 64 to
   parse the UNMAP fields. Volumes created before that fix still have no working discard.
8. **Do not restore an old volumeSnapshot into a different storage class.** Snapshots belong to
   their provisioner. Rolling a migration back means restoring to the *original* class, which
   works — but forward-recovery into the new class does not.

## Requires physical inspection

Cannot be settled over SSH:

1. **Does slot 1 physically exist**, and is it 2280 or 22110? The free CPU Gen4 x4 root port
   (`00:06.0`) is confirmed empty at `Width x0`; whether a socket is wired to it is not. Note the
   contradiction in Minisforum's own materials — the spec table says three 2280 slots, the
   marketing copy mentions "two 22110 M.2".
2. **How many physical SATA connectors** the ASM1164 card exposes (4 or 6), and whether two are
   free.
3. **SODIMM configuration** — 2×32 with no free slot, and whether 2×48 GiB is supported. This is
   now the most valuable physical check, given the memory situation.
4. **Whether the TBU405Pro really has only one bay.** The PCIe capability bits say yes; opening
   it would settle it.

## Out of scope, still open

- **Off-site backup — now the single largest gap.** Everything above is local redundancy. All
  three CloudNativePG clusters use `method: volumeSnapshot` only, so every backup lives on the
  pool it is meant to protect, and there is no WAL archiving or PITR anywhere. Total PostgreSQL
  footprint is ~88 MB on disk, ~195 MB logical — the cost of fixing this is trivial. Use the
  **Barman Cloud Plugin** (`barman-cloud.cloudnative-pg.io`) against an external S3 provider;
  the inline `barmanObjectStore` field is deprecated as of CNPG v1.26. VictoriaMetrics needs
  `vmbackup` separately.
- **Garage.** Evaluated and rejected — see `docs/research/garage-operator-analysis.md`. In-cluster
  object storage would land on this same pool and so cannot be a backup target. It becomes the
  right tool once a *second physical site* exists.
- **`ibakery`.** HelmRelease suspended because it references a Secret that exists in no
  repository, created imperatively and lost. Its database is healthy and still on NFS. While it
  stays suspended the `applications` Kustomization remains unhealthy, which **masks any future
  failure in that tree** — the same blindness that hid this problem for three weeks.
- **The four Released PVs** holding pre-migration database data. They are the migration rollback
  path; they are also 205 MB of stale datasets with live NFS exports. Clean up once the
  migrations are considered settled.
- **`sde2`** — 87.2 GiB of the swap SSD carrying an orphaned L2ARC label from a dead pool.
- **Kubelet eviction thresholds** are at the default `memory.available<100Mi`, which on a 12 GiB
  node is 0.85 % and leaves the kubelet almost no warning before the kernel OOM killer acts.
- **40+ pods have no memory limit**, including `kube-controller-manager`, `kube-scheduler`, all
  democratic-csi pods, and two CNPG instances.
- **The NFS democratic-csi deployment runs an unpinned `:latest` image**, unlike the iSCSI one
  which is pinned to `v1.9.5`.
