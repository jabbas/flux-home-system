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
| 2026-11-05 | `vm.watermark_boost_factor` 15000 → 0 (`/etc/sysctl.d/90-watermark-boost.conf`). Szczegóły w sekcji „Dlaczego host przenosił pamięć do swapu przy wolnym RAM”. | usunąć plik, `sysctl -w vm.watermark_boost_factor=15000` |
| 2026-11-05 | zswap włączony (`lz4`, `max_pool_percent=20`), na stałe przez `/etc/tmpfiles.d/zswap.conf`. Strony wypychane przez `kswapd` trafiają do skompresowanego RAM zamiast na dysk swapu za Thunderboltem. Obejście do czasu pakietu ZFS z poprawką. | `echo 0 > /sys/module/zswap/parameters/enabled`, usunąć plik |
| 2026-11-08 | VM 103 hassio: RAM 16384 → 8192 MB (balon min 4096 bez zmian), zastosowane przy wyłączeniu VM przez właściciela. Pomiar `@ha` przez API Supervisora: kontenery ~2,4 GB, szacowany zestaw roboczy 3–3,5 GB, szczyt 4–4,5 GB; reszta 16 GB to pamięć podręczna gościa, którą host wypchnął do swapu (10,8 GB). Po restarcie swap procesu hassio 0, wolny swap hosta 1,0 → 11,7 GB, HA odpowiada po ~110 s. | `qm set 103 --memory 16384` i restart VM |
| 2026-11-06 | zswap `shrinker_enabled` Y → N (ta sama konfiguracja tmpfiles). Pierwsza noc z zswap: wszystkie strony zapisane na dysk (`pswpout`, 4 036 832) przeszły przez zswap i zostały z niego wypchnięte (`written_back_pages`, dokładnie tyle samo), przy `pool_limit_hit` = 0. Każde wybudzenie `kswapd` przez ZFS uruchamiało też moduł zwalniający zswap. Teraz zapis na dysk następuje dopiero po zapełnieniu puli (20% RAM). | `echo Y > /sys/module/zswap/parameters/shrinker_enabled`; kopia `/root/zswap.conf.bak-2026-11-06` |

### Dlaczego host przenosił pamięć do swapu przy wolnym RAM (2026-11-05)

Po pierwszym nocnym backupie z nowymi ustawieniami swap był zajęty w 98,8%, przy ~23 GB
wolnego RAM. W RRD widać było serie po 0,5–2,5 GB, nieregularnie, najczęściej o
xx:06–xx:12 i xx:37–xx:40, oraz w trakcie vzdump.

Pomiar co 5 s (`/proc/vmstat`) w trakcie serii: do swapu przenosi wyłącznie `kswapd`.
`pgscan_direct`, `allocstall_normal`, `compact_stall` i `thp_fault_alloc` wynosiły 0, a
wolny RAM przez cały czas 21–24 GB. Hipoteza o THP i wymuszonym kompaktowaniu odrzucona.

Ślad `vmscan:mm_vmscan_wakeup_kswapd` ze stosem wywołań (2 minuty w trakcie serii,
izolowana instancja `tracing`, usunięta po pomiarze) pokazał tylko dwa źródła wybudzeń:

1. ZFS (warstwa SPL): `spl_cache_grow_work → __vmalloc → alloc_pages`, rząd 8 (blok 1 MB),
   `GFP_ATOMIC`. W pofragmentowanej pamięci taki blok nie istnieje, każda próba budzi
   `kswapd`; odzyskuje on po ~2 MB i oddaje resztę kompaktowaniu.
2. Podbite progi (`get_page_from_freelist`, rząd 0, flagi `none`):
   `vm.watermark_boost_factor=15000` po zdarzeniach fragmentacji każe odzyskać do 150%
   progu `high` strefy Normal, czyli ~1,1 GB na cykl, niezależnie od wolnej pamięci.

Na hoście z ZFS zwykły cache plików jest prawie pusty (ARC nie jest page cache,
`Cached` 0,75 GB), więc `kswapd` odzyskuje niemal wyłącznie pamięć gości, czyli przenosi
ją do swapu, mimo `swappiness=10`. Podbijanie progów było źródłem dużych serii, dlatego
zostało wyłączone.

Pomiar po zmianie (45 min, 21:39–22:24 UTC) wobec 42 min przed nią: do swapu trafiło
702 MB zamiast ~2,5 GB (~3,5× mniej), a ze swapu wróciło 1434 MB, więc swap po raz
pierwszy netto maleje (wolne 2,91 → 3,47 GB). `kswapd` nadal odzyskuje pamięć seriami
po ~150–280 MB (np. 21:45, 21:52 UTC). Pozostałe źródło to wybudzenia z ZFS (SPL,
`__vmalloc` rzędu 8); w strefie Normal wolnych bloków rzędu 8 jest często tylko 3–20.

To znany błąd jądra 7.0 w połączeniu z OpenZFS 2.4.x:

- Od jądra 6.19 `vmalloc` najpierw próbuje dużych bloków (commit jądra `a0615780`,
  „mm/vmalloc: request large order pages from buddy allocator”) i przy każdej nieudanej
  próbie zostawia `__GFP_KSWAPD_RECLAIM`, więc budzi `kswapd`. Nie ma ustawienia, które
  to wyłącza. Proxmox przeszedł z jądra 6.17 na 7.0, stąd problem.
- SPL przydziela slaby `zio_buf_comb_*` (liniowe bufory ARC, slab ~1 MB, rząd 8) właśnie
  przez `vmalloc`.
- Zgłoszenia: OpenZFS [#18893](https://github.com/openzfs/zfs/issues/18893), Proxmox
  [bug 8278](https://bugzilla.proxmox.com/show_bug.cgi?id=8278).
- Poprawka: OpenZFS [PR #19276](https://github.com/openzfs/zfs/pull/19276), commit
  `a0c443a` (scalony 2026-10-19) — `kv_alloc()` zdejmuje `__GFP_KSWAPD_RECLAIM`. Stan na
  2026-11-05: nie ma jej w ZFS 2.4.4 ani w `2.4.5-staging`; łatka do pakietu Proxmoxa
  `zfsonlinux` jest na liście pve-devel od 2026-11-04.

**Docelowe rozwiązanie:** aktualizacja pakietu ZFS Proxmoxa zawierającego commit
`a0c443a`, potem restart hosta (wykonuje właściciel). Własny moduł przez DKMS odrzucony:
ZFS jest głównym systemem plików hosta. Do tego czasu zswap ogranicza skutki.

### Incydent 2026-11-06 23:18–23:26 UTC: brak CPU, nie pamięć

Restart `kube-apiserver` (talos1, talos2), `kube-scheduler` (talos3) i wszystkich
kontrolerów Flux; średnie opóźnienie zapytań apiservera do etcd 7,8–12 s. Tym razem
swap i iowait były w normie (zswap i `watermark_boost_factor=0` działały).

| Dowód | Wartość |
|---|---|
| CPU hosta (RRD) | 95–99% przez 23:10–23:28 UTC |
| VM Talos | razem ~17 rdzeni średnio, każda w szczycie ~8, na 20 wątkach hosta (3 × 18 vCPU) |
| Namespace `ci` | 20–35 rdzeni: ~16 `build-homebudget-*` i 2 `release-homebudget-*` naraz; każdy `*-test-web-pod` do ~9 rdzeni |
| Limity w `ci` | brak `ResourceQuota` i `LimitRange`; krok `vitest` miał request 2 rdzenie bez limitu |

Poprawka: `flux/infrastructure/tekton/ci/limits.yaml` — `LimitRange` (domyślny limit
4 rdzenie, domyślny request 250m na kontener) i `ResourceQuota` `requests.cpu: 10`
(~2 przebiegi testów naraz, reszta czeka w stanie `ExceededResourceQuota`). Otwarte:
skąd ~18 przebiegów naraz (seria pushy czy zdublowane wyzwalacze).

### Otwarte

- Weryfikacja po kilku nocnych backupach. Pierwsza noc (5.11): backup 16 min zamiast ~27,
  0 restartów, szczyt 99. percentyla opóźnienia apiservera do etcd 425 ms (3.11: 146 ms,
  4.11: 87 ms) — jedna noc nie przesądza.
- Czekamy na pakiet ZFS Proxmoxa z commitem `a0c443a` (śledzić bug 8278 i shortlog
  `zfsonlinux`). Po aktualizacji: restart hosta przez właściciela, potem można rozważyć
  wycofanie `vm.watermark_boost_factor=0` i zswap.
- Weryfikacja zswap po `shrinker_enabled=N` (2026-11-06, seria o 20:19 UTC): 337 MB
  trafiło do zswap, 0 stron zapisanych z zswap na dysk, 0 stron na `sde`; pula 121 MB
  trzyma ~305 MB (kompresja ~2,5:1); wolny swap na dysku wzrósł z 1,4 do 7,6 GB, bo
  goście wczytują stare strony. Do potwierdzenia przy nocnym vzdump.
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
