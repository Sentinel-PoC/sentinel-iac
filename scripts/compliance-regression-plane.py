#!/usr/bin/env python3
"""
compliance-regression-plane.py — OPS-318
Process compliance diff output and create/comment Plane issues.

Usage:
  python3 compliance-regression-plane.py \
    --diff compliance-diff.json \
    --mode regressions|recoveries \
    --date-today YYYY-MM-DD \
    --date-yesterday YYYY-MM-DD \
    --run-url https://...

Environment:
  PLANE_API_KEY   — Plane API token (from secrets.PLANE_API_KEY in CI)

Behaviour:
  mode=regressions:
    For each PASS/WARN->FAIL control in the diff:
    - Search COMP project for existing open issue with matching title prefix
    - If none, create a new COMP issue (priority=high)
    - If one already exists, skip (dedup)
  mode=recoveries:
    For each FAIL->PASS/WARN control in the diff:
    - Search COMP project for existing open issue with matching title prefix
    - If found, post a comment noting the control flipped back
    - If not found, skip (nothing to comment on)

Dedup title prefix: "[AUTO] Compliance regression: <control-id>"
COMP project states (open = not Done/Cancelled):
  Done:      8de993bc-8020-41a3-8828-94b280612f83
  Cancelled: 03c48f58-2622-4485-a2b5-19832843c6ea
  Backlog:   52392361-f972-487a-b196-4dcb90bcbf49
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

PLANE_BASE = "https://plane.208.haist.farm/api/v1"
WORKSPACE = "haists-it-consulting"
# COMP project
COMP_PROJECT_ID = "fc6e1833-f48e-42c5-884e-e349d4c26629"
# COMP Backlog state (for new issues)
COMP_BACKLOG_STATE = "52392361-f972-487a-b196-4dcb90bcbf49"
# Closed states (Done + Cancelled)
CLOSED_STATES = {
    "8de993bc-8020-41a3-8828-94b280612f83",  # Done
    "03c48f58-2622-4485-a2b5-19832843c6ea",  # Cancelled
}

ISSUE_TITLE_PREFIX = "[AUTO] Compliance regression: "


def plane_request(api_key, method, path, body=None):
    """Send a Plane API request. Returns (http_code, dict)."""
    url = f"{PLANE_BASE}/{path}"
    headers = {
        "x-api-key": api_key,
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_bytes = exc.read()
        try:
            return exc.code, json.loads(body_bytes.decode("utf-8"))
        except Exception:
            return exc.code, {"raw": body_bytes.decode("utf-8", errors="replace")}
    except Exception as exc:
        return 0, {"error": str(exc)}


def find_open_comp_issue(api_key, control_id):
    """Search COMP issues for an open one with the [AUTO] prefix + control_id.
    Returns the issue dict if found, None otherwise. Paginates up to 10 pages."""
    prefix = f"{ISSUE_TITLE_PREFIX}{control_id}"
    for page in range(10):
        code, data = plane_request(
            api_key, "GET",
            f"workspaces/{WORKSPACE}/projects/{COMP_PROJECT_ID}/issues/"
            f"?per_page=100&cursor=100:{page}:0",
        )
        if code != 200 or not isinstance(data, dict):
            print(f"  Warning: COMP issue search failed (HTTP {code})", file=sys.stderr)
            return None
        results = data.get("results", [])
        if not results:
            break
        for issue in results:
            if issue.get("name", "").startswith(prefix):
                if issue.get("state") not in CLOSED_STATES:
                    return issue
    return None


def build_regression_html(reg, date_today, date_yest, run_url, timestamp):
    ctrl = reg["control"]
    fail_checks = [c for c in reg["checks"] if c.get("status") == "FAIL"]
    checks_json = json.dumps(fail_checks, indent=2)
    return (
        f"<p><strong>Compliance regression auto-detected</strong></p>"
        f"<p><strong>Control:</strong> {ctrl}</p>"
        f"<p><strong>Previous status ({date_yest}):</strong> {reg['prev_status']}</p>"
        f"<p><strong>Current status ({date_today}):</strong> {reg['curr_status']}</p>"
        f"<p><strong>Detected at:</strong> {timestamp}</p>"
        f"<p><a href=\"{run_url}\">CI run (compliance-regression-alert.yml)</a></p>"
        f"<h3>Failing Checks</h3>"
        f"<pre>{checks_json}</pre>"
        f"<p><em>Auto-created by compliance-regression-alert.yml (OPS-318). "
        f"Do NOT auto-close — Judge workflow is the authoritative closer per CLAUDE.md.</em></p>"
    )


def process_regressions(api_key, diff, date_today, date_yest, run_url):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    regressions = diff.get("regressions", [])
    if not regressions:
        print("No regressions to process")
        return 0

    created = 0
    dedup_skipped = 0
    errors = 0

    for reg in regressions:
        ctrl = reg["control"]
        print(f"\nProcessing regression: {ctrl} ({reg['prev_status']} -> {reg['curr_status']})")

        existing = find_open_comp_issue(api_key, ctrl)
        if existing:
            seq_id = existing.get("sequence_id", "?")
            print(f"  Dedup: open COMP-{seq_id} already exists for {ctrl} — skipping create")
            dedup_skipped += 1
            time.sleep(0.3)
            continue

        title = (
            f"{ISSUE_TITLE_PREFIX}{ctrl} "
            f"flipped {reg['prev_status']}→FAIL"
        )
        html = build_regression_html(reg, date_today, date_yest, run_url, timestamp)

        code, resp = plane_request(
            api_key, "POST",
            f"workspaces/{WORKSPACE}/projects/{COMP_PROJECT_ID}/issues/",
            {
                "name": title,
                "description_html": html,
                "priority": "high",
                "state": COMP_BACKLOG_STATE,
            },
        )

        if code in (200, 201):
            seq_id = resp.get("sequence_id", "?")
            issue_id = resp.get("id", "unknown")
            print(f"  Created COMP-{seq_id} (id={issue_id}) for {ctrl}")
            created += 1
        else:
            print(f"  Error creating issue for {ctrl}: HTTP {code}: {resp}",
                  file=sys.stderr)
            errors += 1

        time.sleep(0.5)

    print(f"\nRegressions summary: created={created} dedup_skipped={dedup_skipped} errors={errors}")
    return errors


def process_recoveries(api_key, diff, date_today, date_yest, run_url):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    recoveries = diff.get("recoveries", [])
    if not recoveries:
        print("No recoveries to process")
        return 0

    commented = 0
    not_found = 0
    errors = 0

    for rec in recoveries:
        ctrl = rec["control"]
        print(f"\nProcessing recovery: {ctrl} (FAIL -> {rec['curr_status']})")

        existing = find_open_comp_issue(api_key, ctrl)
        if not existing:
            print(f"  No open COMP issue found for {ctrl} — nothing to comment on")
            not_found += 1
            time.sleep(0.3)
            continue

        issue_id = existing["id"]
        seq_id = existing.get("sequence_id", "?")

        comment_html = (
            f"<p><strong>OBSERVATION</strong> -- Control {ctrl} flipped back to {rec['curr_status']}</p>"
            f"<p><strong>Timestamp:</strong> {timestamp}</p>"
            f"<p>Compliance check on {date_today} shows status <strong>{rec['curr_status']}</strong> "
            f"(was FAIL on {date_yest}).</p>"
            f"<p><a href=\"{run_url}\">CI run (compliance-regression-alert.yml)</a></p>"
            f"<p><em>This issue remains open. Judge workflow is the authoritative closer per CLAUDE.md. "
            f"Operator review required before closing.</em></p>"
        )

        code, resp = plane_request(
            api_key, "POST",
            f"workspaces/{WORKSPACE}/projects/{COMP_PROJECT_ID}/issues/{issue_id}/comments/",
            {"comment_html": comment_html},
        )

        if code in (200, 201):
            print(f"  Commented on COMP-{seq_id} ({issue_id}) for {ctrl} recovery")
            commented += 1
        else:
            print(f"  Error commenting on issue for {ctrl}: HTTP {code}: {resp}",
                  file=sys.stderr)
            errors += 1

        time.sleep(0.5)

    print(f"\nRecoveries summary: commented={commented} no_open_issue={not_found} errors={errors}")
    return errors


def main():
    parser = argparse.ArgumentParser(description="Process compliance diff against Plane")
    parser.add_argument("--diff", required=True, help="Path to compliance-diff.json")
    parser.add_argument("--mode", required=True, choices=["regressions", "recoveries"])
    parser.add_argument("--date-today", required=True)
    parser.add_argument("--date-yesterday", required=True)
    parser.add_argument("--run-url", required=True)
    args = parser.parse_args()

    api_key = os.environ.get("PLANE_API_KEY", "")
    if not api_key:
        print("ERROR: PLANE_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    with open(args.diff) as f:
        diff = json.load(f)

    if args.mode == "regressions":
        errors = process_regressions(
            api_key, diff, args.date_today, args.date_yesterday, args.run_url
        )
    else:
        errors = process_recoveries(
            api_key, diff, args.date_today, args.date_yesterday, args.run_url
        )

    if errors > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
