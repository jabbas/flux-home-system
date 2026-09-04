# Tekton CI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Uruchomić Tekton (Pipelines + Triggers + Dashboard) w klastrze Talos, tak by webhook z GitHuba budował obrazy przez BuildKit i pushował je do GHCR, a definicje pipeline'ów żyły w repozytoriach budowanych aplikacji.

**Architecture:** Tekton Operator instalowany oficjalnym chartem OCI jako `HelmRelease`; `TektonConfig` (profil `all`) aplikowany osobną Flux Kustomization po gotowości operatora; Dashboard wewnętrznie za Authentikiem, EventListener publicznie przez istniejący catch-all tunelu Cloudflare; pipeline'y pobierane git resolverem z `.tekton/` repo aplikacji.

**Tech Stack:** Flux CD (HelmRelease/Kustomization), Tekton Operator 0.81.1 (OCI chart), Tekton Triggers, BuildKit rootless, Traefik, Authentik blueprints, Sealed Secrets, kustomize.

**Spec:** `docs/plans/2026-09-04-tekton-design.md`

---

## Odstępstwo od specyfikacji — przeczytaj przed startem

Spec (sekcja „Konfiguracja HelmRelease") zakładał `TektonConfig` w `extraObjects` charta. **Plan tego nie robi** — powód:

CRD `tektonconfigs.operator.tekton.dev` jest instalowany przez ten sam chart (`installCRDs: true`), a Helm nie czeka na `Established` przed aplikowaniem pozostałych zasobów. Utworzenie CR w tym samym release'ie może paść na `no matches for kind "TektonConfig"`. Przy `install.remediation.retries: 3` Flux odinstalowałby wtedy release — a przy `installCRDs: true` uninstall kasuje kaskadowo CRD wraz ze wszystkimi zasobami Tektona.

Zamiast tego rozdzielamy na dwie Flux Kustomizations, dokładnie wzorem istniejącego `metallb/release` + `metallb/config`:

- `tekton-release` → HelmRelease operatora (+ CRD), health check na Deploymencie
- `tekton-config` → `TektonConfig`, ingress, middleware; `dependsOn: [tekton-release]`

Flux ponawia aplikowanie CR-ów do skutku i nie robi rollbacku, więc problem znika. Katalog `flux/infrastructure/tekton/` dostaje podkatalogi `release/` i `config/`.

---

## Struktura plików

| Ścieżka | Odpowiedzialność |
|---|---|
| `flux/infrastructure/sources/tekton.yaml` | HelmRepository OCI |
| `flux/infrastructure/tekton/release/namespace.yaml` | ns `tekton-operator` |
| `flux/infrastructure/tekton/release/release.yaml` | HelmRelease operatora |
| `flux/infrastructure/tekton/release/kustomization.yaml` | agregat |
| `flux/infrastructure/tekton/config/config.yaml` | `TektonConfig` |
| `flux/infrastructure/tekton/config/middleware.yaml` | forwardAuth Authentik |
| `flux/infrastructure/tekton/config/ingress.yaml` | `tekton.dev.home` → Dashboard |
| `flux/infrastructure/tekton/config/kustomization.yaml` | agregat |
| `flux/infrastructure/tekton/ci/namespace.yaml` | ns `ci` |
| `flux/infrastructure/tekton/ci/buildkit.yaml` | Deployment + Service + PVC |
| `flux/infrastructure/tekton/ci/rbac.yaml` | SA + RoleBindings (EventListener, per-repo) |
| `flux/infrastructure/tekton/ci/secrets.yaml` | SealedSecrets (HMAC, GHCR) |
| `flux/infrastructure/tekton/ci/eventlistener.yaml` | EventListener + TriggerBinding + TriggerTemplate |
| `flux/infrastructure/tekton/ci/ingress.yaml` | `tekton.jabbas.eu` → EventListener |
| `flux/infrastructure/tekton/ci/kustomization.yaml` | agregat |
| `flux/cluster/infrastructure.yaml` | 3 bloki: `tekton-release`, `tekton-config`, `tekton-ci` |
| `authentik-blueprints/chart/templates/blueprint-tekton.yaml` | proxy provider + app + policy |
| `authentik-blueprints/chart/templates/blueprint-outpost.yaml` | wspólna lista providerów outpostu |
| `authentik-blueprints/chart/templates/blueprint-victoria-metrics.yaml` | modyfikacja: usunięcie wpisu outpostu |
| `authentik-blueprints/chart/values.yaml` | grupa `tekton-admins`, `oidc.tekton` |

## Konwencje obowiązujące w każdym tasku

- YAML: 2 spacje, `---` na starcie pliku, pliki kebab-case.
- Walidacja przed commitem: `yamllint .` oraz `uvx flux-local test --enable-helm --path flux/cluster --sources flux-system` (wymaga `kustomize` w PATH).
- Commity: `feat(tekton): ...`, `fix(tekton): ...`, `refactor(authentik-blueprints): ...`.
- **Push do `main` = deploy.** Po pushu wymuś sync: `flux -n flux-system reconcile kustomization flux-system --with-source`.

---

## FAZA 1 — Platforma

### Task 1: HelmRepository OCI

**Files:**
- Create: `flux/infrastructure/sources/tekton.yaml`
- Modify: `flux/infrastructure/sources/kustomization.yaml`

- [ ] **Step 1: Potwierdź, że chart jest osiągalny anonimowo**

```bash
helm show chart oci://ghcr.io/tektoncd/operator/charts/tekton-operator --version 0.81.1
```

Expected: metadane charta, `appVersion: v0.81.1`, `version: 0.81.1`. Jeśli komenda zwróci `not found`, zatrzymaj się i ustal aktualną wersję: `helm show chart oci://ghcr.io/tektoncd/operator/charts/tekton-operator` (bez `--version`) — użyj tej wersji we wszystkich krokach zamiast `0.81.1`.

- [ ] **Step 2: Utwórz HelmRepository**

`flux/infrastructure/sources/tekton.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: tekton
  namespace: flux-system
spec:
  interval: 24h
  type: oci
  url: oci://ghcr.io/tektoncd/operator/charts
```

- [ ] **Step 3: Dopisz do agregatu**

W `flux/infrastructure/sources/kustomization.yaml` dopisz na końcu listy `resources:`:

```yaml
  - tekton.yaml
```

- [ ] **Step 4: Walidacja**

```bash
yamllint .
kubectl apply --dry-run=client -f flux/infrastructure/sources/tekton.yaml
```

Expected: `yamllint` bez błędów; dry-run wypisuje `helmrepository.source.toolkit.fluxcd.io/tekton created (dry run)`.

- [ ] **Step 5: Commit**

```bash
git add flux/infrastructure/sources/tekton.yaml flux/infrastructure/sources/kustomization.yaml
git commit -m "feat(tekton): add OCI HelmRepository for Tekton Operator chart"
```

---

### Task 2: HelmRelease operatora

**Files:**
- Create: `flux/infrastructure/tekton/release/namespace.yaml`
- Create: `flux/infrastructure/tekton/release/release.yaml`
- Create: `flux/infrastructure/tekton/release/kustomization.yaml`

- [ ] **Step 1: Namespace**

Chart nie tworzy namespace'u — zweryfikowane (`helm template` daje 0 zasobów `kind: Namespace`).

`flux/infrastructure/tekton/release/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: tekton-operator
```

- [ ] **Step 2: HelmRelease**

`flux/infrastructure/tekton/release/release.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tekton-operator
  namespace: tekton-operator
spec:
  interval: 30m
  timeout: 15m

  install:
    remediation:
      retries: 3

  upgrade:
    remediation:
      retries: 3

  chart:
    spec:
      chart: tekton-operator
      version: "0.81.1"
      sourceRef:
        kind: HelmRepository
        name: tekton
        namespace: flux-system

  values:
    # UWAGA: chart szablonuje CRD w templates/, więc odinstalowanie tego
    # HelmRelease (lub usunięcie Kustomization tekton-release z
    # flux/cluster/infrastructure.yaml) skasuje KASKADOWO wszystkie zasoby
    # Tektona w klastrze, łącznie z PipelineRunami. Zachowanie zamierzone.
    installCRDs: true

    operator:
      # TektonConfig aplikujemy z gita (flux/infrastructure/tekton/config),
      # nie pozwalamy operatorowi tworzyć go samodzielnie.
      autoInstallComponents: false
      defaultTargetNamespace: tekton-pipelines
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 512Mi

    webhook:
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
        limits:
          memory: 256Mi
```

- [ ] **Step 3: Kustomization**

`flux/infrastructure/tekton/release/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - release.yaml
```

- [ ] **Step 4: Walidacja**

```bash
yamllint .
flux build kustomization tekton-release --path ./flux/infrastructure/tekton/release --dry-run
```

Expected: wyrenderowane `Namespace` + `HelmRelease`, bez błędów parsowania.

- [ ] **Step 5: Commit**

```bash
git add flux/infrastructure/tekton/release
git commit -m "feat(tekton): add Tekton Operator HelmRelease"
```

---

### Task 3: Podpięcie `tekton-release` do Fluxa i wdrożenie

**Files:**
- Modify: `flux/cluster/infrastructure.yaml` (dopisz na końcu pliku)

- [ ] **Step 1: Potwierdź stan wyjściowy**

```bash
kubectl get ns | grep -i tekton
kubectl get crd | grep -i tekton
```

Expected: brak wyników z obu komend (start od zera). Jeśli coś istnieje — zatrzymaj się i ustal, skąd.

- [ ] **Step 2: Dopisz blok Kustomization**

Na końcu `flux/cluster/infrastructure.yaml`:

```yaml

---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tekton-release
  namespace: flux-system
spec:
  interval: 1m0s
  timeout: 10m0s
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/infrastructure/tekton/release
  dependsOn:
    - name: sources
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: tekton-operator
      namespace: tekton-operator
```

- [ ] **Step 3: Walidacja pełnego drzewa**

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
```

Expected: wszystkie testy PASS (chart zostanie pobrany z GHCR — pierwszy przebieg potrwa dłużej).

- [ ] **Step 4: Commit i deploy**

```bash
git add flux/cluster/infrastructure.yaml
git commit -m "feat(tekton): wire tekton-release Kustomization into cluster"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

- [ ] **Step 5: Zweryfikuj wdrożenie**

```bash
flux get kustomizations -A | grep tekton
kubectl -n tekton-operator get deploy,pod
kubectl get crd | grep operator.tekton.dev | wc -l
```

Expected: `tekton-release` = Ready True; Deploymenty `tekton-operator` (2 kontenery) i `tekton-operator-webhook` w stanie Running; **13 CRD-ków** `*.operator.tekton.dev`.

Jeśli pody nie wstają — sprawdź `kubectl -n tekton-operator describe pod` pod kątem odrzucenia przez Pod Security Admission i zanotuj to; ten sam problem wróci w Fazie 2.

---

### Task 4: TektonConfig — komponenty Tektona

**Files:**
- Create: `flux/infrastructure/tekton/config/config.yaml`
- Create: `flux/infrastructure/tekton/config/kustomization.yaml`
- Modify: `flux/cluster/infrastructure.yaml`

- [ ] **Step 1: TektonConfig**

`flux/infrastructure/tekton/config/config.yaml`:

```yaml
---
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  name: config
spec:
  # profile: all == pipelines + triggers + dashboard
  profile: all
  targetNamespace: tekton-pipelines
  pipeline:
    # Wymagane, by PipelineRun mógł pobrać definicję z .tekton/ repo aplikacji
    enable-git-resolver: true
  pruner:
    # Stary pruner oparty o CronJob — wyłączony na rzecz tektonpruner
    disabled: true
  tektonpruner:
    disabled: false
    global-config:
      enforcedConfigLevel: global
      ttlSecondsAfterFinished: 3600
      successfulHistoryLimit: 5
      failedHistoryLimit: 3
```

- [ ] **Step 2: Kustomization**

`flux/infrastructure/tekton/config/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - config.yaml
```

- [ ] **Step 3: Blok Kustomization w Fluxie**

Na końcu `flux/cluster/infrastructure.yaml`:

```yaml

---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tekton-config
  namespace: flux-system
spec:
  interval: 1m0s
  timeout: 10m0s
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/infrastructure/tekton/config
  dependsOn:
    - name: tekton-release
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: tekton-pipelines-controller
      namespace: tekton-pipelines
    - apiVersion: apps/v1
      kind: Deployment
      name: tekton-triggers-controller
      namespace: tekton-pipelines
    - apiVersion: apps/v1
      kind: Deployment
      name: tekton-dashboard
      namespace: tekton-pipelines
```

- [ ] **Step 4: Walidacja i deploy**

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/tekton/config flux/cluster/infrastructure.yaml
git commit -m "feat(tekton): apply TektonConfig with profile all and git resolver"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

- [ ] **Step 5: Zweryfikuj komponenty**

```bash
kubectl get tektonconfig config -o jsonpath='{.status.conditions}' | jq
kubectl -n tekton-pipelines get deploy
kubectl -n tekton-pipelines get cm config-defaults -o yaml | grep -i resolver
```

Expected: `TektonConfig` w stanie `Ready: True`; Deploymenty `tekton-pipelines-controller`, `tekton-pipelines-webhook`, `tekton-triggers-controller`, `tekton-triggers-webhook`, `tekton-triggers-core-interceptors`, `tekton-dashboard` — wszystkie Available.

Jeśli `tekton-config` wisi na health checku: nazwy Deploymentów mogły się zmienić między wersjami operatora — sprawdź `kubectl -n tekton-pipelines get deploy` i popraw `healthChecks`, po czym commit `fix(tekton): correct health check deployment names`.

---

### Task 5: Grupa `tekton-admins` i blueprint Authentika

**Files:**
- Modify: `flux/infrastructure/authentik-blueprints/chart/values.yaml`
- Create: `flux/infrastructure/authentik-blueprints/chart/templates/blueprint-tekton.yaml`

- [ ] **Step 1: Dodaj grupę i konfigurację ikony**

W `values.yaml`, w sekcji `groups:` dopisz:

```yaml
  - name: tekton-admins
    superuser: false
```

W sekcji `oidc:` dopisz:

```yaml
  tekton:
    icon: https://raw.githubusercontent.com/cncf/artwork/main/projects/tekton/icon/color/tekton-icon-color.svg
```

- [ ] **Step 2: Blueprint Tektona**

`flux/infrastructure/authentik-blueprints/chart/templates/blueprint-tekton.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "authentik-blueprints.fullname" . }}-tekton
  labels:
    {{- include "authentik-blueprints.componentLabels" (dict "context" . "component" "tekton") | nindent 4 }}
data:
  tekton.yaml: |
    version: 1
    metadata:
      name: Tekton Dashboard Proxy Setup
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
      # Proxy provider for forwardAuth with Traefik
      - model: authentik_providers_proxy.proxyprovider
        id: tekton-provider
        identifiers:
          name: Tekton Proxy
        attrs:
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
          invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
          external_host: https://tekton.dev.home
          mode: forward_single
          access_token_validity: hours=24

      # Application
      - model: authentik_core.application
        id: tekton-app
        identifiers:
          slug: tekton
        attrs:
          name: Tekton
          icon: {{ .Values.oidc.tekton.icon | quote }}
          provider: !Find [authentik_providers_proxy.proxyprovider, [name, "Tekton Proxy"]]

      # Policy binding for access control
      - model: authentik_policies.policybinding
        identifiers:
          order: 0
          target: !Find [authentik_core.application, [slug, tekton]]
          group: !Find [authentik_core.group, [name, tekton-admins]]
        attrs:
          enabled: true
          negate: false
          timeout: 30
```

Zwróć uwagę: **brak wpisu `authentik_outposts.outpost`** — trafia on do wspólnego blueprintu w Tasku 6.

- [ ] **Step 3: Walidacja renderowania**

```bash
helm template flux/infrastructure/authentik-blueprints/chart | grep -A5 'tekton.yaml'
```

Expected: ConfigMap z blueprintem renderuje się, ikona podstawiona z values.

- [ ] **Step 4: Commit** (bez pushu — push razem z Taskiem 6)

```bash
git add flux/infrastructure/authentik-blueprints/chart
git commit -m "feat(authentik-blueprints): add Tekton proxy provider and tekton-admins group"
```

---

### Task 6: Refaktor wpisu outpostu (naprawa istniejącego błędu)

`blueprint-victoria-metrics.yaml` ustawia `providers:` na embedded outpoście, co **nadpisuje** listę zamiast do niej dopisywać. Dodanie drugiego takiego wpisu odebrałoby uwierzytelnianie jednemu z serwisów.

**Files:**
- Create: `flux/infrastructure/authentik-blueprints/chart/templates/blueprint-outpost.yaml`
- Modify: `flux/infrastructure/authentik-blueprints/chart/templates/blueprint-victoria-metrics.yaml`

- [ ] **Step 1: Zapisz stan wyjściowy outpostu**

```bash
kubectl -n authentik exec deploy/authentik-stack-server -- \
  ak shell -c "from authentik.outposts.models import Outpost; o=Outpost.objects.get(name='authentik Embedded Outpost'); print([p.name for p in o.providers.all()])"
```

Expected: lista nazw providerów. Zanotuj wynik — po Tasku 6 lista musi zawierać **wszystkie** dotychczasowe pozycje plus `Tekton Proxy`. Jeśli komenda się nie powiedzie, odczytaj listę w UI Authentika (Applications → Outposts → authentik Embedded Outpost).

- [ ] **Step 2: Wspólny blueprint outpostu**

`flux/infrastructure/authentik-blueprints/chart/templates/blueprint-outpost.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "authentik-blueprints.fullname" . }}-outpost
  labels:
    {{- include "authentik-blueprints.componentLabels" (dict "context" . "component" "outpost") | nindent 4 }}
data:
  outpost.yaml: |
    version: 1
    metadata:
      name: Embedded Outpost Providers
      labels:
        blueprints.goauthentik.io/instantiate: "true"
    entries:
      # UWAGA: attrs.providers NADPISUJE listę providerów outpostu.
      # Każdy nowy proxy provider MUSI być dopisany tutaj — nigdy we
      # własnym blueprincie serwisu, bo skasuje pozostałe.
      - model: authentik_outposts.outpost
        identifiers:
          name: "authentik Embedded Outpost"
        state: present
        attrs:
          config:
            authentik_host: https://authentik.dev.home
          providers:
            - !Find [authentik_providers_proxy.proxyprovider, [name, "Victoria Metrics Proxy"]]
            - !Find [authentik_providers_proxy.proxyprovider, [name, "Tekton Proxy"]]
```

- [ ] **Step 3: Usuń wpis outpostu z blueprintu Victoria Metrics**

W `blueprint-victoria-metrics.yaml` usuń całość od komentarza `# Update embedded outpost...` do końca pliku (linie 48-57), czyli blok:

```yaml
      # Update embedded outpost to include this provider and set authentik_host
      - model: authentik_outposts.outpost
        identifiers:
          name: "authentik Embedded Outpost"
        state: present
        attrs:
          config:
            authentik_host: https://authentik.dev.home
          providers:
            - !Find [authentik_providers_proxy.proxyprovider, [name, "Victoria Metrics Proxy"]]
```

Plik ma się kończyć na policy bindingu (linia 46).

- [ ] **Step 4: Walidacja i deploy**

```bash
helm template flux/infrastructure/authentik-blueprints/chart | grep -c 'authentik_outposts.outpost'
```

Expected: **1** (dokładnie jedno wystąpienie w całym charcie).

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/authentik-blueprints/chart/templates
git commit -m "refactor(authentik-blueprints): move outpost provider list to shared blueprint"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

- [ ] **Step 5: Zweryfikuj, że nic nie straciło auth**

Powtórz komendę ze Stepu 1.

Expected: lista providerów zawiera `Victoria Metrics Proxy` **oraz** `Tekton Proxy`, plus wszystko, co było tam wcześniej. Dodatkowo otwórz `https://vmui.dev.home` — musi nadal przekierowywać do logowania Authentika.

Jeśli w Stepie 1 wyszło, że outpost miał providera dla firecrawla (z `flux-homeapps`), a teraz go nie ma — dopisz go do listy w `blueprint-outpost.yaml` i zacommituj `fix(authentik-blueprints): restore firecrawl provider on embedded outpost`.

---

### Task 7: Ingress Dashboardu za Authentikiem

**Files:**
- Create: `flux/infrastructure/tekton/config/middleware.yaml`
- Create: `flux/infrastructure/tekton/config/ingress.yaml`
- Modify: `flux/infrastructure/tekton/config/kustomization.yaml`

- [ ] **Step 1: Potwierdź nazwę i port Service Dashboardu**

```bash
kubectl -n tekton-pipelines get svc tekton-dashboard -o jsonpath='{.spec.ports[0].port}{"\n"}'
```

Expected: `9097`. Jeśli inny — użyj wartości z outputu w Stepie 3.

- [ ] **Step 2: Middleware**

`flux/infrastructure/tekton/config/middleware.yaml`:

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-auth
  namespace: tekton-pipelines
spec:
  forwardAuth:
    address: http://authentik-stack-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
```

- [ ] **Step 3: Ingress**

`flux/infrastructure/tekton/config/ingress.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: tekton-pipelines-authentik-auth@kubernetescrd
spec:
  ingressClassName: traefik-internal
  rules:
    - host: tekton.dev.home
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tekton-dashboard
                port:
                  number: 9097
```

- [ ] **Step 4: Dopisz do agregatu**

W `flux/infrastructure/tekton/config/kustomization.yaml`:

```yaml
resources:
  - config.yaml
  - middleware.yaml
  - ingress.yaml
```

- [ ] **Step 5: Deploy i weryfikacja**

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/tekton/config
git commit -m "feat(tekton): expose Dashboard at tekton.dev.home behind Authentik"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

Otwórz `https://tekton.dev.home` w przeglądarce.

Expected: przekierowanie do Authentika; po zalogowaniu kontem w grupie `tekton-admins` — Dashboard Tektona. Konto **spoza** grupy musi dostać odmowę dostępu.

**Faza 1 zakończona.** Platforma działa, Dashboard chroniony.

---

## FAZA 2 — CI

### Task 8: Namespace `ci` i rozpoznanie Pod Security Admission

Ryzyko ze speca: rootless BuildKit wymaga `seccompProfile: Unconfined`, czego PSA `baseline` zabrania. **Najpierw sprawdzamy empirycznie**, zamiast z góry podnosić uprawnienia.

**Files:**
- Create: `flux/infrastructure/tekton/ci/namespace.yaml`
- Create: `flux/infrastructure/tekton/ci/kustomization.yaml`
- Modify: `flux/cluster/infrastructure.yaml`

- [ ] **Step 1: Odczytaj politykę PSA klastra**

```bash
kubectl get ns tekton-pipelines -o jsonpath='{.metadata.labels}' | jq
kubectl -n kube-system get cm -o name | grep -i admission
```

Zanotuj, czy namespace'y mają etykiety `pod-security.kubernetes.io/enforce`. To determinuje Step 3.

- [ ] **Step 2: Namespace bez podniesionych uprawnień**

`flux/infrastructure/tekton/ci/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ci
```

`flux/infrastructure/tekton/ci/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

Blok w `flux/cluster/infrastructure.yaml`:

```yaml

---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tekton-ci
  namespace: flux-system
spec:
  interval: 1m0s
  timeout: 5m0s
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/infrastructure/tekton/ci
  dependsOn:
    - name: tekton-config
    - name: sealed-secrets
    - name: democratic-csi
```

- [ ] **Step 3: Test PSA — pod rootless BuildKita**

```bash
git add flux/infrastructure/tekton/ci flux/cluster/infrastructure.yaml
git commit -m "feat(tekton): add ci namespace"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

Następnie test jednorazowy (nie commitujemy go):

```bash
kubectl -n ci run psa-probe --image=moby/buildkit:master-rootless --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"psa-probe","image":"moby/buildkit:master-rootless","command":["sleep","30"],"securityContext":{"seccompProfile":{"type":"Unconfined"},"runAsUser":1000,"runAsGroup":1000}}]}}'
kubectl -n ci get pod psa-probe
kubectl -n ci delete pod psa-probe --ignore-not-found
```

Expected — **dwa możliwe wyniki, oba akceptowalne:**

- Pod przechodzi (`Running`/`Completed`) → PSA nie blokuje, **nie dodawaj** etykiety, przejdź do Taska 9 bez zmian.
- `Error from server (Forbidden): ... violates PodSecurity "baseline:latest": seccompProfile` → dopisz do `namespace.yaml`:

  ```yaml
    labels:
      # rootless BuildKit wymaga seccompProfile: Unconfined, czego baseline zabrania
      pod-security.kubernetes.io/enforce: privileged
  ```

  i zacommituj `fix(tekton): allow privileged PSA in ci namespace for rootless BuildKit`, po czym powtórz test.

- [ ] **Step 4: Zapisz wynik w planie**

Odhacz tutaj, który wariant zaszedł — Task 9 zakłada, że pod z `seccompProfile: Unconfined` da się już uruchomić w `ci`.

---

### Task 9: BuildKit

**Files:**
- Create: `flux/infrastructure/tekton/ci/buildkit.yaml`
- Modify: `flux/infrastructure/tekton/ci/kustomization.yaml`

- [ ] **Step 1: Ustal aktualny tag BuildKita**

```bash
crane ls docker.io/moby/buildkit 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rootless$' | tail -5
```

Jeśli `crane` nie jest zainstalowany, sprawdź https://github.com/moby/buildkit/releases i weź najnowszy stabilny tag. Poniżej użyto `v0.27.0-rootless` — **podmień na ustalony tag**, jeśli się różni.

- [ ] **Step 2: Deployment, Service i cache PVC**

`flux/infrastructure/tekton/ci/buildkit.yaml`:

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: buildkit-cache
  namespace: ci
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: zfs-nfs-csi
  resources:
    requests:
      storage: 20Gi

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: buildkitd
  namespace: ci
spec:
  replicas: 1
  strategy:
    # PVC jest RWO — Recreate zapobiega blokadzie Multi-Attach przy rolloucie
    type: Recreate
  selector:
    matchLabels:
      app: buildkitd
  template:
    metadata:
      labels:
        app: buildkitd
      annotations:
        container.apparmor.security.beta.kubernetes.io/buildkitd: unconfined
    spec:
      containers:
        - name: buildkitd
          image: moby/buildkit:v0.27.0-rootless
          args:
            - --addr
            - tcp://0.0.0.0:1234
            - --oci-worker-no-process-sandbox
          readinessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 5
            periodSeconds: 30
          livenessProbe:
            exec:
              command: ["buildctl", "debug", "workers"]
            initialDelaySeconds: 5
            periodSeconds: 30
          securityContext:
            seccompProfile:
              type: Unconfined
            runAsUser: 1000
            runAsGroup: 1000
          ports:
            - containerPort: 1234
              name: buildkit
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              memory: 4Gi
          volumeMounts:
            - name: cache
              mountPath: /home/user/.local/share/buildkit
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: buildkit-cache

---
apiVersion: v1
kind: Service
metadata:
  name: buildkitd
  namespace: ci
spec:
  selector:
    app: buildkitd
  ports:
    - port: 1234
      targetPort: 1234
      name: buildkit
```

- [ ] **Step 3: Dopisz do agregatu i wdróż**

```yaml
resources:
  - namespace.yaml
  - buildkit.yaml
```

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/tekton/ci
git commit -m "feat(tekton): add rootless BuildKit daemon with layer cache"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

- [ ] **Step 4: Zweryfikuj, że demon odpowiada**

```bash
kubectl -n ci get pod -l app=buildkitd
kubectl -n ci exec deploy/buildkitd -- buildctl debug workers
```

Expected: pod `Running` i `1/1 Ready`; `buildctl debug workers` listuje co najmniej jednego workera z platformą `linux/amd64`.

Jeśli pod pada na PSA mimo Taska 8, albo na `failed to create shim` — przełącz się na fallback z speca (Buildah `vfs`) i udokumentuj to commitem `fix(tekton): replace BuildKit with Buildah vfs builder`.

---

### Task 10: Sekrety — HMAC webhooka i push do GHCR

**Files:**
- Create: `flux/infrastructure/tekton/ci/secrets.yaml`
- Modify: `flux/infrastructure/tekton/ci/kustomization.yaml`

Pilotowe repo: **`jabbas/ibakery`**, obraz `ghcr.io/jabbas/ibakery`.

- [ ] **Step 1: Wygeneruj sekret HMAC**

```bash
openssl rand -hex 32
```

Zapisz wynik — trafi zarówno do SealedSecret, jak i do konfiguracji webhooka na GitHubie (Task 12).

- [ ] **Step 2: Utwórz PAT do GHCR**

Na GitHubie: Settings → Developer settings → Personal access tokens → Fine-grained, scope **`write:packages`**, ograniczony do repo `jabbas/ibakery`. Skopiuj token.

- [ ] **Step 3: Zapieczętuj oba sekrety**

```bash
# HMAC webhooka
kubectl -n ci create secret generic tekton-github-webhook \
  --from-literal=secretToken='<HMAC-ze-Stepu-1>' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > /tmp/sealed-webhook.yaml

# Credentials do GHCR dla repo ibakery
kubectl -n ci create secret docker-registry ghcr-ibakery \
  --docker-server=ghcr.io \
  --docker-username=jabbas \
  --docker-password='<PAT-ze-Stepu-2>' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > /tmp/sealed-ghcr.yaml
```

Złóż oba `SealedSecret`y w `flux/infrastructure/tekton/ci/secrets.yaml`, rozdzielone `---`, z `---` na początku pliku.

**Nigdy nie commituj plików pośrednich ani wartości w postaci jawnej.** `.gitignore` repo pokrywa `*secret.yaml` — upewnij się, że plik nazywa się `secrets.yaml` i **nie** jest przez to ignorowany:

```bash
git check-ignore -v flux/infrastructure/tekton/ci/secrets.yaml
```

Expected: brak wyniku (plik nie jest ignorowany). Jeśli jest ignorowany — nazwij plik `sealed-secrets.yaml` i użyj tej nazwy w `kustomization.yaml`.

- [ ] **Step 4: Wdróż i zweryfikuj rozpieczętowanie**

```bash
yamllint .
git add flux/infrastructure/tekton/ci
git commit -m "feat(tekton): add sealed secrets for GitHub webhook and GHCR push"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
kubectl -n ci get secret tekton-github-webhook ghcr-ibakery
```

Expected: oba sekrety istnieją, typy odpowiednio `Opaque` i `kubernetes.io/dockerconfigjson`.

---

### Task 11: RBAC — ServiceAccounty

Zgodnie ze specem: SA dla EventListenera + **osobny SA per repozytorium** z własnym sekretem GHCR.

**Files:**
- Create: `flux/infrastructure/tekton/ci/rbac.yaml`
- Modify: `flux/infrastructure/tekton/ci/kustomization.yaml`

- [ ] **Step 1: RBAC**

`flux/infrastructure/tekton/ci/rbac.yaml`:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-triggers-sa
  namespace: ci

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tekton-triggers-eventlistener-binding
  namespace: ci
subjects:
  - kind: ServiceAccount
    name: tekton-triggers-sa
    namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-roles

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-triggers-eventlistener-clusterbinding
subjects:
  - kind: ServiceAccount
    name: tekton-triggers-sa
    namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles

---
# SA per repozytorium — skompromitowane repo wynosi wyłącznie własny token GHCR
apiVersion: v1
kind: ServiceAccount
metadata:
  name: build-ibakery
  namespace: ci
secrets:
  - name: ghcr-ibakery
imagePullSecrets:
  - name: ghcr-ibakery
```

- [ ] **Step 2: Potwierdź, że ClusterRole Triggers istnieją**

```bash
kubectl get clusterrole | grep tekton-triggers-eventlistener
```

Expected: `tekton-triggers-eventlistener-roles` i `tekton-triggers-eventlistener-clusterroles` (instaluje je operator w Tasku 4). Jeśli ich nie ma — Triggers nie wstały; wróć do Taska 4.

- [ ] **Step 3: Wdróż**

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/tekton/ci
git commit -m "feat(tekton): add service accounts for triggers and per-repo builds"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
kubectl -n ci get sa
```

Expected: `tekton-triggers-sa` i `build-ibakery`.

---

### Task 12: EventListener, Triggers i publiczny endpoint

**Files:**
- Create: `flux/infrastructure/tekton/ci/eventlistener.yaml`
- Create: `flux/infrastructure/tekton/ci/ingress.yaml`
- Modify: `flux/infrastructure/tekton/ci/kustomization.yaml`

- [ ] **Step 1: EventListener z zabezpieczeniami**

`flux/infrastructure/tekton/ci/eventlistener.yaml`:

```yaml
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: github-push
  namespace: ci
spec:
  params:
    - name: repo-url
      value: $(body.repository.clone_url)
    - name: repo-name
      value: $(body.repository.name)
    - name: revision
      value: $(body.after)

---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: build-from-repo
  namespace: ci
spec:
  params:
    - name: repo-url
    - name: repo-name
    - name: revision
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: build-$(tt.params.repo-name)-
        namespace: ci
      spec:
        taskRunTemplate:
          serviceAccountName: build-$(tt.params.repo-name)
        pipelineRef:
          # Definicja pipeline'u pochodzi z repo aplikacji, w wersji z tego commita
          resolver: git
          params:
            - name: url
              value: $(tt.params.repo-url)
            - name: revision
              value: $(tt.params.revision)
            - name: pathInRepo
              value: .tekton/pipeline.yaml
        params:
          - name: repo-url
            value: $(tt.params.repo-url)
          - name: revision
            value: $(tt.params.revision)
          - name: image
            value: ghcr.io/jabbas/$(tt.params.repo-name)
        workspaces:
          - name: source
            volumeClaimTemplate:
              spec:
                accessModes:
                  - ReadWriteOnce
                storageClassName: zfs-nfs-csi
                resources:
                  requests:
                    storage: 5Gi

---
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: github
  namespace: ci
spec:
  serviceAccountName: tekton-triggers-sa
  triggers:
    - name: github-push
      interceptors:
        # 1. Weryfikacja sygnatury HMAC — odrzuca payloady spoza GitHuba
        - ref:
            name: github
          params:
            - name: secretRef
              value:
                secretName: tekton-github-webhook
                secretKey: secretToken
            - name: eventTypes
              value:
                - push
        # 2. Allowlista repozytoriów — tylko świadomie dopuszczone repo
        - ref:
            name: cel
          params:
            - name: filter
              value: >-
                body.repository.full_name in ['jabbas/ibakery'] &&
                body.ref == 'refs/heads/main'
      bindings:
        - ref: github-push
      template:
        ref: build-from-repo
```

**Uwaga o forkach:** ten EventListener reaguje wyłącznie na `push` do `main` w repozytorium z allowlisty, więc payloady z forków nie mają jak wyzwolić builda. Jeśli w przyszłości dodasz trigger na `pull_request`, **musisz** dołożyć do filtra CEL warunek `body.pull_request.head.repo.full_name == body.repository.full_name` — inaczej PR z forka wykona dowolny kod z własnym `.tekton/pipeline.yaml`, mając dostęp do tokenu GHCR.

- [ ] **Step 2: Ingress publiczny**

`flux/infrastructure/tekton/ci/ingress.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tekton-webhook
  namespace: ci
spec:
  # traefik-external jest publiczny — Cloudflare terminuje TLS, więc bez spec.tls
  ingressClassName: traefik-external
  rules:
    - host: tekton.jabbas.eu
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: el-github
                port:
                  number: 8080
```

- [ ] **Step 3: Dopisz do agregatu i wdróż**

```yaml
resources:
  - namespace.yaml
  - buildkit.yaml
  - secrets.yaml
  - rbac.yaml
  - eventlistener.yaml
  - ingress.yaml
```

```bash
yamllint .
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
git add flux/infrastructure/tekton/ci
git commit -m "feat(tekton): add GitHub EventListener with HMAC and repo allowlist"
git push
flux -n flux-system reconcile kustomization flux-system --with-source
```

- [ ] **Step 4: Zweryfikuj Service i osiągalność z internetu**

```bash
kubectl -n ci get svc el-github
kubectl -n ci get pod -l eventlistener=github
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://tekton.jabbas.eu
```

Expected: Service `el-github` na porcie 8080; pod EventListenera Running; `curl` zwraca kod **inny niż 404** (najpewniej 400 lub 401 — brak sygnatury HMAC). Kod 404 oznacza, że Ingress nie złapał hosta.

- [ ] **Step 5: Skonfiguruj webhook na GitHubie**

W `jabbas/ibakery` → Settings → Webhooks → Add webhook:
- Payload URL: `https://tekton.jabbas.eu`
- Content type: `application/json`
- Secret: HMAC z Taska 10 Step 1
- Events: **Just the push event**

Expected: GitHub pokazuje dostarczenie testowe (ping) z kodem 2xx lub 400 — sprawdź w Recent Deliveries, że request w ogóle dociera.

---

### Task 13: Pipeline w repo aplikacji i test end-to-end

To jedyny task **poza tym repozytorium** — plik trafia do `jabbas/ibakery`.

**Files:**
- Create (w repo `jabbas/ibakery`): `.tekton/pipeline.yaml`

- [ ] **Step 1: Napisz pipeline**

`.tekton/pipeline.yaml` w repo `jabbas/ibakery`:

```yaml
---
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
    - name: image
      type: string
  workspaces:
    - name: source
  tasks:
    - name: clone
      workspaces:
        - name: source
          workspace: source
      params:
        - name: repo-url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)
      taskSpec:
        params:
          - name: repo-url
          - name: revision
        workspaces:
          - name: source
        steps:
          - name: git-clone
            image: alpine/git:2.45.2
            script: |
              #!/bin/sh
              set -eu
              git clone "$(params.repo-url)" "$(workspaces.source.path)/repo"
              cd "$(workspaces.source.path)/repo"
              git checkout "$(params.revision)"

    - name: build-and-push
      runAfter:
        - clone
      workspaces:
        - name: source
          workspace: source
      params:
        - name: image
          value: $(params.image)
        - name: revision
          value: $(params.revision)
      taskSpec:
        params:
          - name: image
          - name: revision
        workspaces:
          - name: source
        steps:
          - name: buildctl
            image: moby/buildkit:v0.27.0
            env:
              - name: BUILDKIT_HOST
                value: tcp://buildkitd.ci.svc.cluster.local:1234
              - name: DOCKER_CONFIG
                value: /tekton/creds/.docker
            script: |
              #!/bin/sh
              set -eu
              cd "$(workspaces.source.path)/repo"
              buildctl build \
                --frontend dockerfile.v0 \
                --local context=. \
                --local dockerfile=. \
                --output type=image,name=$(params.image):$(params.revision),push=true \
                --export-cache type=inline \
                --import-cache type=registry,ref=$(params.image):cache
```

Tag obrazu to pełny SHA commita — niemutowalny, zgodnie ze specem (przygotowanie pod Flux image automation).

- [ ] **Step 2: Commit w repo aplikacji**

```bash
git add .tekton/pipeline.yaml
git commit -m "ci: add Tekton build pipeline"
git push
```

- [ ] **Step 3: Obserwuj wyzwolony run**

```bash
kubectl -n ci get pipelinerun -w
```

Expected: nowy `PipelineRun` `build-ibakery-*` powstaje w ciągu kilku sekund po pushu.

- [ ] **Step 4: Diagnostyka, jeśli run nie powstał**

```bash
kubectl -n ci logs -l eventlistener=github --tail=50
```

Typowe przyczyny i reakcje:
- `invalid X-Hub-Signature` → HMAC w SealedSecret różni się od tego w GitHubie; przegeneruj sekret (Task 10).
- Brak logów o zdarzeniu → request nie dotarł; sprawdź Recent Deliveries w GitHubie i `curl` ze Stepu 4 Taska 12.
- `expression returned false` → filtr CEL odrzucił; sprawdź, czy push był do `main` i czy `full_name` repo pasuje do allowlisty.

- [ ] **Step 5: Zweryfikuj wynik builda**

```bash
kubectl -n ci get pipelinerun --sort-by=.metadata.creationTimestamp | tail -1
tkn -n ci pipelinerun logs --last -f
crane ls ghcr.io/jabbas/ibakery
```

Expected: `PipelineRun` w stanie `Succeeded`; w GHCR widoczny tag równy SHA commita.

- [ ] **Step 6: Zweryfikuj Dashboard i pruner**

Otwórz `https://tekton.dev.home` — run musi być widoczny w UI.

```bash
kubectl -n ci get pipelinerun
```

Expected: po godzinie (`ttlSecondsAfterFinished: 3600`) zakończone runy znikają, a historia nie przekracza 5 udanych / 3 nieudanych.

---

## Weryfikacja końcowa

- [ ] `flux get kustomizations -A` — `tekton-release`, `tekton-config`, `tekton-ci` wszystkie Ready
- [ ] `https://tekton.dev.home` wymaga logowania Authentikiem i wpuszcza tylko `tekton-admins`
- [ ] `https://vmui.dev.home` **nadal** wymaga logowania (regresja po refaktorze outpostu)
- [ ] Push do `main` w `jabbas/ibakery` produkuje obraz `ghcr.io/jabbas/ibakery:<sha>`
- [ ] `uvx flux-local test --enable-helm --path flux/cluster --sources flux-system` przechodzi
- [ ] Renovate widzi chart: sprawdź Dependency Dashboard po najbliższym przebiegu — `tekton-operator` ma być na liście

## Poza zakresem tego planu

Zgodnie ze specem: Flux image automation domykający pętlę CI→CD, Tekton Chains, Tekton Results, middleware z IP-allowlist na zakresy GitHuba.
