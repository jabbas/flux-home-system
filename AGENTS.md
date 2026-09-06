# AGENTS.md

Talos Kubernetes home lab, GitOps-managed. Ansible bootstraps Proxmox VMs + Talos + Flux once; after that **everything deploys by pushing to `main`** — Flux reconciles from Git. No CI in this repo; lint locally.

## Two-repo layout

- **This repo** (`flux-home-system`): cluster bootstrap + infrastructure. Flux entrypoint is `./flux/cluster` (set in `bootstrap/provision/05_provision_job.yaml`).
- **`jabbas/flux-homeapps`** (GitRepository `home-applications`): end-user apps, wired in via `flux/cluster/{applications,internal-apps,demos}.yaml`. App changes belong there, not here.

## Map

- `flux/cluster/` — top-level Flux Kustomizations. `flux-system/gotk-*.yaml` are Flux-generated: do not edit.
- `flux/cluster/infrastructure.yaml` — the dependency graph (source of truth for ordering). Gist: `sources` → everything; `sealed-secrets` + `snapshot-controller` → `democratic-csi` → `cloudnativepg` → `authentik` → `victoria-metrics` → `grafana`; `traefik` needs `metallb-config`.
- `flux/infrastructure/<component>/` — one dir per component (`kustomization.yaml`, `namespace.yaml`, `release.yaml`).
- `bootstrap/` — Ansible (`site.yaml`) creates VMs 401–403 on `pve.home`, installs Talos, then an in-cluster Job runs `flux bootstrap`. Talos version + schematic pinned in `bootstrap/site.yaml`.
- `docs/plans/` — design/implementation docs named `YYYY-MM-DD-<topic>-{design,implementation}.md`.

## Commands

The live cluster is reachable from this machine (`kubectl`, `flux` work directly).

```bash
yamllint .                            # max line 200 (warning); config in .yamllint
ansible-lint                          # run in bootstrap/; skip list in .ansible-lint
flux build kustomization <name> --path ./flux/infrastructure/<name>  # render locally
flux get kustomizations -A            # cluster state
flux -n flux-system reconcile kustomization flux-system --with-source  # force sync after push
kubectl apply --dry-run=client -f <file>
```

Full bootstrap / teardown: see `README.md`. Short version:

```bash
cd bootstrap
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done
uv sync && source .venv/bin/activate
ansible-playbook site.yaml
```

## Adding an infrastructure component

Three touchpoints, all required:

1. `flux/infrastructure/<name>/` with `kustomization.yaml` (+ `namespace.yaml`, `release.yaml`)
2. HelmRepository in `flux/infrastructure/sources/<name>.yaml` **and** an entry in `sources/kustomization.yaml`
3. Flux Kustomization block in `flux/cluster/infrastructure.yaml` with correct `dependsOn`

## Helm patterns

- **Wrapper chart** when an upstream chart needs extra resources (see `authentik/`, `authentik-blueprints/`): local chart at `flux/infrastructure/<app>/chart/` with upstream as dependency in `Chart.yaml`, custom templates alongside; HelmRelease points at `chart: ./flux/infrastructure/<app>/chart` with GitRepository `flux-system` sourceRef and `reconcileStrategy: Revision`.
- **`Chart.lock` and `charts/*.tgz` are committed.** After changing chart dependencies, run `helm dependency update` in the chart dir and commit the tgz.
- Nontrivial HelmReleases use `interval: 30m`, `timeout: 15m`, install/upgrade `remediation.retries: 3`. Apps with RWO PVCs need `deploymentStrategy: Recreate` / `recreatePods: true` to avoid Multi-Attach deadlocks (see grafana).
- **Chart versions are pinned** (exact `version:` in every HelmRelease). Upgrades arrive as Renovate PRs — review the changelog, check the `validate` workflow, merge. Never remove a pin; to upgrade manually, change the pin in a PR.
- Wrapper chart dependency bumps (authentik) are two-step: Renovate PRs the `Chart.yaml` change; before merging run `helm dependency update` in the chart dir and commit the updated `Chart.lock` + `charts/*.tgz` to the same PR.
- Validate chart rendering locally (same gate as CI): `uvx flux-local test --enable-helm --path flux/cluster --sources flux-system` (needs `kustomize` installed).

## Talos machine config patches

`bootstrap/patch/*.yaml` are **Talos 1.14 multi-document configs**, not the old monolithic
`v1alpha1` machine config. Talos 1.14 split `v1alpha1` into ~30 separate documents, so each
patch now carries its own `apiVersion: v1alpha1` + `kind:` (`KubeNodeConfig`,
`KubeAPIServerConfig`, `KubeAuthenticationConfig`, `ResolverConfig`, `TimeSyncConfig`,
`SysctlConfig`, `RegistryTLSConfig`) and targets that document only. The installer image is
**not** a patch — it is a `--install-image` flag on `talosctl gen config`, because any patch
touching `UnattendedInstallConfig` wipes `provisioning.diskSelector` even when it does not
mention it.

**The `-p @patch/…` list in `roles/initialize_talos_configuration/tasks/main.yaml` is the
source of truth for what actually gets applied — not the contents of `bootstrap/patch/`.**
The directory also holds two files that nothing references: `proxy-ipvs-mode.yaml` (still in
the legacy `cluster.proxy` format) and `provision-secret.yaml` (+ `.age`, a manifest that
landed in the wrong directory). They are deliberately left in place; seeing an unmigrated
file next to the eight live ones does not mean the migration is unfinished.

Four traps that are not visible in the files themselves:

- **`Unstructured` fields are replaced wholesale, not merged.**
  `KubeAuthenticationConfig.configuration` is one, so the `anonymous` block with `/livez`,
  `/readyz` and `/healthz` must be repeated in the patch. Drop it and those endpoints simply
  disappear — `talosctl validate` will not notice, because it does not inspect `Unstructured`
  content semantically.
- **Lists append, they do not replace.** Applying `nameservers.yaml` twice yields four
  nameservers and still validates. The playbook regenerates the config with `--force` on every
  run, so bootstrap is safe, but these patches must only ever be applied to a **freshly
  generated** config — never with `talosctl patch` against a live node.
- **`$patch: delete` is not idempotent.** It fails hard when its target is already gone, which
  is the same freshness requirement seen from the other side.
- **Both `KubeNodeConfig` patches are control-plane-only.** `allow-scheduling.yaml` deletes the
  control-plane taint, which a worker never has, so it dies with `lookup failed` on
  `worker.yaml`. This is moot today: the playbook applies `controlplane.yaml` to all three
  nodes and `worker.yaml` is unused. **If workers are ever added, both `KubeNodeConfig`
  patches have to be scoped to control-plane nodes.**

## Secrets

- Bootstrap secrets: age-encrypted `*.age` files decrypted in place (`age -d -i ~/.ssh/jabbas f.age > f`); encrypt with `age -R ~/.ssh/key.pub`. Decrypted copies sit in the working tree — never commit them (`.gitignore` covers `*secret.yaml`, `talosconfig`, `controlplane.yaml`, `worker.yaml`, `secrets.yaml`).
- `bootstrap/secrets.yaml` (Talos cluster PKI) is the exception: no `.age` counterpart, generated by the playbook (`talosctl gen secrets`) when absent and never overwritten when present. Losing it means the next bootstrap creates a *new* cluster identity.
- In-cluster: Sealed Secrets. The keypair is restored from `bootstrap/provision/00_sealed_secrets-secret.yaml.age` during bootstrap, so existing SealedSecrets survive cluster rebuilds — never regenerate that key.
- Secrets needed across namespaces (CA cert, OAuth creds): `flux/infrastructure/shared-secrets/` + reflector annotations.

## Authentik blueprints

Adding a service behind Authentik forwardAuth takes three edits, and missing either of the last two fails silently:

1. New blueprint template in `flux/infrastructure/authentik-blueprints/chart/templates/` (copy `blueprint-tekton.yaml`).
2. **Register the ConfigMap** in `blueprints.configMaps` in `flux/infrastructure/authentik/chart/values.yaml` — the worker mounts only blueprints from that explicit list; unregistered ones render into the cluster and are simply never loaded.
3. **Add the proxy provider to `blueprint-outpost.yaml`** — that single shared blueprint owns the embedded outpost's provider list, and `attrs.providers` overwrites rather than appends. A provider missing from it is unknown to the outpost and its host returns errors.

Known wrinkle: on a fresh cluster bootstrap `blueprint-outpost.yaml` may apply before the provider blueprints exist, so it lands in `error` until authentik's next discovery pass. It self-heals; don't hand-fix it in the UI. Diagnose blueprints from the **worker** pod (`kubectl -n authentik exec deploy/authentik-stack-worker -- ls /blueprints/mounted/`) — the server pod has no blueprints mounted.

## Conventions

- Commits: conventional style with component scope — `fix(victoria-metrics): ...`, `feat(bootstrap): ...`, `docs: ...`.
- YAML: 2-space indent, `---` at file start. Files kebab-case (`release-internal.yaml`); Ansible vars snake_case; Helm values camelCase.
- Use Context7 MCP for Helm/Kubernetes/Flux/Ansible docs when generating config.

## Cluster facts

- Endpoint `https://kube.home:6443`, cluster `k8s`, 3 control-plane nodes `talos1-3` (Proxmox VMIDs 401–403 on `pve.home`).
- Talos pinned in `bootstrap/site.yaml` (currently 1.14.0; extensions: iscsi-tools, qemu-guest-agent, util-linux-tools). The pin is what a *fresh* bootstrap installs — the live nodes still run 1.13.5.
- Ingress classes `traefik-internal` / `traefik-external`; services at `*.dev.home`; OIDC via Authentik (`authentik.dev.home`); storage class `zfs-nfs-csi` via democratic-csi (driver config is a SealedSecret).
