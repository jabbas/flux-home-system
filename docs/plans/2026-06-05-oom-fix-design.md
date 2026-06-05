# OOM Fix — Cluster Memory Overcommit Reduction

**Date:** 2026-06-05
**Status:** Approved
**Approach:** B — Replica reduction + limit corrections

## Problem

Cluster nodes repeatedly hit MemoryPressure, triggering kernel OOM Killer and mass pod evictions. All 3 nodes affected simultaneously.

### Root Cause

Memory limits are overcommitted at 79-90% of allocatable RAM per node. Requests are low (21-25%), so the scheduler places pods freely, but when multiple pods approach their limits concurrently, total consumption exceeds physical RAM.

### Current State (per node ~15 GiB allocatable)

| Node   | Requests    | Limits          |
|--------|-------------|-----------------|
| talos1 | 3529Mi (23%) | 12436Mi (81%)  |
| talos2 | 3940Mi (25%) | 13824Mi (90%)  |
| talos3 | 3311Mi (21%) | 12160Mi (79%)  |

### Key Offenders

| Pod                  | Current Usage | Limit  | % of Limit |
|----------------------|---------------|--------|------------|
| kube-apiserver x3    | 781-1206 Mi   | 2 GiB  | 38-59%     |
| vmstorage x2         | 712-768 Mi    | 2 GiB  | 35-38%     |
| authentik-server x2  | 616-732 Mi    | 1 GiB  | 60-71%     |
| authentik-db x3      | ~566 Mi       | 1 GiB  | 55%        |
| authentik-worker x2  | 402-489 Mi    | 1 GiB  | 39-48%     |
| grafana              | 497 Mi        | 512 Mi | 97%        |
| firecrawl-worker     | 380 Mi        | none   | unlimited  |
| firecrawl-api        | 364 Mi        | none   | unlimited  |

## Design

### 1. Victoria Metrics — Replica Reduction

Reduce HA replicas for stateless components. vmstorage stays at 2 (replicationFactor=2 requires it).

| Component      | Before | After | Rationale                                      |
|----------------|--------|-------|------------------------------------------------|
| vmstorage      | 2      | 2     | Data redundancy requires >= 2                  |
| vmselect       | 2      | 1     | Stateless query proxy, restart takes seconds   |
| vminsert       | 2      | 1     | Stateless ingestion proxy, vmagent buffers     |
| vmagent        | 2      | 1     | Single scraper sufficient for home lab         |
| vmalert        | 2      | 1     | Alerting non-critical for home lab             |
| alertmanager   | 2      | 1     | Same as above                                  |

HelmRelease interval: 1m -> 5m (reduces operator reconciliation churn).

`topologySpreadConstraints` remain as-is on all components — they are no-ops with 1 replica and cause no harm. Removing them would be churn with no benefit, and they'll be ready if replicas are scaled back up.

**File:** `flux/infrastructure/victoria-metrics/release.yaml`
**Savings:** ~1.4 GiB limits recovered

### 2. Authentik — Replica Reduction

| Component | Before | After | Rationale                                          |
|-----------|--------|-------|----------------------------------------------------|
| server    | 2      | 2     | OIDC must stay available — Traefik, Grafana depend on it |
| worker    | 2      | 1     | Background tasks only, not in auth flow            |
| database  | 3      | 2     | CNPG: 1 primary + 1 replica with automatic failover is sufficient |

**File:** `flux/infrastructure/authentik/chart/values.yaml`
**Savings:** ~2.0 GiB limits recovered

### 3. Grafana — Limit Increase

Dashboard sidecar downloads and caches dashboards from grafana.com. 497/512 Mi is normal usage, not a leak. Limit is simply too low.

| Setting  | Before | After |
|----------|--------|-------|
| limit    | 512Mi  | 768Mi |
| request  | 256Mi  | 256Mi |

768Mi gives ~35% headroom over observed usage. 1Gi would be excessive.

**File:** `flux/infrastructure/grafana/release.yaml`
**Cost:** +256Mi limits

### 4. Firecrawl — Right-size Limits + Add Missing Limits

Main containers (api, worker, nuq-worker) already have limits but they are oversized (2Gi/2Gi/1Gi vs actual usage 364/380/248 Mi). Playwright and redis have no limits at all.

| Container          | Current Usage | Current Limit | Proposed Limit |
|--------------------|---------------|---------------|----------------|
| firecrawl-api      | 364 Mi        | 2Gi           | 768Mi          |
| firecrawl-worker   | 380 Mi        | 2Gi           | 768Mi          |
| firecrawl-nuq-worker | 248 Mi      | 1Gi           | 512Mi          |
| playwright-service | unknown       | none          | 512Mi          |
| redis              | unknown       | none          | 256Mi          |

CNPG postgres instances have no limits but are managed by the CNPG operator template in the wrapper chart — adding limits there is a separate concern.

**File:** `flux-homeapps` repo: `applications/firecrawl/chart/values.yaml`
**Savings:** ~3.5 GiB limits recovered (api+worker drop from 4Gi to 1.5Gi total)

### 5. Snapshot Controller — Replica Reduction

| Setting  | Before | After |
|----------|--------|-------|
| replicas | 3      | 1     |

Lightweight component, creates VolumeSnapshots on demand. Not on critical path.

**File:** `flux/infrastructure/snapshot-controller/release.yaml`
**Savings:** ~128Mi limits recovered

## Impact Summary

### Memory Limits per Node (estimated)

|               | Before      | After       |
|---------------|-------------|-------------|
| Limits / alloc | 79-90%     | ~55-65%     |
| Headroom      | 1.5-3 GiB   | 5-6 GiB    |

### Files Changed

| Repository        | File                                                    | Changes                                          |
|-------------------|---------------------------------------------------------|--------------------------------------------------|
| flux-home-system  | `flux/infrastructure/victoria-metrics/release.yaml`     | 5 components replicas 2->1, interval 1m->5m      |
| flux-home-system  | `flux/infrastructure/authentik/chart/values.yaml`       | worker replicas 2->1, db instances 3->2           |
| flux-home-system  | `flux/infrastructure/grafana/release.yaml`              | memory limit 512Mi->768Mi                         |
| flux-home-system  | `flux/infrastructure/snapshot-controller/release.yaml`  | replicas 3->1                                     |
| flux-homeapps     | `applications/firecrawl/chart/values.yaml`              | Right-size limits (768/768/512 Mi), add playwright+redis limits |

### Risk Assessment

- **Low risk:** Grafana limit bump, Firecrawl limits, snapshot controller reduction
- **Medium risk:** VM replica reduction (brief metric gaps during pod restarts), Authentik db 3->2 (still has failover, but narrower)
- **Mitigation:** All changes are GitOps — revert is a single `git revert` + Flux reconcile

### What This Does NOT Change

- kube-apiserver limits (managed by Talos, not Flux)
- vmstorage replicas (required for replicationFactor=2)
- Authentik server replicas (OIDC availability is critical)
- Memory requests (staying conservative to keep scheduling flexible)
