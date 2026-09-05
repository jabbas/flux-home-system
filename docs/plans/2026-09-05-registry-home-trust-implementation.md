# Zaufanie do `registry.home` na nodach Talosa — plan wdrożenia

> **Dla agentów:** WYMAGANY SUB-SKILL: użyj `superpowers:subagent-driven-development`
> albo `superpowers:executing-plans`. Kroki mają składnię checkboxów (`- [ ]`).

**Cel:** Nody Talosa mają ufać certyfikatowi `registry.home` podpisanemu przez
prywatne `jabbas-ca`, żeby containerd mógł anonimowo pobierać stamtąd obrazy.

**Architektura:** Jeden patch machine config dodający `machine.registries.config`
dla `registry.home` z certyfikatem CA. Aplikowany na żywe nody strategic merge
patchem i jednocześnie commitowany do listy patchy bootstrapu, żeby przetrwał
przebudowę klastra.

**Stack:** Talos 1.13.5, `talosctl`, Ansible (bootstrap), Kubernetes Job (weryfikacja).

**Design:** `docs/plans/2026-09-05-registry-home-trust-design.md`

---

## Uwagi o charakterze weryfikacji

To jest zmiana w konfiguracji żywego klastra, nie kod aplikacyjny. Rolę testów pełnią:

- **Test negatywny wykonywany JAKO PIERWSZY** — Job musi zawieść na `x509`, zanim
  cokolwiek zmienimy. Bez tego test pozytywny niczego nie dowodzi, bo mógłby
  przechodzić z zupełnie innego powodu.
- Weryfikacja per node przez `talosctl image pull` — precyzyjna i niedestrukcyjna.
- Weryfikacja realnej ścieżki kubeleta przez Job.

## Ustalenia, które kształtują ten plan

**JSON6902 nie działa na tym klastrze.** Machineconfig na nodach jest
wielodokumentowy, więc `talosctl patch machineconfig --patch '[{"op":"add",...}]'`
odbija się od `JSON6902 patches are not supported for multi-document machine
configuration`. Ustalone empirycznie 2026-09-05 przy usuwaniu auth dla ghcr.io.
Używamy **strategic merge patcha**.

**Zawsze `-m no-reboot`.** Jeśli Talos uzna restart za konieczny, komenda ma paść,
a nie zrestartować node control-plane.

**Zawsze `--dry-run` przed pierwszym zapisem.** Diff pokazuje dokładnie, co się
zmieni.

## Struktura plików

| Plik | Odpowiedzialność |
|---|---|
| `bootstrap/patch/registry-home.yaml` | patch machine config z CA dla `registry.home` |
| `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml` | dopisanie patcha do listy `-p @patch/...` |
| `/tmp/registry-trust-test/` | efemeryczne: obraz testowy i manifest Joba, kasowane w Zadaniu 6 |

---

### Zadanie 1: Obraz testowy w rejestrze

Potrzebny jest obraz, którego **nie ma w cache containerd** na żadnym nodzie —
inaczej test negatywny przejdzie z cache'a i niczego nie sprawdzi.

**Files:** tylko `/tmp/registry-trust-test/` (efemeryczne)

- [ ] **Krok 1: Zbuduj i wypchnij obraz z unikalnym tagiem**

```bash
mkdir -p /tmp/registry-trust-test && cd /tmp/registry-trust-test
TAG="trust-$(date +%s)"
echo "$TAG" > tag.txt

cat > Containerfile <<'EOF'
FROM docker.io/library/alpine:3.20
RUN echo "registry.home trust probe" > /probe.txt
CMD ["cat", "/probe.txt"]
EOF

podman build -t registry.home/smoke/trust:${TAG} .
podman login registry.home -u jabbas
podman push registry.home/smoke/trust:${TAG}
```

Unikalny tag ze znacznikiem czasu jest istotny: gwarantuje, że żaden node nie ma
tego obrazu w cache.

Jeśli `podman pull` obrazu bazowego padnie na CDN Docker Huba, użyj
`mirror.gcr.io/library/alpine:3.20`.

- [ ] **Krok 2: Potwierdź, że obraz jest w rejestrze**

```bash
CA=~/Projects/container-registry/roles/prepare-os/files/jabbas-ca.crt
TAG=$(cat /tmp/registry-trust-test/tag.txt)
curl -s --cacert $CA https://registry.home/v2/smoke/trust/tags/list
```

Oczekiwane: JSON zawierający `$TAG`.

- [ ] **Krok 3: Potwierdź, że obrazu NIE MA na żadnym nodzie**

```bash
for ip in 10.1.250.11 10.1.250.12 10.1.250.13; do
  echo "=== $ip ==="
  talosctl -n $ip image list --namespace cri | grep -c 'registry.home' || true
done
```

Oczekiwane: `0` na każdym nodzie. Jeśli gdziekolwiek jest `registry.home`,
zatrzymaj się — cache zafałszuje test negatywny.

---

### Zadanie 2: Test negatywny — Job musi zawieść na `x509`

**To jest bramka.** Jeśli Job zawiedzie z innego powodu albo — co gorsza — przejdzie,
cała późniejsza weryfikacja jest bezwartościowa.

**Files:** `/tmp/registry-trust-test/job.yaml` (efemeryczne)

- [ ] **Krok 1: Utwórz manifest Joba**

```bash
cd /tmp/registry-trust-test
TAG=$(cat tag.txt)
cat > job.yaml <<EOF
---
apiVersion: batch/v1
kind: Job
metadata:
  name: registry-trust-probe
  namespace: default
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: registry.home/smoke/trust:${TAG}
          imagePullPolicy: Always
EOF
```

`backoffLimit: 0` — jedna próba, bez retry. `imagePullPolicy: Always` wymusza
pobranie zamiast użycia cache'a.

- [ ] **Krok 2: Uruchom Joba i poczekaj na niepowodzenie pulla**

```bash
kubectl apply -f /tmp/registry-trust-test/job.yaml
sleep 20
kubectl -n default get pods -l job-name=registry-trust-probe
kubectl -n default describe pod -l job-name=registry-trust-probe | tail -25
```

Oczekiwane: pod w stanie `ImagePullBackOff` lub `ErrImagePull`, a w zdarzeniach
komunikat zawierający **`x509: certificate signed by unknown authority`**.

- [ ] **Krok 3: BRAMKA — zweryfikuj przyczynę niepowodzenia**

```bash
kubectl -n default get events --field-selector involvedObject.kind=Pod \
  --sort-by=.lastTimestamp -o wide | grep -i 'failed\|x509' | tail -5
```

**ZATRZYMAJ SIĘ, jeśli komunikat NIE zawiera `x509`.** Inne przyczyny i co oznaczają:

| Komunikat | Znaczenie | Reakcja |
|---|---|---|
| `x509: certificate signed by unknown authority` | oczekiwane — brak CA | idź dalej |
| `not found` / `manifest unknown` | zły tag albo obraz nie dojechał | wróć do Zadania 1 |
| `no such host` | DNS na nodzie nie rozwiązuje `registry.home` | problem spoza tego planu |
| `unauthorized` | rejestr wymaga auth przy pullu | sprzeczne z `anonymousPolicy` — zbadaj |
| pod `Completed` | **obraz był w cache** — test bezwartościowy | wróć do Zadania 1 Krok 3 |

- [ ] **Krok 4: Zapisz dowód i usuń Joba**

Zapisz komunikat błędu verbatim — będzie potrzebny w raporcie jako punkt odniesienia.

```bash
kubectl delete -f /tmp/registry-trust-test/job.yaml
```

---

### Zadanie 3: Patch w repozytorium

**Files:**
- Create: `bootstrap/patch/registry-home.yaml`
- Modify: `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml`

- [ ] **Krok 1: Wyciągnij CA w postaci base64**

Certyfikat jest już w repo w dokładnie tej formie, której oczekuje Talos —
w Secrecie dla reflectora:

```bash
cd ~/Projects/flux-home-system
CA_B64=$(grep 'ca.crt:' flux/infrastructure/shared-secrets/jabbas-ca.yaml | awk '{print $2}')
echo "$CA_B64" | head -c 60; echo
```

Użycie istniejącej wartości zamiast ponownego kodowania gwarantuje, że nody
i klaster ufają dokładnie temu samemu certyfikatowi.

- [ ] **Krok 2: Zweryfikuj, że to naprawdę `jabbas-ca`**

```bash
echo "$CA_B64" | base64 -d | openssl x509 -noout -subject -dates -ext basicConstraints
```

Oczekiwane: `CN=jabbas-ca`, `CA:TRUE`, `notAfter` w 2033.

Porównaj z certyfikatem, którym podpisany jest `registry.home`:

```bash
diff <(echo "$CA_B64" | base64 -d) \
     ~/Projects/container-registry/roles/prepare-os/files/jabbas-ca.crt && echo IDENTYCZNE
```

Oczekiwane: `IDENTYCZNE`. Jeśli się różnią, zatrzymaj się — nody ufałyby innemu CA
niż to, które podpisało certyfikat rejestru.

- [ ] **Krok 3: Utwórz `bootstrap/patch/registry-home.yaml`**

```bash
cd ~/Projects/flux-home-system
CA_B64=$(grep 'ca.crt:' flux/infrastructure/shared-secrets/jabbas-ca.yaml | awk '{print $2}')

cat > bootstrap/patch/registry-home.yaml <<EOF
---
# Private OCI registry (zot) at registry.home, TLS signed by the private jabbas-ca.
# Only the CA is needed: reads are anonymous, so no auth block and no
# imagePullSecrets anywhere in the cluster.
machine:
  registries:
    config:
      registry.home:
        tls:
          ca: ${CA_B64}
EOF
```

`CA_B64` jest tu ustawiane ponownie, żeby ten krok był samodzielny — nie zakładaj,
że zmienna przetrwała z Kroku 1.

Komentarz po angielsku, zgodnie z regułą językową.

- [ ] **Krok 4: Dopisz patch do listy w roli**

W `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml`, w zadaniu
`Apply patches`, dodaj `-p @patch/registry-home.yaml \` do listy. Zachowaj poprawne
kontynuacje linii — ostatni wpis nie ma backslasha.

- [ ] **Krok 5: Walidacja lokalna**

```bash
yamllint bootstrap/patch/registry-home.yaml
cd bootstrap && uvx ansible-lint ; cd ..
```

Oczekiwane: brak NOWYCH zgłoszeń względem stanu sprzed zmiany. W repo są
preegzystujące zgłoszenia `ansible-lint` dotyczące innych plików — porównaj
z bazą, nie zakładaj, że wyjście ma być puste.

- [ ] **Krok 6: Commit**

```bash
git add bootstrap/patch/registry-home.yaml \
        bootstrap/roles/initialize_talos_configuration/tasks/main.yaml
git commit -m "feat(bootstrap): trust the registry.home CA on Talos nodes"
```

Nie pushuj — użytkownik pushuje sam.

---

### Zadanie 4: Aplikacja na żywe nody

Sekwencyjnie, po jednym nodzie, z weryfikacją po każdym. To trzy węzły
control-plane jednego klastra.

- [ ] **Krok 1: Dry-run na pierwszym nodzie**

```bash
cd ~/Projects/flux-home-system
talosctl -n 10.1.250.11 patch machineconfig -m no-reboot --dry-run \
  --patch-file bootstrap/patch/registry-home.yaml
```

Oczekiwane: diff pokazujący dodanie `machine.registries.config."registry.home".tls.ca`
oraz `Applied configuration without a reboot`.

**ZATRZYMAJ SIĘ, jeśli diff pokazuje cokolwiek poza tym** — w szczególności
usunięcie albo zmianę innych sekcji.

- [ ] **Krok 2: talos1**

```bash
talosctl -n 10.1.250.11 patch machineconfig -m no-reboot \
  --patch-file bootstrap/patch/registry-home.yaml

talosctl -n 10.1.250.11 get machineconfig -o yaml | grep -A4 'registry.home'
kubectl get node talos1
```

Oczekiwane: wpis obecny, node `Ready`, brak reboota.

**ZATRZYMAJ SIĘ, jeśli node przestanie być `Ready`** — nie ruszaj pozostałych.

- [ ] **Krok 3: Potwierdź, że pull działa na talos1**

```bash
TAG=$(cat /tmp/registry-trust-test/tag.txt)
talosctl -n 10.1.250.11 image pull --namespace cri registry.home/smoke/trust:${TAG}
```

Oczekiwane: pobranie kończy się sukcesem, bez `x509`.

To jest moment prawdy — jeśli tu zadziała, reszta to powtórzenie.

- [ ] **Krok 4: talos2**

```bash
talosctl -n 10.1.250.12 patch machineconfig -m no-reboot \
  --patch-file bootstrap/patch/registry-home.yaml
talosctl -n 10.1.250.12 get machineconfig -o yaml | grep -A4 'registry.home'
kubectl get node talos2
TAG=$(cat /tmp/registry-trust-test/tag.txt)
talosctl -n 10.1.250.12 image pull --namespace cri registry.home/smoke/trust:${TAG}
```

- [ ] **Krok 5: talos3**

```bash
talosctl -n 10.1.250.13 patch machineconfig -m no-reboot \
  --patch-file bootstrap/patch/registry-home.yaml
talosctl -n 10.1.250.13 get machineconfig -o yaml | grep -A4 'registry.home'
kubectl get node talos3
TAG=$(cat /tmp/registry-trust-test/tag.txt)
talosctl -n 10.1.250.13 image pull --namespace cri registry.home/smoke/trust:${TAG}
```

- [ ] **Krok 6: Zweryfikuj, że nody i repo mają identyczną konfigurację**

```bash
for ip in 10.1.250.11 10.1.250.12 10.1.250.13; do
  echo "=== $ip ==="
  talosctl -n $ip get machineconfig -o yaml \
    | grep -A3 'registry.home' | grep 'ca:' | md5
done
grep 'ca:' bootstrap/patch/registry-home.yaml | md5
```

Oczekiwane: cztery identyczne sumy. Rozjazd repo z żywym klastrem ujawniłby się
dopiero przy następnym bootstrapie — czyli w najgorszym możliwym momencie.

- [ ] **Krok 7: Sprawdź zdrowie klastra**

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
```

Oczekiwane: trzy nody `Ready`, brak podów w stanie innym niż `Running`/`Completed`.

---

### Zadanie 5: Test pozytywny — ten sam Job musi przejść

- [ ] **Krok 1: Usuń obraz z cache'a nodów**

Job z Zadania 2 mógłby teraz przejść z cache'a, bo Zadanie 4 pobrało obraz na
wszystkie trzy nody. Żeby test sprawdzał realny pull, wyczyść cache:

```bash
TAG=$(cat /tmp/registry-trust-test/tag.txt)
for ip in 10.1.250.11 10.1.250.12 10.1.250.13; do
  DIGEST=$(talosctl -n $ip image list --namespace cri \
    | grep "registry.home/smoke/trust:${TAG}" | awk '{print $4}')
  [ -n "$DIGEST" ] && talosctl -n $ip image remove --namespace cri "$DIGEST"
done
```

Uwaga: `talosctl image remove` po tagu jest **cichym no-opem** — obraz siedzi pod
referencją z digestem. Ustalone empirycznie 2026-09-05. Dlatego usuwamy po digeście
i weryfikujemy skutek.

```bash
for ip in 10.1.250.11 10.1.250.12 10.1.250.13; do
  talosctl -n $ip image list --namespace cri | grep -c 'registry.home' || true
done
```

Oczekiwane: `0` na każdym nodzie.

- [ ] **Krok 2: Uruchom ten sam Job**

```bash
kubectl apply -f /tmp/registry-trust-test/job.yaml
kubectl -n default wait --for=condition=complete --timeout=120s job/registry-trust-probe
```

Oczekiwane: `job.batch/registry-trust-probe condition met`.

- [ ] **Krok 3: Potwierdź, że pull faktycznie się odbył**

```bash
kubectl -n default describe pod -l job-name=registry-trust-probe | grep -i 'pulling\|pulled'
kubectl -n default logs -l job-name=registry-trust-probe
```

Oczekiwane: zdarzenie `Successfully pulled image`, logi zawierające
`registry.home trust probe`.

Zdarzenie `Container image ... already present on machine` zamiast `Pulled`
oznacza, że czyszczenie cache'a z Kroku 1 nie zadziałało — wróć do niego.

---

### Zadanie 6: Sprzątanie

- [ ] **Krok 1: Usuń Joba i pliki tymczasowe**

```bash
kubectl delete -f /tmp/registry-trust-test/job.yaml --ignore-not-found
```

- [ ] **Krok 2: Usuń obraz testowy z rejestru**

```bash
CA=~/Projects/container-registry/roles/prepare-os/files/jabbas-ca.crt
TAG=$(cat /tmp/registry-trust-test/tag.txt)
DIGEST=$(curl -s --cacert $CA -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  -I https://registry.home/v2/smoke/trust/manifests/${TAG} \
  | tr -d '\r' | awk '/[Dd]ocker-[Cc]ontent-[Dd]igest/{print $2}')

curl -s -o /dev/null -w '%{http_code}\n' -u jabbas --cacert $CA \
  -X DELETE "https://registry.home/v2/smoke/trust/manifests/${DIGEST}"
```

Oczekiwane: `202`.

- [ ] **Krok 3: Usuń obraz z cache'a nodów i z lokalnego podmana**

```bash
TAG=$(cat /tmp/registry-trust-test/tag.txt)
for ip in 10.1.250.11 10.1.250.12 10.1.250.13; do
  DIGEST=$(talosctl -n $ip image list --namespace cri \
    | grep "registry.home/smoke/trust" | awk '{print $4}')
  [ -n "$DIGEST" ] && talosctl -n $ip image remove --namespace cri "$DIGEST"
done

podman rmi registry.home/smoke/trust:${TAG} 2>/dev/null || true
rm -rf /tmp/registry-trust-test
```

- [ ] **Krok 4: Stan końcowy**

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
git -C ~/Projects/flux-home-system status --short
git -C ~/Projects/flux-home-system log --oneline -3
```

Oczekiwane: trzy nody `Ready`, brak nieoczekiwanych podów, drzewo czyste,
commit z Zadania 3 na wierzchu.

Miejsce w rejestrze zwolni się po przejściu GC zota (`gcDelay: 1h`) — pusty wpis
`smoke/trust` w `/v2/_catalog` do tego czasu jest oczekiwany, nie jest usterką.

---

## Ryzyka

**Test negatywny może przejść z cache'a.** Dlatego Zadanie 1 Krok 3 sprawdza, że
obrazu nie ma na żadnym nodzie, a tag jest unikalny.

**`talosctl image remove` po tagu nic nie robi.** Cichy no-op z RC=0 — usuwamy po
digeście i weryfikujemy skutek.

**Trzy nody control-plane.** Zmiana `machine.registries` nie wymaga reboota, ale
dotyka całej płaszczyzny sterowania. Sekwencyjnie, `-m no-reboot`, weryfikacja po
każdym.

**Rozjazd repo z klastrem.** Zadanie 4 Krok 6 porównuje sumy kontrolne — bez tego
rozjazd ujawniłby się przy następnym bootstrapie.

**Zmiany w `bootstrap/` nie są objęte CI.** `.github/workflows/validate.yaml`
reaguje tylko na `flux/**`. Walidacja lokalna jest jedyną bramką.
