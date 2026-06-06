# Supply Chain Risk Management Plan (SR-2, PM-30)

**Document ID**: PLAN-SCRM-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This plan establishes the Overwatch Platform's approach to managing supply chain risks for all software, hardware, and service dependencies. It defines approved sources, vendor trust assessments, and procedures for responding to supply chain compromise.

## 2. Scope

This plan covers all external dependencies of the Overwatch Platform:

- Operating systems and package repositories
- Container images and registries
- Infrastructure software (hypervisors, orchestration, secrets management)
- Cloud services (DNS, offsite backup)
- Open source components and their upstream maintainers
- Hardware vendors (physical hosts)

## 3. Supply Chain Inventory

### 3.1 Software Components

| Component | Vendor/Source | Version | Registry/Source | Criticality |
|-----------|-------------|---------|-----------------|-------------|
| Ubuntu 24.04 LTS | Canonical | 24.04 | `archive.ubuntu.com` | Critical |
| OKD 4.19 | Red Hat / OKD Community | 4.19 | `quay.io/openshift` | Critical |
| HashiCorp Vault | HashiCorp | 1.21.2 | Docker Hub `hashicorp/vault` | Critical |
| GitLab CE | GitLab Inc. | Latest Omnibus | `packages.gitlab.com` | Critical |
| MinIO | MinIO Inc. | Latest | `dl.min.io` | High |
| Docker CE | Docker Inc. | Latest | `download.docker.com` | High |
| Proxmox VE | Proxmox Server Solutions | 8.x | `download.proxmox.com` | Critical |
| ArgoCD | CNCF / Argo Project | 2.x (via OpenShift GitOps) | Red Hat Operator Hub | High |
| Traefik | Traefik Labs | 3.x | Binary release | Medium |
| Pangolin | Pangolin Project | Latest | GitHub releases | Medium |
| Trivy | Aqua Security | 0.69.1 | GitHub releases | Medium |
| gitleaks | Gitleaks LLC | 8.30.0 | GitHub releases | Medium |
| AIDE | AIDE Project | Distro package | Ubuntu repos | Low |
| rclone | rclone.org | Latest | `rclone.org` | Medium |

### 3.2 Cloud Services

| Service | Provider | Purpose | Data Sensitivity |
|---------|----------|---------|-----------------|
| Backblaze B2 | Backblaze Inc. | Offsite encrypted backups | High (encrypted at rest) |
| Cloudflare DNS | Cloudflare Inc. | DNS management, Let's Encrypt DNS-01 | Low (DNS records only) |
| ProtonVPN | Proton AG | VPN tunnel for seedbox | Low (tunnel only) |
| Let's Encrypt | ISRG | TLS certificates | None (public CA) |

## 4. Approved Registries and Sources

### 4.1 Approved Container Registries

| Registry | URL | Usage | Verification |
|----------|-----|-------|-------------|
| Docker Hub | `docker.io` | Vault, seedbox images | Official images only, verify publisher |
| Quay.io | `quay.io` | OKD, ArgoCD images | Red Hat-signed images |
| GitHub Container Registry | `ghcr.io` | Utility images | Verify upstream repo |

### 4.2 Approved Package Sources

| Source | Usage | Verification |
|--------|-------|-------------|
| Ubuntu `archive.ubuntu.com` | OS packages | APT GPG signatures |
| GitLab `packages.gitlab.com` | GitLab CE | GPG key verification |
| Docker `download.docker.com` | Docker CE | GPG key verification |
| HashiCorp releases | Vault binary | SHA256 checksum + GPG |
| Red Hat Operator Hub | OpenShift operators | Red Hat signing |

### 4.3 Prohibited Sources

- Unverified third-party Docker registries
- Packages from personal GitHub repositories without code review
- Pre-built binaries from untrusted sources
- Container images with `latest` tag in production (pin versions)

## 5. Vendor Trust Assessment

### 5.1 Critical Vendors

**Canonical (Ubuntu 24.04 LTS)**
- Trust Level: High
- Justification: Industry-standard LTS, 10-year support commitment, Ubuntu Pro available
- Risk: Low — broad community, transparent security process
- Mitigation: Timely patching, Trivy scanning, AIDE monitoring

**Red Hat / OKD Community (OKD 4.19)**
- Trust Level: High
- Justification: OKD is the upstream community distribution of OpenShift, backed by Red Hat engineering
- Risk: Medium — community project, not commercially supported
- Mitigation: Pin to stable releases, monitor release notes, etcd backups

**HashiCorp (Vault 1.21.2)**
- Trust Level: High
- Justification: Industry-standard secrets management, BSL license, well-audited
- Risk: Low — active development, regular security patches
- Mitigation: Version pinning in Ansible, pre-upgrade snapshots, audit logging

**Proxmox (Proxmox VE 8.x)**
- Trust Level: High
- Justification: Open-source hypervisor with commercial support option, Debian-based
- Risk: Low — stable release cycle, enterprise adoption
- Mitigation: Subscribe to security advisories, staged updates

**GitLab (GitLab CE)**
- Trust Level: High
- Justification: Widely adopted, open-core model, regular security releases
- Risk: Low — monthly security releases, transparent CVE process
- Mitigation: Enable auto-update channel, weekly backups

### 5.2 High-Trust Vendors

**MinIO**
- Trust Level: High
- Justification: S3-compatible, open-source (AGPLv3), active community
- Risk: Low — well-tested, simple architecture
- Mitigation: Version pinning, replica for redundancy

**Backblaze**
- Trust Level: High
- Justification: Established cloud storage provider, SOC 2 compliant
- Risk: Low — data encrypted before upload (rclone crypt), Backblaze never sees plaintext
- Mitigation: Client-side encryption, key separation (keys in Vault + Proton Pass)

**Cloudflare**
- Trust Level: High
- Justification: Major CDN/DNS provider, DNS-scoped API token limits blast radius
- Risk: Low — scoped token with DNS-only permissions, no data exposure
- Mitigation: Token rotation, minimum-privilege scoping

### 5.3 Medium-Trust Vendors

**Pangolin / Traefik**
- Trust Level: Medium
- Justification: Smaller projects, less security audit history
- Risk: Medium — reverse proxy is network-exposed
- Mitigation: Firewall rules, TLS enforcement, regular updates, no management UI exposed externally

**Aqua Security (Trivy) / gitleaks**
- Trust Level: Medium
- Justification: Security scanning tools, well-regarded in DevSecOps community
- Risk: Low — read-only scanning, no production data access
- Mitigation: Pin versions, verify checksums on download

## 6. Open Source Dependency Management

### 6.1 Dependency Tracking

- All direct dependencies SHALL be tracked in the Component Lifecycle Tracker (`compliance/component-lifecycle.md`).
- Version updates SHALL be reviewed for security advisories before adoption.
- EOL components SHALL be upgraded per the Maintenance Policy timeline.

### 6.2 Vulnerability Scanning

- Trivy SHALL scan all IaC files and filesystem packages on every CI pipeline run.
- Trivy findings with `allow_failure: false` SHALL block deployment of vulnerable components.
- New CVEs in critical components SHALL be assessed within 72 hours of public disclosure.

### 6.3 Image Verification

- Container images SHALL be pulled from approved registries only.
- Production deployments SHALL use pinned image tags (e.g., `hashicorp/vault:1.21.2`), not `latest`.
- Image digests SHOULD be recorded in deployment manifests where supported.

## 7. Container Image Supply Chain Workflow

The following workflow applies to all container images deployed on the Overwatch OKD cluster.

### 7.1 Workflow: Build → Push → Scan → Deploy → Verify

```
Developer Workstation    GitLab CI           Harbor              ArgoCD/OKD
       |                     |                  |                     |
  1. Commit code ───────► 2. CI Pipeline       |                     |
       |                  ├─ yamllint          |                     |
       |                  ├─ ansible-lint      |                     |
       |                  ├─ gitleaks ──────────────────────► DefectDojo
       |                  └─ trivy-scan ───────────────────► DefectDojo
       |                     |                  |                     |
       |               3. Build image           |                     |
       |                  (if applicable)       |                     |
       |                     |                  |                     |
       |               4. Push to Harbor ────► 5. Stored in          |
       |                                       sentinel/ project     |
       |                     |                  |                     |
       |                     |                  |              6. ArgoCD sync
       |                     |                  |              ├─ Pull from Harbor
       |                     |                  |              ├─ Deploy to OKD
       |                     |                  |              └─ Health check
       |                     |                  |                     |
       |                     |                  |              7. Verify
       |                     |                  |              ├─ Pod healthy
       |                     |                  |              └─ Grafana metrics
```

### 7.2 Stage Details

**1. Build** — Images are built from Dockerfiles or pulled from upstream registries.
- Custom images (e.g., Backstage): built in CI, tagged with version or `latest`.
- Upstream images (e.g., DefectDojo, Keycloak): pulled from Docker Hub or vendor registries.

**2. Push to Harbor** — All production images are mirrored to `harbor.208.haist.farm/sentinel/`.
- Upstream images are mirrored via `docker pull` + `docker tag` + `docker push`.
- This ensures the air-gapped OKD cluster can pull images without internet access.

**3. Scan** — Trivy runs in the GitLab CI pipeline on every commit to `main`:
- `trivy-iac`: Scans Terraform, Ansible, Kubernetes manifests for misconfigurations.
- `trivy-fs`: Scans filesystem for known vulnerabilities in packages.
- Results are automatically uploaded to DefectDojo for tracking and triage.
- Gitleaks scans for secrets in code (hard block — pipeline fails if secrets detected).

**4. Deploy** — ArgoCD auto-syncs from the `overwatch-gitops` repo on `main` branch:
- Helm values reference Harbor image paths (e.g., `harbor.208.haist.farm/sentinel/defectdojo-django`).
- ArgoCD Application manifests define image overrides via `helm.parameters`.
- Self-heal and auto-prune enabled for all managed applications.

**5. Verify** — Post-deployment health is confirmed via:
- ArgoCD sync status (Synced/Healthy).
- Grafana dashboards (pod restarts, resource usage, error rates).
- Wazuh SIEM alerts for anomalous behavior.

### 7.3 Image Registry Policy

| Registry | Role | Access |
|----------|------|--------|
| `harbor.208.haist.farm` | Primary (air-gapped mirror) | OKD cluster pulls from here |
| `docker.io` | Upstream source | Mirror to Harbor only |
| `quay.io` | Upstream source (OKD/Red Hat) | Mirror to Harbor only |
| `ghcr.io` | Upstream source (community) | Mirror to Harbor only |

### 7.4 Current Gaps

- **Image signing** (cosign/notation) is not yet implemented. Images are verified by digest where possible.
- **Admission control** (Kyverno image verification policy) is deployed but not enforcing signature checks.
- **SBOM generation** is not automated. Consider adding Trivy SBOM output to CI pipeline.

## 8. Supply Chain Incident Response

### 8.1 Detection

Supply chain compromises may be detected via:
- Trivy vulnerability database updates flagging a compromised package
- Security advisory from upstream vendor (mailing list, GitHub advisory)
- AIDE detecting unexpected binary changes
- Community reports (CISA, NVD, vendor security pages)

### 8.2 Response Procedure

1. **Assess**: Determine if the compromised component is deployed on the platform.
2. **Isolate**: If deployed, isolate the affected system (Proxmox firewall, stop container).
3. **Identify**: Determine the known-good version and verify its integrity.
4. **Remediate**: Roll back to the known-good version or apply vendor-provided patch.
5. **Verify**: Run Trivy scan, AIDE check, and functional tests after remediation.
6. **Document**: Record the incident, timeline, and actions taken in `compliance/incidents/`.

### 8.3 Communication

- Monitor vendor security channels:
  - Ubuntu: `ubuntu-security-announce` mailing list
  - HashiCorp: `discuss.hashicorp.com/c/vault` + GitHub security advisories
  - OKD/OpenShift: `github.com/okd-project/okd/releases`
  - GitLab: `about.gitlab.com/releases/categories/releases/`
  - Docker: `docs.docker.com/engine/release-notes/`

## 9. Review Schedule

- This plan SHALL be reviewed annually by the system owner.
- Vendor trust assessments SHALL be updated when adding new components.
- The supply chain inventory SHALL be updated with every component upgrade.

## 10. References

- NIST SP 800-53 Rev 5: SR-2, SR-3, SR-5, SR-6, SR-11, PM-30
- NIST SP 800-161 Rev 1: Cybersecurity Supply Chain Risk Management
- Component Lifecycle Tracker (`compliance/component-lifecycle.md`)
- Maintenance Policy (`policies/maintenance-policy.md`)
