# Kontrakt pipeline'u Tektona — co repo aplikacji musi dostarczyć

Data: 2026-09-09
Odbiorca: sesja pracy w repozytorium budowanej aplikacji (pierwszy przypadek: `jabbas/homebudget`)

## Po co ten dokument

Platforma CI jest gotowa i zweryfikowana end-to-end. Brakuje jednego pliku — `.tekton/pipeline.yaml` w repozytorium aplikacji. Ten dokument opisuje, co pipeline dostaje od platformy i czego platforma po nim oczekuje, żeby nie trzeba było tego odkrywać metodą prób.

Podział odpowiedzialności jest celowy: `flux-home-system` dostarcza platformę, `flux-homeapps` instaluje aplikacje, a **jak zbudować aplikację wie jej własne repo**. Dodanie kolejnego projektu do CI nie wymaga PR-a w repozytoriach GitOps.

## Ścieżka, w którą wpina się pipeline

```
push do main
  → webhook GitHuba → tekton.jabbas.eu (Cloudflare → tunel → Traefik)
  → EventListener: weryfikacja HMAC, filtr CEL (allowlista repo + refs/heads/main)
  → TriggerTemplate tworzy PipelineRun
  → git resolver pobiera .tekton/pipeline.yaml Z TEGO SAMEGO COMMITA   ← twój plik
  → pipeline buduje i pushuje do registry.home
```

Pipeline jest pobierany w wersji z budowanego commita, więc zmiana pipeline'u i zmiana kodu mogą iść w jednym PR.

## Kontrakt

### Co dostajesz w parametrach

| Parametr | Wartość | Uwagi |
|---|---|---|
| `repo-url` | `https://github.com/jabbas/homebudget.git` | z `body.repository.clone_url` |
| `revision` | pełny SHA commita | z `body.after` |
| `image-prefix` | `registry.home/homebudget` | prefiks, **nie** pełna nazwa obrazu |

`image-prefix` jest prefiksem świadomie: platforma nie wie, ile obrazów produkuje repo. Nazewnictwo konkretnych obrazów należy do pipeline'u.

### Co dostajesz w środowisku

| Zasób | Wartość |
|---|---|
| Workspace | `source` — PVC 5Gi, `storageClassName: zfs-nfs-csi` |
| ServiceAccount | `build-homebudget` (namespace `ci`) |
| Demon BuildKita | `tcp://buildkitd.ci.svc.cluster.local:1234` |
| Sekret do pushu | `registry-home-push` (typ `dockerconfigjson`, namespace `ci`) |
| Sekret do klonowania | `github-pat-readonly` (klucz `token`, namespace `ci`) |
| Rejestr | `registry.home` — TLS z prywatnego `jabbas-ca`, zaufany przez BuildKita i przez węzły |

**Klonowanie prywatnego repo wymaga poświadczeń — i nie dostaniesz ich automatycznie.** Parametr `gitToken` uwierzytelnia wyłącznie **resolver** pobierający ten plik; własny krok klonujący pipeline'u to osobne połączenie. `ServiceAccount build-<repo>` ma podpięty tylko sekret do rejestru, bez sekretu z adnotacją `tekton.dev/git-*`, więc creds-init nie wstrzyknie niczego dla gita.

Krok klonujący musi więc sam sięgnąć po `github-pat-readonly`. **Podawaj token przez `GIT_ASKPASS`, nie przez URL** — token w adresie zdalnym zostaje w `.git/config` na współdzielonym PVC i wypływa w `git remote -v` oraz w logach.

Pipeline musi zadeklarować `params` o powyższych nazwach i workspace `source` — inaczej `TriggerTemplate` nie dopasuje.

### Czego się od pipeline'u oczekuje

- Tagowanie **pełnym SHA commita**, nigdy `latest`. Tagi niemutowalne są warunkiem sensownego rollbacku i przyszłej automatyki Fluxa.
- Push wyłącznie do `registry.home`. Konto CI **nie ma prawa kasowania** — pipeline nie posprząta po sobie i nie powinien próbować.

## Poświadczenia do pushu — używaj sprawdzonej metody

`ServiceAccount build-homebudget` ma podpięty sekret przez `secrets:` i `imagePullSecrets:`. Mimo to **podawaj poświadczenia jawnie przez projected volume** — ta ścieżka została przetestowana i działa:

```yaml
        steps:
          - name: build
            image: moby/buildkit:v0.33.0
            env:
              - name: BUILDKIT_HOST
                value: tcp://buildkitd.ci.svc.cluster.local:1234
              - name: DOCKER_CONFIG
                value: /tekton/home/.docker
            script: |
              #!/bin/sh
              set -eu
              ...
        volumes:
          - name: docker-config
            projected:
              sources:
                - secret:
                    name: registry-home-push
                    items:
                      - key: .dockerconfigjson
                        path: config.json      # buildctl oczekuje katalogu z config.json
```

Automatyczne wstrzykiwanie poświadczeń przez `creds-init` Tektona (samo podpięcie sekretu do SA) **nie zostało zweryfikowane** w tej konfiguracji. Może działać — ale jeśli sięgniesz po nie i push zwróci 401, to jest pierwszy podejrzany.

Podział, o którym łatwo zapomnieć: **poświadczenia płyną z klienta (`buildctl`), ale połączenie TLS nawiązuje demon.** CA rejestru jest już skonfigurowane po stronie `buildkitd`; twoją stroną są wyłącznie poświadczenia.

## Specyfika homebudgetu

Trzy fakty ustalone przy analizie repo:

1. Pliki budowania nazywają się **`Containerfile`**, nie `Dockerfile` → `buildctl` wymaga `--opt filename=Containerfile`.
2. Repo produkuje **dwa obrazy**:
   - `${image-prefix}-api` — kontekst `.` (ten sam obraz obsługuje też workera, inna komenda startowa)
   - `${image-prefix}-web` — kontekst `frontend/`
3. `docker/storage-init.Containerfile` to narzędzie stosu deweloperskiego z `docker-compose.yml` — **nie idzie do rejestru**.

Oba obrazy można budować równolegle (`runAfter` na tym samym tasku klonującym).

## Pułapki, każda kosztowała czas

**Workspace `emptyDir` nie przechodzi między taskami.** Każdy TaskRun to osobny pod, więc każdy dostaje własny `emptyDir` i kontekst budowania wychodzi pusty. Objaw jest mylący: `transferring dockerfile: 2B`, potem `failed to read dockerfile`. Albo jeden task z wieloma krokami i wolumenem na poziomie taska, albo PVC (`TriggerTemplate` daje PVC, więc w produkcji problem nie występuje — pojawia się przy ręcznych testach).

**Obraz `moby/buildkit` ma ENTRYPOINT `buildkitd`.** Krok Tektona musi używać `script:` (nadpisuje entrypoint) albo jawnego `command:`. Inaczej zamiast klienta uruchomisz drugi demon — który odpowie sam sobie i da fałszywie pozytywny wynik.

**`--output type=cacheonly` nie istnieje w v0.33.0.** Do budowania bez pushu po prostu pomiń `--output`.

**Cache warstw BuildKita nie może leżeć na NFS.** Rozpakowywanie warstw robi `lchown`, a NFS z `sec=sys` odrzuca to jako EPERM. Dotyczy wyłącznie wewnętrznego cache'u demona (już rozwiązane po stronie platformy — `emptyDir` na dysku węzła). Workspace ze źródłami na NFS jest w porządku.

**Namespace `ci` ma PSA `enforce: privileged`.** Nie licz na to gdzie indziej; jeśli pipeline miałby kiedyś działać w innym namespace, rootless BuildKit zostanie odrzucony przez `baseline` z powodu `seccompProfile: Unconfined`.

**BuildKit nie widzi `.containerignore`.** Czyta wyłącznie `.dockerignore` albo `<nazwa-pliku>.dockerignore`. Repozytoria budowane lokalnie Podmanem zwykle mają `.containerignore` — wtedy kontekst budowania w CI jest **szerszy niż lokalnie**, cicho, bez błędu. Objawia się dopiero tym, że build wciąga pliki testowe albo `node_modules`. Albo przepisz plik w kroku klonującym, albo trzymaj w repo prawdziwy `.dockerignore`.

**Obrazy bazowe idą prosto z Docker Huba.** `buildkitd` ma skonfigurowane CA tylko dla `registry.home`, nie ma mirrora dla `docker.io` — więc buildy podlegają anonimowym limitom Docker Huba. Nie ugryzło jeszcze, ale to latentna przyczyna losowych awarii; `mirror.gcr.io` jest tańszym obejściem niż debugowanie tego pod presją.

## Jak przetestować bez czekania na webhooka

Nie trzeba pushować, żeby sprawdzić pipeline. Wystarczy ręczny `PipelineRun` wskazujący git resolverem na gałąź roboczą:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: manual-homebudget-
  namespace: ci
spec:
  taskRunTemplate:
    serviceAccountName: build-homebudget
  pipelineRef:
    resolver: git
    params:
      - name: url
        value: https://github.com/jabbas/homebudget.git
      - name: revision
        value: <gałąź lub SHA>
      - name: pathInRepo
        value: .tekton/pipeline.yaml
      - name: gitToken
        value: github-pat-readonly
  params:
    - name: repo-url
      value: https://github.com/jabbas/homebudget.git
    - name: revision
      value: <ten sam SHA>
    - name: image-prefix
      value: registry.home/homebudget
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          storageClassName: zfs-nfs-csi
          resources:
            requests:
              storage: 5Gi
```

`gitToken` przyjmuje **nazwę sekretu**, nie token. Repo jest prywatne, więc ten parametr jest obowiązkowy także przy ręcznych testach.

**Diagnostyka git resolvera — jeden komunikat, trzy przyczyny.** Resolver po cichu ignoruje nieznane parametry, więc `clone error: authentication required` oznacza jedno z: literówka w nazwie parametru, brak konfiguracji auth, albo zły token. Komunikat jest identyczny we wszystkich trzech przypadkach. Sygnał, że auth działa, to błąd o **brakującym pliku**, nie o autoryzacji.

## Weryfikacja gotowego pipeline'u

```bash
kubectl -n ci get pipelinerun
tkn -n ci pipelinerun logs --last -f

curl -s --cacert <jabbas-ca.crt> https://registry.home/v2/_catalog
curl -s --cacert <jabbas-ca.crt> https://registry.home/v2/homebudget-api/tags/list
```

Sukcesem jest tag równy SHA commita w obu repozytoriach obrazów. Sam `Succeeded` na `PipelineRun` nie wystarcza — obraz musi być widoczny w rejestrze.

Po pierwszym udanym buildzie zostaje jeszcze test pełnej ścieżki: prawdziwy push do `main`, który zweryfikuje trzy odcinki nietestowane do tej pory — `revision` z payloadu webhooka, `ServiceAccount build-homebudget` i workspace na PVC.

## Sprzątanie PipelineRunów — uwaga na mylącą konfigurację

Zakończone runy znikają po **godzinie** (`ttlSecondsAfterFinished: 3600`, historia 5 udanych / 3 nieudanych). Workspace PVC ma `ownerReference` na `PipelineRun`, więc jest kasowany razem z nim — PVC nie kumulują się po każdym buildzie.

**Pułapka diagnostyczna:** w `TektonConfig` pole `spec.pruner` jest `disabled: true`, ale sprzątaniem zajmuje się **osobny komponent `tektonpruner`**, który jest włączony. Ktoś, kto sprawdzi tylko `spec.pruner`, wyciągnie odwrotny wniosek. Prawdziwa konfiguracja jest w `spec.tektonpruner.global-config`.

## Retencja obrazów — co przetrwa, a co zniknie

Polityka jest po stronie rejestru, nie pipeline'u:

- tagi wyglądające na semver (`v1.2.3`) — **trzymane bez limitu**
- pozostałe, czyli tagi per-commit SHA — **10 ostatnio wypchniętych na repozytorium**
- manifesty nieotagowane — kasowane

Konsekwencja praktyczna: **push bez tagu (po samym digeście) zniknie po godzinie.** GC chodzi raz dziennie około 10:10, więc skutki widać z opóźnieniem, nie od razu po buildzie.

## Dodanie kolejnego repozytorium do CI

Dla porządku, gdy przyjdzie następna aplikacja — po stronie `flux-home-system`:

1. wpis w allowliście CEL w `flux/infrastructure/tekton/ci/eventlistener.yaml`
2. `ServiceAccount build-<repo>` w `rbac.yaml`
3. webhook na GitHubie z tym samym sekretem HMAC

**Nowy token nie jest potrzebny** — `github-pat-readonly` jest read-only na wszystkie repozytoria.
