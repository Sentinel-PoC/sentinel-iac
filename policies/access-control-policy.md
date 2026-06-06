# Access Control Policy (AC-1)

**Document ID**: POL-AC-001
**Version**: 1.0
**Effective Date**: 2026-06-02
**Last Review**: 2026-06-02
**Next Review**: 2027-06-02
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for managing access to all Overwatch Platform components. It ensures that access is granted on a least-privilege basis, accounts are managed throughout their lifecycle, and access rights are reviewed and recertified regularly. The policy supports the CIA triad by ensuring only authorized principals can reach platform resources.

## 2. Scope

This policy applies to all Overwatch Platform components and accounts, including:

- Virtual machine administrative accounts (root, ubuntu, koiakoia)
- Service accounts (Vault AppRoles, Wazuh agents, Forgejo runner service)
- Automation accounts (sentinel-worker, sentinel-judge, sentinel-admin Forgejo tokens)
- OKD cluster access (htpasswd-based authentication)
- Vault authentication methods (AppRole, SSH CA, JWT)
- All human operators with interactive access to platform infrastructure

This policy does NOT cover end-user accounts for hosted applications (Plane, Harbor, Keycloak users); those are governed by application-level policies.

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve account creation and role assignments, authorize policy exceptions, review policy annually |
| **Automated Tooling** (claude-automation / AI agents) | Enforce access controls via Ansible IaC; propose account changes via Forgejo PRs; use scoped tokens only |
| **Forgejo CI/CD** (sentinel-worker) | Execute pipeline automation with push-only rights; no merge authority |
| **Forgejo Judge** (sentinel-judge) | Review and merge PRs with APPROVED status; no direct push to main |
| **Vault SSH CA** | Issue short-lived (30-min TTL) JIT SSH certificates for interactive administrative access |

## 4. Policy Statements

### 4.1 Account Management (AC-2)

- All accounts SHALL be defined in IaC (Ansible roles in `sentinel-iac`) or Vault configuration.
- Accounts not required for platform operation SHALL be removed or disabled.
- Service accounts SHALL use non-interactive shells (`nologin`) unless interactive access is explicitly required and documented.
- A current account inventory SHALL be maintained at `compliance/ac2-account-inventory.md`.
- The account inventory SHALL be reviewed quarterly and updated whenever accounts are added, modified, or removed.

### 4.2 Least Privilege (AC-6)

- Accounts SHALL be granted only the privileges necessary to perform their function.
- Interactive shell access to VMs is restricted to: `ubuntu` (Ansible automation principal), `koiakoia` (operator), and `root` (emergency break-glass only).
- Forgejo automation tokens are role-separated: `sentinel-worker` (propose only), `sentinel-judge` (review/merge), `sentinel-admin` (break-glass operator use only; agents do not use for routine work).
- Vault policies are scoped to specific secret paths and operations. The `claude-automation` policy defines the maximum privilege set available to AI automation; agent sessions use further-scoped tokens.
- OKD RBAC roles SHALL be assigned at the namespace level where possible, not cluster-wide.

### 4.3 Access Enforcement (AC-3)

- SSH access to all VMs requires a Vault-signed certificate with a valid principal matching the target account.
- Certificate TTL is 30 minutes. Long-lived SSH keys are not used for interactive administrative access.
- Password authentication is disabled system-wide on all managed hosts.
- Vault tokens and AppRole credentials are rotated on a defined schedule (see `vault-approle-agent-bootstrap` role).

### 4.4 Account Types

| Type | Examples | Authentication | Shell |
|------|----------|---------------|-------|
| **Human administrative** | ubuntu, koiakoia | Vault JIT SSH cert (30-min TTL) | /bin/bash |
| **System/break-glass** | root | Vault JIT SSH cert | /bin/bash |
| **Service (no shell)** | system daemons, wazuh, haproxy | Service-specific (API keys, sockets) | /usr/sbin/nologin |
| **CI/CD automation** | sentinel-worker, sentinel-judge | API tokens stored in Vault | N/A (API only) |
| **Vault AppRoles** | sentinel-agent, sentinel-unifi-collector | AppRole role_id + secret_id | N/A (API only) |

### 4.5 Access Review and Recertification (AC-2(4))

- The system owner SHALL review the account inventory (`compliance/ac2-account-inventory.md`) quarterly.
- Review evidence SHALL be recorded via git commit updating the `Last Review` date and `Date` field in the inventory document.
- Accounts found to be no longer needed SHALL be removed from IaC and a Forgejo PR opened within 5 business days of the review finding.
- Vault AppRole secret_ids SHALL be rotated at least annually.

### 4.6 Separation of Duties (AC-5)

- Code changes follow a three-role model: WORKER proposes (push branch + open PR), JUDGE reviews (APPROVED) and merges, Operator makes final deploy decisions.
- No agent role has both propose and merge rights to the `sentinel-iac` repository.
- `sentinel-admin` token is operator break-glass only; AI agents do not use it for routine automation.
- See `CLAUDE.md §8` for full branch, merge, and review strategy.

## 5. Enforcement

- Non-compliant account configurations SHALL be flagged by Ansible `--check --diff` runs and treated as IaC drift.
- Unauthorized interactive logins (missing Vault JIT cert or unknown principal) are denied by sshd `AuthorizedPrincipalsFile` configuration.
- Vault audit logs capture all authentication attempts; denied requests generate Wazuh alerts (local rule 100006 and 100021).

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- Reviews SHALL be triggered earlier following: significant infrastructure changes, personnel changes, security incidents involving access control.
- Review evidence SHALL be recorded via git commit updating the `Last Review` and `Next Review` dates.

## 7. References

- NIST SP 800-53 Rev 5: AC-1, AC-2, AC-2(4), AC-3, AC-5, AC-6
- Overwatch Account Inventory (`compliance/ac2-account-inventory.md`)
- Infrastructure Deployment Guide (`compliance/infrastructure-deployment-guide.md`)
- Vault SSH CA role documentation (`ansible/roles/jit-ssh-trust/`)
- Agent Operating Framework (`CLAUDE.md`)
