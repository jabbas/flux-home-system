# Renovate + Helm Version Pinning — Design

> Status: APPROVED (2026-07-06). Companion implementation plan: to be written
> (`2026-07-06-renovate-version-pinning-implementation.md`).
> Separate track from AdGuard/DNS hardening (see 2026-07-06-adguard-dns-hardening-design.md).

## Context / Motivation

On 2026-07-06 three independent chart-related failures hit the cluster in one evening:

1. **sealed-secrets**: HelmRepository URL died (upstream org move) — blocked 20/21 Kustomizations via `sources` `wait: true`.
2. **traefik**: chart 41.0.1 released with a breaking values schema (`logs` → `log`/`accessLog`); auto-picked-up because no version pin → HelmRelease upgrade failures on the live ingress.
3. **victoria-metrics-k8s-stack**: chart 0.85.10 broke legacy `defaultRules.rules` boolean syntax; same root cause — no pin.

Root pattern: **almost no HelmRelease pins a chart version** (`reconcileStrategy: ChartVersion`
with no `version:` = track latest). Every upstream release deploys itself to the cluster,
unreviewed, at arbitrary times. Exceptions today: grafana (`version: "8.*"`, still floating
within major) and the authentik wrapper charts (effectively pinned via committed `Chart.lock`
+ vendored `charts/*.tgz`).

## Goals

- No chart upgrade ever reaches the cluster without a human-reviewed Git commit.
- Stay current: automated PRs with changelogs for every new chart version.
- Catch breaking values schemas **before merge**, not on the cluster.

## Non-Goals (deliberately deferred)

- Talos / Flux version tracking via Renovate regex managers (add later once the bot is settled).
- Automerge of any kind (config switch documented, disabled).
- Container image digest pinning.
- CI beyond the single validation workflow.

## Decisions (approved by owner)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Renovate hosting | **Mend Renovate GitHub App** (cloud). Revised from initial self-hosted preference after review; accepted trade-off: no `postUpgradeTasks`. |
| 2 | Pinning | Exact `version:` in every HelmRelease, set to the **currently deployed** versions (read from the live cluster at implementation time). |
| 3 | Scope | HelmRelease chart versions in **both repos** (`flux-home-system`, `flux-homeapps`) + wrapper chart `Chart.yaml` dependencies (helmv3 manager). |
| 4 | Automerge | **None.** Every PR is reviewed manually. (Future option: patch-level automerge gated on the validation check — one line in renovate.json, documented but off.) |
| 5 | Validation gate | **flux-local** rendering the whole Flux tree (incl. HelmReleases) as a GitHub Actions check on PRs + runnable locally with the same command. Fallback if flux-local proves unfit: plain `yq`+`helm template` script (method battle-tested during the 2026-07-06 incidents). |

## Architecture

```
Mend Renovate App (cloud)
  └── scans both repos on schedule
  └── opens PR per chart update (grouped per chart, changelog attached)
        └── GitHub Actions: flux-local test/diff  → status check on PR
              └── human reviews changelog + rendered diff + check status → merge
                    └── Flux deploys (unchanged pipeline)
```

### Components

1. **`renovate.json`** (repo root, both repos)
   - `flux` manager: detects HelmRelease `version:` + HelmRepository sources under `flux/**`.
   - `helmv3` manager: wrapper chart `Chart.yaml` dependencies (authentik, authentik-blueprints).
   - packageRules: group patch/minor/major labels; `automerge: false` everywhere.
   - Onboarding: the app opens an onboarding PR first; merge activates scanning.

2. **Version pins** — one-time change: add exact `version:` to every HelmRelease in
   `flux/infrastructure/**` (and later flux-homeapps). Grafana's `"8.*"` becomes exact.
   Authentik wrapper charts stay as-is (Chart.lock already pins; Renovate bumps
   `Chart.yaml`, human runs `helm dependency update` + commits the tgz — procedure
   goes into AGENTS.md).

3. **Validation workflow** — `.github/workflows/validate.yaml`: on pull_request,
   run flux-local against `flux/cluster` (renders Kustomizations + HelmReleases with
   real chart downloads; fails on schema/template errors). Must be verified in the
   first implementation task, including a **negative control**: the workflow must go
   red when fed the known-bad traefik 40.x `logs:` values against chart 41.x.

4. **AGENTS.md updates** — validation command, wrapper-chart `helm dependency update`
   procedure, "chart upgrades arrive as Renovate PRs" convention.

### Owner-side (manual, outside repo)

- Install the Mend Renovate GitHub App and grant it `flux-home-system` + `flux-homeapps`.

## Edge Cases / Risks

- **Wrapper chart PRs are two-step** (Chart.yaml bump by bot, `helm dependency update`
  by human) — documented; low frequency.
- **flux-local unknown-unknowns** (SOPS? local GitRepository chart paths? — repo uses a
  same-repo GitRepository chart source for authentik): verified in implementation task 1;
  fallback script keeps the design valid regardless.
- **Renovate needs HelmRepository reachability** to see new versions — a dead repo URL
  (incident #1 class) surfaces as a stale dependency dashboard, not a blocked cluster. Good.
- **flux-homeapps** is a separate repo not inspected during this design; its pinning task
  executes in that repo's checkout and may surface its own quirks.

## Success Criteria

- Every HelmRelease in both repos has an exact `version:`.
- Renovate dependency dashboard lists all tracked charts; a test PR appears for the next
  upstream release.
- Validation workflow: green on main, **red on the negative-control PR**.
- No spontaneous chart upgrades on the cluster from this point on.
