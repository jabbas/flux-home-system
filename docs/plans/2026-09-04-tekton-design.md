# Tekton CI — design

Data: 2026-09-04

## Cel

Uruchomić Tekton w klastrze do dwóch zastosowań:

1. **Budowanie obrazów kontenerów** własnych aplikacji i push do GHCR.
2. **CI dla repozytoriów GitHub** — testy i lint uruchamiane w klastrze, wyzwalane webhookiem.

Zadania operacyjne (backupy, migracje) są możliwe na tej samej platformie, ale nie są przedmiotem tego designu.

## Decyzje

### 1. Instalacja: oficjalny chart OCI Tekton Operatora

Tekton nie ma oficjalnego charta dla poszczególnych komponentów, ale **od `v0.80.0` projekt publikuje chart Operatora jako artefakt OCI**:

```
oci://ghcr.io/tektoncd/operator/charts/tekton-operator
```

Chart wychodzi z tego samego commita co release operatora (tag `tekton-operator-X.Y.Z` obok `vX.Y.Z`), więc nie ma opóźnienia względem upstreamu. Zweryfikowano: wersja `0.81.1` ciągnie się anonimowo, `appVersion: v0.81.1`, brak zależności.

Dzięki temu Tekton wchodzi jako **zwykły `HelmRelease` z przypiętą wersją**, spójnie z pozostałymi 17 komponentami repo, i Renovate obsługuje bumpy natywnie (datasource OCI helm) — bez custom managerów i bez vendoringu.

**Odrzucone alternatywy:**

| Opcja | Powód odrzucenia |
|---|---|
| OperatorHub.io + OLM | Jedyny kanał `alpha`, wersja 0.79.0 (marzec) vs upstream 0.81.1; OLM pomija releasy, a wersja jest sterowana katalogiem, nie gitem — Renovate nie ma czego podbijać. Wymagałby też instalacji samego OLM z surowego `release.yaml`. |
| Remote base na `release.yaml` | Flux odradza remote bases; `flux-local test` w CI traci hermetyczność; pierwszy wyłom w konwencji repo. |
| Vendoring `release.yaml` | ~675 KB YAML w repo, dwustopniowy upgrade (Renovate + skrypt przegrywający plik). |
| Charty społecznościowe | Brak żywego charta instalującego Operator — kandydaci (`kubebb`, `cloudnativetoolkit`) umarli w 2023. `cdfoundation/tekton-helm-chart` żyje, ale pakuje wyłącznie Pipelines, bez Triggers/Dashboard. |

### 2. Zakres komponentów

`TektonConfig` z `profile: all` → **Pipelines + Triggers + Dashboard**. Bez Chains i Results — YAGNI, do rozważenia później.

### 3. Webhook publiczny, Dashboard wewnętrzny

- **EventListener**: `tekton.jabbas.eu`, `ingressClassName: traefik-external`.
- **Dashboard**: `tekton.dev.home`, `ingressClassName: traefik-internal`, za forwardAuth do Authentika.

Dashboard nie ma własnego uwierzytelniania — publiczne wystawienie oznaczałoby otwarty panel sterowania klastrem.

### 4. Definicje pipeline'ów w repozytoriach aplikacji

`Pipeline`/`Task` żyją w `.tekton/` repo budowanej aplikacji i są pobierane w runtime przez **git resolver** Tektona, w wersji z budowanego commita. `flux-home-system` dostarcza platformę, `flux-homeapps` instaluje aplikacje — a jak się aplikację buduje, wie jej własne repo.

Konsekwencja: dodanie nowego projektu do CI nie wymaga PR-a w repozytoriach GitOps (poza jednorazowym SA + sekretem, patrz §Bezpieczeństwo).

## Architektura

```
GitHub ──webhook──► Cloudflare (*.jabbas.eu, proxied, TLS)
                         │
                    cloudflared (LXC 1000, catch-all → 10.1.200.0:80)
                         │
                    traefik-external ──► EventListener (ns: ci)
                                              │ HMAC + CEL interceptor
                                              ▼
                                         PipelineRun (ns: ci)
                                              │ git resolver → .tekton/pipeline.yaml @ commit
                                              ▼
                                         BuildKit ──► ghcr.io/jabbas/<app>:<sha>

Dashboard: tekton.dev.home ──► traefik-internal ──► forwardAuth (Authentik) ──► tekton-dashboard
```

### Namespace'y

| Namespace | Zawartość |
|---|---|
| `tekton-operator` | operator + webhook (chart **nie tworzy** namespace'u — dostarczamy własny) |
| `tekton-pipelines` | komponenty tworzone przez operator (`targetNamespace`) |
| `ci` | EventListener, `PipelineRun`y, BuildKit, ServiceAccounty, sekrety |

## Struktura plików

```
flux/infrastructure/sources/tekton.yaml       # HelmRepository type: oci → ghcr.io/tektoncd/operator/charts
flux/infrastructure/tekton/
├── kustomization.yaml
├── namespace.yaml                            # tekton-operator, ci
├── release.yaml                              # HelmRelease, version: "0.81.1"
├── middleware.yaml                           # forwardAuth → Authentik
├── ingress.yaml                              # tekton.dev.home → tekton-dashboard
├── eventlistener.yaml                        # + TriggerBinding, TriggerTemplate
├── ingress-webhook.yaml                      # tekton.jabbas.eu → el-github, traefik-external
├── buildkit.yaml                             # Deployment + Service + PVC (cache)
├── rbac.yaml                                 # ServiceAccounty per repo
└── secrets.yaml                              # SealedSecret: HMAC webhooka, dockerconfigjson do GHCR

flux/infrastructure/authentik-blueprints/chart/templates/
├── blueprint-tekton.yaml                     # nowy: proxy provider + application + policy binding
├── blueprint-outpost.yaml                    # nowy: wspólny wpis outpostu (patrz Refaktor)
└── blueprint-victoria-metrics.yaml           # zmiana: usunięcie wpisu outpostu
```

Trzy touchpointy z `AGENTS.md`: katalog komponentu + wpis w `sources/kustomization.yaml` + blok w `flux/cluster/infrastructure.yaml`:

```yaml
name: tekton
dependsOn: [sources, traefik, authentik, sealed-secrets, democratic-csi]
timeout: 10m0s
healthChecks:
  - Deployment/tekton-operator w ns tekton-operator
```

`democratic-csi` w zależnościach, bo workspace'y i cache BuildKita wymagają PVC na `zfs-nfs-csi`.

## Konfiguracja HelmRelease

Dwie wartości ustawiane wbrew domyślnym, obie świadomie:

**`installCRDs: true`** (domyślnie `false`). Chart ostrzega, że przy odinstalowaniu kasuje kaskadowo wszystkie zasoby Tektona. W GitOpsie znaczy to, że usunięcie bloku z `infrastructure.yaml` wyczyści też `PipelineRun`y — uznajemy to za pożądane zachowanie przy deinstalacji. Ostrzeżenie trafia do komentarza w `release.yaml`. Alternatywa (CRD z osobnego `release.yaml`) wracałaby do remote base.

**`operator.autoInstallComponents: false` + `TektonConfig` w `extraObjects`.** Domyślnie operator sam tworzy `TektonConfig/config`, przez co profil i polityka prunera powstają poza gitem. Jawny CR trzyma je pod GitOpsem:

```yaml
extraObjects:
  - apiVersion: operator.tekton.dev/v1alpha1
    kind: TektonConfig
    metadata:
      name: config
    spec:
      profile: all
      targetNamespace: tekton-pipelines
      pipeline:
        enable-git-resolver: true
      pruner:
        disabled: true
      tektonpruner:
        disabled: false
        global-config:
          enforcedConfigLevel: global
          ttlSecondsAfterFinished: 3600
          successfulHistoryLimit: 5
          failedHistoryLimit: 3
```

Pruner jest obowiązkowy, nie opcjonalny — bez niego `PipelineRun`y narastają w etcd bez ograniczenia.

## Sieć i TLS

Cloudflare ma wildcard `*.jabbas.eu CNAME <uuid>.cfargotunnel.com` (proxied), a `container-cloudflared` (`roles/cloudflared/templates/config.yml.j2`) ma regułę catch-all:

```yaml
- hostname: "*.jabbas.eu"
  service: http://10.1.200.0:80    # traefik-external
```

Dlatego **`tekton.jabbas.eu` nie wymaga zmian w DNS ani w konfiguracji tunelu**. Potwierdzone empirycznie: nieistniejące hosty `*.jabbas.eu` zwracają 404 Traefika, nie błąd 1033 Cloudflare.

TLS terminuje Cloudflare; do klastra wchodzi HTTP. Ingress webhooka ma **puste `spec.tls`**, zgodnie ze wzorcem `demos/httpbin` i `ibakery`. W klastrze nie ma cert-managera i nie jest potrzebny.

**Uwaga operacyjna:** `traefik-external` jest publiczny z automatu — każdy Ingress w tej klasie trafia natychmiast do internetu. Jedynym publicznym zasobem tego designu jest EventListener.

## Bezpieczeństwo

Opcja „pipeline w repo aplikacji" oznacza, że kod z repo definiuje, co wykona się w klastrze. Wymaga to trzech zabezpieczeń:

1. **Weryfikacja HMAC** — `GitHubInterceptor` z `secretRef` na SealedSecret. Odrzuca payloady bez poprawnej sygnatury GitHuba. Authentik/forwardAuth jest tu nieprzydatny: webhook nie przejdzie interaktywnego redirectu SSO.

2. **Odrzucanie forków** — interceptor CEL:
   ```
   body.pull_request.head.repo.full_name == body.repository.full_name
   ```
   plus **allowlista repozytoriów** w EventListenerze. Bez tego dowolny PR z forka może podmienić `.tekton/pipeline.yaml` i wynieść sekrety.

3. **ServiceAccount per repozytorium** — każde repo dostaje własny SA w `ci` z własnym sekretem `dockerconfigjson` (PAT ze scope `write:packages`). Skompromitowane repo wynosi wyłącznie swój token, nie dostęp do wszystkich obrazów.

Koszt utrzymania: dodanie repo do CI = jeden SA + jeden SealedSecret + wpis w allowliście, w tym repo. Sam pipeline pozostaje po stronie aplikacji.

## Refaktor: wpis outpostu w blueprintach Authentika

`blueprint-victoria-metrics.yaml` kończy się wpisem ustawiającym listę providerów embedded outpostu:

```yaml
- model: authentik_outposts.outpost
  identifiers: {name: "authentik Embedded Outpost"}
  attrs:
    providers:
      - !Find [... "Victoria Metrics Proxy"]
```

Ten wpis **nadpisuje listę, nie dopisuje do niej**. Analogiczny blok w blueprincie Tektona spowodowałby, że ostatni zastosowany blueprint wygra, a drugi serwis straci uwierzytelnianie.

Rozwiązanie: wydzielić wpis outpostu do `blueprint-outpost.yaml`, który listuje **wszystkie** proxy providery naraz (Victoria Metrics + Tekton), i usunąć go z `blueprint-victoria-metrics.yaml`.

Przy implementacji zweryfikować na żywym Authentiku, jakie providery ma obecnie embedded outpost. Podejrzenie: `firecrawl` (z `flux-homeapps`) ma middleware forwardAuth, ale w repo nie ma dla niego proxy providera — jego uwierzytelnianie może już teraz nie działać poprawnie.

## Dostęp do Dashboardu

Nowa grupa **`tekton-admins`** w `authentik-blueprints/chart/values.yaml` (obok `kubernetes-admins`, `monitoring-admins`), związana policy bindingiem z aplikacją Tekton.

## Builder: BuildKit

Kaniko jest **zarchiwizowane** i nie dostaje poprawek — odpada. Używamy BuildKita w trybie rootless: Deployment + Service w `ci`, `Task` wywołujący `buildctl`, cache warstw na PVC (`zfs-nfs-csi`) współdzielony między runami.

**Ryzyko do zweryfikowania jako pierwszy krok implementacji:** Talos egzekwuje Pod Security Admission na poziomie `baseline`, a rootless BuildKit zwykle wymaga `seccompProfile: Unconfined`, czego baseline zabrania. Prawdopodobnie namespace `ci` będzie potrzebował etykiety `pod-security.kubernetes.io/enforce: privileged`. Nie zakładamy tego z góry — najpierw test, czy BuildKit wstaje bez podnoszenia uprawnień. Fallback: Buildah w trybie `vfs`.

Tagowanie: `ghcr.io/jabbas/<app>:<git-sha>` — niemutowalne tagi po SHA, nigdy `latest`.

## Poza zakresem (future work)

- **Domknięcie pętli CI→CD.** Tagowanie po SHA jest dobrane tak, by dało się później dołożyć Flux image automation (`ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation`) bez zmiany pipeline'ów — potrzebne będą tylko nowe zasoby Fluxa i deploy key do `flux-homeapps`.
- **Tekton Chains** (podpisywanie i provenance obrazów) i **Results** (trwała historia runów w CNPG).
- Middleware z IP-allowlist na zakresy egress GitHuba jako dodatkowa warstwa przed EventListenerem.

## Weryfikacja

Przed wdrożeniem:

```bash
uvx flux-local test --enable-helm --path flux/cluster --sources flux-system
```

Po wdrożeniu:

```bash
flux get kustomizations -A
kubectl get tektonconfig config -o yaml           # profil all, resolver włączony
kubectl -n tekton-pipelines get deploy            # pipelines, triggers, dashboard
curl -I https://tekton.jabbas.eu                  # EventListener odpowiada przez tunel
```

## Stan klastra przed wdrożeniem

Zweryfikowano: brak namespace'ów i CRD Tektona — start od zera. Serwer Kubernetes `v1.35.2`, powyżej wymaganego przez chart `kubernetesMinVersion: v1.34.0`.
