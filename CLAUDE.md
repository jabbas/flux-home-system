# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a home lab Kubernetes infrastructure repository using:
- **Talos Linux** as the Kubernetes distribution (immutable, secure OS)
- **Flux CD** for GitOps-based continuous delivery
- **Ansible** for initial cluster bootstrapping on Proxmox VE

## Architecture

### Deployment Flow

```
Proxmox VE (Hypervisor)
    ↓ Ansible (bootstrap/)
Talos Linux VMs (3x control plane: 401-403)
    ↓ talosctl bootstrap
Kubernetes Cluster (kube.home:6443)
    ↓ Flux reconciliation
Infrastructure Stack (flux/infrastructure/):
    sources → metallb → traefik → cloudnativepg → authentik
    ↓
User Applications (external repo: flux-homeapps)
```

### Directory Structure

- `bootstrap/` - Ansible playbooks and roles for initial cluster setup
  - `roles/create_controlpanes/` - Creates Talos VMs on Proxmox
  - `roles/initialize_talos_configuration/` - Generates and applies Talos configs, bootstraps cluster, provisions Flux
  - `patch/` - Talos machine configuration patches (allow-scheduling, oidc, proxy-ipvs-mode, etc.)
  - `provision/` - Initial Kubernetes manifests applied in sorted order (00_, 01_, etc.)
- `flux/` - Flux CD GitOps manifests
  - `cluster/` - Top-level Flux Kustomizations defining deployment order via `dependsOn`
  - `cluster/internal-apps.yaml` - References external repo `flux-homeapps` for user applications
  - `infrastructure/` - Core infrastructure components (HelmReleases, namespaces)
  - `infrastructure/sources/` - HelmRepository definitions for all charts
  - `infrastructure/authentik/` - Authentik identity provider (wrapper chart with CNPG database)
  - `infrastructure/authentik-blueprints/` - OIDC flow blueprints (deployed before Authentik)

### Flux Dependency Chain

Dependencies in `flux/cluster/infrastructure.yaml` define deployment order:
1. `sources` → All HelmRepositories
2. Depend on `sources` only: `metrics-server`, `metallb-release`, `sealed-secrets`, `snapshot-controller`, `reflector`, `authentik-blueprints`
3. `metallb-config` → `sources` + `metallb-release`
4. `democratic-csi` → `sources` + `sealed-secrets` + `snapshot-controller`
5. `traefik` → `sources` + `sealed-secrets` + `metallb-config`
6. `cloudnativepg` → `sources` + `snapshot-controller` + `democratic-csi`
7. `authentik` → `sources` + `cloudnativepg` + `traefik` + `reflector` + `authentik-blueprints`
8. `internal-apps` (in `flux/cluster/internal-apps.yaml`) → `traefik` + `authentik` (references external repo: `flux-homeapps`)

### Helm Chart Wrapper Pattern

For applications requiring additional Kubernetes resources beyond what the upstream chart provides, use a wrapper chart:
- Create a local chart in `flux/infrastructure/<app>/chart/` with upstream chart as dependency in `Chart.yaml`
- Add custom templates (e.g., `database.yaml` for CloudNativePG clusters, `secrets.yaml` for auto-generated secrets)
- Reference the chart from HelmRelease using GitRepository source with path to chart directory
- Example: Authentik uses this pattern (`flux/infrastructure/authentik/chart/`) with CNPG database
- Blueprints are deployed separately in `flux/infrastructure/authentik-blueprints/`

### Infrastructure Components

Deployed via HelmReleases:
- **MetalLB** - Load balancer for bare metal (release + config separated)
- **Traefik** - Ingress controller (internal + external instances)
- **Sealed Secrets** - Encrypted secrets management
- **CloudNativePG** - PostgreSQL operator
- **Democratic-CSI** - Storage provisioner (ZFS on Proxmox)
- **Snapshot Controller** - Volume snapshots
- **Metrics Server** - Resource metrics
- **Reflector** - Secret/ConfigMap replication across namespaces
- **Authentik** - Identity provider (wrapper chart with CNPG database)
- **Authentik Blueprints** - OIDC configuration blueprints (separate deployment, depends on Authentik)

## Common Commands

### Bootstrap a New Cluster

```bash
cd bootstrap

# Decrypt age-encrypted secrets
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done

# Run the playbook (requires Python venv with ansible)
ansible-playbook site.yaml
```

### Secret Encryption

```bash
# Encrypt with age
age -R ~/.ssh/key.pub flux-system-secret.yaml >flux-system-secret.yaml.age

# Decrypt
age -d -i ~/.ssh/key flux-system-secret.yaml.age
```

### Flux Operations

```bash
# Force reconciliation
flux -n flux-system reconcile kustomization flux-system --with-source

# Reconcile specific component
flux -n flux-system reconcile kustomization traefik

# Check Flux status
flux get kustomizations -A
flux get helmreleases -A

# Suspend/resume reconciliation
flux -n flux-system suspend kustomization <name>
flux -n flux-system resume kustomization <name>
```

### Talos Operations

```bash
# Get cluster status
talosctl -n talos1 health

# Apply machine config patch
talosctl -n talos1 patch machineconfig -p @patch/provision.yaml

# Upgrade Talos
talosctl -n talos1 upgrade --image=ghcr.io/siderolabs/installer:v1.12.0

# Get logs
talosctl -n talos1 logs kubelet
talosctl -n talos1 dmesg
```

### Destroy Cluster

```bash
rm -f controlplane.yaml talosconfig worker.yaml ~/.talos/config ~/.kube/config && \
  echo 401 402 403 | xargs -n1 ssh pve.home qm stop && \
  echo 401 402 403 | xargs -n1 ssh pve.home qm destroy
```

### Python Environment

Uses `uv` for dependency management. Dependencies in `bootstrap/pyproject.toml`:
- ansible, kubernetes, proxmoxer, requests-toolbelt

```bash
cd bootstrap
uv sync
source .venv/bin/activate
```

## Required Tools

```bash
# Talos cluster management
talosctl              # Control Talos nodes

# Kubernetes
kubectl               # Kubernetes CLI
kubeseal              # Sealed Secrets encryption
kubelogin             # OIDC login plugin (brew install int128/kubelogin/kubelogin)
flux                  # Flux CD CLI

# Infrastructure
ansible               # Bootstrap orchestration (via uv in bootstrap/)
ansible-lint          # Ansible linting

# Encryption
age                   # Secret encryption for bootstrap secrets
```

## Linting

```bash
# YAML linting (max line length: 200)
yamllint .

# Ansible linting
cd bootstrap && ansible-lint
```

## Key Configuration

- **Talos cluster**: 3 control plane nodes (talos1, talos2, talos3) as Proxmox VMs 401-403
- **Node specs**: 18 cores, 16GB RAM, 32GB virtio disk per node
- **Cluster endpoint**: `https://kube.home:6443`
- **Talos schematic extensions**: iscsi-tools, nvme-cli, qemu-guest-agent, thunderbolt, util-linux-tools, zfs
- **Linting**: YAML line length 200 chars (`.yamllint`); ansible-lint skips `command-instead-of-shell`, `line-length`, `yaml[line-length]` (`.ansible-lint`)

## OIDC Configuration

### Kubernetes API Server OIDC
- **Patch file**: `bootstrap/patch/oidc.yaml`
- **Issuer**: `https://authentik.dev.home/application/o/talos-cluster/`
- **Client ID**: `talos-cluster-id`
- **CA**: `jabbas-ca` (embedded in patch, also in system keychain)

### kubectl OIDC Login
Requires `kubelogin` plugin:
```bash
brew install int128/kubelogin/kubelogin

kubectl config set-credentials oidc-user \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://authentik.dev.home/application/o/talos-cluster/ \
  --exec-arg=--oidc-client-id=talos-cluster-id \
  --exec-arg=--oidc-client-secret=<OIDC_CLIENT_SECRET> \
  --exec-arg=--oidc-extra-scope=profile \
  --exec-arg=--oidc-extra-scope=email \
  --exec-arg=--oidc-extra-scope=groups

kubectl config set-context oidc --cluster=k8s --user=oidc-user
```

Note: Extra scopes are required for `preferred_username` and `groups` claims used by the API server.
Get the client secret with: `kubectl get secret authentik-stack-oidc-talos -n authentik -o jsonpath='{.data.AUTHENTIK_TALOS_SECRET}' | base64 -d`
