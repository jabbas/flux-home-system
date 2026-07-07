# Renovate + Version Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Design spec: `docs/plans/2026-07-06-renovate-version-pinning-design.md`.

**Goal:** Pin every HelmRelease chart version to the currently deployed release and wire up Mend Renovate (GitHub App) + a PR validation gate, so chart upgrades only ever happen via reviewed PRs.

**Architecture:** One-time exact `version:` pins in all HelmReleases (both repos) → `renovate.json` per repo (flux + helmv3 managers, no automerge) → GitHub Actions validation workflow rendering the full Flux tree (flux-local; fallback: yq+helm template script) → owner installs the Mend app.

**Tech Stack:** Flux v2 HelmReleases, Renovate (Mend cloud app), flux-local (allenporter), helm, yq, GitHub Actions.

**Deployed versions captured 2026-07-06 from the live cluster** (all HelmReleases Ready at capture time). If execution is delayed, re-verify with `flux get helmreleases -A` and update pins to whatever is deployed THEN.

---

### Task 1: Verify flux-local (decision gate for Task 4)

**Files:** none (verification only)

- [ ] **Step 1: Availability check**

Run: `uvx flux-local --version`
Expected: a version number. If uvx cannot install it, try `pipx run flux-local --version`. If neither works, record "flux-local UNAVAILABLE" and use the FALLBACK variant in Task 4.

- [ ] **Step 2: Render the real tree**

Run from repo root:
```bash
uvx flux-local test --enable-helm --path flux/cluster
```
Expected: PASS (exit 0) — it must handle: 12 HelmRepositories, the two local GitRepository-sourced wrapper charts (`./flux/infrastructure/authentik/chart`, `.../authentik-blueprints/chart`), and the cluster layout (no kustomization.yaml at `flux/cluster` root). Chart downloads require network. If it fails on repo-structure quirks that cannot be resolved with obvious flags (e.g. `--sources`), record the exact error and use the FALLBACK variant in Task 4.

- [ ] **Step 3: Negative control (the tool must catch the July 6 traefik bug)**

```bash
git stash list >/dev/null  # ensure clean state understanding
cp flux/infrastructure/traefik/release-internal.yaml /tmp/ri-backup.yaml
# reintroduce the known-bad pre-41.x block: replace the log/accessLog block with:
#     logs:
#       general:
#         level: ERROR
uvx flux-local test --enable-helm --path flux/cluster; echo "exit: $?"
cp /tmp/ri-backup.yaml flux/infrastructure/traefik/release-internal.yaml
git diff --stat  # must be empty
```
Expected: non-zero exit mentioning the schema error (`Additional property logs is not allowed`). If flux-local passes the broken values, it is NOT a valid gate → FALLBACK variant in Task 4.

- [ ] **Step 4: Record the verdict** — write down the exact working command line (or "FALLBACK") for Task 4.

---

### Task 2: Pin all HelmRelease versions (this repo)

**Files (13 modifications):** add `version: "<pin>"` under `spec.chart.spec` (directly after the `chart:` line); for grafana and descheduler REPLACE the existing wildcard `version:` line.

| File | Chart | Pin to |
|---|---|---|
| `flux/infrastructure/cloudnativepg/release.yaml` | cloudnative-pg | `0.29.0` |
| `flux/infrastructure/democratic-csi/release.yaml` | democratic-csi | `0.15.1` |
| `flux/infrastructure/snapshot-controller/release.yaml` | snapshot-controller | `0.3.0` |
| `flux/infrastructure/grafana/release.yaml` | grafana | `8.15.0` (replace `8.*`) |
| `flux/infrastructure/descheduler/release.yaml` | descheduler | `0.35.1` (replace `0.35.*`) |
| `flux/infrastructure/metrics-server/release.yaml` | metrics-server | `3.13.1` |
| `flux/infrastructure/reflector/release.yaml` | reflector | `10.0.56` |
| `flux/infrastructure/sealed-secrets/release.yaml` | sealed-secrets | `2.19.1` |
| `flux/infrastructure/metallb/release/release.yaml` | metallb | `0.16.1` |
| `flux/infrastructure/traefik/release-external.yaml` | traefik | `41.0.2` |
| `flux/infrastructure/traefik/release-internal.yaml` | traefik | `41.0.2` |
| `flux/infrastructure/victoria-metrics/prometheus-crds.yaml` | prometheus-operator-crds | `30.0.1` |
| `flux/infrastructure/victoria-metrics/release.yaml` | victoria-metrics-k8s-stack | `0.85.10` |

Do NOT touch `authentik/release.yaml` and `authentik-blueprints/release.yaml` (local Git-sourced charts, pinned via Chart.lock).

- [ ] **Step 1: Pre-check for drift**

Run: `flux get helmreleases -A`
Expected: every REVISION matches the "Pin to" column above (ignore the two `0.1.0+<sha>` local charts and the flux-homeapps ones: httpbin, headlamp, firecrawl). If ANY differs, update the table/pins to the live value before editing.

- [ ] **Step 2: Apply the 13 edits**

Each edit has this shape (example, cloudnativepg):
```yaml
  chart:
    spec:
      chart: cloudnative-pg
      version: "0.29.0"
      reconcileStrategy: ChartVersion
```

- [ ] **Step 3: Validate**

Run: `yamllint flux/` (expect clean) and the Task 1 validation command (expect PASS — pins match deployed, so rendering must succeed).

- [ ] **Step 4: Commit + push**

```bash
git add flux/infrastructure
git commit -m "feat(flux): pin all HelmRelease chart versions to deployed releases"
git push
```

- [ ] **Step 5: Verify cluster no-op**

```bash
flux -n flux-system reconcile kustomization flux-system --with-source
flux get helmreleases -A
```
Expected: all Ready, REVISION values unchanged, no upgrades triggered (pins == deployed). Any HelmRelease attempting an upgrade means a wrong pin — STOP and fix.

---

### Task 3: Renovate configuration (this repo)

**Files:** Create: `renovate.json` (repo root)

- [ ] **Step 1: Write `renovate.json`**

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":dependencyDashboard"
  ],
  "timezone": "Europe/Warsaw",
  "flux": {
    "managerFilePatterns": ["/^flux/.+\\.ya?ml$/"]
  },
  "helmv3": {
    "managerFilePatterns": ["/^flux/.+/chart/Chart\\.ya?ml$/"]
  },
  "packageRules": [
    {
      "matchManagers": ["flux", "helmv3"],
      "automerge": false
    },
    {
      "matchUpdateTypes": ["major"],
      "labels": ["dependencies", "major"]
    },
    {
      "matchUpdateTypes": ["minor", "patch"],
      "labels": ["dependencies"]
    },
    {
      "matchDepNames": ["traefik"],
      "groupName": "traefik"
    }
  ]
}
```
(The traefik group makes both HelmReleases bump in ONE PR — they must move together.)

- [ ] **Step 2: Validate the config**

Run: `npx --yes --package renovate renovate-config-validator renovate.json`
Expected: "Config validated successfully". If it flags renamed/unknown keys (Renovate config schema moves fast — e.g. `managerFilePatterns` vs legacy `fileMatch`), adjust per the validator's message and re-run until clean.

- [ ] **Step 3: Commit + push**

```bash
git add renovate.json
git commit -m "feat: add Renovate configuration (flux + helmv3 managers, no automerge)"
git push
```

---

### Task 4: PR validation workflow

**Files:** Create: `.github/workflows/validate.yaml` (+ `scripts/validate-helm.sh` only in FALLBACK variant)

- [ ] **Step 1: Write the workflow — PRIMARY variant (flux-local verified in Task 1)**

```yaml
---
name: validate
on:
  pull_request:
    paths:
      - "flux/**"
      - ".github/workflows/validate.yaml"
jobs:
  flux-local-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: flux-local test
        uses: docker://ghcr.io/allenporter/flux-local:latest
        with:
          args: test --enable-helm --path /github/workspace/flux/cluster
```
Adjust `args`/entrypoint to the exact command recorded in Task 1 Step 4 if it differs.

**FALLBACK variant** (only if Task 1 said FALLBACK): create `scripts/validate-helm.sh`:
```bash
#!/usr/bin/env bash
# Render every pinned HelmRelease against its chart repo — schema/template gate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
declare -A REPOS=(
  [authentik]="https://charts.goauthentik.io/"
  [cloudnativepg]="https://cloudnative-pg.github.io/charts"
  [democratic-csi]="https://democratic-csi.github.io/charts"
  [descheduler]="https://kubernetes-sigs.github.io/descheduler/"
  [grafana]="https://grafana.github.io/helm-charts"
  [metallb]="https://metallb.github.io/metallb"
  [metrics-server]="https://kubernetes-sigs.github.io/metrics-server"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [reflector]="https://emberstack.github.io/helm-charts"
  [sealed-secrets]="https://bitnami.github.io/sealed-secrets"
  [traefik]="https://traefik.github.io/charts"
  [victoria-metrics]="https://victoriametrics.github.io/helm-charts"
)
fail=0
while IFS= read -r f; do
  chart=$(yq '.spec.chart.spec.chart' "$f")
  [[ "$chart" == ./* || "$chart" == "null" ]] && continue
  version=$(yq '.spec.chart.spec.version' "$f")
  repo=$(yq '.spec.chart.spec.sourceRef.name' "$f")
  url="${REPOS[$repo]:-}"
  if [[ -z "$url" ]]; then echo "SKIP (unknown repo $repo): $f"; continue; fi
  vals=$(mktemp); yq '.spec.values // {}' "$f" > "$vals"
  if helm template x "$chart" --repo "$url" --version "$version" -f "$vals" > /dev/null 2>/tmp/err.$$; then
    echo "OK:   $f ($chart@$version)"
  else
    echo "FAIL: $f ($chart@$version)"; sed 's/^/      /' /tmp/err.$$; fail=1
  fi
  rm -f "$vals"
done < <(grep -rl "kind: HelmRelease" flux/ --include="*.yaml")
exit $fail
```
`chmod +x scripts/validate-helm.sh`; workflow then runs `./scripts/validate-helm.sh` on ubuntu-latest after installing helm+yq (`uses: azure/setup-helm@v4`, `sudo snap install yq` or mikefarah/yq download).

- [ ] **Step 2: Commit + push**

```bash
git add .github/workflows/validate.yaml scripts/ 2>/dev/null || git add .github/workflows/validate.yaml
git commit -m "feat(ci): add PR validation gate rendering the Flux tree"
git push
```

- [ ] **Step 3: Negative-control PR (the gate must go red)**

```bash
git checkout -b test/validate-gate
# reintroduce the bad traefik block in release-internal.yaml (logs: general: level: ERROR)
git commit -am "test: negative control for validation gate" && git push -u origin test/validate-gate
gh pr create --fill
```
Wait for the workflow run: `gh pr checks --watch`
Expected: **FAILURE** on the validate job. Then clean up:
```bash
gh pr close test/validate-gate --delete-branch
git checkout main && git branch -D test/validate-gate
```
If the check came back GREEN on broken values: STOP — the gate is worthless; debug before proceeding.

---

### Task 5: AGENTS.md update

**Files:** Modify: `AGENTS.md`

- [ ] **Step 1: Add to the "Helm patterns" section**

```markdown
- **Chart versions are pinned** (exact `version:` in every HelmRelease). Upgrades arrive as
  Renovate PRs — review the changelog, check the `validate` workflow status, merge. Never
  remove a pin. To upgrade manually, change the pin in a PR.
- Wrapper chart dependency bumps (authentik) are two-step: Renovate PRs the `Chart.yaml`
  change; before merging run `helm dependency update` in the chart dir and commit the
  updated `Chart.lock` + `charts/*.tgz` to the same PR.
- Validate chart rendering locally: `uvx flux-local test --enable-helm --path flux/cluster`
  (or `./scripts/validate-helm.sh` if present) — same gate as the PR workflow.
```
(Use the variant matching Task 1's verdict; drop the parenthetical that doesn't apply.)

- [ ] **Step 2: Commit + push**

```bash
git add AGENTS.md
git commit -m "docs: document Renovate/pinning conventions in AGENTS.md"
git push
```

---

### Task 6: flux-homeapps repo

**Files (in the OTHER repo):** locate checkout at `~/Projects/flux-homeapps`; if absent: `git clone git@github.com:jabbas/flux-homeapps.git ~/Projects/flux-homeapps`.

- [ ] **Step 1: Inventory HelmReleases there**

Run: `grep -rl "kind: HelmRelease" . --include="*.yaml"` and inspect each.
Known from the cluster: `httpbin` (chart httpbin@1.0.0, repo https://jabbas.github.io/chart-httpbin/, currently unpinned), `headlamp` (0.39.0 — already exactly pinned), `firecrawl` (local chart — skip).

- [ ] **Step 2: Pin httpbin** — add `version: "1.0.0"` under its `spec.chart.spec`. Pin anything else found unpinned to its deployed version (`flux get helmreleases -A` is the source of truth).

- [ ] **Step 3: Add `renovate.json`** — same content as Task 3 but with manager patterns matching that repo's layout (check actual top-level dirs, likely `applications/`, `internal-apps/`, `demos/`):
```json
"flux":   { "managerFilePatterns": ["/\\.ya?ml$/"] },
"helmv3": { "managerFilePatterns": ["/chart/Chart\\.ya?ml$/"] }
```
Run the validator (Task 3 Step 2 command).

- [ ] **Step 4: Commit + push** (that repo's commit conventions — check `git log --oneline -5` there first):

```bash
git add renovate.json <pinned files>
git commit -m "feat: pin HelmRelease versions and add Renovate config"
git push
```

- [ ] **Step 5: Verify cluster no-op** — `flux get helmreleases -A`: httpbin stays Ready at 1.0.0.

---

### Task 7: Owner activation + end-to-end verification

- [ ] **Step 1 (OWNER, manual):** Install the Mend Renovate GitHub App: https://github.com/apps/renovate → Install → select repositories `jabbas/flux-home-system` and `jabbas/flux-homeapps`.

- [ ] **Step 2: Watch activation** — because `renovate.json` already exists, Renovate skips onboarding and scans directly. Within ~an hour expect: a "Dependency Dashboard" issue in each repo listing all detected charts.

Verify detection coverage: the dashboard must list all 13 pinned charts (+ httpbin, headlamp, + authentik Chart.yaml deps). If a chart is missing → the manager file patterns in renovate.json need adjusting (open a fix PR).

- [ ] **Step 3: First real PR** — when the next upstream chart release lands, verify the PR: changelog attached, `validate` check runs and is green, no automerge happens. Merge it manually. Flux deploys. Done — the loop is closed.

---

## Explicitly NOT in this plan (future options, documented in the design)

- Patch-level automerge (`"matchUpdateTypes": ["patch"], "automerge": true` gated on the validate check).
- Talos / Flux version tracking via customManagers regex.
- Container image pinning.
