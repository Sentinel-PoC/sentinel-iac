#!/usr/bin/env python3
"""
OPS-576: Atomic Red Team gap-filer.

Reads a single atom run result from stdin (JSON) and creates a Plane OPS issue
for detection gaps — i.e. atoms where Wazuh produced no matching alert.

Called by atom-runner.py for each FAIL result. Can also be run standalone:
    echo '{"technique": "T1053.003", ...}' | python3 gap-filer.py

Environment variables:
    PLANE_API_KEY   - Plane API key
    PLANE_WORKSPACE - Plane workspace slug (default: haists-it-consulting)
    PLANE_PROJECT   - Plane project UUID (default: OPS project UUID)

Exit codes:
    0 — issue created (prints issue URL to stdout)
    1 — error (prints error to stderr)
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

import requests

log = logging.getLogger("gap-filer")
logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(message)s")

PLANE_BASE_URL = "https://plane.208.haist.farm/api/v1"
PLANE_API_KEY = os.environ.get("PLANE_API_KEY", "")
PLANE_WORKSPACE = os.environ.get("PLANE_WORKSPACE", "haists-it-consulting")
PLANE_PROJECT = os.environ.get(
    "PLANE_PROJECT", "223c0b66-4255-406e-932f-3b50c0e93543"
)

# Plane label UUIDs (confirmed live — OPS-576 pre-flight)
LABEL_CAT_SECURITY = "ea9e03b1-c284-44fd-97a8-22ea977f2168"
LABEL_ORIGIN_AGENT = "118b04b4-6404-4991-aed8-706752b9c91b"

# Plane state UUID: "Todo"
STATE_TODO = "b7d7cdca-d840-4821-a27d-63ab85049ee3"

# OPS-576 parent issue UUID (gap issues are children of the harness issue)
PARENT_ISSUE = "73ad1180-2d6b-4f82-bbee-a9af635177c7"


def build_issue_body(result: dict) -> str:
    """Build HTML description for a gap issue."""
    technique = result.get("technique", "UNKNOWN")
    atom_name = result.get("name", "Unknown atom")
    exec_time = result.get("execution_time", "unknown")
    expected_rules = result.get("expected_rule_ids", [])
    detection_hits = result.get("detection_hits", [])
    error_msg = result.get("error", "")

    rules_str = (
        ", ".join(str(r) for r in expected_rules)
        if expected_rules
        else "any (no specific rules configured)"
    )

    hits_html = ""
    if detection_hits:
        hits_html = "<ul>" + "".join(
            f"<li>Rule {h.get('rule_id', '?')}: {h.get('rule_desc', '?')} @ {h.get('timestamp', '?')}</li>"
            for h in detection_hits
        ) + "</ul>"
    else:
        hits_html = "<p>No Wazuh alerts found within the detection window.</p>"

    return f"""<h3>Detection Gap — {technique}</h3>
<p>
  Atomic Red Team atom <strong>{atom_name}</strong> (<code>{technique}</code>) executed
  against <code>atomic-target</code> at <code>{exec_time}</code> but produced
  <strong>no Wazuh detection</strong> within the configured 5-minute window.
</p>

<h4>Expected Wazuh Rules</h4>
<p>{rules_str}</p>

<h4>Actual Detections</h4>
{hits_html}

<h4>MITRE ATT&CK Reference</h4>
<p>
  <a href="https://attack.mitre.org/techniques/{technique.replace('.', '/')}/">
    https://attack.mitre.org/techniques/{technique.replace('.', '/')}/
  </a>
</p>

<h4>Recommended Action</h4>
<ul>
  <li>Author a SIGMA rule covering this technique (feed to OPS-574 SIGMA pipeline)</li>
  <li>Verify the Wazuh agent on <code>atomic-target</code> was running and connected during the test</li>
  <li>Check <code>/var/ossec/logs/alerts/alerts.json</code> on <code>wazuh-server</code> for raw events</li>
  <li>If rule already exists, verify the log source is being forwarded from <code>atomic-target</code></li>
</ul>

<h4>Evidence</h4>
<p>
  Atom execution result: <code>{json.dumps(result, indent=2)[:500]}</code>
</p>
{'<h4>Error</h4><p>' + error_msg + '</p>' if error_msg else ''}

<p><em>Auto-filed by <code>gap-filer.py</code> (OPS-576) — {datetime.now(timezone.utc).isoformat()}</em></p>
"""


def create_plane_issue(result: dict) -> str:
    """
    Create a Plane OPS issue for a detection gap.
    Returns the issue URL on success, raises on failure.
    """
    technique = result.get("technique", "UNKNOWN")
    atom_name = result.get("name", "Unknown atom")

    title = f"[ATOM-GAP] {technique}: {atom_name} — no Wazuh detection"
    body_html = build_issue_body(result)

    payload = {
        "name": title,
        "description_html": body_html,
        "priority": "medium",
        "state": STATE_TODO,
        "parent": PARENT_ISSUE,
        "label_ids": [LABEL_CAT_SECURITY, LABEL_ORIGIN_AGENT],
    }

    url = (
        f"{PLANE_BASE_URL}/workspaces/{PLANE_WORKSPACE}"
        f"/projects/{PLANE_PROJECT}/issues/"
    )

    resp = requests.post(
        url,
        json=payload,
        headers={"x-api-key": PLANE_API_KEY, "Content-Type": "application/json"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()

    issue_id = data.get("sequence_id", "?")
    issue_uuid = data.get("id", "")
    issue_url = (
        f"https://plane.208.haist.farm/haists-it-consulting/projects/"
        f"{PLANE_PROJECT}/issues/{issue_uuid}/"
    )
    log.info("Created Plane issue OPS-%s: %s", issue_id, issue_url)
    return issue_url


def main() -> int:
    if not PLANE_API_KEY:
        log.error("PLANE_API_KEY not set")
        return 1

    # Read atom result JSON from stdin
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        log.error("Failed to parse stdin JSON: %s", exc)
        return 1

    # Only file for genuine FAILs (skip PASS and ERROR — caller should filter)
    status = data.get("status", "")
    if status != "FAIL":
        log.info("Status is %s (not FAIL) — no gap issue needed", status)
        print(f"skip:{status}")
        return 0

    try:
        url = create_plane_issue(data)
        print(url)
        return 0
    except requests.HTTPError as exc:
        log.error("Plane API error: %s — %s", exc, exc.response.text[:200] if exc.response else "")
        return 1
    except Exception as exc:
        log.error("Unexpected error: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
