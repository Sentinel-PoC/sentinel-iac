# Sentinel IaC

[![pipeline status](http://192.168.12.68/admin1/sentinel-iac/badges/main/pipeline.svg)](http://192.168.12.68/admin1/sentinel-iac/-/commits/main)

Infrastructure as Code for Project Sentinel — Ansible playbooks, Terraform configs, Packer templates, and compliance tooling.

## Directory Structure

```
sentinel-iac/
├── ansible/           # Playbooks, roles, and inventory
│   ├── inventory/     # hosts.ini (canonical inventory)
│   ├── playbooks/     # Per-VM playbooks
│   └── roles/         # Ansible roles (11 roles)
├── ci/                # CI/CD job definitions (included by .gitlab-ci.yml)
├── compliance/        # NIST 800-53 compliance docs and cross-references
├── docs/              # Gap analysis, architecture docs
├── infrastructure/    # Terraform, DR scripts, service configs
│   ├── bootstrap/     # DR-only Terraform (manual, not CI-managed)
│   ├── managed/       # CI-managed Terraform (OpenTofu)
│   └── modules/       # Shared Terraform modules
├── packer/            # Golden image templates (per-file init required)
├── pangolin/          # Pangolin proxy configs (live on pangolin-proxy VM)
├── policies/          # OPA/Rego policies
├── rollback/          # Rollback scripts
├── scripts/           # Operational scripts (compliance checks, exporters)
├── techdocs/          # Backstage TechDocs source
└── wazuh/             # Wazuh custom rules and configs
```

## Ansible

### Playbooks

| Playbook | Target | CI Job |
|----------|--------|--------|
| `iac-control.yml` | 192.168.12.210 | `rebuild-iac-control` |
| `vault-server.yml` | 192.168.12.206 | `rebuild-vault` |
| `gitlab-server.yml` | 192.168.12.68 | `rebuild-gitlab` |
| `minio-bootstrap.yml` | 192.168.12.58 | `rebuild-minio` |
| `seedbox-vm.yml` | 192.168.12.69 | `rebuild-seedbox` |
| `config-server.yml` | 192.168.12.132 | `rebuild-config-server` |
| `crowdsec.yml` | 192.168.12.168 | `rebuild-crowdsec` |
| `wazuh-server.yml` | 192.168.12.100 | `rebuild-wazuh` |
| `pangolin-proxy.yml` | 192.168.12.168 | Manual only |

### Roles

`common`, `config-server`, `crowdsec`, `docker-host`, `gitlab-server`, `iac-control`, `minio-server`, `seedbox`, `vault-server`, `wazuh-agent`, `wazuh-server`

### Usage

```bash
cd ansible

# Full playbook
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml

# Tag-scoped run
ansible-playbook -i inventory/hosts.ini playbooks/vault-server.yml --tags ssh

# Dry run
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --check --diff
```

**Important**: The canonical inventory is `hosts.ini`, not `hosts.yml`.

## CI/CD Pipeline

Stages: `lint` → `security-scan` → `upload-to-defectdojo` → `packer-validate` → `build-templates` → `provision` → `configure` → `compliance-report` → `disaster-recovery`

- **Lint**: yamllint, ansible-lint, tflint
- **Security**: Trivy, Checkov, gitleaks, ShellCheck
- **Build/Provision**: Packer golden images, OpenTofu plan/apply (manual)
- **Configure**: Per-VM rebuild jobs (manual trigger on `main`)

All rebuild and apply jobs require manual trigger. Scan uploads go to DefectDojo.

## Key Gotchas

- **Packer**: Per-file init only (`packer init template.pkr.hcl`, not `packer init .`)
- **Vault playbook**: NEVER run `vault-server.yml` without `--tags` scope
- **Ubuntu SSH**: Service name is `ssh`, not `sshd`
- **Inventory**: `hosts.ini` (INI format), booleans use `False` not `false`
- **Nested SSH**: Use `< /dev/null` or `ssh -n` to prevent stdin consumption
