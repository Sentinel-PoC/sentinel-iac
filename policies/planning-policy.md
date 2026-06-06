# Planning Policy (PL-1)

**Document ID**: POL-PL-001
**Version**: 1.0
**Effective Date**: 2026-06-02
**Last Review**: 2026-06-02
**Next Review**: 2027-06-02
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for security planning on the Overwatch Platform. It ensures that a current System Security Plan (SSP) is maintained, reviewed, and kept accurate relative to the deployed infrastructure. The policy addresses how the platform documents its security posture, tracks gaps, and schedules remediation.

## 2. Scope

This policy applies to all Overwatch Platform security planning artifacts, including:

- The System Security Plan (`compliance/system-security-plan.md` in `sentinel-iac`)
- The Plan of Action and Milestones (`compliance/plan-of-action-and-milestones.md`)
- Security Assessment Reports (`compliance/SAR-overwatch-platform.md`)
- Control implementation statements for all NIST 800-53 controls in scope
- Gap analysis results and remediation tracking (Plane issues in the COMP project)

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve the SSP, authorize system boundaries and risk acceptances, conduct annual SSP review |
| **Automated Tooling** (claude-automation / AI agents) | Draft SSP sections reflecting actual IaC implementation; flag control gaps as Plane COMP issues; update POAM tracking entries |
| **COMPLIANCE-SCRIBE agent** | Maintain compliance documents (SSP, SAR, POAM, gap-analysis.md); the only agent role authorized to write to compliance artifacts |
| **JUDGE agent** | Independently verify control assertions before closing compliance issues; owns the authoritative compliance-check run |

## 4. Policy Statements

### 4.1 System Security Plan (PL-2)

- A current SSP SHALL be maintained at `compliance/system-security-plan.md` in the `sentinel-iac` repository.
- The SSP SHALL reflect the ACTUAL implemented controls, not aspirational or planned controls. Overstated controls SHALL be flagged and downgraded as a compliance finding (COMP project issue).
- The SSP SHALL be reviewed and updated at minimum annually by the system owner.
- Substantive changes to the SSP (control additions, removals, or status changes) SHALL be committed via a Forgejo PR reviewed by the system owner.
- The SSP SHALL document the system boundary, including all infrastructure components listed in `ansible/inventory/`.

### 4.2 SSP as the Primary Planning Document

- For a single-operator, single-site platform of this scope, the SSP serves as the primary security planning document. Separate IS plans (disaster recovery, contingency) are maintained as annexes where required by specific controls.
- The SSP is supplemented by:
  - Configuration Management Plan (`compliance/configuration-management-plan.md`) for CM controls
  - Incident Response Plan (`compliance/incident-response-plan.md`) for IR controls
  - Contingency Planning Policy (`policies/contingency-planning-policy.md`) for CP controls
  - POAM (`compliance/plan-of-action-and-milestones.md`) for active remediation tracking

### 4.3 Plan of Action and Milestones (CA-5)

- Control deficiencies identified via automated scanning (`scripts/nist-compliance-check.sh`), security assessments, or agent findings SHALL be recorded in the POAM.
- Each POAM entry SHALL have: control ID, deficiency description, planned remediation date, Plane issue reference.
- The POAM SHALL be reviewed and updated quarterly.
- POAM entries SHALL be closed only when the JUDGE agent has posted a control-delta JSON confirming the control moved from FAIL to PASS in the compliance check.

### 4.4 Security Assessment and Review Cadence

- Annual: System owner reviews and signs off the SSP, updates the SSP review date.
- Quarterly: POAM review; account inventory review (AC-2); POAM milestone dates updated.
- Continuous: Automated compliance checks run via CI/CD pipeline on every commit to `sentinel-iac`. Results are written to `~/sentinel-cache/config-cache/nist-compliance-latest.json` on iac-control.
- Event-triggered: SSP updates required within 30 days of: infrastructure additions/removals, significant control implementation changes, security incidents, or operator-directed scope changes.

### 4.5 Accuracy Requirement

- No control in the SSP SHALL be marked as "satisfied" or "implemented" unless:
  1. The IaC implementing the control is present in `sentinel-iac`; AND
  2. The automated compliance check (`nist-compliance-check.sh`) returns PASS for that control; OR
  3. The control is marked with a documented risk acceptance signed by the system owner.
- AI agents SHALL NOT write "implemented", "complete", "fixed", or "resolved" about a NIST control until the JUDGE workflow has posted a comment with control-delta JSON. See `CLAUDE.md` assertion rules.

### 4.6 Rules of Behavior

- All personnel with administrative access to the platform SHALL acknowledge the security baseline before access is granted.
- For a single-operator platform, the system owner's awareness of `CLAUDE.md` and `policies/` serves as the rules-of-behavior acknowledgment.
- AI agents operate under the constraints defined in `CLAUDE.md`. Agents that violate scope or assertion rules SHALL have their work rejected by the JUDGE agent and flagged as a COMP finding.

## 5. Enforcement

- SSP inaccuracies (controls marked satisfied when the compliance check fails) SHALL be treated as COMP findings and tracked in Plane with `urgent` or `high` priority.
- Stale POAM entries (milestone dates passed with no update) SHALL be flagged in the quarterly review.
- CI pipeline enforces that compliance artifacts are committed via branch + PR (not direct push to main).

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- Reviews SHALL be triggered earlier if: significant infrastructure changes, NIST 800-53 revision updates, security incidents affecting planning artifacts.
- Review evidence SHALL be recorded via git commit updating the `Last Review` and `Next Review` dates.

## 7. References

- NIST SP 800-53 Rev 5: PL-1, PL-2, CA-5, CA-6
- System Security Plan (`compliance/system-security-plan.md`)
- Plan of Action and Milestones (`compliance/plan-of-action-and-milestones.md`)
- Agent Operating Framework (`CLAUDE.md`) — assertion rules and compliance workflow
- Automated compliance check (`scripts/nist-compliance-check.sh`) — READ-ONLY, authoritative
