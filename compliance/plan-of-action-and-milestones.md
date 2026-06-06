# Plan of Action and Milestones (POA&M) (CA-5)

**Document ID**: POAM-OWP-001
**Version**: 1.0
**Issue Date**: 2026-04-20
**Review Date**: 2026-07-20 (Quarterly)
**Classification**: Internal
**System**: Overwatch Platform
**Authorizing Official**: Haists Consulting

---

## Purpose

This Plan of Action and Milestones (POA&M) documents known security weaknesses,
deficiencies, and planned remediation activities for the Overwatch Platform. All
items are tracked as issues in the Plane project management system
(plane.208.haist.farm, workspace haists-it-consulting).

This document satisfies NIST SP 800-53 CA-5 requirements. It is updated
quarterly or when new findings are identified.

---

## Active Findings

### F-001 — CVE Backlog: Critical and High Vulnerabilities

| Field | Value |
|-------|-------|
| **Finding ID** | F-001 |
| **Control** | SI-2 (Flaw Remediation) |
| **Source** | DefectDojo / Trivy scan (Plane: SEC-55, SEC-56, SEC-57) |
| **Status** | Open — In Progress |
| **Severity** | High |
| **Description** | Approximately 134 Critical and 337 High CVEs identified across platform container images and packages. Majority are base-image upstream CVEs. |
| **Milestones** | 1. Pin base images to patched versions (SEC-55/56/57) 2. Establish image update cadence 3. Suppress non-exploitable CVEs |
| **Target Completion** | 2026-06-30 |
| **Responsible** | Platform operator |

---

### F-002 — Proxmox Snapshot Verification Failures

| Field | Value |
|-------|-------|
| **Finding ID** | F-002 |
| **Control** | CP-9 (System Backup) |
| **Source** | Operator observation (Plane: OPS-213) |
| **Status** | Open |
| **Severity** | Medium |
| **Description** | Proxmox VM snapshot job reports failures intermittently. Recovery point objective is unverifiable until resolved. |
| **Milestones** | 1. Diagnose snapshot failure root cause 2. Implement alert on failure 3. Validate backup restore |
| **Target Completion** | 2026-05-31 |
| **Responsible** | Platform operator |

---

### F-003 — Sentinel-Agent Observability Gap

| Field | Value |
|-------|-------|
| **Finding ID** | F-003 |
| **Control** | AU-2 (Audit Events), SI-4 (System Monitoring) |
| **Source** | Agent session observation (Plane: OPS-215) |
| **Status** | Open |
| **Severity** | Medium |
| **Description** | sentinel-agent Python process does not emit structured traces to Langfuse. Monitoring coverage has a gap for automated agent activity. |
| **Milestones** | 1. Scope observability requirements for sentinel-agent 2. Implement trace emission 3. Validate in Langfuse dashboard |
| **Target Completion** | 2026-06-30 |
| **Responsible** | Platform operator |

---

### F-004 — SI-2 Flaw Remediation: Real CVE Posture

| Field | Value |
|-------|-------|
| **Finding ID** | F-004 |
| **Control** | SI-2 (Flaw Remediation) |
| **Source** | Compliance check rewrite (Plane: COMP-20) |
| **Status** | Open — Monitoring |
| **Severity** | High |
| **Description** | Compliance check now measures actual CVE backlog via DefectDojo rather than a proxy metric. Current posture: FAIL until CVE backlog is reduced below thresholds. |
| **Milestones** | 1. Resolve F-001 CVE backlog items 2. SI-2 compliance check expected to PASS once Critical CVE count drops |
| **Target Completion** | 2026-06-30 |
| **Responsible** | Platform operator |

---

## Closed Findings (Recent)

| Finding ID | Control | Description | Closed Date | Plane Reference |
|------------|---------|-------------|-------------|-----------------|
| C-001 | SC-17 | Vault SSH CA mount not detected by compliance check | 2026-04-19 | COMP-26 |
| C-002 | SA-10 | Forgejo branch protection check path bug | 2026-04-19 | COMP-26 |
| C-003 | CM-3(3) | Terraform drift detection timer path mismatch | 2026-04-19 | COMP-26 |
| C-004 | RA-5 | Trivy scan report path not found by compliance check | 2026-04-19 | COMP-26 |
| C-005 | MA-2 | Maintenance window check broken path reference | 2026-04-19 | COMP-26 |

---

## Review History

| Date | Reviewer | Changes |
|------|----------|---------|
| 2026-04-20 | Agent worker-COMP-27 | Initial document creation — migrated from Plane issue tracking |

---

*This document is generated from Plane issue data. For the authoritative current
finding list and status, see plane.208.haist.farm workspace haists-it-consulting,
projects SEC, OPS, and COMP.*
