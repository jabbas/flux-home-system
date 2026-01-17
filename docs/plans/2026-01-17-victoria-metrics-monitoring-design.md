# Victoria Metrics Monitoring Stack Design

## Overview

Add a full HA monitoring stack using VictoriaMetrics with the vm-operator to monitor Kubernetes cluster health and applications.

## Requirements

- Monitor Kubernetes cluster health and applications
- Resource efficient and simple architecture
- Email alerting (reuse Authentik SMTP)
- vmui for visualization
- 30-day metric retention
- Full HA (survive single node failure)
- VictoriaMetrics native CRDs
- Authentik authentication for vmui
- Everything as code (no manual steps)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         vm-operator                             │
└─────────────────────────────────────────────────────────────────┘
                              │
      ┌───────────────────────┼───────────────────────┐
      ▼                       ▼                       ▼
┌──────────┐          ┌─────────────┐          ┌───────────┐
│ vmagent  │          │  vmcluster  │          │  vmalert  │
│   x2     │─────────▶│ insert x2   │◀─────────│    x2     │
└──────────┘          │ storage x2  │          └───────────┘
                      │ select x2   │                │
                      └─────────────┘                ▼
                            │               ┌───────────────┐
                            ▼               │ alertmanager  │
┌──────────────┐      ┌──────────┐          │      x2       │
│   Authentik  │◀─────│   vmui   │          └───────────────┘
│  forwardAuth │      └──────────┘                  │
└──────────────┘            ▲                       ▼
                            │                   Email
                      vmui.dev.home
```

### Components (all HA)

| Component | Replicas | Purpose |
|-----------|----------|---------|
| vm-operator | 1 | Manages VictoriaMetrics CRDs |
| vmagent | 2 | Scrapes metrics from cluster and apps |
| vminsert | 2 | Ingestion endpoint for vmcluster |
| vmstorage | 2 | Time-series database (30-day retention) |
| vmselect | 2 | Query endpoint for vmcluster |
| vmalert | 2 | Evaluates alerting rules |
| alertmanager | 2 | Routes alerts to email |

### Resource Estimates

| Component | CPU Request | Memory Request | Memory Limit |
|-----------|-------------|----------------|--------------|
| vmstorage x2 | 100m | 256Mi | 512Mi |
| vmselect x2 | 50m | 128Mi | 256Mi |
| vminsert x2 | 50m | 128Mi | 256Mi |
| vmagent x2 | 100m | 256Mi | 256Mi |
| vmalert x2 | 50m | 128Mi | 128Mi |
| alertmanager x2 | 25m | 64Mi | 64Mi |

**Total estimated footprint:** ~1.5 GB memory

### Storage

- Storage class: `zfs-nfs-csi`
- Volume size: 20Gi per vmstorage replica
- Retention: 30 days

## Flux Integration

### Directory Structure

```
flux/
├── cluster/
│   └── infrastructure.yaml        # Add victoria-metrics Kustomization
└── infrastructure/
    ├── sources/
    │   ├── kustomization.yaml     # Add victoria-metrics.yaml to resources
    │   └── victoria-metrics.yaml  # HelmRepository
    ├── authentik-blueprints/
    │   ├── kustomization.yaml     # Add blueprint to resources
    │   └── victoria-metrics-blueprint.yaml
    └── victoria-metrics/
        ├── kustomization.yaml
        ├── namespace.yaml
        ├── helmrelease.yaml
        ├── ingress.yaml           # vmui.dev.home
        └── middleware.yaml        # forwardAuth to Authentik
```

### Dependency Chain

```
victoria-metrics → sources + traefik + authentik + authentik-blueprints + reflector
```

### Files to Create

| File | Purpose |
|------|---------|
| `flux/infrastructure/sources/victoria-metrics.yaml` | HelmRepository for VM charts |
| `flux/infrastructure/authentik-blueprints/victoria-metrics-blueprint.yaml` | Authentik OIDC provider, app, group |
| `flux/infrastructure/victoria-metrics/kustomization.yaml` | Flux Kustomization |
| `flux/infrastructure/victoria-metrics/namespace.yaml` | Namespace definition |
| `flux/infrastructure/victoria-metrics/helmrelease.yaml` | victoria-metrics-k8s-stack chart |
| `flux/infrastructure/victoria-metrics/ingress.yaml` | Ingress for vmui.dev.home |
| `flux/infrastructure/victoria-metrics/middleware.yaml` | Traefik forwardAuth middleware |

### Files to Modify

| File | Change |
|------|--------|
| `flux/infrastructure/sources/kustomization.yaml` | Add `victoria-metrics.yaml` to resources |
| `flux/infrastructure/authentik-blueprints/kustomization.yaml` | Add blueprint to resources |
| `flux/cluster/infrastructure.yaml` | Add victoria-metrics Kustomization with dependencies |
| Authentik SMTP secret | Add reflector annotations for victoria-metrics namespace |

## Metrics Collection

### Built-in Scrape Targets

- kube-state-metrics: Pod, deployment, node status
- node-exporter: Node CPU, memory, disk, network
- kubelet/cAdvisor: Container resource usage
- kube-apiserver: API server latency and request rates
- kube-controller-manager: Controller queue depths
- kube-scheduler: Scheduling latency
- CoreDNS: DNS query rates and errors

### Application Scraping

VMServiceScrape CRDs for:
- Authentik
- CloudNativePG (PostgreSQL)
- Traefik

## Alerting

### Default Alert Rules

- Node down / NotReady
- High CPU/memory/disk usage
- Pod CrashLoopBackOff
- PVC nearly full
- API server errors
- etcd leader changes

### Alert Routing

```yaml
route:
  receiver: email
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
```

### SMTP Configuration

- SMTP credentials shared via Reflector from Authentik namespace
- Alerts sent to jabbas@jabbas.eu

## Authentication

### Authentik Blueprint

Creates:
- Group: `monitoring-admins`
- User binding: `jabbas` → `monitoring-admins`
- OAuth2/OpenID Provider for VictoriaMetrics
- Application linked to provider
- Application bound to `monitoring-admins` group

### Traefik Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-auth
  namespace: victoria-metrics
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local/outpost.goauthenticate.com/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
```

### Ingress

- Host: `vmui.dev.home`
- TLS: enabled (Traefik default cert)
- IngressClass: `traefik-internal`
- Middleware: `authentik-auth`

## Helm Chart

- Chart: `victoria-metrics-k8s-stack`
- Repository: `https://victoriametrics.github.io/helm-charts`
- Key values configured via HelmRelease
