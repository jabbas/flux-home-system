# Zgłoszenie: niestabilność etcd i restarty kontrolerów Flux (2026-11-04)

- Status: **przyczyna potwierdzona, poprawki wdrożone 2026-11-04/05, czeka na weryfikację po nocnym backupie** — szczegóły w sekcji „Diagnoza”
- Zgłasza: agent `architect`, przy wdrożeniu strony `dziegielew.ski` (repozytorium `flux-homeapps`, `applications/homepage/`)
- Odbiorca: agent zajmujący się `flux-home-system` (klaster Talos, kontekst `admin@k8s`, API `https://kube.home:6443`)

## Co zaobserwowano

Obserwacje pochodzą z jednej kontroli tylko do odczytu, wykonanej 2026-11-04 około 00:40 czasu polskiego. Agent `devops` sprawdzał wtedy pierwsze wdrożenie aplikacji `homepage`.

1. **etcd** zwracał błędy `etcdserver: request timed out` i komunikaty `leader changed`.
2. **Kontrolery Flux** w `flux-system` restartowały się i wpadały w `CrashLoopBackOff`. Liczniki restartów w chwili kontroli:

   | Kontroler | Restarty |
   |---|---|
   | `helm-controller` | 12 |
   | `source-controller` | 11 |
   | `notification-controller` | 13 |
   | `kustomize-controller` | 2 |

3. **Kustomizacja `reflector`** była w stanie `Ready=False` z komunikatem:
   `unable to update the healthy status to progressing: etcdserver: request timed out`.
   Przez zależność `dependsOn` w stanie `False` były też **`shared-secrets`** i **`victoria-metrics`**.
4. Po kilku minutach Flux się ustabilizował i zastosował nowy commit `flux-homeapps`.

## Stan późniejszy

Agent `debugger` sprawdził stan 2026-11-04 około 21:07 czasu polskiego, czyli po około 20 godzinach:

- pody Flux działały, a liczniki restartów się nie zmieniły (ostatni restart około 20 godzin wcześniej);
- logi `helm-controller` nie pokazywały błędów, wszystkie wydania były `in-sync`;
- kolejne wdrożenia (`homepage` w wersjach 0.1.1 do 1.0.0) przeszły bez problemu.

Kontrola 2026-11-04 około 22:15 czasu polskiego (agent `devops`, tylko odczyt):

- wszystkie 26 kustomizacji jest `Ready`, w tym `reflector`, `shared-secrets` i `victoria-metrics` (rewizja `89fd0e35`);
- od incydentu kontrolery Flux nie mają nowych restartów (ostatni około 21 godzin wcześniej).

## Czego nie sprawdzono
- Stan etcd po incydencie: lider, alarmy, opóźnienia dysku.
- Czy incydent się powtarza, czy był jednorazowy.
- Przyczyna.

## Diagnoza (agent `debugger`, 2026-11-04/05)

### Przyczyna

Brak pamięci RAM na hoście `pve.home`, a nie problem samego etcd ani dysków VM.

1. Host ma 62 GB RAM. Gościom przydzielono ~86 GB, do tego ~6 GB pamięci podręcznej ZFS (ARC). KSM było wyłączone.
2. Część pamięci VM Talos trafiła do swapu hosta: talos1 2,3 GB, talos2 3,8 GB, talos3 5,3 GB. Swap był zajęty w 27–31 GB z 32 GB.
3. Swap leży na `/dev/sde`, dysku SATA Plextor podłączonym przez Thunderbolt. Przez 38 dni pracy host wczytał z niego ~671 GB, średnio ~17 GB na dobę.
4. Gdy gość sięga po strony ze swapu, jego procesory czekają na wolny dysk. etcd przestaje wysyłać heartbeat na czas, lider się zmienia, a `kube-controller-manager`, `kube-scheduler`, `kube-apiserver` i kontrolery Flux tracą blokady i się restartują.

Dwa wyzwalacze:

- **Codziennie ok. 03:10–03:25 czasu lokalnego:** vzdump o 03:00 w trybie `snapshot` bez fleecingu backupował też VM 401–403, na tę samą pulę `rpool`. W trakcie backupu swap rósł o ~5 GB. Restarty `kube-system` w tym oknie wystąpiły 20, 23, 24, 26, 27, 29, 30 i 31 października.
- **Losowo:** nagłe wczytywanie stron ze swapu, na przykład 2026-10-17 19:15 UTC, 2026-10-31 15:50 UTC i opisany incydent.

### Dowody dla incydentu 2026-11-04 00:33:30–00:41:30 (czas polski)

| Źródło | Obserwacja |
|---|---|
| apiserver, `etcd_request_duration_seconds` (VictoriaMetrics) | średnio z ~8 ms do 2–16 s, 99. percentyl 13–39 s, wszystkie 3 węzły jednocześnie |
| Proxmox RRD hosta | iowait z 2,4% do 17–31% dokładnie w tym oknie, CPU ~28% |
| Proxmox RRD gości | brak istotnego I/O dyskowego gości na starcie; RSS VM Talos rośnie, swap hosta spada o ~0,8 GB, czyli strony wracają ze swapu |
| restarty | `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` o 00:39–00:40, potem kontrolery Flux |

Wdrożenie `homepage` nie było wyzwalaczem: commit trafił do repozytorium o 23:54, a CI w klastrze zużywało na starcie incydentu ~1,2 GB pamięci.

Ograniczenia dowodów: bufor logów etcd w Talosie sięga tylko ~19 godzin wstecz, a VictoriaMetrics nie zbiera metryk z etcd.

### Wdrożone poprawki

| Data | Zmiana | Wycofanie |
|---|---|---|
| 2026-11-04 | KSM: `KSM_THRES_COEF=40` w `/etc/ksmtuned.conf` (było domyślne 20). `ksmtuned` nie widział pamięci w swapie i uważał, że RAM jest dużo. Po 5 minutach odzyskane ~3,9 GB. | kopia `/etc/ksmtuned.conf.bak-2026-11-04`, potem `systemctl restart ksmtuned` |
| 2026-11-04 | LXC frigate (202): RAM 4096 → 6144 MB. Wyczerpywał własny limit (3 zabicia z braku pamięci) i stale korzystał z tego samego swapu na `sde`. Repozytorium `container-frigate`, commit `49ff580`. | `pct set 202 --memory 4096` |
| 2026-11-05 | vzdump: `exclude 202,300` → `202,300,401,402,403`; `fleecing 0` → `enabled=1,storage=local-zfs`. Usunięte archiwa VM 401–403 (~47 GB). | kopia `/root/jobs.cfg.bak-2026-11-05` |

### Otwarte

- Weryfikacja po pierwszym nocnym backupie z nowymi ustawieniami.
- Brak kopii etcd od chwili wykluczenia VM Talos z vzdump.
- Pamięć hosta nadal jest przydzielona z nadmiarem. Ponad 20 GB stron gości zostaje w swapie, dopóki goście ich nie dotkną. Kolejne kroki („Phase 0” w `2026-09-24-pve-storage-redundancy-design.md`) czekają na pomiar: hassio 16 GB, rzeczywiste użycie nieznane.
- Brak metryk etcd w VictoriaMetrics i brak alertu na swap hosta.

## Hipotezy pierwotne (zweryfikowane)

Hipoteza 1 jest potwierdzona częściowo: przyczyną było I/O dysku swapu, a nie zapis WAL. Hipoteza 2 jest potwierdzona dla pamięci, nie dla CPU. Hipoteza 3 nie ma dowodów.

1. **Opóźnienia zapisu na dysk etcd** (fsync WAL) na dyskach maszyn wirtualnych Proxmox. Powiązany kontekst: `docs/plans/2026-09-24-pve-storage-redundancy-design.md`, gdzie jedna noga mirrora działa przez tunel Thunderbolt.
2. **Chwilowe przeciążenie** węzłów control plane (CPU, pamięć, I/O), np. przy jednoczesnej pracy kopii zapasowych lub snapshotów ZFS.
3. **Problem sieciowy** między węzłami control plane.

## Proponowane pierwsze kroki (tylko odczyt)

- `flux get kustomizations --all-namespaces --context admin@k8s`: czy `reflector`, `shared-secrets` i `victoria-metrics` są teraz `Ready=True`.
- `kubectl get pods --namespace flux-system --context admin@k8s`: czy liczniki restartów wzrosły od 2026-11-04.
- `talosctl etcd status`, `talosctl etcd members` i `talosctl etcd alarm list` na węzłach control plane.
- `talosctl logs etcd` i `talosctl dmesg`: okno czasowe 2026-11-03 23:00 do 2026-11-04 01:00 (czas polski), szukać `slow fdatasync`, `apply request took too long` i `leader changed`.
- Jeśli są metryki (VictoriaMetrics):
  - `etcd_disk_wal_fsync_duration_seconds`,
  - `etcd_disk_backend_commit_duration_seconds`,
  - `etcd_server_leader_changes_seen_total`,
  - `etcd_server_slow_apply_total`

  w tym samym oknie.
- Na hoście Proxmox: obciążenie I/O puli ZFS w tym oknie, np. zaplanowane snapshoty, scrub albo replikacja.

## Zasady

- Najpierw dowody, potem zmiana. Żadnych zmian na próbę.
- Bez restartów węzłów i bez działań destrukcyjnych na etcd (defrag, usuwanie członków, przywracanie snapshotu) bez wyraźnej zgody właściciela.
