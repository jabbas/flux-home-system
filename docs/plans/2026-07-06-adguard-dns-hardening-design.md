# AdGuard / DNS hardening — decyzja i plan (odłożony)

> Status: **DO DECYZJI** — wątek sieciowy (router), niezależny od klastra i od wątku Renovate/pinów.
> Wykonanie: ręcznie na OPNsense/AdGuard (zmiany na routerze nie są w IaC tego repo).

## Kontekst — incydent 2026-07-06

Podczas rolling upgrade'u Talosa 1.13.2→1.13.5 węzeł talos2 utknął na ~40 min:
etcd nie mógł ściągnąć obrazu `registry.k8s.io/etcd:v3.6.12`.

**Łańcuch przyczynowy (udowodniony digami):**
1. Upstream DNSCrypt (`dnscrypt.pl`) zwrócił **fałszywy NXDOMAIN** dla
   `prod-registry-k8s-io-eu-central-1.s3.dualstack.eu-central-1.amazonaws.com`
   (host blobów registry.k8s.io; 1.1.1.1 i lokalny Unbound rozwiązywały poprawnie).
2. AdGuard **zakeszował negatywną odpowiedź** i serwował ją wszystkim klientom.
3. Talos host-dns (127.0.0.53 na węzłach) ma **własny negative cache** (TTL ≤900 s
   z SOA MINIMUM) — po naprawie AdGuarda węzeł potrzebował jeszcze ~11 min.
4. To NIE była blocklista: `check_host` → `NotFilteredNotFound`. Czysty zatruty cache.

Podejrzenie, że problemy z Apple App Store mają tę samą przyczynę: **niepotwierdzone**
w sondzie z 2026-07-06 ~01:30 (8 domen Apple czystych na wszystkich trzech resolverach),
ale awaria jest z natury przejściowa — patrz playbook diagnostyczny niżej.

## Topologia obecna

```
klienci/węzły → AdGuard Home 10.1.255.2:53 (UI: http://vgate.home:3000, bez auth)
                  ├── strefa .home        → Unbound 10.1.255.2:5335
                  └── cała reszta         → DNSCrypt (dnscrypt.pl)
Talos nodes: nameservers = [10.1.255.2, 1.1.1.1] (bootstrap/patch/nameservers.yaml)
```

## Kluczowe zrozumienie mechanizmu

**Fallback i parallel upstreams NIE chronią przed kłamiącym resolverem.**
NXDOMAIN to formalnie poprawna odpowiedź DNS:
- failover (10.1.255.2 → 1.1.1.1 na węzłach; fallback w AdGuardzie) odpala się tylko
  przy timeout/unreachable — nigdy przy NXDOMAIN/SERVFAIL-jako-odpowiedź,
- w trybie parallel kłamstwo może wygrać wyścig.

Dlatego rozwiązaniem jest zmiana topologii zaufania, nie dokładanie równoległych
upstreamów ani reguły per-domena (walka z hydrą — dziś AWS, jutro Apple).

## Opcje

### Opcja A — AdGuard → Unbound jako jedyny upstream (REKOMENDOWANA)
W AdGuard: Upstream DNS servers = `10.1.255.2:5335` (tylko). dnscrypt.pl wylatuje.
- Filtrowanie w AdGuardzie, pełna czysta rekursja w Unboundzie (QNAME minimization).
- Zero pośrednika, któremu trzeba ufać; dowód działania: podczas incydentu Unbound
  rozwiązywał poprawnie wszystko, co dnscrypt.pl psuł.
- Koszt: zapytania jawnym DNS do serwerów autorytatywnych (ISP widzi ruch DNS
  z routera; łagodzone przez QNAME minimization).

### Opcja B — wymiana dnscrypt.pl na DoT/DoH do Quad9/Cloudflare
Jeśli szyfrowanie DNS przed ISP jest priorytetem. Przenosi zaufanie na innego
operatora; nie eliminuje klasy problemu (upstream nadal może kłamać), ale zmienia
track record dostawcy.

### Opcja C — reguły per-domena `[/amazonaws.com/]10.1.255.2:5335` (ODRZUCONA)
Działa tylko na znane ofiary; każda kolejna awaria = nowa reguła po fakcie.

### Mitygacje dodatkowe (niezależne od A/B)
- AdGuard: Settings → DNS → sprawdzić/nie podbijać "Override minimum TTL" i
  ograniczyć serwowanie z cache — skraca życie ewentualnego zatrucia.
- Świadomość warstwy 3: węzły Talos cache'ują negatywy do 15 min — po każdej
  naprawie DNS dać klastrowi kwadrans zanim uzna się fix za nieskuteczny.

## Checklist wykonawczy (Opcja A, ~5 min na routerze)

- [ ] AdGuard UI → Settings → DNS settings → Upstream DNS servers:
      zastąpić wpis dnscrypt.pl przez `10.1.255.2:5335`
      (wpis `[/home/]10.1.255.2:5335` może zostać lub zniknąć — będzie redundantny)
- [ ] Zapisać, Clear DNS cache
- [ ] Weryfikacja:
      `dig @10.1.255.2 registry.k8s.io` → NOERROR
      `dig @10.1.255.2 prod-registry-k8s-io-eu-central-1.s3.dualstack.eu-central-1.amazonaws.com` → NOERROR
      `dig @10.1.255.2 apps.apple.com` → NOERROR
- [ ] Obserwacja przez kilka dni: czy problemy z App Store ustały

## Playbook diagnostyczny na nawrót (odpalić W TRAKCIE awarii)

```bash
H=<problematyczny-host>
dig @10.1.255.2 $H +time=3 +tries=1          # co serwuje AdGuard
dig -p 5335 @10.1.255.2 $H +time=3 +tries=1  # co mówi czysty Unbound
dig @1.1.1.1 $H +time=3 +tries=1             # referencja publiczna
# rozjazd AdGuard vs reszta = zatruty cache/upstream; zgodne NXDOMAIN wszędzie = host naprawdę nie istnieje
curl -s "http://vgate.home:3000/control/filtering/check_host?name=$H"   # czy to filtr (NotFilteredNotFound = nie)
```

## Powiązane, ale OSOBNE wątki (nie mieszać z tym dokumentem)

- Renovate + piny wersji HelmRelease — wątek repo/GitOps, osobny plan.
- CNPG scheduled backup (barmanObjectStore) — polisa na dane Postgresa, osobny wątek.
