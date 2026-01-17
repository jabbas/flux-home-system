# AGENTS.md

This file provides guidelines for agentic coding assistants working in this repository.

## Project Overview

This is a **Kubernetes home lab infrastructure repository** using:
- **Talos Linux** - Immutable, secure Kubernetes OS
- **Flux CD** - GitOps continuous delivery
- **Ansible** - Initial cluster bootstrapping on Proxmox VE
- **Helm** - Package management for Kubernetes applications

Primary technologies: YAML (Kubernetes manifests, Ansible playbooks, Flux configurations), Python (Ansible dependencies), Bash (utility scripts)

## Build/Lint/Test Commands

### Linting

```bash
# YAML linting (run from repository root)
yamllint .

# Ansible linting (run from bootstrap directory)
cd bootstrap && ansible-lint

# Kubernetes manifest validation
kubectl apply --dry-run=client -f <manifest.yaml>

# Flux validation
flux diff kustomization <name> --path ./flux/<path>
```

### Bootstrap/Deployment

```bash
# Bootstrap entire cluster (run from bootstrap/)
cd bootstrap

# Decrypt age-encrypted secrets first
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done

# Setup Python virtual environment
uv sync
source .venv/bin/activate

# Run Ansible playbook
ansible-playbook site.yaml
```

### Flux Operations

```bash
# Force reconcile from repository root
flux -n flux-system reconcile kustomization flux-system --with-source

# Reconcile specific component
flux -n flux-system reconcile kustomization <component-name>

# Check status
flux get kustomizations -A
flux get helmreleases -A

# Suspend/resume
flux -n flux-system suspend kustomization <name>
flux -n flux-system resume kustomization <name>
```

### Testing Individual Components

```bash
# Test single Kustomization
flux build kustomization <name> --path ./flux/<path>

# Test HelmRelease rendering
flux diff helmrelease <name> -n <namespace>

# Apply single manifest for testing
kubectl apply -f flux/infrastructure/<component>/<file.yaml>
```

## Code Style Guidelines

### YAML Formatting

**Line Length**: Maximum 200 characters (configured in `.yamllint`)
**Indentation**: 2 spaces (no tabs)
**Document separator**: Use `---` at the start of files
**List style**: Prefer block style for readability

```yaml
# Good
items:
  - name: example
    value: test

# Avoid
items: [{name: example, value: test}]
```

### Ansible Conventions

**Task naming**: Use descriptive, imperative names starting with a capital letter
**Quotes**: Use single quotes for module parameters, double for Jinja2 templates
**With loops**: Use `with_items` for lists, `loop` for modern syntax

```yaml
# Good
- name: Create ControlPane Virtual Machine
  community.proxmox.proxmox_kvm:
    api_user: '{{ proxmox.user }}'
    vmid: "{{ item['vmid'] }}"
  with_items: "{{ controlpanes }}"
```

**Ignored lint rules** (`.ansible-lint`):
- `command-instead-of-shell` - Shell features often needed
- `line-length` - Max 200 chars allowed
- `yaml[line-length]` - Consistent with yamllint

### Kubernetes/Flux Manifests

**API versions**: Use latest stable versions
**Metadata**: Always include `name`, `namespace`, and `labels` where applicable
**Flux dependencies**: Use `dependsOn` to enforce deployment order
**Timeouts**: Infrastructure components: `2m0s`, complex apps: `10m0s`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 1m0s
  timeout: 2m0s
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/infrastructure/traefik
  dependsOn:
    - name: sources
    - name: sealed-secrets
    - name: metallb-config
```

### Helm Chart Wrapper Pattern

For applications requiring custom resources beyond upstream charts:
1. Create local chart in `flux/infrastructure/<app>/chart/`
2. Add upstream chart as dependency in `Chart.yaml`
3. Add custom templates (e.g., `database.yaml` for CNPG clusters)
4. Reference from HelmRelease using GitRepository source

```yaml
# flux/infrastructure/<app>/chart/Chart.yaml
apiVersion: v2
name: app-stack
type: application
version: 0.1.0
dependencies:
  - name: upstream-chart
    version: "1.2.3"
    repository: https://charts.example.com
```

### Naming Conventions

**Files**: Use kebab-case: `release-internal.yaml`, `ipaddresspool.yaml`
**Kubernetes resources**: Use kebab-case with descriptive prefixes
**Ansible variables**: Use snake_case: `talos.cluster_name`, `proxmox.host`
**Helm values**: Use camelCase: `loadBalancerIP`, `ingressClass`

### Comments and Documentation

**Inline comments**: Use YAML comments (`#`) to explain non-obvious configurations
**File headers**: Not required for manifest files
**Complex logic**: Add multi-line comments explaining deployment dependencies

```yaml
# Port 50000 is open - VM started
# Port 10250 and 50001 is open - Apply config done
# Port 6443 is open - bootstrap is done
```

## Secret Management

**Encryption**: Use `age` for bootstrap secrets, Sealed Secrets for Kubernetes
**Never commit**: Unencrypted secrets (`.gitignore` protects `*secret.yaml`)
**Age encryption**: Public key `~/.ssh/key.pub`, private key `~/.ssh/jabbas`

```bash
# Encrypt
age -R ~/.ssh/key.pub secret.yaml >secret.yaml.age

# Decrypt
age -d -i ~/.ssh/key secret.yaml.age >secret.yaml
```

## Error Handling

**Ansible**: Use `register` and `when` for conditional execution
**Flux**: Let Flux retry failed reconciliations automatically
**Timeouts**: Set appropriate timeouts on long-running operations

```yaml
- name: Check if file exists
  ansible.builtin.stat:
    path: "./file.iso"
  register: iso_file

- name: Fetch file
  ansible.builtin.get_url:
    url: "https://example.com/file.iso"
    dest: "./file.iso"
  when: not iso_file.stat.exists
```

## Common Patterns

### Dependency Chain Order

Follow Flux dependency chain (see `flux/cluster/infrastructure.yaml`):
1. `sources` (HelmRepositories) - deployed first
2. Core infrastructure: `metallb-release`, `sealed-secrets`, `snapshot-controller`
3. Storage: `democratic-csi` (depends on sealed-secrets + snapshot-controller)
4. Networking: `traefik` (depends on metallb-config)
5. Database: `cloudnativepg` (depends on storage)
6. Applications: `authentik` (depends on cloudnativepg + traefik)

### GitRepository References

Always use GitRepository source for local charts:

```yaml
spec:
  chart:
    spec:
      chart: ./flux/infrastructure/<app>/chart
      sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
```

## File References

When referencing code, use format: `file_path:line_number`

Example: "Authentik database cluster defined in `flux/infrastructure/authentik/chart/templates/database.yaml:1`"

## Cluster Information

- **Cluster endpoint**: `https://kube.home:6443`
- **Nodes**: 3 control planes (talos1-3, VMs 401-403)
- **Node specs**: 18 cores, 16GB RAM, 32GB disk each
- **Talos version**: 1.12.1 (see `bootstrap/site.yaml:39`)
- **OIDC provider**: Authentik at `https://authentik.dev.home`
