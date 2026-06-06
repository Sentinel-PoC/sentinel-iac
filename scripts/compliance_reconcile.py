#!/usr/bin/env python3
"""
Compliance Reconciliation Pipeline — Overwatch Platform
COMP-7: Artifact consistency checker

Detects divergence between:
  - Deterministic compliance check results (ground truth)
  - SSP implementation statuses
  - Check strength classifications
  - Compliance documentation (markdown artifacts)

This script is READ-ONLY for all compliance artifacts. It produces a
reconciliation report identifying inconsistencies. It does NOT modify
SSP/SAR/POAM — that is the COMPLIANCE-SCRIBE's responsibility.

Architecture reference: autonomous-operations-architecture.md, Section 5
"""

import argparse
import json
import os
import re
import sys
import yaml
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path


# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
DEFAULT_CHECK_JSON = os.path.expanduser(
    "~/sentinel-cache/config-cache/nist-compliance-latest.json"
)
DEFAULT_CHECK_STRENGTH = os.path.expanduser(
    "~/overwatch/check-strength.yaml"
)
DEFAULT_SSP_JSON = os.path.expanduser(
    "~/compliance-vault/system-security-plans/sentinel-ssp/system-security-plan.json"
)
DEFAULT_MD_SSP_DIR = os.path.expanduser(
    "~/compliance-vault/md_ssp"
)
DEFAULT_SCORE_HISTORY = os.path.expanduser(
    "~/sentinel-cache/compliance/nist-score-history.md"
)
DEFAULT_COMPLIANCE_DIR = os.path.expanduser(
    "~/sentinel-cache/compliance"
)
DEFAULT_RESEARCH_LOG = "/var/log/sentinel-agent/research-log.jsonl"
DEFAULT_PREVIOUS_REPORT = os.path.expanduser(
    "~/sentinel-cache/compliance/reconcile-previous.json"
)
DEFAULT_OUTPUT_DIR = os.path.expanduser(
    "~/sentinel-cache/compliance"
)

# Staleness thresholds (days)
STALE_CHECK_THRESHOLD = 7
STALE_SSP_THRESHOLD = 30
STALE_DR_TEST_THRESHOLD = 90

# Zombie metric patterns — hardcoded numbers that persisted incorrectly
ZOMBIE_PATTERNS = [
    (r"\b64[-–]65\s*%", "64-65% zombie metric"),
    (r"\b176[-–]180\b", "176-180 zombie count"),
    (r"~?\s*185\s*/\s*276", "185/276 zombie fraction"),
    (r"\b67\s*%\b.*(?:SAR|compliance|controls)", "67% zombie rate"),
    (r"\b98\s*/\s*125\b", "98/125 stale score (pre-COMP-5)"),
]

# Gap language patterns — words that indicate incomplete implementation
GAP_LANGUAGE_PATTERNS = [
    r"\bgap\b",
    r"\bnot\s+(?:yet|fully|completely)\s+implemented\b",
    r"\bpartially?\s+implemented\b",
    r"\bplanned\b",
    r"\bno\s+formal\b",
    r"\bnot\s+configured\b",
    r"\bmissing\b",
    r"\bincomplete\b",
    r"\bnot\s+enforced\b",
    r"\bnot\s+deployed\b",
    r"\bmanual\s+process\b",
    r"\bno\s+automated\b",
    r"\brequires\s+implementation\b",
]


def load_json(path):
    """Load a JSON file, return None on failure."""
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"WARNING: Cannot load {path}: {e}", file=sys.stderr)
        return None


def load_yaml(path):
    """Load a YAML file, return None on failure."""
    try:
        with open(path) as f:
            return yaml.safe_load(f)
    except (FileNotFoundError, yaml.YAMLError) as e:
        print(f"WARNING: Cannot load {path}: {e}", file=sys.stderr)
        return None


def load_check_results(path):
    """Load and validate the compliance check JSON."""
    data = load_json(path)
    if not data:
        return None
    if "checks" not in data or "summary" not in data:
        print(f"ERROR: {path} missing required keys", file=sys.stderr)
        return None
    return data


def load_check_strength(path):
    """Load check-strength.yaml into a lookup dict keyed by check_id."""
    data = load_yaml(path)
    if not data or "checks" not in data:
        return {}
    registry = {}
    for entry in data["checks"]:
        check_id = entry.get("check_id", "")
        registry[check_id] = {
            "control": entry.get("control", ""),
            "strength": entry.get("strength", "unknown"),
            "reason": entry.get("reason", ""),
        }
    return registry


def load_ssp_statuses(path):
    """Extract per-control implementation-status from OSCAL SSP JSON.

    Returns dict: control_id -> {state, description, has_gap_language}
    """
    data = load_json(path)
    if not data:
        return {}

    ssp = data.get("system-security-plan", {})
    cis = (
        ssp.get("control-implementation", {})
        .get("implemented-requirements", [])
    )

    statuses = {}
    for ci in cis:
        control_id = ci.get("control-id", "")
        states = set()
        descriptions = []

        # Top-level by-components
        for bc in ci.get("by-components", []):
            s = bc.get("implementation-status", {}).get("state", "unknown")
            states.add(s)
            desc = bc.get("description", "")
            if desc:
                descriptions.append(desc)

        # Statement-level by-components
        for stmt in ci.get("statements", []):
            for bc in stmt.get("by-components", []):
                s = bc.get("implementation-status", {}).get("state", "unknown")
                states.add(s)
                desc = bc.get("description", "")
                if desc:
                    descriptions.append(desc)

        # Use most "advanced" state if multiple
        if "implemented" in states:
            effective_state = "implemented"
        elif "partial" in states:
            effective_state = "partial"
        elif "planned" in states:
            effective_state = "planned"
        elif "not-applicable" in states:
            effective_state = "not-applicable"
        else:
            effective_state = "unknown"

        full_desc = " ".join(descriptions).lower()
        has_gap = any(
            re.search(pat, full_desc, re.IGNORECASE)
            for pat in GAP_LANGUAGE_PATTERNS
        )

        statuses[control_id] = {
            "state": effective_state,
            "description_snippet": full_desc[:200] if full_desc else "",
            "has_gap_language": has_gap,
        }

    return statuses


def normalize_control_id(control_str):
    """Normalize control ID: 'AC-3' -> 'ac-3', 'IA-2(1)' -> 'ia-2.1'."""
    s = control_str.lower().strip()
    # Convert parenthetical enhancements: IA-2(1) -> ia-2.1
    s = re.sub(r"\((\d+)\)", r".\1", s)
    return s


def scan_markdown_for_zombies(directory):
    """Scan markdown files in directory for zombie metric patterns."""
    findings = []
    if not os.path.isdir(directory):
        return findings

    for root, _dirs, files in os.walk(directory):
        for fname in files:
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath) as f:
                    content = f.read()
            except OSError:
                continue

            for pattern, description in ZOMBIE_PATTERNS:
                matches = list(re.finditer(pattern, content, re.IGNORECASE))
                for m in matches:
                    # Get line number
                    line_num = content[: m.start()].count("\n") + 1
                    findings.append({
                        "file": fpath,
                        "line": line_num,
                        "pattern": description,
                        "match": m.group(),
                    })

    return findings


def scan_md_ssp_for_gap_language(md_ssp_dir, ssp_statuses):
    """Scan markdown SSP files for gap language in 'implemented' controls."""
    findings = []
    if not os.path.isdir(md_ssp_dir):
        return findings

    for fname in os.listdir(md_ssp_dir):
        if not fname.endswith(".md"):
            continue
        # Derive control ID from filename: ac-3.md -> ac-3, ia-2.1.md -> ia-2.1
        control_id = fname[:-3]

        # Only care about controls marked "implemented" in the SSP
        ssp_entry = ssp_statuses.get(control_id, {})
        if ssp_entry.get("state") != "implemented":
            continue

        fpath = os.path.join(md_ssp_dir, fname)
        try:
            with open(fpath) as f:
                content = f.read()
        except OSError:
            continue

        for pattern in GAP_LANGUAGE_PATTERNS:
            matches = list(re.finditer(pattern, content, re.IGNORECASE))
            for m in matches:
                line_num = content[: m.start()].count("\n") + 1
                findings.append({
                    "control_id": control_id,
                    "file": fpath,
                    "line": line_num,
                    "matched_text": m.group(),
                    "ssp_state": "implemented",
                    "issue": (
                        f"Control {control_id} is marked 'implemented' "
                        f"in SSP but markdown contains gap language: "
                        f"'{m.group()}'"
                    ),
                })

    return findings


def reconcile(check_results, strength_registry, ssp_statuses):
    """Core reconciliation: compare check results against SSP statuses
    and check strengths.

    Returns list of findings.
    """
    findings = []
    checks = check_results.get("checks", [])

    for check in checks:
        status = check.get("status", "")
        control_raw = check.get("control", "")
        check_id = check.get("check", "")
        detail = check.get("detail", "")

        control_id = normalize_control_id(control_raw)
        strength_entry = strength_registry.get(check_id, {})
        strength = strength_entry.get("strength", "strong")
        ssp_entry = ssp_statuses.get(control_id, {})
        ssp_state = ssp_entry.get("state", "not-in-ssp")

        # --- Finding 1: PASS with weak/trivial check but SSP says "implemented" ---
        if status == "PASS" and strength in ("weak", "trivial", "proxy", "misleading"):
            if ssp_state == "implemented":
                findings.append({
                    "type": "weak_check_inflation",
                    "severity": "high",
                    "control": control_raw,
                    "check_id": check_id,
                    "check_status": status,
                    "check_strength": strength,
                    "ssp_state": ssp_state,
                    "recommended_ssp_state": "partial",
                    "reason": (
                        f"Check '{check_id}' passes but is classified as "
                        f"'{strength}' — insufficient evidence to support "
                        f"'implemented' status. Should be 'partial' max."
                    ),
                    "strength_reason": strength_entry.get("reason", ""),
                })

        # --- Finding 2: FAIL or WARN but SSP says "implemented" ---
        if status in ("FAIL", "WARN") and ssp_state == "implemented":
            findings.append({
                "type": "status_mismatch",
                "severity": "high",
                "control": control_raw,
                "check_id": check_id,
                "check_status": status,
                "ssp_state": ssp_state,
                "recommended_ssp_state": "partial",
                "detail": detail,
                "reason": (
                    f"Check '{check_id}' returned {status} but SSP claims "
                    f"'implemented'. SSP must be downgraded to 'partial'."
                ),
            })

        # --- Finding 3: PASS with strong check but SSP says "planned" ---
        if status == "PASS" and strength in ("strong", "moderate"):
            if ssp_state == "planned":
                findings.append({
                    "type": "ssp_undercount",
                    "severity": "medium",
                    "control": control_raw,
                    "check_id": check_id,
                    "check_status": status,
                    "check_strength": strength,
                    "ssp_state": ssp_state,
                    "recommended_ssp_state": "implemented",
                    "reason": (
                        f"Check '{check_id}' passes with '{strength}' "
                        f"strength but SSP still says 'planned'. SSP should "
                        f"be updated to 'implemented'."
                    ),
                })

        # --- Finding 4: Gap language in SSP description for "implemented" control ---
        if ssp_state == "implemented" and ssp_entry.get("has_gap_language"):
            findings.append({
                "type": "gap_language_in_implemented",
                "severity": "medium",
                "control": control_raw,
                "check_id": check_id,
                "ssp_state": ssp_state,
                "description_snippet": ssp_entry.get("description_snippet", ""),
                "reason": (
                    f"Control {control_raw} is marked 'implemented' in SSP "
                    f"but its description contains gap/caveat language."
                ),
            })

        # --- Finding 5: Control has check but is not in SSP at all ---
        if ssp_state == "not-in-ssp":
            findings.append({
                "type": "control_not_in_ssp",
                "severity": "low",
                "control": control_raw,
                "check_id": check_id,
                "check_status": status,
                "reason": (
                    f"Compliance check exists for {control_raw} but control "
                    f"is not found in OSCAL SSP."
                ),
            })

    return findings


def check_staleness(check_results):
    """Check if compliance data is stale."""
    findings = []
    timestamp_str = check_results.get("timestamp", "")
    if not timestamp_str:
        findings.append({
            "type": "stale_data",
            "severity": "high",
            "reason": "Compliance check JSON has no timestamp",
        })
        return findings

    try:
        check_time = datetime.fromisoformat(
            timestamp_str.replace("Z", "+00:00")
        )
        now = datetime.now(timezone.utc)
        age_days = (now - check_time).days

        if age_days > STALE_CHECK_THRESHOLD:
            findings.append({
                "type": "stale_data",
                "severity": "high",
                "check_timestamp": timestamp_str,
                "age_days": age_days,
                "threshold_days": STALE_CHECK_THRESHOLD,
                "reason": (
                    f"Compliance check data is {age_days} days old "
                    f"(threshold: {STALE_CHECK_THRESHOLD} days). "
                    f"All derived metrics may be inaccurate."
                ),
            })
        elif age_days > 1:
            findings.append({
                "type": "stale_data",
                "severity": "low",
                "check_timestamp": timestamp_str,
                "age_days": age_days,
                "reason": f"Compliance data is {age_days} days old.",
            })
    except (ValueError, TypeError) as e:
        findings.append({
            "type": "stale_data",
            "severity": "medium",
            "reason": f"Cannot parse timestamp '{timestamp_str}': {e}",
        })

    return findings


def detect_regressions(check_results, previous_report_path):
    """Compare current check results against previous reconciliation run."""
    findings = []
    if not os.path.exists(previous_report_path):
        return findings

    prev = load_json(previous_report_path)
    if not prev:
        return findings

    prev_checks = {}
    for c in prev.get("check_results", {}).get("checks", []):
        prev_checks[c.get("check", "")] = c.get("status", "")

    current_checks = {}
    for c in check_results.get("checks", []):
        current_checks[c.get("check", "")] = c.get("status", "")

    new_fails = []
    for check_id, status in current_checks.items():
        prev_status = prev_checks.get(check_id)
        if prev_status == "PASS" and status in ("FAIL", "WARN"):
            new_fails.append({
                "check_id": check_id,
                "previous_status": prev_status,
                "current_status": status,
            })

    if len(new_fails) >= 5:
        findings.append({
            "type": "regression",
            "severity": "critical",
            "new_fail_count": len(new_fails),
            "details": new_fails,
            "reason": (
                f"Regression detected: {len(new_fails)} checks went from "
                f"PASS to FAIL/WARN since last reconciliation."
            ),
        })
    elif new_fails:
        findings.append({
            "type": "regression",
            "severity": "medium",
            "new_fail_count": len(new_fails),
            "details": new_fails,
            "reason": (
                f"{len(new_fails)} check(s) regressed since last "
                f"reconciliation."
            ),
        })

    return findings


def compute_honest_metrics(check_results, strength_registry):
    """Compute metrics that account for check strength.

    Returns two sets of metrics:
    - raw: what the check script reports
    - adjusted: accounting for weak/trivial checks
    """
    checks = check_results.get("checks", [])
    summary = check_results.get("summary", {})

    raw = {
        "pass": summary.get("pass", 0),
        "fail": summary.get("fail", 0),
        "warn": summary.get("warn", 0),
        "total": summary.get("total", 0),
        "pass_rate": summary.get("pass_rate", 0),
        "coverage": summary.get("coverage", {}),
    }

    # Adjusted: don't count weak/trivial/proxy/misleading passes as real
    strong_pass = 0
    moderate_pass = 0
    weak_pass = 0
    total_applicable = summary.get("coverage", {}).get(
        "controls_applicable", 226
    )

    for check in checks:
        if check.get("status") != "PASS":
            continue
        check_id = check.get("check", "")
        strength = strength_registry.get(check_id, {}).get("strength", "strong")
        if strength in ("strong",):
            strong_pass += 1
        elif strength in ("moderate",):
            moderate_pass += 1
        else:
            weak_pass += 1

    strong_evidence_count = strong_pass
    moderate_evidence_count = strong_pass + moderate_pass
    total_pass = strong_pass + moderate_pass + weak_pass

    adjusted = {
        "strong_pass": strong_pass,
        "moderate_pass": moderate_pass,
        "weak_pass": weak_pass,
        "total_pass": total_pass,
        "strong_evidence_pct": round(
            strong_evidence_count / total_applicable * 100, 1
        ) if total_applicable > 0 else 0,
        "moderate_or_better_pct": round(
            moderate_evidence_count / total_applicable * 100, 1
        ) if total_applicable > 0 else 0,
        "weak_inflation_count": weak_pass,
        "honest_pass_rate": round(
            moderate_evidence_count / raw["total"] * 100, 1
        ) if raw["total"] > 0 else 0,
    }

    return raw, adjusted


def build_report(
    check_results,
    strength_registry,
    ssp_statuses,
    reconcile_findings,
    staleness_findings,
    regression_findings,
    zombie_findings,
    gap_language_findings,
    raw_metrics,
    adjusted_metrics,
):
    """Build the full reconciliation report."""
    now = datetime.now(timezone.utc).isoformat()

    all_findings = (
        reconcile_findings
        + staleness_findings
        + regression_findings
        + [
            {
                "type": "zombie_metric",
                "severity": "medium",
                "file": z["file"],
                "line": z["line"],
                "pattern": z["pattern"],
                "match": z["match"],
                "reason": f"Zombie metric '{z['match']}' found in {z['file']}:{z['line']}",
            }
            for z in zombie_findings
        ]
        + gap_language_findings
    )

    # Severity counts
    severity_counts = Counter(f.get("severity", "unknown") for f in all_findings)
    type_counts = Counter(f.get("type", "unknown") for f in all_findings)

    report = {
        "reconciliation_report": {
            "timestamp": now,
            "version": "1.0.0",
            "check_source": check_results.get("timestamp", "unknown"),
        },
        "metrics": {
            "raw": raw_metrics,
            "adjusted": adjusted_metrics,
        },
        "ssp_summary": {
            "total_controls_in_ssp": len(ssp_statuses),
            "status_distribution": dict(
                Counter(v["state"] for v in ssp_statuses.values())
            ),
        },
        "findings_summary": {
            "total_findings": len(all_findings),
            "by_severity": dict(severity_counts),
            "by_type": dict(type_counts),
        },
        "findings": all_findings,
        "check_results": {
            "timestamp": check_results.get("timestamp", ""),
            "checks": check_results.get("checks", []),
        },
    }

    return report


def generate_human_summary(report):
    """Generate a human-readable summary of the reconciliation report."""
    lines = []
    lines.append("=" * 70)
    lines.append("COMPLIANCE RECONCILIATION REPORT")
    lines.append(
        f"Generated: {report['reconciliation_report']['timestamp']}"
    )
    lines.append(
        f"Check data: {report['reconciliation_report']['check_source']}"
    )
    lines.append("=" * 70)
    lines.append("")

    # Metrics
    raw = report["metrics"]["raw"]
    adj = report["metrics"]["adjusted"]
    lines.append("--- RAW CHECK METRICS (from nist-compliance-check.sh) ---")
    lines.append(
        f"  Pass: {raw['pass']}/{raw['total']} ({raw['pass_rate']}%)"
    )
    lines.append(f"  Fail: {raw['fail']}  Warn: {raw['warn']}")
    cov = raw.get("coverage", {})
    lines.append(
        f"  Coverage: {cov.get('controls_checked', '?')}"
        f"/{cov.get('controls_applicable', '?')} controls "
        f"({cov.get('coverage_pct', '?')}%)"
    )
    lines.append("")

    lines.append("--- ADJUSTED METRICS (accounting for check strength) ---")
    lines.append(
        f"  Strong evidence PASS: {adj['strong_pass']}"
    )
    lines.append(
        f"  Moderate evidence PASS: {adj['moderate_pass']}"
    )
    lines.append(
        f"  Weak/trivial/proxy/misleading PASS: {adj['weak_pass']}"
    )
    lines.append(
        f"  Honest pass rate (moderate+strong only): "
        f"{adj['honest_pass_rate']}%"
    )
    lines.append(
        f"  Strong evidence coverage: {adj['strong_evidence_pct']}% "
        f"of applicable controls"
    )
    lines.append(
        f"  Moderate-or-better coverage: {adj['moderate_or_better_pct']}% "
        f"of applicable controls"
    )
    lines.append("")

    # SSP summary
    ssp = report["ssp_summary"]
    lines.append("--- SSP STATUS DISTRIBUTION ---")
    for state, count in sorted(ssp["status_distribution"].items()):
        lines.append(f"  {state}: {count}")
    lines.append("")

    # Findings summary
    fs = report["findings_summary"]
    lines.append(f"--- FINDINGS: {fs['total_findings']} total ---")
    lines.append("  By severity:")
    for sev in ("critical", "high", "medium", "low"):
        count = fs["by_severity"].get(sev, 0)
        if count:
            lines.append(f"    {sev}: {count}")
    lines.append("  By type:")
    for typ, count in sorted(fs["by_type"].items()):
        lines.append(f"    {typ}: {count}")
    lines.append("")

    # Detail findings
    if report["findings"]:
        lines.append("--- DETAILED FINDINGS ---")
        for i, f in enumerate(report["findings"], 1):
            severity = f.get("severity", "?").upper()
            ftype = f.get("type", "?")
            reason = f.get("reason", "no reason")
            lines.append(f"\n  [{i}] [{severity}] {ftype}")
            lines.append(f"      {reason}")
            if "control" in f:
                lines.append(f"      Control: {f['control']}")
            if "check_id" in f:
                lines.append(f"      Check: {f['check_id']}")
            if "recommended_ssp_state" in f:
                lines.append(
                    f"      Recommended SSP state: "
                    f"{f['recommended_ssp_state']}"
                )
        lines.append("")

    lines.append("=" * 70)
    lines.append("END OF REPORT")
    lines.append("=" * 70)

    return "\n".join(lines)


def emit_research_event(report, research_log_path):
    """Emit a compliance_reconcile event to research-log.jsonl."""
    adj = report["metrics"]["adjusted"]
    raw = report["metrics"]["raw"]
    fs = report["findings_summary"]

    event = {
        "timestamp": report["reconciliation_report"]["timestamp"],
        "event_type": "compliance_reconcile",
        "source": "reconcile-agent",
        "data": {
            "pass_count": raw["pass"],
            "fail_count": raw["fail"],
            "warn_count": raw["warn"],
            "total_checks": raw["total"],
            "coverage_pct": raw.get("coverage", {}).get("coverage_pct", 0),
            "strong_evidence_pct": adj["strong_evidence_pct"],
            "honest_pass_rate": adj["honest_pass_rate"],
            "weak_inflation_count": adj["weak_inflation_count"],
            "ssp_updates_recommended": fs["by_type"].get(
                "status_mismatch", 0
            ) + fs["by_type"].get("weak_check_inflation", 0),
            "zombie_metrics_found": fs["by_type"].get("zombie_metric", 0),
            "gap_language_found": fs["by_type"].get(
                "gap_language_in_implemented", 0
            ) + fs["by_type"].get("gap_language_in_md_ssp", 0),
            "regression": fs["by_type"].get("regression", 0) > 0,
            "total_findings": fs["total_findings"],
        },
        "plane_issue": "COMP-7",
        "narrative": (
            f"Reconciliation run: {raw['pass']}/{raw['total']} raw PASS "
            f"({raw['pass_rate']}%), honest rate {adj['honest_pass_rate']}%, "
            f"{fs['total_findings']} findings "
            f"({fs['by_severity'].get('high', 0)} high, "
            f"{fs['by_severity'].get('medium', 0)} medium)"
        ),
    }

    try:
        log_dir = os.path.dirname(research_log_path)
        if log_dir and not os.path.exists(log_dir):
            os.makedirs(log_dir, exist_ok=True)
        with open(research_log_path, "a") as f:
            f.write(json.dumps(event) + "\n")
        print(f"Research event emitted to {research_log_path}", file=sys.stderr)
    except OSError as e:
        print(
            f"WARNING: Cannot write research event to "
            f"{research_log_path}: {e}",
            file=sys.stderr,
        )


def main():
    parser = argparse.ArgumentParser(
        description="Compliance Reconciliation Pipeline — COMP-7"
    )
    parser.add_argument(
        "--check-json",
        default=DEFAULT_CHECK_JSON,
        help="Path to compliance check JSON (ground truth)",
    )
    parser.add_argument(
        "--check-strength",
        default=DEFAULT_CHECK_STRENGTH,
        help="Path to check-strength.yaml",
    )
    parser.add_argument(
        "--ssp-json",
        default=DEFAULT_SSP_JSON,
        help="Path to OSCAL SSP JSON",
    )
    parser.add_argument(
        "--md-ssp-dir",
        default=DEFAULT_MD_SSP_DIR,
        help="Path to markdown SSP directory",
    )
    parser.add_argument(
        "--score-history",
        default=DEFAULT_SCORE_HISTORY,
        help="Path to score history markdown",
    )
    parser.add_argument(
        "--compliance-dir",
        default=DEFAULT_COMPLIANCE_DIR,
        help="Directory containing compliance artifacts to scan for zombies",
    )
    parser.add_argument(
        "--previous-report",
        default=DEFAULT_PREVIOUS_REPORT,
        help="Path to previous reconciliation report (for regression detection)",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help="Directory for output files",
    )
    parser.add_argument(
        "--research-log",
        default=DEFAULT_RESEARCH_LOG,
        help="Path to research-log.jsonl",
    )
    parser.add_argument(
        "--json-only",
        action="store_true",
        help="Output JSON report to stdout only",
    )
    parser.add_argument(
        "--no-research-event",
        action="store_true",
        help="Skip emitting research-log event",
    )

    args = parser.parse_args()

    # --- Load inputs ---
    print("Loading compliance check results...", file=sys.stderr)
    check_results = load_check_results(args.check_json)
    if not check_results:
        print(
            "FATAL: Cannot load compliance check results. Aborting.",
            file=sys.stderr,
        )
        sys.exit(1)

    print("Loading check-strength registry...", file=sys.stderr)
    strength_registry = load_check_strength(args.check_strength)
    if not strength_registry:
        print(
            "WARNING: check-strength.yaml not loaded. "
            "All checks treated as strong.",
            file=sys.stderr,
        )

    print("Loading SSP statuses...", file=sys.stderr)
    ssp_statuses = load_ssp_statuses(args.ssp_json)
    if not ssp_statuses:
        print(
            "WARNING: SSP not loaded. SSP cross-reference skipped.",
            file=sys.stderr,
        )

    # --- Run reconciliation checks ---
    print("Running reconciliation...", file=sys.stderr)

    # 1. Core reconciliation (check vs SSP vs strength)
    reconcile_findings = reconcile(
        check_results, strength_registry, ssp_statuses
    )

    # 2. Staleness detection
    staleness_findings = check_staleness(check_results)

    # 3. Regression detection
    regression_findings = detect_regressions(
        check_results, args.previous_report
    )

    # 4. Zombie metric scan
    zombie_scan_dirs = [args.compliance_dir]
    if args.score_history and os.path.dirname(args.score_history):
        zombie_scan_dirs.append(os.path.dirname(args.score_history))
    zombie_findings = []
    for scan_dir in set(zombie_scan_dirs):
        zombie_findings.extend(scan_markdown_for_zombies(scan_dir))

    # 5. Gap language in markdown SSP for "implemented" controls
    gap_language_findings = []
    if ssp_statuses and args.md_ssp_dir:
        gap_md_findings = scan_md_ssp_for_gap_language(
            args.md_ssp_dir, ssp_statuses
        )
        for gf in gap_md_findings:
            gf["type"] = "gap_language_in_md_ssp"
            gf["severity"] = "medium"
        gap_language_findings.extend(gap_md_findings)

    # 6. Compute metrics
    raw_metrics, adjusted_metrics = compute_honest_metrics(
        check_results, strength_registry
    )

    # --- Build report ---
    report = build_report(
        check_results,
        strength_registry,
        ssp_statuses,
        reconcile_findings,
        staleness_findings,
        regression_findings,
        zombie_findings,
        gap_language_findings,
        raw_metrics,
        adjusted_metrics,
    )

    # --- Output ---
    if args.json_only:
        print(json.dumps(report, indent=2))
    else:
        # Write JSON report
        output_json = os.path.join(args.output_dir, "reconcile-report.json")
        os.makedirs(args.output_dir, exist_ok=True)
        with open(output_json, "w") as f:
            json.dump(report, f, indent=2)
        print(f"JSON report written to {output_json}", file=sys.stderr)

        # Save as previous for next regression check
        prev_path = os.path.join(args.output_dir, "reconcile-previous.json")
        with open(prev_path, "w") as f:
            json.dump(report, f, indent=2)
        print(f"Previous report saved to {prev_path}", file=sys.stderr)

        # Print human summary
        summary = generate_human_summary(report)
        print(summary)

    # --- Research event ---
    if not args.no_research_event:
        emit_research_event(report, args.research_log)

    # Exit code based on findings
    high_count = report["findings_summary"]["by_severity"].get("high", 0)
    critical_count = report["findings_summary"]["by_severity"].get("critical", 0)
    if critical_count > 0:
        sys.exit(2)
    elif high_count > 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
