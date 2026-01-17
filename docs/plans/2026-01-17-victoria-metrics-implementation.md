# Victoria Metrics Monitoring Stack Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a full HA VictoriaMetrics monitoring stack with Authentik authentication and email alerting.

**Architecture:** VMCluster (2x vmstorage, vmselect, vminsert) with redundant vmagent, vmalert, and alertmanager. Metrics exposed via vmui at vmui.dev.home behind Authentik forwardAuth.

**Tech Stack:** VictoriaMetrics, vm-operator, Traefik, Authentik, Flux CD, Helm

---

## Task 1: Add VictoriaMetrics HelmRepository

**Files:**
- Create: `flux/infrastructure/sources/victoria-metrics.yaml`
- Modify: `flux/infrastructure/sources/kustomization.yaml`

**Step 1: Create HelmRepository manifest**

Create `flux/infrastructure/sources/victoria-metrics.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: victoria-metrics
  namespace: flux-system
spec:
  interval: 24h
  url: https://victoriametrics.github.io/helm-charts
```

**Step 2: Add to sources kustomization**

Edit `flux/infrastructure/sources/kustomization.yaml` and add `victoria-metrics.yaml` to the resources list (maintain alphabetical order):

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - authentik.yaml
  - cloudnativepg.yaml
  - democratic-csi.yaml
  - metallb.yaml
  - metrics-server.yaml
  - reflector.yaml
  - sealed-secrets.yaml
  - traefik.yaml
  - victoria-metrics.yaml
```

**Step 3: Commit**

```bash
git add flux/infrastructure/sources/victoria-metrics.yaml flux/infrastructure/sources/kustomization.yaml
git commit -m "feat: add VictoriaMetrics HelmRepository"
```

---

## Task 2: Create Authentik Blueprint for VictoriaMetrics

**Files:**
- Create: `flux/infrastructure/authentik-blueprints/chart/templates/blueprint-victoria-metrics.yaml`
- Modify: `flux/infrastructure/authentik-blueprints/chart/values.yaml`

**Step 1: Add values for VictoriaMetrics OIDC**

Edit `flux/infrastructure/authentik-blueprints/chart/values.yaml` and add victoria-metrics configuration under the `oidc` section:

```yaml
oidc:
  # ... existing talos config ...

  victoriaMetrics:
    clientId: victoria-metrics-id
    icon: https://victoriametrics.com/images/logo.svg
```

Add to the `groups` section:

```yaml
groups:
  - name: kubernetes-admins
    superuser: false
  - name: monitoring-admins
    superuser: false
```

Add jabbas to monitoring-admins in the `users` section:

```yaml
users:
  - username: jabbas
    email: jabbas@jabbas.eu
    name: Grzegorz Dzięgielewski
    superuser: true
    groups:
      - kubernetes-admins
      - authentik Admins
      - monitoring-admins
```

**Step 2: Create blueprint template**

Create `flux/infrastructure/authentik-blueprints/chart/templates/blueprint-victoria-metrics.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "authentik-blueprints.fullname" . }}-victoria-metrics
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "authentik-blueprints.labels" . | nindent 4 }}
data:
  victoria-metrics.yaml: |
    version: 1
    metadata:
      name: Victoria Metrics OIDC Setup
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
      - model: authentik_providers_oauth2.oauth2provider
        id: victoria-metrics-provider
        identifiers:
          name: Victoria Metrics
        attrs:
          client_id: {{ .Values.oidc.victoriaMetrics.clientId | quote }}
          client_secret: !Env [AUTHENTIK_VICTORIA_METRICS_SECRET, "fallback-secret"]
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          property_mappings:
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-email]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
            - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-profile]]
          redirect_uris:
            - url: https://vmui.dev.home/*
              matching_mode: regex
          signing_key: !Find [authentik_crypto.certificatekeypair, [name, authentik Self-signed Certificate]]
          access_token_validity: hours=1

      - model: authentik_core.application
        id: victoria-metrics-app
        identifiers:
          slug: victoria-metrics
        attrs:
          name: Victoria Metrics
          provider: !KeyOf victoria-metrics-provider
          policy_engine_mode: any
          icon: {{ .Values.oidc.victoriaMetrics.icon | quote }}

      - model: authentik_policies.policybinding
        identifiers:
          order: 0
          target: !KeyOf victoria-metrics-app
          group: !Find [authentik_core.group, [name, monitoring-admins]]
        attrs:
          enabled: true
          negate: false
          timeout: 30
```

**Step 3: Commit**

```bash
git add flux/infrastructure/authentik-blueprints/chart/templates/blueprint-victoria-metrics.yaml flux/infrastructure/authentik-blueprints/chart/values.yaml
git commit -m "feat: add Authentik blueprint for Victoria Metrics"
```

---

## Task 3: Create Victoria Metrics Namespace and Kustomization

**Files:**
- Create: `flux/infrastructure/victoria-metrics/kustomization.yaml`
- Create: `flux/infrastructure/victoria-metrics/namespace.yaml`

**Step 1: Create namespace manifest**

Create `flux/infrastructure/victoria-metrics/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: victoria-metrics
```

**Step 2: Create component kustomization**

Create `flux/infrastructure/victoria-metrics/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - release.yaml
  - middleware.yaml
  - ingress.yaml
```

**Step 3: Commit**

```bash
git add flux/infrastructure/victoria-metrics/kustomization.yaml flux/infrastructure/victoria-metrics/namespace.yaml
git commit -m "feat: add Victoria Metrics namespace"
```

---

## Task 4: Create Traefik ForwardAuth Middleware

**Files:**
- Create: `flux/infrastructure/victoria-metrics/middleware.yaml`

**Step 1: Create middleware manifest**

Create `flux/infrastructure/victoria-metrics/middleware.yaml`:

```yaml
---
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
      - X-authentik-email
```

**Step 2: Commit**

```bash
git add flux/infrastructure/victoria-metrics/middleware.yaml
git commit -m "feat: add Authentik forwardAuth middleware for Victoria Metrics"
```

---

## Task 5: Create vmui Ingress

**Files:**
- Create: `flux/infrastructure/victoria-metrics/ingress.yaml`

**Step 1: Create ingress manifest**

Create `flux/infrastructure/victoria-metrics/ingress.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vmui
  namespace: victoria-metrics
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: victoria-metrics-authentik-auth@kubernetescrd
spec:
  ingressClassName: traefik-internal
  rules:
    - host: vmui.dev.home
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vmselect-vmcluster
                port:
                  number: 8481
```

**Step 2: Commit**

```bash
git add flux/infrastructure/victoria-metrics/ingress.yaml
git commit -m "feat: add vmui ingress with Authentik authentication"
```

---

## Task 6: Create Victoria Metrics HelmRelease

**Files:**
- Create: `flux/infrastructure/victoria-metrics/release.yaml`

**Step 1: Create HelmRelease manifest**

Create `flux/infrastructure/victoria-metrics/release.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-metrics-stack
  namespace: victoria-metrics
spec:
  chart:
    spec:
      chart: victoria-metrics-k8s-stack
      reconcileStrategy: ChartVersion
      sourceRef:
        kind: HelmRepository
        name: victoria-metrics
        namespace: flux-system
  interval: 1m0s
  timeout: 10m0s
  install:
    remediation:
      retries: 3
  values:
    # VM Operator
    victoria-metrics-operator:
      enabled: true
      operator:
        disable_prometheus_converter: false

    # VMCluster - HA storage
    vmcluster:
      enabled: true
      spec:
        retentionPeriod: "30d"
        replicationFactor: 2

        vmstorage:
          replicaCount: 2
          storage:
            volumeClaimTemplate:
              spec:
                storageClassName: zfs-nfs-csi
                resources:
                  requests:
                    storage: 20Gi
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi

        vmselect:
          replicaCount: 2
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi

        vminsert:
          replicaCount: 2
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi

    # Disable vmsingle (using vmcluster instead)
    vmsingle:
      enabled: false

    # vmagent - HA scraping
    vmagent:
      enabled: true
      spec:
        replicaCount: 2
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi

    # vmalert - HA alerting
    vmalert:
      enabled: true
      spec:
        replicaCount: 2
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi

    # Alertmanager - HA
    alertmanager:
      enabled: true
      spec:
        replicaCount: 2
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            memory: 128Mi
        configSecret: alertmanager-config

    # Grafana disabled (using vmui)
    grafana:
      enabled: false

    # Default scrape configs
    kubelet:
      enabled: true
    kubeApiServer:
      enabled: true
    kubeControllerManager:
      enabled: true
    kubeScheduler:
      enabled: true
    kubeEtcd:
      enabled: true
    coreDns:
      enabled: true
    kubeProxy:
      enabled: true

    # kube-state-metrics
    kube-state-metrics:
      enabled: true

    # node-exporter (Prometheus-style)
    prometheus-node-exporter:
      enabled: true

    # Default alerting rules
    defaultRules:
      create: true
      rules:
        etcd: true
        general: true
        k8s: true
        kubeApiserverAvailability: true
        kubeApiserverBurnrate: true
        kubeApiserverHistogram: true
        kubeApiserverSlos: true
        kubeControllerManager: true
        kubelet: true
        kubeProxy: true
        kubeSchedulerAlerting: true
        kubeSchedulerRecording: true
        kubeStateMetrics: true
        network: true
        node: true
        nodeExporterAlerting: true
        nodeExporterRecording: true
        vmagent: true
        vmhealth: true
```

**Step 2: Commit**

```bash
git add flux/infrastructure/victoria-metrics/release.yaml
git commit -m "feat: add Victoria Metrics k8s-stack HelmRelease"
```

---

## Task 7: Create Alertmanager Configuration Secret

**Files:**
- Create: `flux/infrastructure/victoria-metrics/alertmanager-config.yaml`
- Modify: `flux/infrastructure/victoria-metrics/kustomization.yaml`

**Step 1: Create alertmanager config secret**

Create `flux/infrastructure/victoria-metrics/alertmanager-config.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: victoria-metrics
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      smtp_smarthost: smtp-relay.gmail.com:587
      smtp_from: alertmanager@jabbas.eu
      smtp_require_tls: true

    route:
      receiver: email
      group_by: ['namespace', 'alertname']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h

    receivers:
      - name: email
        email_configs:
          - to: jabbas@jabbas.eu
            send_resolved: true
```

**Step 2: Add to kustomization**

Update `flux/infrastructure/victoria-metrics/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - alertmanager-config.yaml
  - release.yaml
  - middleware.yaml
  - ingress.yaml
```

**Step 3: Commit**

```bash
git add flux/infrastructure/victoria-metrics/alertmanager-config.yaml flux/infrastructure/victoria-metrics/kustomization.yaml
git commit -m "feat: add Alertmanager email configuration"
```

---

## Task 8: Add Victoria Metrics to Flux Kustomization

**Files:**
- Modify: `flux/cluster/infrastructure.yaml`

**Step 1: Add Kustomization with dependencies**

Edit `flux/cluster/infrastructure.yaml` and add the victoria-metrics Kustomization at the end:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: victoria-metrics
  namespace: flux-system
spec:
  interval: 1m0s
  timeout: 10m0s
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/infrastructure/victoria-metrics
  dependsOn:
    - name: sources
    - name: traefik
    - name: authentik
    - name: authentik-blueprints
    - name: reflector
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: vmoperator-victoria-metrics-operator
      namespace: victoria-metrics
```

**Step 2: Commit**

```bash
git add flux/cluster/infrastructure.yaml
git commit -m "feat: add Victoria Metrics Flux Kustomization with dependencies"
```

---

## Task 9: Add Reflector Annotations to Authentik SMTP Secret (if needed)

**Note:** Based on the exploration, Authentik's email config is in values.yaml, not a secret. The SMTP credentials appear to use Gmail's SMTP relay which doesn't require authentication when used from authorized IP/domain.

If SMTP authentication is needed later, add reflector annotations to share secrets. For now, alertmanager uses the same smtp-relay.gmail.com endpoint configured inline.

**Step 1: Verify SMTP configuration works**

After deployment, check alertmanager logs:

```bash
kubectl logs -n victoria-metrics -l app.kubernetes.io/name=alertmanager
```

**Step 2: Skip this task if Gmail relay works without auth**

No commit needed for this task.

---

## Task 10: Final Validation

**Step 1: Review all files created**

```bash
git log --oneline -10
git diff main..feature/victoria-metrics --stat
```

**Step 2: Validate YAML syntax**

```bash
# If yamllint available
yamllint flux/infrastructure/victoria-metrics/
yamllint flux/infrastructure/sources/victoria-metrics.yaml
```

**Step 3: Create summary commit (optional)**

If any fixes were needed, commit them:

```bash
git add -A
git commit -m "fix: address validation issues"
```

---

## Post-Implementation: Deployment Verification

After pushing to main or creating a PR:

1. **Watch Flux reconciliation:**
   ```bash
   flux get kustomizations -w
   ```

2. **Check Victoria Metrics pods:**
   ```bash
   kubectl get pods -n victoria-metrics
   ```

3. **Verify vmui access:**
   - Navigate to https://vmui.dev.home
   - Authenticate via Authentik
   - Run test query: `up`

4. **Test alerting:**
   ```bash
   # Send test alert
   kubectl exec -n victoria-metrics -it deploy/vmalert-vmalert -- \
     wget -qO- 'http://localhost:8080/-/reload'
   ```

5. **Check Alertmanager:**
   ```bash
   kubectl port-forward -n victoria-metrics svc/vmalertmanager-alertmanager 9093:9093
   # Open http://localhost:9093
   ```
