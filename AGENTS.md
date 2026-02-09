# AGENTS.md

Guidelines for agentic coding assistants working in this Kubernetes home lab infrastructure repository.

## Project Overview

- **Talos Linux** - Immutable, secure Kubernetes OS
- **Flux CD** - GitOps continuous delivery
- **Ansible** - Initial cluster bootstrapping on Proxmox VE
- **Helm** - Package management

Primary technologies: YAML (K8s manifests, Ansible, Flux), Python (Ansible), Bash

## Build/Lint/Test Commands

### Linting
```bash
yamllint .                           # YAML linting (max 200 chars)
cd bootstrap && ansible-lint         # Ansible linting
kubectl apply --dry-run=client -f <file>   # Validate K8s manifest
```

### Bootstrap/Deployment
```bash
cd bootstrap
for f in $(find . -name \*.age); do age -d -i ~/.ssh/jabbas ${f} >${f%.*}; done  # Decrypt secrets
uv sync && source .venv/bin/activate  # Setup Python env
ansible-playbook site.yaml            # Run full playbook
ansible-playbook site.yaml --tags "create_vms"  # Run specific tags
```

### Flux Operations
```bash
flux -n flux-system reconcile kustomization flux-system --with-source  # Force reconcile
flux -n flux-system reconcile kustomization <name>                    # Reconcile component
flux get kustomizations -A              # Check Kustomization status
flux get helmreleases -A                # Check HelmRelease status
flux build kustomization <name> --path ./flux/<path>   # Test Kustomization
kubectl apply -f flux/infrastructure/<component>/<file>  # Apply single manifest
```

## Code Style Guidelines

### YAML Formatting
- **Line length**: Max 200 chars (`.yamllint`)
- **Indentation**: 2 spaces, no tabs
- **Document separator**: Use `---` at file start
- **List style**: Prefer block style

```yaml
# Good
items:
  - name: example
    value: test

# Avoid
items: [{name: example, value: test}]
```

### Ansible Conventions
- **Task naming**: Descriptive, imperative, capitalized
- **Quotes**: Single quotes for modules, double for Jinja2
- **Loops**: `with_items` for lists

```yaml
- name: Create ControlPane Virtual Machine
  community.proxmox.proxmox_kvm:
    api_user: '{{ proxmox.user }}'
    vmid: "{{ item['vmid'] }}"
  with_items: "{{ controlpanes }}"
```

**Ignored lint rules** (`.ansible-lint`): `command-instead-of-shell`, `line-length`, `yaml[line-length]`

### Kubernetes/Flux Manifests
- **API versions**: Latest stable
- **Metadata**: Always include `name`, `namespace`, `labels`
- **Flux dependencies**: Use `dependsOn` for deployment order
- **Timeouts**: Infrastructure: `2m0s`, complex apps: `10m0s`

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
```

### Helm Chart Wrapper Pattern
For apps needing custom resources beyond upstream charts:
1. Create local chart in `flux/infrastructure/<app>/chart/`
2. Add upstream chart as dependency in `Chart.yaml`
3. Add custom templates (e.g., `database.yaml`)
4. Reference from HelmRelease using GitRepository source

```yaml
# Chart.yaml
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
- **Files**: kebab-case: `release-internal.yaml`
- **K8s resources**: kebab-case with descriptive prefixes
- **Ansible variables**: snake_case: `talos.cluster_name`
- **Helm values**: camelCase: `loadBalancerIP`

### Comments
- Use `#` for non-obvious configurations
- Multi-line comments for complex logic/dependencies

## Secret Management
- **Encryption**: `age` for bootstrap, Sealed Secrets for K8s
- **Never commit**: Unencrypted secrets (`.gitignore` protects `*secret.yaml`)

```bash
age -R ~/.ssh/key.pub secret.yaml >secret.yaml.age    # Encrypt
age -d -i ~/.ssh/jabbas secret.yaml.age >secret.yaml  # Decrypt
```

## Error Handling
- **Ansible**: Use `register` and `when` for conditionals
- **Flux**: Let Flux retry failed reconciliations
- **Timeouts**: Set appropriate timeouts for long operations

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

## Dependency Chain

Follow order in `flux/cluster/infrastructure.yaml`:
1. `sources` (HelmRepositories)
2. Core: `metallb-release`, `sealed-secrets`, `snapshot-controller`
3. Storage: `democratic-csi` (needs sealed-secrets + snapshot-controller)
4. Networking: `traefik` (needs metallb-config)
5. Database: `cloudnativepg` (needs storage)
6. Shared Secrets: `shared-secrets` (needs reflector)
7. Apps: `authentik` (needs cloudnativepg + traefik), `grafana` (needs traefik + victoria-metrics + shared-secrets)

### Shared Secrets Pattern

For secrets needed by multiple applications (CA certs, shared credentials), use dedicated Kustomization:

```yaml
# flux/infrastructure/shared-secrets/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - jabbas-ca.yaml  # Secret with reflector annotations
```

**Benefits:**
- Faster deployment (no waiting for heavy apps like authentik)
- No external repo dependencies
- Secrets are part of main infrastructure repo
- Use k8s-reflector to auto-copy to other namespaces

### HelmRelease Reliability

For complex applications with external dependencies, add reliability configs:

```yaml
spec:
  interval: 30m
  timeout: 15m              # Increase for dashboard downloads
  install:
    remediation:
      retries: 3            # Auto-retry on transient failures
  upgrade:
    remediation:
      retries: 3
  values:
    recreatePods: true      # Avoid Multi-Attach with PVC
```

**Common issues this prevents:**
- Timeout waiting for dashboard downloads from grafana.com
- PVC Multi-Attach errors during reinstallation
- Race conditions with secret availability

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

Use format: `file_path:line_number`

Example: "`flux/infrastructure/authentik/chart/templates/database.yaml:1`"

## Cluster Information

- **Endpoint**: `https://kube.home:6443`
- **Nodes**: 3 control planes (talos1-3, VMs 401-403)
- **Specs**: 18 cores, 16GB RAM, 32GB disk each
- **Talos**: 1.12.3 (`bootstrap/site.yaml:39`)
- **OIDC**: Authentik at `https://authentik.dev.home`
- **Extensions**: iscsi-tools, nvme-cli, qemu-guest-agent, thunderbolt, util-linux-tools
