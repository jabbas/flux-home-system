# OOM Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce cluster memory overcommit from 79-90% to ~55-65% of allocatable RAM per node, eliminating recurring OOM events.

**Architecture:** GitOps changes only — modify Helm values in two repos (flux-home-system, flux-homeapps). Flux reconciles changes automatically after git push. No manual kubectl operations.

**Tech Stack:** Flux CD, Helm, YAML

**Design spec:** `docs/plans/2026-06-05-oom-fix-design.md`

---

### Task 1: Victoria Metrics — Reduce Replicas and Reconciliation Interval

**Files:**
- Modify: `flux/infrastructure/victoria-metrics/release.yaml`

- [ ] **Step 1: Change HelmRelease interval from 1m to 5m**

In `flux/infrastructure/victoria-metrics/release.yaml`, change line 16:

```yaml
# Before
  interval: 1m0s

# After
  interval: 5m0s
```

- [ ] **Step 2: Reduce vmselect replicas from 2 to 1**

In the same file, change line 75:

```yaml
# Before
        vmselect:
          replicaCount: 2

# After
        vmselect:
          replicaCount: 1
```

- [ ] **Step 3: Reduce vminsert replicas from 2 to 1**

In the same file, change line 92:

```yaml
# Before
        vminsert:
          replicaCount: 2

# After
        vminsert:
          replicaCount: 1
```

- [ ] **Step 4: Reduce vmagent replicas from 2 to 1**

In the same file, change line 116:

```yaml
# Before
        replicaCount: 2

# After
        replicaCount: 1
```

This is inside `vmagent.spec.replicaCount`.

- [ ] **Step 5: Reduce vmalert replicas from 2 to 1**

In the same file, change line 136:

```yaml
# Before
        replicaCount: 2

# After
        replicaCount: 1
```

This is inside `vmalert.spec.replicaCount`.

- [ ] **Step 6: Reduce alertmanager replicas from 2 to 1**

In the same file, change line 156:

```yaml
# Before
        replicaCount: 2

# After
        replicaCount: 1
```

This is inside `alertmanager.spec.replicaCount`.

- [ ] **Step 7: Validate YAML syntax**

Run:
```bash
yamllint flux/infrastructure/victoria-metrics/release.yaml
```

Expected: No errors (warnings about line length are OK per `.yamllint` config).

- [ ] **Step 8: Commit**

```bash
git add flux/infrastructure/victoria-metrics/release.yaml
git commit -m "fix(victoria-metrics): reduce replicas to prevent OOM

Reduce stateless components from 2 to 1 replica:
- vmselect, vminsert, vmagent, vmalert, alertmanager
- vmstorage stays at 2 (replicationFactor=2 requires it)
- HelmRelease interval 1m -> 5m to reduce reconciliation churn

Part of cluster OOM fix — see docs/plans/2026-06-05-oom-fix-design.md"
```

---

### Task 2: Authentik — Reduce Worker and Database Replicas

**Files:**
- Modify: `flux/infrastructure/authentik/chart/values.yaml`

- [ ] **Step 1: Reduce database instances from 3 to 2**

In `flux/infrastructure/authentik/chart/values.yaml`, change line 7:

```yaml
# Before
database:
  instances: 3

# After
database:
  instances: 2
```

CNPG will automatically decommission the third replica. The remaining 2 provide 1 primary + 1 replica with automatic failover.

- [ ] **Step 2: Reduce worker replicas from 2 to 1**

In the same file, change line 145:

```yaml
# Before
  worker:
    replicas: 2

# After
  worker:
    replicas: 1
```

- [ ] **Step 3: Validate YAML syntax**

Run:
```bash
yamllint flux/infrastructure/authentik/chart/values.yaml
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add flux/infrastructure/authentik/chart/values.yaml
git commit -m "fix(authentik): reduce replicas to prevent OOM

- worker: 2 -> 1 (background tasks only, not in auth flow)
- database: 3 -> 2 (CNPG primary + 1 replica with auto-failover)
- server stays at 2 (OIDC availability is critical)

Part of cluster OOM fix — see docs/plans/2026-06-05-oom-fix-design.md"
```

---

### Task 3: Grafana — Increase Memory Limit

**Files:**
- Modify: `flux/infrastructure/grafana/release.yaml`

- [ ] **Step 1: Increase memory limit from 512Mi to 768Mi**

In `flux/infrastructure/grafana/release.yaml`, change line 118:

```yaml
# Before
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 512Mi

# After
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 768Mi
```

- [ ] **Step 2: Validate YAML syntax**

Run:
```bash
yamllint flux/infrastructure/grafana/release.yaml
```

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add flux/infrastructure/grafana/release.yaml
git commit -m "fix(grafana): increase memory limit 512Mi -> 768Mi

Grafana consistently uses ~497Mi (97% of 512Mi limit).
Dashboard sidecar caches downloaded dashboards in memory.
768Mi gives ~35% headroom.

Part of cluster OOM fix — see docs/plans/2026-06-05-oom-fix-design.md"
```

---

### Task 4: Snapshot Controller — Reduce Replicas

**Files:**
- Modify: `flux/infrastructure/snapshot-controller/release.yaml`

- [ ] **Step 1: Reduce replicas from 3 to 1**

In `flux/infrastructure/snapshot-controller/release.yaml`, change line 18:

```yaml
# Before
  values:
    replicaCount: 3

# After
  values:
    replicaCount: 1
```

- [ ] **Step 2: Validate YAML syntax**

Run:
```bash
yamllint flux/infrastructure/snapshot-controller/release.yaml
```

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add flux/infrastructure/snapshot-controller/release.yaml
git commit -m "fix(snapshot-controller): reduce replicas 3 -> 1

Lightweight component, creates VolumeSnapshots on demand.
Not on critical path — single replica sufficient for home lab.

Part of cluster OOM fix — see docs/plans/2026-06-05-oom-fix-design.md"
```

---

### Task 5: Firecrawl — Right-size and Add Missing Memory Limits

**Files:**
- Modify: `/Users/jabbas/Projects/flux-homeapps/applications/firecrawl/chart/values.yaml`

This is in the **flux-homeapps** repo, not flux-home-system.

- [ ] **Step 1: Right-size API memory limits**

In `/Users/jabbas/Projects/flux-homeapps/applications/firecrawl/chart/values.yaml`, change the api resources (lines 46-52):

```yaml
# Before
  api:
    replicaCount: 1
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi

# After
  api:
    replicaCount: 1
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 768Mi
```

- [ ] **Step 2: Right-size worker memory limits**

In the same file, change the worker resources (lines 57-64):

```yaml
# Before
  worker:
    replicaCount: 1
    port: 3005
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi

# After
  worker:
    replicaCount: 1
    port: 3005
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 768Mi
```

- [ ] **Step 3: Right-size nuq-worker memory limits**

In the same file, change the nuqWorker resources (lines 69-76):

```yaml
# Before
  nuqWorker:
    replicaCount: 1
    port: 3006
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi

# After
  nuqWorker:
    replicaCount: 1
    port: 3006
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

- [ ] **Step 4: Add playwright memory limits**

In the same file, add resources to the playwright section (after line 37):

```yaml
# Before
  playwright:
    repository: ghcr.io/firecrawl/playwright-service
    tag: latest
    pullPolicy: Always
    replicaCount: 1

# After
  playwright:
    repository: ghcr.io/firecrawl/playwright-service
    tag: latest
    pullPolicy: Always
    replicaCount: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

Note: The upstream Firecrawl chart may or may not support `playwright.resources`. Verify by checking `applications/firecrawl/chart/charts/firecrawl-0.2.0.tgz` templates. If not supported, use a postRenderer patch in the HelmRelease instead. If the chart does not support it, skip this step and add a TODO comment in the values file.

- [ ] **Step 5: Add redis memory limits**

In the same file, add resources to the redis section (after line 108):

```yaml
# Before
  redis:
    image: redis:7-alpine
    replicaCount: 1

# After
  redis:
    image: redis:7-alpine
    replicaCount: 1
    resources:
      requests:
        cpu: 25m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
```

Same caveat as playwright — verify chart support for `redis.resources`.

- [ ] **Step 6: Validate YAML syntax**

Run:
```bash
cd /Users/jabbas/Projects/flux-homeapps
yamllint applications/firecrawl/chart/values.yaml
```

Expected: No errors.

- [ ] **Step 7: Commit (in flux-homeapps repo)**

```bash
cd /Users/jabbas/Projects/flux-homeapps
git add applications/firecrawl/chart/values.yaml
git commit -m "fix(firecrawl): right-size memory limits to prevent OOM

- api: 2Gi -> 768Mi (actual usage ~364Mi)
- worker: 2Gi -> 768Mi (actual usage ~380Mi)
- nuq-worker: 1Gi -> 512Mi (actual usage ~248Mi)
- playwright: add 512Mi limit (was unlimited)
- redis: add 256Mi limit (was unlimited)

Part of cluster OOM fix"
```

---

### Task 6: Verify Changes After Flux Reconciliation

This task runs after pushing both repos. Wait ~5 minutes for Flux to reconcile.

- [ ] **Step 1: Push flux-home-system changes**

```bash
cd /Users/jabbas/Projects/flux-home-system
git push
```

- [ ] **Step 2: Push flux-homeapps changes**

```bash
cd /Users/jabbas/Projects/flux-homeapps
git push
```

- [ ] **Step 3: Force Flux reconciliation (optional, speeds up)**

```bash
flux -n flux-system reconcile kustomization flux-system --with-source
flux -n flux-system reconcile kustomization victoria-metrics
flux -n flux-system reconcile kustomization authentik
flux -n flux-system reconcile kustomization grafana
flux -n flux-system reconcile kustomization infrastructure
```

- [ ] **Step 4: Verify Victoria Metrics pod count**

```bash
kubectl get pods -n victoria-metrics
```

Expected: vmstorage x2, vmselect x1, vminsert x1, vmagent x1, vmalert x1, alertmanager x1, operator x1, kube-state-metrics x1 = **9 pods total** (down from 14).

- [ ] **Step 5: Verify Authentik pod count**

```bash
kubectl get pods -n authentik
```

Expected: server x2, worker x1, db x2 = **5 pods total** (down from 7).

- [ ] **Step 6: Verify snapshot controller**

```bash
kubectl get pods -n democratic-system | grep snapshot
```

Expected: 1 snapshot-controller pod (down from 3).

- [ ] **Step 7: Verify Grafana memory limit**

```bash
kubectl get pod -n grafana -o json | jq -r '.items[].spec.containers[].resources.limits.memory'
```

Expected: `768Mi`

- [ ] **Step 8: Verify node memory allocation**

```bash
kubectl describe nodes | grep -A 5 "Allocated resources:" | grep memory
```

Expected: Limits per node should be below 70% of allocatable (~10.5 GiB or less per node).

- [ ] **Step 9: Verify all pods healthy**

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Expected: Only header line, no pods in Error/CrashLoopBackOff/Pending state.

- [ ] **Step 10: Verify no memory pressure**

```bash
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): MemoryPressure=\(.status.conditions[] | select(.type=="MemoryPressure") | .status)"'
```

Expected:
```
talos1: MemoryPressure=False
talos2: MemoryPressure=False
talos3: MemoryPressure=False
```
