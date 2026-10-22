# Kubelet image GC 70/60 — plan wdrożenia węzeł po węźle

> **Dla agentów:** kroki mają składnię checkboxów (`- [ ]`). Plan **nie zawiera reboota
> żadnego noda** — zmiana `KubeletConfig` restartuje tylko usługę kubeleta. Playbook
> uruchamia **właściciel klastra** albo agent na jego **wyraźną prośbę w bieżącej
> rozmowie**. Jeden nod na raz; nie przechodź do następnego, dopóki poprzedni nie
> przeszedł wszystkich checków.

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
`nodefs.available: 10%`. Dysk: talos1 **54%**, talos3 66%, talos2 **81%** (5,95 GB wolne).
Machine config identyczny na wszystkich trzech nodach i równy
`bootstrap/controlplane.yaml` + osiem patchy z playbooka.

**Metoda:** ścieżka repo — `ansible-playbook site.yaml` — ale **węzeł po węźle, z
kanarkiem**, sterowana extra-vars (opisane w `bootstrap/site.yaml`):

| Zmienna | Znaczenie | Gdy nieustawiona |
|---------|-----------|------------------|
| `talos_apply_nodes` | lista lub string po przecinku (`talos1` albo `talos1.home`) — tylko te nody | wszystkie nody |
| `talos_apply_mode` | `dry-run` → `talosctl apply --dry-run`, diff wypisany per nod; `try` → `--mode=try` | tryb `auto` |
| `talos_apply_try_timeout` | czas do automatycznego rollbacku w trybie `try` (duration Go) | `5m` |
| `talos_skip_patches` | nazwy patchy do pominięcia (ścieżka rollbacku) | wszystkie patche |
| `talos_skip_iso_upload` | `true` → bez pobierania/wgrywania ISO do Proxmoxa (tylko istniejące VM-ki) | ISO wgrywane (`force: true`) |

Literówka w trybie, nazwie noda, patcha albo w timeoucie zatrzymuje playbook w
`pre_tasks`, **zanim** cokolwiek dotknie Proxmoxa czy noda.

**Co robi przebieg „serwisowy”** (ustawione `talos_apply_nodes`, `talos_apply_mode` lub
`talos_skip_patches`):

- rola `create_controlpanes` jest nieunikniona — buduje inwentarz (`add_host`) dla
  `groups['all']`. Na żywym klastrze: `proxmox_kvm` nie rusza istniejących VM 401–403,
  start — już działają, czekanie na port 50000 (read-only). Z `talos_skip_iso_upload=true`
  ISO nie jest wgrywane;
- `gen secrets` — pominięte (`secrets.yaml` istnieje); `gen config --force` nadpisuje
  lokalne `bootstrap/controlplane.yaml`, `worker.yaml`, `talosconfig` (gitignored; ta sama
  tożsamość klastra z `secrets.yaml`, nowy cert klienta);
- `talosctl get version` per nod (read-only) — ustala, że nody są zaprovisionowane (bez
  `--insecure`);
- `Apply patches` **tylko** na wybranych nodach, w wybranym trybie;
- czekanie na apid, `service etcd` (read-only), bootstrap etcd pominięty (etcd `Running`),
  czekanie na 6443, aktualizacja endpointów w lokalnym `bootstrap/talosconfig`;
- **pominięte:** kopia do `~/.talos/config`, `talosctl kubeconfig` (żadnych kontekstów
  `admin@k8s-1`), `provision/*.yaml`.

W `dry-run` dodatkowo pominięte: bootstrap etcd i czekanie na 6443 — **żaden nod nie jest
zmieniany**.

**Semantyka `--mode=try` (Talos 1.14, `talosctl apply-config --help` + dokumentacja):**
konfiguracja jest stosowana natychmiast, ale **nie jest zapisywana na dysk**; jeśli w
ciągu `--timeout` nie przyjdzie kolejne `apply`, Talos sam przywraca poprzednią. Jeśli
zmiana wymagałaby reboota, `try` zwraca błąd i niczego nie stosuje. **Utrwalenie** =
ponowny przebieg dla tego samego noda **bez** `talos_apply_mode` (tryb `auto` zapisuje
config). Gdyby okno minęło i nastąpił rollback, ten sam przebieg `auto` po prostu
nałoży zmianę od nowa — stan końcowy identyczny, tylko bez siatki bezpieczeństwa.
Uwaga: obrazy usunięte przez GC w oknie `try` **nie wracają** po rollbacku (pobiorą się
ponownie przy potrzebie).

---

## Zadanie 1: Pre-checki (read-only)

- [ ] **Krok 1: Wersje** — oczekiwane: Talos 1.14.0 na każdym nodzie, wszystkie `Ready`.

```bash
talosctl -n talos1.home version --short
talosctl -n talos2.home version --short
talosctl -n talos3.home version --short
kubectl get nodes -o wide            # VERSION v1.37.0, STATUS Ready
```

- [ ] **Krok 2: `configz` przed** — oczekiwane 85/80 (zapisz wynik do porównania).

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos2/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get --raw /api/v1/nodes/talos3/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
```

- [ ] **Krok 3: Dysk per nod** — zanotuj `pct` (nodefs = imagefs na Talosie).

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
kubectl get --raw /api/v1/nodes/talos2/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
kubectl get --raw /api/v1/nodes/talos3/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
```

Kolejność wdrożenia wynika z tego kroku: najmniej zajęty nod jest kanarkiem (dziś
talos1 54% → talos3 66% → talos2 81%). Jeśli proporcje się zmieniły — dostosuj kolejność,
talos2 (powyżej 70%) i tak zostaw na koniec.

- [ ] **Krok 4: Brak działających buildów** — żaden PipelineRun w `ci` nie może mieć
  `SUCCEEDED=Unknown`. Jeśli coś biegnie — poczekaj na koniec (restart kubeleta nie zabija
  podów, ale nie ma powodu ryzykować).

```bash
kubectl get pipelineruns -n ci
```

- [ ] **Krok 5: etcd zdrowy** — trzech członków, brak `ERRORS`, wspólny `RAFT TERM`.

```bash
talosctl -n talos1.home,talos2.home,talos3.home etcd status
```

- [ ] **Krok 6: Restarty podów — zdjęcie przed** (do porównania po każdym nodzie).

```bash
kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[*].restartCount' | sort > /tmp/pods-before.txt
```

- [ ] **Krok 7: Repo na właściwym commicie** — `main` zawiera patch, pin i zmienne.

```bash
grep -n 'kubelet-image-gc\|kubernetes-version\|talos_apply_mode' bootstrap/roles/initialize_talos_configuration/tasks/main.yaml
grep -n 'kubernetes_version\|talos_apply_nodes_resolved' bootstrap/site.yaml
```

Oczekiwane: patch na liście `initialize_talos_configuration_patches`,
`--kubernetes-version` w `gen config`, `kubernetes_version: 1.37.0` w `site.yaml`.
**Bez pinu nie uruchamiać** — playbook podbiłby Kubernetesa do 1.37.1.

- [ ] **Krok 8: Środowisko playbooka**

```bash
cd bootstrap
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done
uv sync && source .venv/bin/activate
```

- [ ] **Krok 9: Potwierdzenie właściciela** — dopiero teraz.

> **Zasada na cały czas rolloutu:** dopóki nie wszystkie nody mają 70/60, **nie
> uruchamiaj playbooka bez `talos_apply_nodes`** — pełny przebieg nałożyłby patch na
> wszystkie trzy naraz.

---

## Zadanie 2 (Krok 0): Dry-run na wszystkich nodach

- [ ] **Krok 1: Dry-run**

```bash
ansible-playbook site.yaml -e talos_apply_mode=dry-run -e talos_skip_iso_upload=true
```

Task `Show the dry-run diff per node` wypisuje wynik `talosctl apply --dry-run` dla
talos1, talos2, talos3. Nie wklejaj tego wyjścia poza terminal bez przejrzenia.

- [ ] **Krok 2: Świeża baza ma przypięte obrazy** — w nowo wygenerowanym
  `bootstrap/controlplane.yaml` wszystkie obrazy Kubernetesa na v1.37.0.

```bash
grep -n 'image:' controlplane.yaml
```

Oczekiwane: `kubelet`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`,
`kube-proxy` — wszystkie `:v1.37.0`; installer `…:v1.14.0`. Cokolwiek innego — **STOP**.

- [ ] **Krok 3: Diff każdego noda = tylko `KubeletConfig.config`**

Oczekiwane dla każdego z trzech nodów: zmiana bez reboota, a w diffie wyłącznie dokument
`kind: KubeletConfig`, gdzie `config: {}` zamienia się na:

```yaml
config:
    imageGCHighThresholdPercent: 70
    imageGCLowThresholdPercent: 60
```

**STOP**, jeśli którykolwiek nod: wymaga reboota, ma w diffie inny dokument (obrazy,
certyfikaty, sieć, patche list typu `nameservers`), albo diffy nodów się różnią.

---

## Zadanie 3 (Krok 1): Kanarek — talos1

- [ ] **Krok 1: `try` z 15-minutowym oknem**

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos1 -e talos_apply_mode=try -e talos_apply_try_timeout=15m -e talos_skip_iso_upload=true
```

Zanotuj godzinę zakończenia tasku `Apply patches` — od niej liczy się okno 15 min.

- [ ] **Krok 2: Checki w oknie `try`** (celuj w ≤ 10 min, żeby zdążyć z utrwaleniem).

```bash
talosctl -n talos1.home service kubelet          # STATE Running, HEALTH OK
kubectl get node talos1                           # Ready (chwilowe NotReady w trakcie restartu jest OK)
kubectl get --raw /api/v1/nodes/talos1/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, evictionHard}'
kubectl get pods -A --no-headers --field-selector spec.nodeName=talos1 -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[*].restartCount' | sort | diff <(grep ' talos1 ' /tmp/pods-before.txt) -
kubectl get events -A --field-selector involvedObject.name=talos1 --sort-by=.lastTimestamp | tail -20
```

Oczekiwane: kubelet `Running`, nod `Ready`, `configz` **70/60**, `evictionHard` bez zmian,
diff podów pusty (poza podami, które w międzyczasie normalnie się zakończyły lub powstały,
np. z CronJobów) — **bez wzrostu `RESTARTS`**, bez nowych `Evicted`/`Error`. Coś nie tak → **nie utrwalaj**, przejdź do „Abort / rollback”
(albo po prostu poczekaj na automatyczny rollback po 15 min).

- [ ] **Krok 3: Utrwalenie** — ten sam nod, **bez** `talos_apply_mode` (tryb `auto`):

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos1 -e talos_skip_iso_upload=true
```

Kolejne `apply` kończy okno `try`, a `auto` zapisuje config na dysk. Jeśli okno zdążyło
minąć (`configz` wróciło do 85/80), ten przebieg nałoży zmianę od nowa — powtórz Krok 2.

- [ ] **Krok 4: Potwierdzenie trwałości** — dopiero gdy od Kroku 1 minęło > 15 min
  (czyli po terminie ewentualnego rollbacku) i co najmniej 10 min od Kroku 3:

```bash
kubectl get --raw /api/v1/nodes/talos1/proxy/configz | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent}'
ansible-playbook site.yaml -e talos_apply_nodes=talos1 -e talos_apply_mode=dry-run -e talos_skip_iso_upload=true
kubectl get events -A --field-selector involvedObject.name=talos1 --sort-by=.lastTimestamp | tail -20
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
talosctl -n talos1.home,talos2.home,talos3.home etcd status
```

Oczekiwane: nadal **70/60**; dry-run dla talos1 pokazuje **pusty diff** (żadnych zmian);
brak nowych ostrzeżeń związanych z talos1; etcd 3/3 zdrowy.

---

## Zadanie 4 (Krok 2): talos3

talos3 stoi na ~66% — poniżej nowego progu, więc GC nie powinien ruszyć od razu.

- [ ] **Krok 1:** `try`

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos3 -e talos_apply_mode=try -e talos_apply_try_timeout=15m -e talos_skip_iso_upload=true
```

- [ ] **Krok 2:** checki jak w Zadaniu 3, Krok 2 — z `talos3` / `talos3.home`.
- [ ] **Krok 3:** utrwalenie

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos3 -e talos_skip_iso_upload=true
```

- [ ] **Krok 4:** trwałość jak w Zadaniu 3, Krok 4 (z `talos3`), w tym ≥ 10 min
  obserwacji i pusty dry-run.

---

## Zadanie 5 (Krok 3): talos2 — natychmiastowy GC

talos2 stoi na ~81%, powyżej nowego progu 70%. Kubelet sprawdza obrazy co ~5 min, więc
w ciągu kilku minut od restartu usunie nieużywane obrazy, celując w 60% (~6,7 GB).

- [ ] **Krok 1:** `try`

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos2 -e talos_apply_mode=try -e talos_apply_try_timeout=15m -e talos_skip_iso_upload=true
```

- [ ] **Krok 2:** checki jak w Zadaniu 3, Krok 2 (z `talos2`), plus obserwacja GC:

```bash
kubectl get --raw /api/v1/nodes/talos2/proxy/stats/summary | jq '.node.fs | {used: .usedBytes, cap: .capacityBytes, pct: (100 * .usedBytes / .capacityBytes | floor)}'
kubectl get events -A --field-selector reason=FreeDiskSpaceFailed
kubectl get events -A --field-selector reason=ImageGCFailed
kubectl get events -A --field-selector involvedObject.kind=Node,involvedObject.name=talos2
```

Oczekiwane: `pct` spada w stronę 60%. `FreeDiskSpaceFailed` / `ImageGCFailed`
(„Failed to garbage collect required amount of images… only found X bytes eligible to
free”) to **ostrzeżenie, nie awaria**: GC usunął, co mógł, resztę zajmują obrazy w użyciu
albo dane spoza obrazów (etcd, logi, `emptyDir`, cache BuildKita). Będzie się powtarzać co
~5 min, dopóki zajętość > 70%. **To nie jest powód do rollbacku** — utrwal i wtedy:

1. Sprawdź, co zajmuje miejsce: `talosctl -n talos2.home usage /var --depth 2 --humanize`.
2. Dominują dane spoza obrazów → osobny problem (rozmiar wolumenu, cache BuildKita,
   retencja logów).
3. Zajętość dalej rośnie w stronę 85% → rozważ powiększenie dysku VM; **nie** podnoś progów
   GC z powrotem do 85.

- [ ] **Krok 3:** utrwalenie

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos2 -e talos_skip_iso_upload=true
```

- [ ] **Krok 4:** trwałość jak w Zadaniu 3, Krok 4 (z `talos2`), plus ponowny pomiar dysku.

- [ ] **Krok 5: Stan końcowy** — dry-run na wszystkich nodach musi dać pusty diff (repo ==
  klaster), `configz` 70/60 na trzech nodach.

```bash
ansible-playbook site.yaml -e talos_apply_mode=dry-run -e talos_skip_iso_upload=true
```

---

## Abort / rollback

- **W oknie `try`:** nie rób nic — po `talos_apply_try_timeout` Talos sam przywróci
  poprzedni config (kubelet zrestartuje się z 85/80). Sprawdź `configz` po upływie okna.
- **Natychmiast albo po utrwaleniu:** ten sam nod, z pominiętym patchem, tryb `auto`
  (najpierw podgląd przez dry-run — diff powinien pokazać `config` → `{}`):

```bash
ansible-playbook site.yaml -e talos_apply_nodes=talos1 -e talos_skip_patches=kubelet-image-gc.yaml -e talos_apply_mode=dry-run -e talos_skip_iso_upload=true
ansible-playbook site.yaml -e talos_apply_nodes=talos1 -e talos_skip_patches=kubelet-image-gc.yaml -e talos_skip_iso_upload=true
```

  (podmień `talos1` na właściwy nod; kilka nodów: `-e talos_apply_nodes=talos1,talos3`).
  Świeża baza ma `config: {}`, więc kubelet wraca do domyślnych 85/80. Weryfikacja jak w
  Zadaniu 3, Krok 2 — oczekiwane 85/80.
- **Wycofanie na stałe:** usuń `kubelet-image-gc.yaml` z listy
  `initialize_talos_configuration_patches` w
  `bootstrap/roles/initialize_talos_configuration/tasks/main.yaml` (commit/revert tylko tej
  linii — **pin Kubernetesa zostaje**). Bez tego kolejny pełny przebieg playbooka nałoży
  patch z powrotem.
- Jeśli którykolwiek `Apply patches` zgłosi błąd — **STOP**, nie powtarzaj w ciemno;
  zdiagnozuj albo wykonaj rollback.

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
- [ ] etcd 3/3 zdrowy, `kubectl get nodes` — wszystkie `Ready`.
