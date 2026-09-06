# ZFS Friendly Volume Names Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all democratic-csi ZFS datasets from `pvc-<uuid>` names to `{namespace}-{pvcname}` so datasets are identifiable in `zfs list` on pve.home.

**Architecture:** Configure democratic-csi to name NEW volumes via `_private.csi.volume.idTemplate` (requires `--extra-create-metadata` on the external-provisioner). Then re-provision every existing volume: empty caches by PVC deletion, CNPG databases by rolling instance replacement (operator streams data from surviving replica), grafana by manual data copy. vmstorage history loss is accepted (owner confirmed metrics history not needed).

**Tech Stack:** Flux CD, Helm (democratic-csi chart 0.15.1), SealedSecrets (kubeseal), CNPG operator, ZFS on pve.home (SSH), kubectl.

**Key facts (verified during planning):**
- Repo: `/Users/jabbas/Projects/flux-home-system` (branch `main`, push triggers Flux)
- Driver config secret: `democratic-system/csi-zfs-pve-ssd`, key `driver-config-file.yaml`, sealed in `flux/infrastructure/democratic-csi/config-zfs-pve-ssd.yaml` with `sealedsecrets.bitnami.com/cluster-wide: "true"`
- HelmRelease: `flux/infrastructure/democratic-csi/release.yaml` (chart `democratic-csi` 0.15.1, driver `zfs-generic-nfs`)
- Dynamic dataset parent on pve.home: `rpool/k8s` (NFS-shared filesystem datasets)
- StorageClass `zfs-nfs-csi`, reclaimPolicy **Delete** → deleting a PVC DESTROYS its dataset
- Current volumes (all Bound, no orphans):
  - `authentik/authentik-stack-db-3` → pvc-301d63f0… (CNPG, replicated ×2)
  - `authentik/authentik-stack-db-4` → pvc-8841925b… (CNPG)
  - `firecrawl/firecrawl-firecrawl-stack-db-1` → pvc-401ce362… (CNPG ×2)
  - `firecrawl/firecrawl-firecrawl-stack-db-2` → pvc-edf5ba4f… (CNPG)
  - `ibakery/ibakery-db-1` → pvc-ba3ff082… (CNPG ×2)
  - `ibakery/ibakery-db-2` → pvc-e3c89fdd… (CNPG; has nightly VolumeSnapshot — will be orphaned/regenerated, acceptable)
  - `grafana/grafana` → pvc-a46325ad… (single PVC, ~30M, needs data copy)
  - `victoria-metrics/vmselect-cachedir-vmselect-vm-{0,1}` → pvc-b7d6769f…, pvc-32248454… (pure cache, disposable)
  - `victoria-metrics/vmstorage-db-vmstorage-vm-{0,1}` → pvc-9fe1f7a8…, pvc-9de7d78f… (history loss ACCEPTED by owner)

---

### Task 1: Enable `--extra-create-metadata` on the external-provisioner

**Files:**
- Modify: `flux/infrastructure/democratic-csi/release.yaml` (the `controller.externalProvisioner` block, currently lines 38–44)

- [ ] **Step 1: Edit release.yaml**

Change:

```yaml
      externalProvisioner:
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
```

to:

```yaml
      externalProvisioner:
        extraArgs:
          - --extra-create-metadata
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
```

- [ ] **Step 2: Verify the chart renders the flag**

```bash
cd /Users/jabbas/Projects/flux-home-system
helm repo add democratic-csi https://democratic-csi.github.io/charts/ 2>/dev/null; helm repo update democratic-csi >/dev/null
helm template democratic-csi democratic-csi/democratic-csi --version 0.15.1 -n democratic-system \
  -f <(python3 -c "import yaml,sys; d=yaml.safe_load(open('flux/infrastructure/democratic-csi/release.yaml')); print(yaml.dump(d['spec']['values']))") \
  | grep -B2 -A2 "extra-create-metadata"
```

Expected: rendered controller Deployment args include `--extra-create-metadata` on the `external-provisioner` container. If the chart ignores `extraArgs` (nothing rendered), STOP and check chart values reference: `helm show values democratic-csi/democratic-csi --version 0.15.1 | grep -A10 externalProvisioner` and adapt the key accordingly.

- [ ] **Step 3: Commit and push**

```bash
git add flux/infrastructure/democratic-csi/release.yaml
git commit -m "feat(democratic-csi): pass PVC metadata to driver for dataset naming

--extra-create-metadata makes csi.storage.k8s.io/pvc/name and
.../pvc/namespace available to the driver as create parameters,
enabling human-readable ZFS dataset names via idTemplate."
git push origin main
```

- [ ] **Step 4: Wait for Flux + verify live deployment**

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile helmrelease democratic-csi -n democratic-system
kubectl get deployment -n democratic-system democratic-csi-controller -o yaml | grep -A1 "extra-create-metadata"
kubectl get pods -n democratic-system
```

Expected: `--extra-create-metadata` present in controller pod args; controller pod Running/Ready after rollout.

### Task 2: Add `idTemplate` to the driver config (reseal `csi-zfs-pve-ssd`)

**Files:**
- Modify: `flux/infrastructure/democratic-csi/config-zfs-pve-ssd.yaml` (replace with newly sealed secret)

- [ ] **Step 1: Confirm kubeseal is available and find the sealed-secrets controller**

```bash
which kubeseal || brew install kubeseal
kubectl get pods -A | grep -i sealed
```

Note the controller namespace and service name (e.g. `kube-system`/`sealed-secrets`). Used in Step 4.

- [ ] **Step 2: Extract the live (unsealed) driver config**

```bash
umask 077
kubectl get secret -n democratic-system csi-zfs-pve-ssd \
  -o jsonpath='{.data.driver-config-file\.yaml}' | base64 -d > /tmp/driver-config.yaml
grep -n "_private" /tmp/driver-config.yaml || echo "no existing _private block"
head -5 /tmp/driver-config.yaml
```

Expected: a `zfs-generic-nfs` driver config (contains SSH credentials — keep in /tmp only, delete in Step 7). Confirm there is NO existing `_private:` top-level key (if there is, merge instead of append).

- [ ] **Step 3: Append the idTemplate block**

```bash
cat >> /tmp/driver-config.yaml <<'EOF'
_private:
  csi:
    volume:
      idTemplate: "{{ parameters.[csi.storage.k8s.io/pvc/namespace] }}-{{ parameters.[csi.storage.k8s.io/pvc/name] }}"
EOF
python3 -c "import yaml; d=yaml.safe_load(open('/tmp/driver-config.yaml')); print('YAML OK; _private:', d.get('_private'))"
```

Expected: `YAML OK; _private: {'csi': {'volume': {'idTemplate': ...}}}`

- [ ] **Step 4: Seal the updated secret (cluster-wide scope, matching the existing file)**

```bash
kubectl create secret generic csi-zfs-pve-ssd -n democratic-system \
  --from-file=driver-config-file.yaml=/tmp/driver-config.yaml \
  --dry-run=client -o yaml \
| kubeseal --format yaml --scope cluster-wide \
    --controller-namespace <NS-from-step-1> --controller-name <NAME-from-step-1> \
> /tmp/csi-zfs-pve-ssd-sealed.yaml
grep -c "encryptedData" /tmp/csi-zfs-pve-ssd-sealed.yaml
```

Expected: `1`. The output must carry annotation `sealedsecrets.bitnami.com/cluster-wide: "true"` — verify with `grep cluster-wide /tmp/csi-zfs-pve-ssd-sealed.yaml` (should appear; if missing, add the annotation under both `metadata.annotations` and `spec.template.metadata.annotations` exactly as in the current repo file).

- [ ] **Step 5: Replace the repo file, commit, push**

```bash
cd /Users/jabbas/Projects/flux-home-system
cp /tmp/csi-zfs-pve-ssd-sealed.yaml flux/infrastructure/democratic-csi/config-zfs-pve-ssd.yaml
git diff --stat
git add flux/infrastructure/democratic-csi/config-zfs-pve-ssd.yaml
git commit -m "feat(democratic-csi): name new ZFS datasets {namespace}-{pvcname}

Adds _private.csi.volume.idTemplate to the driver config so newly
provisioned volumes get identifiable dataset names on rpool/k8s
instead of pvc-<uuid>. Existing volumes unaffected until re-provisioned."
git push origin main
```

- [ ] **Step 6: Reconcile, restart controller, verify**

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization democratic-csi -n flux-system
# verify the live secret picked up the change:
kubectl get secret -n democratic-system csi-zfs-pve-ssd -o jsonpath='{.data.driver-config-file\.yaml}' | base64 -d | grep -A3 "_private"
# restart controller so the driver re-reads config:
kubectl rollout restart deployment -n democratic-system democratic-csi-controller
kubectl rollout status deployment -n democratic-system democratic-csi-controller --timeout=120s
```

Expected: live secret contains the `_private` block; controller rolls out cleanly.

- [ ] **Step 7: Clean up plaintext credentials**

```bash
rm -f /tmp/driver-config.yaml /tmp/csi-zfs-pve-ssd-sealed.yaml
```

### Task 3: Canary — verify naming works end to end

- [ ] **Step 1: Create a throwaway PVC**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: naming-canary
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: zfs-nfs-csi
  resources:
    requests:
      storage: 100Mi
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/naming-canary -n default --timeout=60s
kubectl get pv $(kubectl get pvc naming-canary -n default -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
```

Expected: volumeHandle is `default-naming-canary` (NOT `pvc-<uuid>`).

- [ ] **Step 2: Verify on ZFS**

```bash
ssh pve.home zfs list -r rpool/k8s | grep naming-canary
```

Expected: `rpool/k8s/default-naming-canary` exists.

- [ ] **Step 3: Delete canary and verify cleanup**

```bash
kubectl delete pvc naming-canary -n default
sleep 15
ssh pve.home zfs list -r rpool/k8s | grep naming-canary || echo "CLEANED UP OK"
```

Expected: `CLEANED UP OK` (reclaimPolicy Delete destroys the dataset).

**STOP if the canary fails.** Do not proceed to data migrations with broken naming.

### Task 4: Re-provision vmselect caches (disposable)

For each of `vmselect-cachedir-vmselect-vm-0` and `vmselect-cachedir-vmselect-vm-1` (one at a time):

- [ ] **Step 1: Delete PVC then pod (instance 0)**

```bash
kubectl delete pvc vmselect-cachedir-vmselect-vm-0 -n victoria-metrics --wait=false
kubectl delete pod vmselect-vm-0 -n victoria-metrics
# PVC finalizer clears once pod is gone; StatefulSet recreates pod; pod recreation triggers new PVC.
# If the new pod sits Pending because it raced the terminating PVC: kubectl delete pod vmselect-vm-0 -n victoria-metrics  (again)
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/vmselect-cachedir-vmselect-vm-0 -n victoria-metrics --timeout=120s
kubectl wait --for=condition=Ready pod/vmselect-vm-0 -n victoria-metrics --timeout=180s
```

- [ ] **Step 2: Verify new dataset name**

```bash
kubectl get pvc vmselect-cachedir-vmselect-vm-0 -n victoria-metrics -o jsonpath='{.spec.volumeName}{"\n"}'
ssh pve.home zfs list -r rpool/k8s | grep vmselect
```

Expected: dataset `rpool/k8s/victoria-metrics-vmselect-cachedir-vmselect-vm-0`.

- [ ] **Step 3: Repeat Steps 1–2 for `vmselect-cachedir-vmselect-vm-1` / pod `vmselect-vm-1`**

### Task 5: Re-provision vmstorage (history loss accepted)

Same procedure as Task 4, one instance at a time, waiting for full health between instances:

- [ ] **Step 1: Instance 0**

```bash
kubectl delete pvc vmstorage-db-vmstorage-vm-0 -n victoria-metrics --wait=false
kubectl delete pod vmstorage-vm-0 -n victoria-metrics
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/vmstorage-db-vmstorage-vm-0 -n victoria-metrics --timeout=120s
kubectl wait --for=condition=Ready pod/vmstorage-vm-0 -n victoria-metrics --timeout=180s
```

- [ ] **Step 2: Verify metrics still flowing (vminsert writes to the new empty shard)**

```bash
kubectl get pods -n victoria-metrics
# All vm* pods Ready. Optionally check grafana or vmui for fresh datapoints.
```

- [ ] **Step 3: Instance 1 (same as Step 1 with vm-1), then verify dataset names**

```bash
ssh pve.home zfs list -r rpool/k8s | grep vmstorage
```

Expected: `rpool/k8s/victoria-metrics-vmstorage-db-vmstorage-vm-0` and `...-vm-1`.

### Task 6: CNPG rolling re-provision — firecrawl (lowest-value DB first, procedure canary)

- [ ] **Step 1: Identify primary vs replica**

```bash
kubectl get cluster -n firecrawl firecrawl-firecrawl-stack-db -o jsonpath='primary={.status.currentPrimary}{"\n"}'
kubectl get pods -n firecrawl -l cnpg.io/cluster=firecrawl-firecrawl-stack-db
```

(If the Cluster resource name differs, find it: `kubectl get cluster -n firecrawl`.)

- [ ] **Step 2: Replace the REPLICA instance first**

```bash
# Assume replica is instance -1 (adjust to whichever is NOT currentPrimary):
kubectl delete pvc firecrawl-firecrawl-stack-db-1 -n firecrawl --wait=false
kubectl delete pod firecrawl-firecrawl-stack-db-1 -n firecrawl
# CNPG creates a NEW instance (db-3) with a new PVC and streams data from the primary.
kubectl get pods -n firecrawl -w   # until new db pod Running and cluster shows 2 ready
kubectl get cluster -n firecrawl -o wide
```

Expected: Cluster phase back to `Cluster in healthy state`, 2 instances ready.

- [ ] **Step 3: Replace the old PRIMARY (CNPG fails over automatically)**

```bash
kubectl delete pvc firecrawl-firecrawl-stack-db-2 -n firecrawl --wait=false
kubectl delete pod firecrawl-firecrawl-stack-db-2 -n firecrawl
kubectl get cluster -n firecrawl -o wide -w   # until healthy, 2 ready
```

- [ ] **Step 4: Verify datasets + app**

```bash
ssh pve.home zfs list -r rpool/k8s | grep firecrawl
kubectl get pods -n firecrawl
```

Expected: two datasets named `rpool/k8s/firecrawl-firecrawl-firecrawl-stack-db-{3,4}`; firecrawl pods healthy.

### Task 7: CNPG rolling re-provision — ibakery

Same procedure as Task 6:

- [ ] **Step 1: Identify primary** (`kubectl get cluster -n ibakery` → currentPrimary of `ibakery-db`)
- [ ] **Step 2: Replace replica** (delete its PVC `ibakery-db-<n>` + pod, wait healthy)
- [ ] **Step 3: Replace old primary** (same, wait healthy)
- [ ] **Step 4: Verify**

```bash
ssh pve.home zfs list -r rpool/k8s | grep ibakery
kubectl get volumesnapshot -n ibakery
```

Expected: datasets `rpool/k8s/ibakery-ibakery-db-{3,4}`. Note: the existing VolumeSnapshot `ibakery-db-backup-…` references the destroyed dataset and may show broken — acceptable; the next scheduled backup creates a fresh one. Verify the morning after that a new snapshot appears and is `READYTOUSE=true`.

### Task 8: CNPG rolling re-provision — authentik (with safety dump)

- [ ] **Step 1: Fresh logical backup first**

```bash
PRIMARY=$(kubectl get cluster -n authentik authentik-stack-db -o jsonpath='{.status.currentPrimary}')
kubectl exec -n authentik $PRIMARY -- pg_dumpall -U postgres > ~/authentik-pre-rename-$(date +%F).sql
ls -lh ~/authentik-pre-rename-*.sql   # sanity: non-trivial size
```

- [ ] **Step 2: Replace replica** (whichever of db-3/db-4 is NOT `$PRIMARY`):

```bash
kubectl delete pvc <replica-pvc-name> -n authentik --wait=false
kubectl delete pod <replica-pod-name> -n authentik
kubectl get cluster -n authentik -o wide -w   # until healthy, 2 ready (new instance db-5)
```

- [ ] **Step 3: Verify SSO still works** — log into https://authentik.dev.home before touching the primary.

- [ ] **Step 4: Replace old primary**

```bash
kubectl delete pvc <old-primary-pvc> -n authentik --wait=false
kubectl delete pod <old-primary-pod> -n authentik
kubectl get cluster -n authentik -o wide -w   # failover + rejoin, until healthy
```

- [ ] **Step 5: Verify**

```bash
ssh pve.home zfs list -r rpool/k8s | grep authentik
# Log into authentik UI again; check an OIDC app (grafana/headlamp) still authenticates.
```

Expected: datasets `rpool/k8s/authentik-authentik-stack-db-{5,6}`; SSO functional. Keep the dump for a few days, then delete.

### Task 9: grafana (single PVC — copy data through pve.home)

- [ ] **Step 1: Identify old dataset and scale down**

```bash
OLDPV=$(kubectl get pvc grafana -n grafana -o jsonpath='{.spec.volumeName}')
echo "old dataset: rpool/k8s/$OLDPV"
kubectl scale deployment grafana -n grafana --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=grafana -n grafana --timeout=120s
```

- [ ] **Step 2: Stage a copy on pve.home (before PVC deletion destroys the dataset)**

```bash
ssh pve.home "mkdir -p /root/grafana-migration && cp -a /rpool/k8s/$OLDPV/. /root/grafana-migration/ && du -sh /root/grafana-migration"
```

Expected: ~30M staged.

- [ ] **Step 3: Delete + recreate the PVC via Helm**

```bash
kubectl delete pvc grafana -n grafana
flux reconcile helmrelease grafana -n grafana
kubectl get pvc grafana -n grafana
```

Expected: PVC recreated and Bound with volumeName `grafana-grafana`. If Helm did not recreate it (no drift correction), create it manually with matching Helm metadata:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana
  namespace: grafana
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: grafana
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: grafana
    meta.helm.sh/release-namespace: grafana
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: zfs-nfs-csi
  resources:
    requests:
      storage: 1Gi
EOF
```

- [ ] **Step 4: Restore data into the new dataset**

```bash
ssh pve.home "cp -a /root/grafana-migration/. /rpool/k8s/grafana-grafana/ && ls -la /rpool/k8s/grafana-grafana/ | head"
```

- [ ] **Step 5: Scale up and verify**

```bash
kubectl scale deployment grafana -n grafana --replicas=1
kubectl rollout status deployment grafana -n grafana --timeout=180s
# Log into grafana UI: dashboards/datasources/prefs intact.
```

- [ ] **Step 6: Clean up staging**

```bash
ssh pve.home rm -rf /root/grafana-migration
```

### Task 10: Final verification + record

- [ ] **Step 1: Full dataset listing — zero UUIDs left**

```bash
ssh pve.home zfs list -r rpool/k8s
ssh pve.home zfs list -r rpool/k8s | grep -c "pvc-" || echo "NO UUID DATASETS REMAIN"
```

Expected: every dataset reads `{namespace}-{pvcname}`; count of `pvc-` names is 0.

- [ ] **Step 2: Cluster health sweep**

```bash
kubectl get pods -A | grep -v "Running\|Completed" || echo "all pods healthy"
flux get helmreleases -A | grep -v True || echo "all HRs ready"
kubectl get cluster -A   # all CNPG clusters "Cluster in healthy state"
```

- [ ] **Step 3: Store outcome in project memory** (memory_store): migration done, naming convention `{namespace}-{pvcname}` via idTemplate + extra-create-metadata, CNPG instance numbers advanced (authentik db-5/6, firecrawl db-3/4, ibakery db-3/4), vmstorage history reset on YYYY-MM-DD, authentik safety dump location.
