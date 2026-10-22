# Kubelet image GC 70/60 — plan wdrożenia

> **Dla agentów:** kroki mają składnię checkboxów (`- [ ]`). Plan **nie zawiera restartu
> ani reboota żadnego noda** — zmiana `KubeletConfig` restartuje tylko usługę kubeleta.
> Mimo to **przed uruchomieniem playbooka trzeba mieć potwierdzenie właściciela klastra**
> w bieżącej rozmowie.

**Cel:** Kubelet zaczyna sprzątać nieużywane obrazy przy 70% zajętości dysku (do 60%),
zamiast przy 85%/80%, żeby buildy CI nie wpychały nodów w `DiskPressure`.

**Dlaczego:** Każdy nod ma jeden 32 GB wolumen `EPHEMERAL`, współdzielony przez obrazy,
etcd i logi. Domyślny próg GC (85%) pokrywa się z twardym progiem eksmisji
`imagefs.available<15%`, więc GC rusza dokładnie wtedy, gdy kubelet już eksmituje pody.
Build BuildKita ciągnący obrazy bazowe przepycha nod przez ten próg — tak padło wydanie
homebudget 0.2.1 (2026-10-21). Przy 70% zostaje ~4,8 GB zapasu do progu eksmisji.

**Stan wyjściowy (zweryfikowany read-only 2026-10-22):** talos1/2/3 na Talos 1.14.0,
kubelet v1.37.0; `configz`: `imageGCHighThresholdPercent: 85`,
`imageGCLowThresholdPercent: 80`, `evictionHard` `imagefs.available: 15%`,
`nodefs.available: 10%`. Dysk: talos1 54%, talos2 **81%** (5,95 GB wolne), talos3 66%.
Machine config identyczny na wszystkich trzech nodach i równy
`bootstrap/controlplane.yaml` + osiem patchy z playbooka.

**Metoda:** standardowa ścieżka repo — `ansible-playbook site.yaml`. Playbook jest
wznawialny na żywym klastrze: VM-ki istnieją (bez zmian), `gen config --force` generuje
świeżą bazę, `talosctl apply` (tryb `auto`) nakłada wszystkie patche na już
zaprovisionowane nody, bootstrap etcd jest pomijany (strażnik `service etcd` → `Running`).

---

## Co się zmienia

| Plik | Zmiana |
|------|--------|
| `bootstrap/patch/kubelet-image-gc.yaml` | nowy dokument `KubeletConfig`, `config.imageGCHighThresholdPercent: 70`, `config.imageGCLowThresholdPercent: 60` |
| `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml` | `-p @patch/kubelet-image-gc.yaml` na liście patchy; `--kubernetes-version {{ talos.kubernetes_version }}` w `gen config` |
| `bootstrap/site.yaml` | `talos.kubernetes_version: 1.37.0` |
| `AGENTS.md` | dziewięć żywych patchy, nody na 1.14.0, nowa pułapka (`KubeletConfig.config` jest `Unstructured`; pin wersji Kubernetesa) |

**Dlaczego pin Kubernetesa jest częścią tej zmiany:** bez `--kubernetes-version` lokalny
`talosctl` 1.14.4 wygenerowałby obrazy Kubernetesa 1.37.1 — samo uruchomienie playbooka
po to, żeby nałożyć próg GC, po cichu podbiłoby control plane. Z pinem jedyne obrazy
zależne od wersji (`kubelet`, `kube-apiserver`, `kube-controller-manager`,
`kube-scheduler`, `kube-proxy`) zostają na v1.37.0. Upgrade Kubernetesa to osobna,
świadoma operacja: `talosctl upgrade-k8s`, potem podbicie pinu.

**Pułapka:** `KubeletConfig.config` to pole `Unstructured` — patch podmienia je w całości.
Każde przyszłe ustawienie kubeleta musi trafić do `kubelet-image-gc.yaml`, nie do
drugiego patcha.

**Weryfikacja offline (zrobiona przy przygotowaniu):** `bootstrap/controlplane.yaml` +
dziewięć patchy → `talosctl validate --mode metal` → *valid for metal mode*; diff
z żywym configiem talos1 (talos2/3 mają identyczny) → jedyna różnica to
`KubeletConfig.config: {}` → klucze GC 70/60.

---

## Zadanie 1: Pre-checki (read-only)

- [ ] **Krok 1: Wersje** — oczekiwane: Talos 1.14.0 na każdym nodzie.

```bash
talosctl -n talos1.home version --short
talosctl -n talos2.home version --short
talosctl -n talos3.home version --short
kubectl get nodes -o wide            # VERSION v1.37.0, wszystkie Ready
```

- [ ] **Krok 2: `configz` przed** — oczekiwane 85/80 (zapisz wynik do porównania).

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos2/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos3/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
```

- [ ] **Krok 3: Dysk per nod** — zanotuj `usedBytes`/`capacityBytes` (nodefs = imagefs na Talosie).

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
kubectl get --raw /api/v1/nodes/talos2/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
kubectl get --raw /api/v1/nodes/talos3/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
```

- [ ] **Krok 4: Brak działających buildów** — żaden PipelineRun nie może mieć `SUCCEEDED=Unknown`.

```bash
kubectl get pipelineruns -A
```

Jeśli coś biegnie — poczekaj na koniec. Restart kubeleta w trakcie buildu nie zabija
podów, ale nie ma powodu ryzykować.

- [ ] **Krok 5: etcd zdrowy** — trzech członków, brak `ERRORS`, wspólny `RAFT TERM`.

```bash
talosctl -n talos1.home,talos2.home,talos3.home etcd status
```

- [ ] **Krok 6: Repo na właściwym commicie** — `main` zawiera ten plan i patch.

```bash
grep -n 'kubelet-image-gc\|kubernetes-version' bootstrap/roles/initialize_talos_configuration/tasks/main.yaml
grep -n 'kubernetes_version' bootstrap/site.yaml
```

Oczekiwane: oba wpisy w roli, `kubernetes_version: 1.37.0` w `site.yaml`. **Bez pinu nie
uruchamiać** — playbook podbiłby Kubernetesa do 1.37.1.

- [ ] **Krok 7: Potwierdzenie właściciela** — dopiero teraz.

---

## Zadanie 2: Wdrożenie przez playbook

- [ ] **Krok 1: Uruchom playbook**

```bash
cd bootstrap
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done
uv sync && source .venv/bin/activate
ansible-playbook site.yaml
```

Czego się spodziewać na żywym klastrze:

- ISO jest ponownie wgrywane do Proxmoxa (`force: true`) — nieszkodliwe.
- `proxmox_kvm` nie rusza istniejących VM 401–403; start — już działają.
- `gen config --force` nadpisuje `bootstrap/controlplane.yaml` świeżą bazą (z pinem
  v1.37.0 — treściowo ta sama baza).
- `Apply patches` idzie w pętli po talos1 → talos2 → talos3, tryb `auto`, **bez**
  `--insecure` (nody są zaprovisionowane). Zmiana dotyczy tylko `KubeletConfig`, więc
  Talos stosuje ją bez reboota: restartuje kubeleta. Pody działają dalej; nody mogą na
  kilka–kilkanaście sekund pokazać `NotReady`.
- Bootstrap etcd pominięty (etcd `Running`).
- `~/.talos/config` nadpisany `bootstrap/talosconfig` (ta sama treść);
  `talosctl kubeconfig` scala świeży kubeconfig do `~/.kube/config` — jeśli kontekst
  `admin@k8s` już istnieje z innym certyfikatem, talosctl może dodać kontekst z sufiksem
  (`admin@k8s-1`); sprawdź `kubectl config get-contexts` po przebiegu.
- `provision/*.yaml` stosowane ponownie (`state: present`) — te same obiekty, bez zmian.

**Jeśli którykolwiek task `Apply patches` zgłosi błąd — STOP.** Nie uruchamiaj playbooka
ponownie w ciemno; przejdź do sekcji „Rollback” albo zdiagnozuj.

- [ ] **Krok 2: Weryfikacja bazy** — w świeżo wygenerowanym `controlplane.yaml` wszystkie
  obrazy Kubernetesa na v1.37.0.

```bash
grep -n 'image:' bootstrap/controlplane.yaml
```

Oczekiwane: `kubelet`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`,
`kube-proxy` — wszystkie `:v1.37.0`; installer `…:v1.14.0`.

---

## Zadanie 3: Weryfikacja po wdrożeniu

- [ ] **Krok 1: Kubelet i nody**

```bash
talosctl -n talos1.home,talos2.home,talos3.home service kubelet   # STATE Running, HEALTH OK
kubectl get nodes                                                    # wszystkie Ready, v1.37.0
```

- [ ] **Krok 2: `configz` po** — oczekiwane 70/60 na każdym nodzie, `evictionHard` bez zmian.

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos2/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos3/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
```

- [ ] **Krok 3: Brak zakłóceń poza restartem kubeleta** — żadnych nowych restartów/eksmisji.

```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get events -A --sort-by=.lastTimestamp | tail -40
talosctl -n talos1.home,talos2.home,talos3.home etcd status
```

- [ ] **Krok 4: talos2 — natychmiastowy GC.** talos2 stoi na ~81%, czyli powyżej nowego
  progu 70%. W ciągu kilku minut kubelet usunie nieużywane obrazy, celując w 60%
  (~6,7 GB do zwolnienia). Sprawdź dysk (Zadanie 1, Krok 3) i zdarzenia:

```bash
kubectl get events -A --field-selector involvedObject.kind=Node,involvedObject.name=talos2
```

Jeśli pojawi się `FreeDiskSpaceFailed` / `ImageGCFailed` („Failed to garbage collect
required amount of images… only found X bytes eligible to free”): GC usunął co mógł, ale
resztę zajmują obrazy w użyciu albo dane spoza obrazów (etcd, logi, `emptyDir`, cache
BuildKita) — kubelet nie może ich ruszyć. To ostrzeżenie, nie awaria; będzie się
powtarzać co ~5 min, dopóki zajętość jest > 70%. Wtedy:

1. Sprawdź, co zajmuje miejsce: `talosctl -n talos2.home usage /var --depth 2 --humanize`.
2. Jeśli dominują dane spoza obrazów — to osobny problem (rozmiar wolumenu, cache
   BuildKita, retencja logów), nie powód do rollbacku tej zmiany.
3. Jeśli zajętość nadal rośnie w stronę 85% — rozważ podniesienie wolumenu/dysku VM;
   nie podnoś progów GC z powrotem do 85.

---

## Rollback

Ta sama metoda, bez nowego patcha: usuń `-p @patch/kubelet-image-gc.yaml` z listy w
`bootstrap/roles/initialize_talos_configuration/tasks/main.yaml` (np. `git revert` tylko
tej linii — **pin Kubernetesa zostaje**), następnie `ansible-playbook site.yaml`. Świeża
baza ma `config: {}`, więc kubelet wraca do domyślnych 85/80. Weryfikacja jak w Zadaniu 3,
oczekiwane 85/80.

---

## Post-checki po 24 h

- [ ] Dysk per nod (Zadanie 1, Krok 3) — wszystkie nody ≲ 70% poza chwilowymi pikami
  w trakcie buildów.
- [ ] Brak `DiskPressure`:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'
kubectl get events -A --field-selector reason=EvictionThresholdMet
kubectl get events -A --field-selector reason=FreeDiskSpaceFailed
```

- [ ] Tempo ponownych pobrań obrazów — niższy próg GC oznacza częstsze usuwanie obrazów
  bazowych BuildKita i ich ponowne pobieranie. Sprawdź czas buildów kilku ostatnich
  PipelineRunów i zdarzenia `Pulling` (`kubectl get events -A --field-selector
  reason=Pulling`; zdarzenia żyją ~1 h, więc sprawdzaj w trakcie buildu). Jeśli każdy
  build pobiera wszystko od zera — rozważyć 75/65.
- [ ] Kolejny build wydania homebudget kończy się bez eksmisji.
