# pve.home storage redundancy — design

Status: **parked / not started.** No change has been made to the host. Every figure below
comes from a read-only inspection of the live system on 2026-09-24.

## Why this document exists

It started as an evaluation of `garage-operator` for deploying Garage (S3-compatible object
storage) on the cluster. That evaluation concluded Garage does not solve the problem it was
being considered for — see `docs/research/garage-operator-analysis.md`. Working out *where*
Garage data would physically land uncovered a more serious issue, which is what this document
captures.

**The finding: `rpool` is a two-way stripe with zero redundancy, and everything runs on it.**

## Problem statement

`pve.home` is the single physical host for the entire home lab. It is also the NFS server
backing the Kubernetes cluster's only storage class.

Losing either of the two NVMe drives destroys, simultaneously:

- the Proxmox root filesystem
- all VMs, including the whole Talos control plane (`talos1-3`, VMIDs 401–403)
- all LXC containers
- every Kubernetes PersistentVolume
- Time Machine backups
- Frigate NVR recordings

There is no redundancy, essentially no snapshot coverage, and no copy on any other medium.

Aggravating factor: both drives are **45 % worn** and their power-on hours differ by **six
hours**. In a stripe they wear symmetrically, so their failure risk is *correlated in time*,
not independent.

## Current state

### Host

| | |
|---|---|
| Model | Minisforum MS-01 (SMBIOS reports OEM string `Micro Computer (HK) Tech Limited / Venus Series`) |
| Board | Shenzhen Meigao `AHWSA` (CWWK/Topton family) |
| CPU | Intel Core i9-13900H, 14C/20T |
| RAM | 62 GiB DDR5 SODIMM, **non-ECC** |
| PVE | pve-manager 9.2.11, kernel 7.0.14-12-pve |
| Uptime at inspection | 35 days |

### `rpool` topology

```
rpool  size 3.62T  alloc 2.48T  free 1.15T  frag 58%  cap 68%  ONLINE
  nvme-eui...3a18-part3   1.82T   ONLINE      <- separate top-level vdev
  nvme-eui...3a36-part3   1.82T   ONLINE      <- separate top-level vdev
```

Two independent top-level `disk` vdevs. **This is a stripe, not a mirror.**

- `ashift` 12 (correct)
- `autotrim` **off**
- `compression` lz4
- last scrub 2026-09-13, 0 errors, 0 known data errors
- `feature@device_removal` **enabled** (never used)
- `feature@raidz_expansion` **enabled**
- `feature@log_spacemap` active

### NVMe drives

Both identical: KIOXIA EXCERIA PLUS G3 2 TB, firmware `ELFA01.2`, **DRAM-less**, M.2 2280.
Vendor-rated endurance ≈ 800 TBW (vendor spec; NVMe does not expose rated TBW).

| | `nvme0` | `nvme1` |
|---|---|---|
| Serial | YDBKF0VTZ0EA | YDBKF0UXZ0EA |
| PCI address | `5a:00.0` via root port `00:1d.0` | `59:00.0` via root port `00:1c.4` |
| Link | **PCIe 3.0 x2** (root port `LnkCap` limit) | PCIe 3.0 x4 |
| Percentage Used | **45 %** | **45 %** |
| Data written | 184 TB | 188 TB |
| Power-on hours | 19 597 | 19 591 |
| Temperature | 58 °C | 55 °C |
| Available spare | 100 % | 100 % |
| Media/data errors | 0 | 0 |
| Thermal throttle events | 0 | 0 |

Unsafe shutdowns: **93** on both.

Write rate ≈ 84 TB/year per drive. At that pace both reach 100 % wear in roughly 2.5 years,
**at the same time**.

Note the discrepancy: 184 TB written is ~23 % of 800 TBW, yet the drive's own counter says
45 %. The gap is write amplification — ZFS copy-on-write plus sync writes from NFS on a
DRAM-less controller. Trust the drive's counter.

### M.2 slots

MS-01 official specification (`store.minisforum.com/products/minisforum-ms-01-workstation`):
three M.2 2280 slots — one PCIe 4.0 x4, one PCIe 3.0 x4, one PCIe 3.0 x2.

Mapping to observed PCIe topology:

| Slot | Spec | Observed | Occupant |
|---|---|---|---|
| 1 ("leftmost") | **PCIe 4.0 x4, CPU** | `00:06.0`, `LnkCap x4 @16GT/s`, `Width x0` | **EMPTY** |
| 2 | PCIe 3.0 x4, PCH | `00:1c.4`, x4 @8GT/s | `nvme1` |
| 3 | PCIe 3.0 x2, PCH | `00:1d.0`, `LnkCap x2` | `nvme0` |

**The free slot is the fastest one** — the only Gen4 link and the only one attached directly
to the CPU. Slot-to-port mapping is inference from Raptor Lake-H topology; it matches the
published spec in every detail but is confirmed only by inserting a drive.

`dmidecode -t slot` on this board is **useless** — five entries, all `Available`, all sharing
ID 1 and bus address `00:00.0`, despite two drives being physically present. Do not draw
conclusions from it.

### PCIe slot

MS-01 has one PCIe 4.0 x16 physical / **x8 electrical**, half-height single-slot.

It is **occupied** by an ASMedia ASM1164 SATA controller (`01:00.0`, subsystem ID reports
`QNAP Systems 1853`). Observed `LnkCap x8 @32GT/s` but `LnkSta x2 @8GT/s` — the card itself
is only x2 Gen3. Adequate for four spinning disks (~1.6 GB/s shared), but the slot is spent.

### SATA and the HDDs

**MS-01 has no internal SATA ports and no drive bays** (48 mm chassis). The four 3.5" disks
are therefore in an **external enclosure with its own power supply**, connected through the
ASM1164 card. This makes the HDD set a genuinely separate hardware failure domain from the
NVMe — different enclosure, different PSU — though the same room.

Kernel reports `20/24 ports implemented (port mask 0xffff0f)`; this is bogus firmware, the
ASM1164 silicon is a 6-port device. Four ports are in use, all linked at 6.0 Gbps. Whether
0, 1 or 2 physical connectors remain free cannot be determined remotely.

All four disks are **completely unused**: no partition table, no `blkid` signature, no
`wipefs` signature, not in any ZFS pool or LVM group, not passed through to any VM or LXC
(verified against every `/etc/pve/qemu-server/*.conf` and `/etc/pve/lxc/*.conf`).

| Device | Model | Size | POH | SMART notes |
|---|---|---|---|---|
| `sda` | TOSHIBA HDWN160 (N300) | 6 TB | 59 344 (6.8 y) | 168 reallocated, 20 realloc events, **186 CRC UDMA** |
| `sdb` | HGST HDN726060ALE614 | 6 TB | 57 254 (6.5 y) | 0 reallocated, **44 Offline_Uncorrectable** |
| `sdc` | TOSHIBA HDWN160 (N300) | 6 TB | 57 478 (6.6 y) | 112 reallocated, 13 realloc events, 13 CRC |
| `sdd` | HGST HDN726060ALE614 | 6 TB | 54 427 (6.2 y) | clean — 0 reallocated, 0 pending, 0 CRC |

All report SMART `PASSED`. All are far outside a normal reliability window. **Suitable as a
second copy, not as the only copy of anything.** The CRC count on `sda` indicates a cable or
controller-port problem, not a platter problem — worth reseating before use.

### Space consumers on `rpool`

| Dataset | Used | Belongs on NVMe? |
|---|---|---|
| `rpool/timemachine` | 993 G | No — and at **97 % of its 1 T quota** |
| `rpool/nvr` (Frigate) | 921 G | No — sequential writes, **no quota set** |
| `rpool/home/backup` | 244 G | No |
| `rpool/var-lib-vz` | 221 G | No — ISOs, VM dumps, templates |
| `rpool/data` | 120 G | Yes — VM/LXC zvols |
| `rpool/k8s` | 6.13 G | Yes — Kubernetes PVs |
| `rpool/k8s-snapshots` | 96 K (empty) | — |

**The first four total ~2.38 T of the 2.48 T allocated.** Moving them off drops `rpool` to
roughly 600 G, which is what makes several options below possible.

`rpool/nvr` having no quota is its own hazard: Frigate can fill the pool and take down
Kubernetes storage with it.

### Snapshots

Three, all CSI-created, all on one volume:

```
rpool/k8s/ibakery-ibakery-db-2@snapshot-fa0d907f-...  304K
rpool/k8s/ibakery-ibakery-db-2@snapshot-ad04386f-...   80K
rpool/k8s/ibakery-ibakery-db-2@snapshot-5fdaf123-...   80K
```

Nothing for `rpool/ROOT/pve-1`, nothing for VM zvols, nothing for `rpool/home`, nothing for
`rpool/nvr`. With no redundancy, snapshots are the only line of defence — and there is none.

### Kubernetes storage path

The NFS server runs **on this host**; there is no separate NAS or TrueNAS VM.

- `nfs-server` active, listening on `0.0.0.0:2049`, rpcbind on `:111`
- `/etc/exports` is empty; real exports live in `/etc/exports.d/zfs.exports`, marked
  "DO NOT EDIT THIS FILE MANUALLY" — managed via the ZFS `sharenfs` property by
  democratic-csi's `zfs-generic-nfs` driver
- exports correspond 1:1 to `rpool/k8s/<namespace>-<pvc>` datasets, e.g.
  `authentik-authentik-stack-db-1/2`, `firecrawl-*-db-1/2`, `ibakery-ibakery-db-1/2`,
  `grafana-grafana`, `victoria-metrics-vmstorage-db-vmstorage-vm-0/1`
- export options `no_root_squash, async, sec=sys`
- the host mounts no external NFS
- `/etc/pve/storage.cfg` defines only `dir: local` and `zfspool: local-zfs`

So pods mount `pve.home:/rpool/k8s/<ns>-<pvc>`, and those datasets sit on the unprotected
stripe.

### Memory — the real bottleneck

```
MemTotal      65 442 328 kB
MemAvailable   2 545 692 kB     <- 3.9 %
Swap                     0      <- none at all
CommitLimit   32 721 164 kB
Committed_AS 101 428 008 kB     <- 3.1x CommitLimit
```

VM/LXC allocation totals 96 256 MiB (94 GiB) on a 62 GiB host — **1.55× overcommit**. It
holds together only because KSM reclaims ~10 GiB (`pages_sharing` 2 610 740). With no swap,
a load spike invokes the OOM killer rather than paging.

ARC is capped at 6.7 GiB but memory pressure has squeezed it to **2.82 GiB**, close to its
`c_min` of 1.95 GiB. Hit ratio 90.2 % (7.58 G hits / 819 M misses) — respectable, but at
2.82 GiB against 2.48 T of data it is caching almost nothing but metadata.

**Consequences for every option below:** a larger pool needs *more* ARC, and ARC is already
not getting what it was allotted. L2ARC would make things worse, since its headers live in
ARC. **Add RAM before growing storage.**

The board has two DDR5 SODIMM slots. Whether the current 64 GiB is 2×32 (no free slot) and
whether 2×48 GiB is supported needs physical verification.

### Thermals

| Sensor | Reading | Limit |
|---|---|---|
| **CPU package** | **95 °C** | high/crit **100 °C** |
| Cores | 76–95 °C | 100 °C |
| `nvme` 59:00 | 53.9 °C | warn 82.8 / crit 84.8 |
| `nvme` 5a:00 | 57.9 °C | warn 82.8 / crit 84.8 |
| MT7922 Wi-Fi | 50 °C | — |

Both NVMe report `Warning Comp. Temperature Time: 0` and `Critical: 0` — they have never
throttled, and have ~25 °C of headroom.

The constraint is the chassis, not the drives. **The CPU sits 5 °C below its throttle point**
with the system merely running its normal workload. Minisforum ships MS-01 with exactly
**one** M.2 heatsink for three slots.

## Risk summary

| Severity | Issue |
|---|---|
| 🔴 | `rpool` is a stripe. One drive failure destroys host, cluster, all PVs, all backups. |
| 🔴 | Drive wear is **correlated** — 45 % each, 6 hours apart in power-on time. |
| 🔴 | No snapshot policy. Three CSI snapshots on one volume is the entire coverage. |
| 🟠 | Both NVMe reach end of rated life in ~2.5 years, simultaneously. DRAM-less, no PLP, 93 unsafe shutdowns. |
| 🟠 | `MemAvailable` 2.4 GiB, zero swap, 1.55× overcommit. ARC starved to 42 % of its cap. |
| 🟠 | `rpool/timemachine` at 97 % of quota — backups will start failing. |
| 🟠 | CPU at 95 °C / 100 °C limit. |
| 🟡 | `rpool/nvr` has no quota — Frigate can fill the pool and break Kubernetes storage. |
| 🟡 | Fragmentation 58 % at 68 % capacity; `autotrim` off. |
| 🟡 | All four HDDs at 54–59 k hours with reallocated sectors or offline-uncorrectables. |
| 🟡 | No ECC memory. |
| ℹ️ | 24 TB of HDD spins 24/7 doing nothing. |

## Available positions for NVMe

Four, but they are **not equivalent**:

| Position | Link | Bootable | Character |
|---|---|---|---|
| Slot 1 (free) | PCIe 4.0 x4, CPU | yes | best |
| Slot 2 | PCIe 3.0 x4, PCH | yes | occupied by `nvme1` |
| Slot 3 | PCIe 3.0 **x2**, PCH | yes | occupied by `nvme0`, narrowest |
| Thunderbolt 4 enclosure (owned) | ~3 GB/s, hot-plug | **no** | cable, weak cooling |

A TB4 leg in the root pool is an operational hazard: an unplugged cable, a TB controller
reset, enclosure sleep or thermal throttling degrades the pool. It cannot be a boot device.
**Excellent transitional position, poor permanent one.**

## Options

### Option 0 — do nothing

Keeps the risks above. Included only as the baseline: the expected cost is total loss of the
lab on the first NVMe failure, with the two candidate drives wearing out in lockstep.

### Option 1 — two mirrors across four positions (recommended)

Two new drives; `zpool attach` twice. **Fully online, no data movement, no downtime.**
Usable capacity unchanged at 3.62 T.

**Mirror pairing is the critical decision.** Do *not* pair like with like:

```
WRONG: mirror A = new + new
       mirror B = KIOXIA + KIOXIA    <- both 45 % worn, correlated failure
```

Vdev B would consist of two drives that wear out together; losing a top-level vdev loses the
pool. That reproduces the very problem being fixed.

```
RIGHT: mirror A = nvme0 (worn, slot 3) + new (slot 1)
       mirror B = nvme1 (worn, slot 2) + new (TB4)
```

Every vdev then survives the loss of its worn member. Cost: vdev A writes at x2 link speed,
since a mirror is as fast as its slower member. Acceptable — redundancy before throughput.

### Option 2 — raidz1 across three internal drives

3.62 T usable, tolerates one failure, uses only internal slots. **Requires destroy and
restore**: no operation converts two single-disk vdevs into a raidz vdev, and
`raidz_expansion` only extends an *existing* raidz. So: full backup of 2.48 T → `zpool
destroy` → recreate → restore, with the root pool offline throughout.

Honest accounting of the trade:

- **In favour:** the only way to keep 3.62 T with three drives; mirrors would need four.
  `raidz_expansion` is enabled, so a fourth drive could be added later.
- **Against:** unreachable without downtime; random write IOPS of a single vdev rather than
  two; resilver must read *all* surviving drives and recompute parity, which is the worst
  possible stress on correlated-wear drives; `zpool remove` is permanently unavailable for
  raidz vdevs, and raidz1 cannot later become a mirror.
- **Space amplification is often overstated.** At `ashift=12` on 3-wide raidz1: 16 K
  `volblocksize` → 1.5× overhead, 8 K → 1.5×, 4 K → 2.0×. Only the 4 K case loses to a
  mirror's 2.0×. **Check `zfs get volblocksize rpool/data` before using this as an
  argument.**
- On NVMe the IOPS objection is much weaker than on spinning disks — a single vdev still
  delivers tens of thousands of IOPS.

**The argument that actually decides it:** after `nvr` and `timemachine` move to HDD, `rpool`
needs ~600 G. raidz1 buys 3.62 T instead of 1.81 T — capacity that would sit empty — and
charges downtime, a Proxmox restore, a worse resilver profile and permanent loss of
flexibility for it. If the four idle HDDs did not exist, this recommendation would flip.

### Option 3 — raidz2 across four positions

3.62 T usable, tolerates two failures. Also requires destroy and restore, also pulls the TB4
leg permanently into the pool, also forecloses `zpool remove`. Strongest fault tolerance on
paper, worst fit for a pool that is about to shrink to 600 G.

### Orthogonal: the HDD pool

Independent of which option is chosen, the four idle 6 TB disks should become a pool.

Prefer **two mirrors (stripe of mirrors, ~10.9 TiB)** over `raidz1` (~16 TiB). At 57 k hours
a 6 TB raidz1 resilver runs long and hammers all three survivors; a mirror resilver reads
only its partner and finishes much sooner. Pair so that no mirror contains two suspect
drives: `sdd`+`sda` and `sdb`+`sdc`.

Migration targets, in order of benefit: `rpool/nvr` (sequential writes, and the main cause of
SSD wear), `rpool/timemachine` (also fixes the 97 % quota), `rpool/home/backup`,
`rpool/var-lib-vz`.

## Recommended path

Assumes **two new 4 TB NVMe** with DRAM cache. Every step is online.

### Phase 1 — redundancy immediately

1. Install new drive in slot 1. Replicate the partition layout from an existing drive
   (`sgdisk --replicate`): ESP + ZFS partition.
2. `proxmox-boot-tool format` and `init` the new ESP.
3. `zpool attach rpool <nvme0-part3> <slot1-part3>` → vdev A becomes a mirror.
4. Install second new drive in the TB4 enclosure.
   `zpool attach rpool <nvme1-part3> <tb4-dev>` → vdev B becomes a mirror.

Result: **pool fully redundant at 3.62 T, zero data moved.** The single largest risk is gone.

### Phase 2 — slim down `rpool`

5. Create the HDD pool (two mirrors). Migrate `nvr`, `timemachine`, `home/backup`,
   `var-lib-vz` with `zfs send | zfs recv`. `rpool` allocation drops 2.48 T → ~600 G.
6. Set a quota on the relocated `nvr` dataset.

### Phase 3 — consolidate internally

7. `zpool remove` vdev B entirely — frees `nvme1` *and* the TB4 drive. Now permitted, since
   600 G fits comfortably on the remaining vdev.
8. Move the TB4 drive into the vacated slot 2. `zpool attach` it to vdev A → three-way mirror.
9. `zpool detach nvme0` → leaves `mirror(4 TB slot 1, 4 TB slot 2)`.
10. `zpool set autoexpand=on` / `zpool online -e` → 3.62 T usable from one vdev.

### Phase 4 — the things that were missing anyway

11. Snapshot policy (sanoid or zfs-auto-snapshot) covering `rpool/ROOT`, `rpool/data`,
    `rpool/k8s`, `rpool/home`.
12. `zfs send` replication `rpool` → HDD pool. This is the first point at which a second copy
    on different media exists.

**End state:** a mirror of two new 4 TB drives in the two fastest slots, both bootable with
initialised ESPs. Slot 3 (the x2 link) free. TB4 enclosure free. Both worn KIOXIA out of the
pool — one as a cold spare, one in the TB4 enclosure for offline copies. Bulk data on
spinning disks in a separate enclosure with its own PSU. Capacity unchanged.

Nothing in this path requires a reinstall, a restore, or cluster downtime.

### Why 4 TB rather than 2 TB

During phases 1–2 each mirror is capped by its smaller member, so only 1.81 T of each 4 TB
drive is usable — half sits idle. After phase 3, `autoexpand` recovers it and 3.62 T comes
from **one** vdev in **two** slots. With 2 TB drives the end state would require keeping all
four positions permanently occupied, including the Thunderbolt one.

### Drive selection criteria

In priority order:

1. **DRAM cache — mandatory.** More important than sequential throughput. The current
   drives' 45 % wear at only 184 TB written is write amplification on a DRAM-less controller
   under ZFS. Buying another DRAM-less drive repeats the mistake.
2. **Different vendor or batch** from the existing pair, to decorrelate failure timing.
3. **Power-loss protection if budget allows**, given 93 unsafe shutdowns. Note that MS-01
   ships with a U.2 conversion plate and officially supports U.2 — a used enterprise U.2
   drive (e.g. Micron 7450, Kioxia CD6) offers PLP and far higher endurance, at the cost of
   space and heat.

## Critical gotchas

1. **ESP, not just ZFS.** `rpool` lives on partition 3; partition 2 is the ESP. Attaching
   only the ZFS partition leaves a pool that survives a drive failure but a machine that will
   not boot from the survivor. Replicate the GPT, then run `proxmox-boot-tool format` +
   `init` on every new ESP, and verify with `proxmox-boot-tool status`. Keep an ESP on all
   three internal drives. **This is the classic way this operation goes wrong, and it is
   discovered during an outage.**
2. **Attach partitions, not whole disks.** `zpool attach rpool nvme0n1p3 nvme2n1p3`, never
   `nvme2n1`.
3. **`zpool remove` is the only irreversible step.** It also leaves a permanent *indirect
   vdev mapping* that consumes RAM for the life of the pool — and RAM is this host's scarcest
   resource. At ~600 G the mapping is small, but it is not free. Confirm
   `feature@device_removal` is still `enabled` and that allocation fits the survivor
   *before* starting, and let the removal finish (`zpool status` reports progress) before
   touching anything else.
4. **Ordering in phase 3.** Detaching before attaching, or skipping `autoexpand`, leaves a
   1.81 T pool despite two 4 TB drives. Verify with `zpool list` after step 10.
5. **The TB4 leg is transitional.** While it is a mirror member, treat the enclosure as part
   of the server: do not unplug it, do not let it sleep, watch its temperature.
6. **Fit a heatsink to the new drive in slot 1** — it is a Gen4 link next to the CPU, and the
   box shipped with only one heatsink.
7. **Repaste while the case is open.** 95 °C against a 100 °C limit is not a state to add a
   heat source to.
8. **RAM before capacity.** A larger pool with the same 2.4 GiB of available memory yields a
   slower system, not a faster one.

## Requires physical inspection

Cannot be settled over SSH:

1. **Does slot 1 physically exist**, and is it 2280 or 22110? The free CPU Gen4 x4 root port
   (`00:06.0`) is confirmed; whether a socket is wired to it is not. Note the contradiction
   in Minisforum's own materials — the spec table says three 2280 slots, the marketing copy
   mentions "two 22110 M.2".
2. **How many physical SATA connectors** the ASM1164 card exposes (4 or 6), and whether two
   are free.
3. **SODIMM configuration** — 2×32 with no free slot, and whether 2×48 GiB is supported.
4. **Cooling condition** — 95 °C suggests dried thermal paste or a clogged heatsink.

## Out of scope, still open

- **Off-site backup.** Everything above is local redundancy. With one host and one room there
  is still no off-site copy. CloudNativePG currently uses `method: volumeSnapshot` only, so
  snapshots live on the same pool as the data, and there is no WAL archiving or PITR.
  Cheapest fix is `barmanObjectStore` pointing at an external S3 (B2/Wasabi/Hetzner), plus
  `vmbackup` for VictoriaMetrics. One commit, independent of this document.
- **Garage.** Evaluated and rejected for this cluster — see
  `docs/research/garage-operator-analysis.md`. It would be the right tool once a *second
  physical site* exists, since geo-distribution is its actual design purpose. It is not a
  substitute for having one.
- **`autotrim`** on `rpool` is off; worth revisiting for NVMe.
- **Fragmentation** 58 % at 68 % capacity will improve on its own once the bulk datasets move
  off.
