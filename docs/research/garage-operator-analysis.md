# garage-operator — analysis

Source: <https://github.com/rajsinghtech/garage-operator>
Docs: <https://rajsinghtech.github.io/garage-operator/>

## TL;DR

A Kubernetes operator (Go / Kubebuilder v4) for managing [Garage](https://garagehq.deuxfleurs.fr/)
— a distributed, S3-compatible object storage written in Rust, designed for self-hosting
and geo-distributed deployments.

| Item | Value |
|---|---|
| License | Apache-2.0 |
| Stars / forks | ~257 / 27 |
| Open issues | 6 |
| Latest release | v0.7.10 |
| Repo age | ~8 months (created 2026-01-15) |
| Maintainers | effectively one (`rajsinghtech`) + Renovate |
| Pace | PRs numbered up to #410 |

## What it does

It stitches together two worlds: Kubernetes (StatefulSets, PVCs, DaemonSets, Services, PDBs) and
the **Garage Admin API v2** (layout, buckets, S3 keys). The operator does not invoke the Garage CLI —
that is a deliberate architectural decision.

### CRDs (group `garage.rajsingh.info`, all namespaced)

| Kind | Version | Short | Role |
|---|---|---|---|
| `GarageCluster` | **v1beta2** (v1beta1 deprecated, v1alpha1 conversion) | `gc` | topology, configuration, layout, federation, health |
| `GarageNode` | v1beta1 | `gn` | a single Garage identity + its role in the layout |
| `GarageBucket` | v1beta1 | `gb` | bucket, aliases, quotas, website, lifecycle, grants |
| `GarageKey` | v1beta1 | `gk` | S3 keys (generated/imported) → Secret with credentials |
| `GarageAdminToken` | v1beta1 | `gat` | static Admin API bearer token in a Secret |
| `GarageReferenceGrant` | v1beta1 | `grg` | cross-namespace reference authorization (Gateway API pattern) |

### Four GarageCluster topology "shapes"

`storage` and `connectTo` are mutually exclusive:

| Shape | Required fields | Workload |
|---|---|---|
| Storage | `storage` | 1 StatefulSet (replica=1) per slot; `nodeLocalPools[]` → DaemonSet per pool |
| Unified | `storage` + `gateway` | storage + 1 gateway `GarageNode` per Auto replica |
| Edge gateway | `gateway` + `connectTo` | 1 gateway StatefulSet; storage is remote |
| Management handle | `connectTo` only | **no** workload — the operator manages a remote Admin API |

Additionally: node-local pools (DaemonSet + HostPath per Node), multi-site federation
(`remoteClusters[]`), multi-disk (`data.paths[]`), `zoneFrom` (Node label → zone),
COSI integration, ServiceMonitor, GitOps disaster recovery via `dataSourceRef`.

## The key architectural idea

**The Garage identity (`node_key`) is the durability boundary.** The operator never assumes
that a K8s name, a StatefulSet ordinal, or a PVC name proves that a new process is the same Garage
node. Implementation consequences:

- **`OnDelete` rollout with UID-based fencing** — **at most one actor is replaced
  at a time**; the operator verifies the exact replacement Pod and the Garage identity, waits for
  layout and health stabilization. State in `status.storageRollout`.
- **Drain with "terminal proof"** — in `consistencyMode: consistent` the operator proves layout
  convergence → starts the exact block repair workers → observes delayed resync → **keeps
  the source process online** until it gathers proof of completion. State in `status.storageDrain`.
- **Add-before-remove cycles** for nodes (`cyclePhase`, `cycleSiblingNodeId`).
- **PVC reservations by UID** — `status.managedPVCs` records the exact PVC UID or a pending
  reservation; `observedPodUid` prevents reuse of stale process proof.
- **Fail-closed as the default policy**:
  - `layoutManagement.autoApply: false` — changes wait in `status.stagedRoles` / `layoutPreview`
  - scale-down blocked below `replication.factor` → `StorageScaleDownBlocked`
  - deletion of a non-empty bucket blocked → `DeletionBlocked / BucketNotEmpty`
  - admission webhooks required (immutable identity fields, cross-namespace, reserved env vars)
  - leader election de facto mandatory (serialization of layout mutations)

## Technology stack

| Dependency | Version |
|---|---|
| Go | 1.26.0 |
| `sigs.k8s.io/controller-runtime` | v0.25.1 |
| `k8s.io/api` / `apimachinery` / `client-go` | v0.37.0 |
| Kubebuilder CLI | 4.10.1 (`go.kubebuilder.io/v4`, domain `rajsingh.info`) |
| `BurntSushi/toml` | v1.6.0 (renders `garage.toml`) |
| `google/cel-go` | v0.29.2 (CEL validation in CRDs) |
| Ginkgo / Gomega | v2.32.2 / v1.43.0 |
| Prometheus Operator API | v0.94.0 |

**Runtime:** K8s 1.25+ (1.27+ for node-local pools), Helm 3.8+, Garage v2.0.0+
(tested on v2.4.0, samples v2.4.1), **cert-manager** for webhooks.

**Dockerfile:** multi-stage `golang:1.27` → `gcr.io/distroless/static:nonroot`
(both pinned to digests), `CGO_ENABLED=0`, `USER 65532`, native Go cross-compilation.
Platforms: amd64, arm64, arm, s390x, ppc64le.

## Strengths

1. **A serious approach to data durability** — the identity-first design solves real classes
   of bugs that, in naive operators, end in data loss.
2. **Extreme test coverage** — tests exceed production code in volume:
   `test/e2e/e2e_test.go` 369 KB, `api/v1beta1/webhook_test.go` 196 KB,
   `dual_version_test.go` 44 KB (simultaneous v1beta1/v1beta2). Plus "meta" tests:
   `rbac_chart_sync_test.go`, `crd_upgrade_compatibility_test.go`, `config_determinism_test.go`.
3. **Enterprise-class supply chain** — keyless cosign, provenance attestations
   (`gh attestation verify`), SPDX SBOM, all base images pinned to digests,
   verification of the `install.yaml` artifact as well.
4. **Documentation at the level of a commercial product** — an MkDocs Material site
   (concepts / getting-started / how-to / operations / reference), 7 dated design docs,
   MIGRATION.md 35 KB, README 94 KB, versioned JSON Schemas in `schemas/`.
5. **Rich, observable status** — `layoutDiagnosis`, `unreachablePeers`, `blockErrorDetails`,
   `resyncQueueLength`, `scrubStatus`, `activeRepairs` + granular conditions
   (`QuorumAtRisk`, `PeerUnreachable`, `GatewayLayoutDegraded`, `StorageDrainReady`…).
6. **Cross-namespace security** modeled on the Gateway API ReferenceGrant.
7. **9 CI workflows**: test, test-e2e (matrix), lint, docker, helm, release, schemas, pages.

## Weaknesses and risks

### Organizational

1. **Bus factor ≈ 1.** Effectively a single maintainer, no organization, governance, or foundation.
   For a storage operator holding production data — a high risk.
2. **Pre-1.0.** Within 8 months: v1alpha1 → v1beta1 (deprecated) → v1beta2. Further
   breaking changes are likely.
3. **Short track record** — no public production references.

### Technical

4. **Monolithic controller files** — `garagecluster_controller.go` **332 KB**,
   `garagenode_controller.go` 214 KB, `garagecluster_webhook.go` (v1beta2) 146 KB.
   Serious structural debt: it hinders review and onboarding and increases regression risk.
5. **Operational complexity** — 4 topology shapes, Auto vs Manual, node-local pools,
   federation, edge gateway, management handle, factor migration. Many transitions are
   **one-way** (`Auto → Manual`, changes to `backing`/`gateway`/`external`).
6. **Flaky e2e** — recent commits: "deflake multicluster bootstrap", "deflake e2e
   setup/teardown", "CRD discovery and teardown races". The most complex paths
   (multicluster/federation) are not yet deterministic.
7. **Many "compatibility-only" fields** — `security.tls` (rejected), `volumeClaimTemplateSpec`
   (rejected), `effectivePermissions` (not populated), `dbEngine`/`garageFeatures`/
   `storedData` on GarageNode (not populated), old conditions. **The CRD schema lies
   about actual capabilities** — you have to read admission warnings as the source of truth.
   A real trap for GitOps.

### Security

8. **`GarageAdminToken` is not a real token** — a static bearer in a Secret with no
   server-side scope, expiry, or revocation. `expiresAt`/`neverExpires` are fictional.
   Deleting the resource **does not revoke** the bytes already read by a running Garage process.
9. **No credential rotation on key expiry** — `GarageKey` expiry sets
   `status.phase: Expired`, but does not rotate the credentials.
10. **`namespaceSelector` in ReferenceGrant** = authorization based on Namespace labels.
    Whoever can change a Namespace label changes the authorization scope. An empty selector = all.
11. **`rpc_secret` shared across the mesh, with no in-place rotation.** Garage removed `rpc_tls`,
    so the operator does not have that layer. Exposing the RPC port = a serious risk.
12. **`webhooks.enabled=false`** removes almost all of the operator's safety, and it is
    an ordinary Helm flag. The dependency on cert-manager is hard.

### Functional gaps

13. **Website routing rules / redirect-all** are not managed through CRDs — you have to use the S3 API.
14. **`dataSourceRef` (disaster recovery)** requires an external populator (Volsync / Kopia
    Restore), is **immutable**, and the operator "cannot look inside the source's contents".
    A partial restore will get as far as Garage starting and only fail there. The docs themselves recommend
    configuring populator retry/timeout/alerting "so that recovery does not hang silently".
15. **`VolumeGroupSnapshot`** as the foundation of restore is expected to reach GA only in K8s 1.36
    — the functionality is ahead of the ecosystem.
16. **`Ready=True` does not mean healthy.** The docs explicitly warn: Ready only says that the desired
    shape has been reconciled — not that data is backed up or that a federation peer is alive.
    An easy source of a false sense of security in alerting.
17. **Node-local pools are not a failure domain** nor a replication group — even though they look like one.

## Installation

Requirements: K8s 1.25+ (1.27+ for node-local pools), Helm 3.8+, Garage v2.0.0+, cert-manager.

```bash
helm install garage-operator \
  oci://ghcr.io/rajsinghtech/charts/garage-operator \
  --version 0.7.10 \
  --namespace garage-operator-system \
  --create-namespace
```

Namespace-scoped mode:

```bash
helm upgrade --install garage-operator \
  oci://ghcr.io/rajsinghtech/charts/garage-operator \
  --namespace garage-operator-system --create-namespace \
  --set 'watchNamespaces={storage,team-a,team-b}'
```

Supply chain verification:

```bash
IMAGE=ghcr.io/rajsinghtech/garage-operator:v0.7.10
cosign verify "$IMAGE" \
  --certificate-identity-regexp '^https://github.com/rajsinghtech/garage-operator/\.github/workflows/docker\.yml@refs/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify "oci://$IMAGE" --repo rajsinghtech/garage-operator
cosign download attestation "$IMAGE" --predicate-type https://spdx.dev/Document/v2.3
```

## Usage example

**1. Admin API token** (in the same namespace as the GarageCluster):

```bash
kubectl create namespace garage
kubectl create secret generic garage-admin-token -n garage \
  --from-literal=admin-token="$(openssl rand -hex 32)"
```

**2. The cluster:**

```yaml
apiVersion: garage.rajsingh.info/v1beta2
kind: GarageCluster
metadata:
  name: garage
  namespace: garage
spec:
  image: dxflrs/garage:v2.4.1@sha256:9c96caa2612d3411acc5b0e6701fb238dbfba33e533a6d7d3d811a4b12d0d020
  zone: lab
  replication:
    factor: 3
    consistencyMode: consistent
  storage:
    replicas: 3
    metadata:
      size: 10Gi
    data:
      size: 100Gi
  network:
    rpcBindPort: 3901
    service:
      type: ClusterIP
  s3Api:
    bindPort: 3900
    region: garage
  admin:
    adminTokenSecretRef:
      name: garage-admin-token
      key: admin-token
```

> `replicas: 3` + `factor: 3` make sense **only** when 3 independent failure domains exist.
> For a local experiment: `factor: 1` + `EmptyDir`, treat the data as disposable.

**3. Bucket + key:**

```yaml
apiVersion: garage.rajsingh.info/v1beta1
kind: GarageBucket
metadata:
  name: app-data
  namespace: garage
spec:
  clusterRef:
    name: garage
  quotas:
    maxSize: 10Gi
---
apiVersion: garage.rajsingh.info/v1beta1
kind: GarageKey
metadata:
  name: app-key
  namespace: garage
spec:
  clusterRef:
    name: garage
  bucketPermissions:
    - bucketRef:
        name: app-data
      read: true
      write: true
```

**4. Retrieving the credentials:**

```bash
kubectl wait --for=condition=Ready garagecluster/garage -n garage --timeout=10m
kubectl wait --for=condition=Ready garagekey/app-key -n garage --timeout=5m
kubectl -n garage get secret app-key -o jsonpath='{.data.access-key-id}' | base64 -d
kubectl -n garage get secret app-key -o jsonpath='{.data.secret-access-key}' | base64 -d
kubectl -n garage get secret app-key -o jsonpath='{.data.endpoint}' | base64 -d
```

By default the Secret contains: `access-key-id`, `secret-access-key`, `endpoint`, `host`,
`scheme`, `region`. Optionally (via `secretTemplate`): `bucket-name`, `credentials`
(AWS shared credentials file).

**Inspection:**

```bash
kubectl get garagecluster,garagenode -n garage
kubectl get garagecluster garage -n garage \
  -o jsonpath='{.status.phase}{"\n"}{.status.layoutDiagnosis}{"\n"}'
kubectl get garagecluster garage -n garage -o jsonpath='{.status.conditions}'
```

## Alternatives — the ecosystem landscape

As of 2026-09-14.

### All solutions found for Garage

| Solution | URL | Type | ★ | Last activity | Status |
|---|---|---|---|---|---|
| **Official Deuxfleurs Helm chart** | `git.deuxfleurs.fr/Deuxfleurs/garage` → `script/helm/garage` | StatefulSet + CRD for discovery only | in-tree | alongside Garage releases (v2.4.x) | The only official one |
| **rajsinghtech/garage-operator** | <https://github.com/rajsinghtech/garage-operator> | full operator | **257** | v0.7.10, 2026-09-10 | Dominant |
| LordAntonius/garage-s3-operator | <https://github.com/LordAntonius/garage-s3-operator> | buckets/keys only | 4 | 2026-02-15 | Hibernating |
| spiarh/garage-s3-operator | <https://github.com/spiarh/garage-s3-operator> | buckets/keys only | 0 | 2026-07-21 | Prototype |
| buktio/buktio-operator | <https://github.com/buktio/buktio-operator> | buckets/keys only | 0 | 2026-06-23 | Embryonic (1 day) |
| Arsolitt/terraform-provider-garagehq | <https://github.com/Arsolitt/terraform-provider-garagehq> | Terraform, Admin API **v2** | 14 | 2026-09-06 | Active |
| jkossis/terraform-provider-garage | <https://github.com/jkossis/terraform-provider-garage> | Terraform | 15 | 2026-07-16 | Active |
| d0ugal/terraform-provider-garage | <https://github.com/d0ugal/terraform-provider-garage> | Terraform, Admin API v1 | 5 | 2026-09-13 | Active |
| zarethrex/ansible-role-deuxfleurs-garage-s3 | <https://github.com/zarethrex/ansible-role-deuxfleurs-garage-s3> | Ansible (bare metal) | 0 | 2026-06-08 | Niche |
| **Crossplane provider** | — | — | — | — | **Does not exist** |

Additionally ~8 independent Helm charts on ArtifactHub (all of them bare StatefulSets):
`charts-derwitt-dev/garage` (2.4.2 — the freshest), `deimosfr-charts/garage` (2.3.0),
`ncsa/garage` (0.9.1), `kfirfer/garage` (0.5.3), `charliecharts/garage` (0.7.1),
`quench-garage/garage` (0.0.10, hardened single-node), `garage-ui/garage-ui` (web UI).

### What the official Garage documentation recommends

[Cookbook: Kubernetes](https://garagehq.deuxfleurs.fr/documentation/cookbook/kubernetes/)
points to **exactly one** thing: a Helm chart cloned from the source repo
(`git clone https://git.deuxfleurs.fr/Deuxfleurs/garage && cd garage/script/helm`).
The chart is **not published** to any Helm/OCI registry.

Acknowledged limitations:

- The `garagenodes.deuxfleurs.fr` CRD serves **solely** for `kubernetes_discovery` — not for
  managing buckets/keys.
- *"After deploying, cluster layout must be configured **manually**"* — the layout is typed in
  by hand via `kubectl exec ... garage layout`.
- Growing a PVC requires the `kubectl delete sts --cascade=orphan` hack.
- Deleting the release leaves an orphaned CRD.

The documentation **does not mention any operator** — neither its own nor a third-party one.
Interpretation: Deuxfleurs treats Kubernetes as *one of many* targets (alongside Docker,
systemd, NixOS) and deliberately does not invest in a K8s-native lifecycle. Garage's philosophy
("lightweight, simple, self-hosted at small scale") is directly at odds with building a heavy operator.
That explains the vacuum filled by an external project.

### Is there any real competition?

**No.** `rajsinghtech/garage-operator` is the dominant option, indeed the only serious one:

1. **A 64:1 advantage in stars** over the closest "competitor" (257 vs 4); the rest have 0★.
2. **The only one that deploys and manages a cluster at all.** All three alternatives
   (LordAntonius, spiarh, buktio) are *day-2* operators — they assume a running Garage and only
   call the Admin API for buckets and keys. Functionally they cover **one** of seven areas.
3. **The only one with an ecosystem** — docs site, releases with `install.yaml`, Helm chart, compatibility
   matrix, e2e, Renovate, external contributors.

**An interesting phenomenon:** **4 independent** Terraform providers for Garage appeared within a year.
The community is just as willing to solve the bucket provisioning problem **outside** Kubernetes
as through CRDs. That is a real architectural alternative, not merely a curiosity.

### Competitive context: MinIO / Ceph / SeaweedFS

| Project | ★ | Last push | Status |
|---|---|---|---|
| `rook/rook` (Ceph RGW / `CephObjectStore`) | 13 659 | 2026-09-14 | CNCF Graduated, very active |
| `minio/operator` | 1 422 | 2026-03-20 | 🔴 **ARCHIVED** |
| `seaweedfs/seaweedfs-operator` | 334 | 2026-09-14 | Active |
| `rajsinghtech/garage-operator` | 257 | 2026-09-14 | Active |

**The most important observation:** `minio/operator` has been **archived** (`archived: true`,
last commit 2026-03-20) — this fits a broader trend of closing off MinIO features
in the community edition. The official MinIO operator has ceased to be a safe choice, which materially
increases the appeal of Garage and SeaweedFS as alternatives.

Positioning: Rook = enterprise/datacenter (at the cost of enormous operational complexity);
MinIO Operator = **dead**; SeaweedFS Operator = medium maturity, community-driven;
Garage Operator = the youngest, the fastest growing, a single maintainer, but functionally
surprisingly complete. With 257★ it is in the same league as SeaweedFS (334★), even though it was created
7 years later (2026 vs 2019).

### Selection recommendation

| Scenario | Recommendation |
|---|---|
| Declarative management in K8s, GitOps | `rajsinghtech/garage-operator`, pinned version, API treated as unstable until 1.0 |
| Priority: stability, you accept a manual layout | official chart + Terraform provider for buckets/keys |
| Hedging against the bus factor | fork the operator + pin to a digest |

## Verdict

The project is **considerably more mature than a typical hobby operator** — the engineering quality (tests,
supply chain, documentation) is at the level of a commercial product, and the approach to
data durability is well thought through and articulated.

**It is suitable for production under these conditions:**

- pinned versions: chart + operator + Garage image — all down to digests
- cert-manager installed, webhooks **enabled**
- leader election enabled
- deliberately following `MIGRATION.md` at every upgrade
- alerting based on the real conditions (`QuorumAtRisk`, `PeerUnreachable`), **not** on `Ready`

**This is not "set and forget".** The configuration surface is enormous, many transitions
are one-way and require manual procedures. There is no 1.0-class API stability guarantee.
