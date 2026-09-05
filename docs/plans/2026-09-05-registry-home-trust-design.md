# Zaufanie do `registry.home` w klastrze — design

Data: 2026-09-05
Status: zatwierdzony, gotowy do planu wdrożenia

## Cel

Sprawić, żeby nody Talosa ufały prywatnemu rejestrowi OCI `registry.home` przy
pobieraniu obrazów przez containerd.

Zakres obejmuje **wyłącznie ścieżkę zaufania TLS dla pulla**. Nie wdraża żadnego
obrazu, nie dotyka BuildKita ani Tektona i nie rozstrzyga, gdzie docelowo mają
lądować artefakty CI.

## Dlaczego teraz, skoro nic jeszcze nie ciągnie z `registry.home`

Bo potrzeba jest znana i zadeklarowana, a nie hipotetyczna: obrazy będą budowane
Tektonem. Odroczenie ma konkretny koszt — kiedy pierwszy pipeline zawiedzie,
diagnozowałoby się jednocześnie pipeline, BuildKita i zaufanie TLS. Rozdzielenie
„ścieżka zaufania działa" od „pierwszy obraz się buduje" to izolacja błędów, nie
nadmiarowa robota.

Certyfikat CA jest statyczny i ważny do 2033-11-25, więc nie ma ryzyka, że
konfiguracja zdezaktualizuje się przed użyciem.

## Kontekst

`registry.home` (10.1.250.253) to zot w LXC 1002 na `pve.home`, wdrożony
2026-09-05 z repozytorium `container-registry`. HTTPS na :443, certyfikat podpisany
przez prywatne `jabbas-ca`. **Odczyt anonimowy, zapis i kasowanie po
uwierzytelnieniu** jako `jabbas`.

W tym repo nie ma dziś ani jednego odwołania do `registry.home`. Nie ma też żadnej
innej konfiguracji rejestrów: `bootstrap/patch/ghcr-registry-secret.yaml` (wyłącznie
`auth` dla `ghcr.io`, bez mirrorów i bez TLS) został usunięty 2026-09-05 — wszystkie
obrazy ciągnięte z `ghcr.io` są publiczne, więc uwierzytelnienie niczego nie
odblokowywało. Patch dla `registry.home` będzie pierwszym wpisem w `machine.registries`.

`jabbas-ca` jest już obecne w dwóch miejscach, ale **żadne z nich nie rozwiązuje
tego problemu**:

- `bootstrap/patch/oidc.yaml` kładzie CA w `/var/certs/jabbas-ca.crt` na nodach,
  ale wyłącznie jako wolumen dla apiservera (OIDC). Nie trafia ani do systemowego
  trust store'u, ani do containerd.
- `flux/infrastructure/shared-secrets/jabbas-ca.yaml` trzyma CA jako Secret
  z propagacją przez reflector — dziś tylko do namespace'u `grafana`.

## Kluczowe rozróżnienie: zaufanie ≠ uwierzytelnienie

To jest sedno całego dokumentu, bo obie rzeczy mylą się nagminnie.

**Anonimowy odczyt** oznacza brak potrzeby poświadczeń. Nie oznacza braku TLS.
Containerd ma standardowy zestaw publicznych CA i przy pierwszym pullu przerwie
handshake, zanim w ogóle dojdzie do pytania o uwierzytelnienie.

Zmierzone empirycznie na kliencie OCI, ten sam rejestr, dwie próby:

| Stan | Komunikat |
|---|---|
| bez CA | `x509: certificate signed by unknown authority` |
| CA obecne, bez logowania | `authentication required` (HTTP 401) |

Dwa różne błędy, dwie różne przyczyny, dwie różne naprawy. Anonimowy odczyt
eliminuje wyłącznie drugi.

**Konsekwencja dla klastra:** potrzebny jest wyłącznie certyfikat CA. Żadnych
`imagePullSecrets`, żadnych sekretów do rotowania i propagowania przez namespace'y.
To realny zysk z modelu dostępu wybranego przy projektowaniu rejestru.

## Rozwiązanie

Trust store'y poszczególnych warstw są od siebie niezależne i żadna nie dziedziczy
po innej. Ten dokument zajmuje się wyłącznie pierwszą.

### containerd na nodach — pull do podów

Nowy `bootstrap/patch/registry-home.yaml`, dopisany do listy `-p @patch/...`
w `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml`:

```yaml
---
machine:
  registries:
    config:
      registry.home:
        tls:
          ca: <base64 PEM jabbas-ca.crt>
```

Bez sekcji `auth` — pull jest anonimowy.

Stosujemy **stary styl `v1alpha1 machine.registries`**, spójnie z resztą patchy
w `bootstrap/patch/`. Talos 1.13 wspiera nowy, wielodokumentowy `RegistryTLSConfig`,
ale mieszanie obu stylów w jednym `talosctl apply` jest ryzykowne. Migracja całości
to osobna decyzja, poza zakresem.

Uwaga praktyczna z usuwania `ghcr-registry-secret.yaml` (2026-09-05): machineconfig
na nodach jest już wielodokumentowy, przez co `talosctl patch machineconfig`
**odrzuca patche JSON6902** (`JSON6902 patches are not supported for multi-document
machine configuration`). Do punktowych zmian w `machine.registries` trzeba użyć
strategic merge patcha, a do skasowania klucza — `$patch: delete`.

Patch trafia jednocześnie do repo (reprodukowalność przy bootstrapie) i na żywy
klaster przez `talosctl patch machineconfig` — inaczej zadziałałby dopiero po
przebudowie. Repo ma na to precedens w `docs/plans/2026-07-05-talos-1.13.5-upgrade-implementation.md`.

Zgodnie z dokumentacją Talosa konfiguracja TLS obejmuje wszystkie pobrania obrazów
z tego endpointu — zarówno przez Talos, jak i przez workloady Kubernetesa.

### Czego NIE robimy

`imagePullSecrets` — niepotrzebne przy anonimowym odczycie. Konfiguracja containerd
wystarcza.

`certSecretRef` dla Flux source-controllera — potrzebne dopiero, gdyby z
`registry.home` szły charty OCI albo `ImageRepository` dla image automation.
Dziś nie idą; kontrolery image automation nie są nawet zainstalowane.

Konfiguracja BuildKita i propagacja CA do namespace'u `ci` — obsługiwane osobno,
patrz „Poza zakresem".

## Weryfikacja

Sensem tego projektu jest nieodkrywanie problemów przy pierwszym prawdziwym obrazie.
Weryfikacja nie może więc czekać na pierwszy prawdziwy obraz — potrzebny jest obraz
testowy, wypchnięty i pobrany, a następnie usunięty.

Obraz testowy wypychany do `registry.home` z maszyny roboczej (podman, CA już
skonfigurowane), następnie Job w klastrze pobierający go i kończący się sukcesem.
Dowodem jest `Successfully pulled image` w zdarzeniach poda oraz `Completed`
na Jobie.

**Test negatywny wykonujemy jako pierwszy.** Ten sam Job przed zmianą musi zawieść
na `x509: certificate signed by unknown authority`. Bez negatywnego punktu
odniesienia test pozytywny nie dowodzi, że cokolwiek naprawiliśmy — mógłby
przechodzić z zupełnie innego powodu.

**Sprzątanie:** obraz testowy usuwany z rejestru, Job z klastra. Miejsce zwolni się
po przejściu GC zota (`gcDelay: 1h`), co jest oczekiwane i nie jest usterką.

## Ryzyka

**Weryfikacja negatywna wymaga ostrożności.** Job musi zawieść na `x509` przed
zmianą — jeśli zawiedzie z innego powodu (zły tag, brak obrazu w rejestrze), test
pozytywny po zmianie niczego nie dowiedzie.

**`talosctl patch machineconfig` na trzech nodach control-plane.** Zmiana sekcji
`machine.registries` nie wymaga reboota, ale dotyka wszystkich węzłów klastra.
Stosować sekwencyjnie, z weryfikacją po każdym.

**Rozjazd repo z żywym klastrem.** Patch aplikowany na żywo i commitowany do repo
muszą być identyczne. Rozjazd ujawni się dopiero przy następnym bootstrapie —
czyli w najgorszym możliwym momencie.

**`.github/workflows/validate.yaml` nie obejmuje `bootstrap/`.** Zmiany w patchach
Talosa nie są weryfikowane przez CI. Walidacja lokalna (`ansible-lint`, `yamllint`)
jest jedyną bramką.

## Poza zakresem

### BuildKit i Tekton — obsługiwane osobno

Warstwa push nie należy do tego dokumentu, ale dwa ustalenia z analizy warto
zachować, żeby nie trzeba było ich odkrywać ponownie:

**CA wskazuje się jawnie w `buildkitd.toml`, nie przez podmianę systemowego
bundla.** Zamontowanie pliku na `/etc/ssl/certs/ca-certificates.crt` w podzie
`buildkitd` przykryłoby bundle i zerwało zaufanie do `ghcr.io`, `docker.io`
i reszty — awaria trudna do powiązania z przyczyną.

**Poświadczenia i zaufanie mieszkają po przeciwnych stronach.** W BuildKicie
poświadczenia płyną z *klienta* (`buildctl`, przez `DOCKER_CONFIG` w sesji), ale
połączenie TLS nawiązuje *demon*. CA musi więc trafić do `buildkitd`, a sekret
z hasłem do kroku Tektona. Konfiguracja jednej strony bez drugiej nie zadziała.

Dostarczenie CA do namespace'u `ci` wymagałoby dopisania go do
`reflection-allowed-namespaces` w `flux/infrastructure/shared-secrets/jabbas-ca.yaml`
(dziś tylko `grafana`); wzorzec konsumpcji jest sprawdzony w
`flux/infrastructure/grafana/release.yaml`.

### Pozostałe

- Rozstrzygnięcie, czy obrazy z CI mają lądować w `registry.home`, czy w `ghcr.io`
- Pipeline Tektona, EventListener, triggery, sekret z poświadczeniami push
- Mirror / pull-through cache dla `docker.io` — mimo że istniejąca blocklista
  OPNsense na `*.cloudfront.docker.com` (obchodzona regułą w
  `bootstrap/patch/nameservers.yaml`) jest realnym argumentem za rozważeniem tego
  osobno
- Migracja `machine.registries` na wielodokumentowy styl Talos 1.13
- Flux image automation
