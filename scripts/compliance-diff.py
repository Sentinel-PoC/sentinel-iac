#!/usr/bin/env python3
"""
compliance-diff.py — OPS-318
Diff two nist-compliance-check JSON reports and emit a structured delta.

Usage:
  python3 compliance-diff.py <today.json> <yesterday.json> <output.json>

Output schema:
  {
    "regressions": [  # PASS/WARN -> FAIL
      {"control": "AC-1", "prev_status": "PASS", "curr_status": "FAIL", "checks": [...]}
    ],
    "recoveries": [   # FAIL -> PASS/WARN
      {"control": "AC-2", "prev_status": "FAIL", "curr_status": "PASS", "checks": [...]}
    ]
  }

When multiple checks share a control-id, takes the worst status (FAIL > WARN > PASS)
to classify the control, matching how compliance-heartbeat.yml treats controls.
"""
import json
import sys
from pathlib import Path

SEVERITY = {"FAIL": 2, "WARN": 1, "PASS": 0}
REVERSE_SEV = {2: "FAIL", 1: "WARN", 0: "PASS"}


def worst_status(checks):
    """Return worst-case status across all checks for a control-id."""
    worst = 0
    for c in checks:
        worst = max(worst, SEVERITY.get(c.get("status", "PASS"), 0))
    return REVERSE_SEV[worst]


def build_control_map(report_path):
    """Return dict: control_id -> {status, checks: [check objects]}"""
    data = json.loads(Path(report_path).read_text())
    by_control = {}
    for check in data.get("checks", []):
        ctrl = check.get("control", "UNKNOWN")
        by_control.setdefault(ctrl, []).append(check)
    return {
        ctrl: {"status": worst_status(checks), "checks": checks}
        for ctrl, checks in by_control.items()
    }


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <today.json> <yesterday.json> <output.json>",
              file=sys.stderr)
        sys.exit(1)

    today_map = build_control_map(sys.argv[1])
    yest_map = build_control_map(sys.argv[2])
    output_path = sys.argv[3]

    regressions = []  # PASS/WARN -> FAIL
    recoveries = []   # FAIL -> PASS/WARN

    for ctrl, today_info in today_map.items():
        yest_info = yest_map.get(ctrl, {"status": "PASS", "checks": []})
        t_status = today_info["status"]
        y_status = yest_info["status"]

        if y_status != "FAIL" and t_status == "FAIL":
            regressions.append({
                "control": ctrl,
                "prev_status": y_status,
                "curr_status": t_status,
                "checks": today_info["checks"],
            })
        elif y_status == "FAIL" and t_status != "FAIL":
            recoveries.append({
                "control": ctrl,
                "prev_status": y_status,
                "curr_status": t_status,
                "checks": today_info["checks"],
            })

    output = {"regressions": regressions, "recoveries": recoveries}
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)

    reg_count = len(regressions)
    rec_count = len(recoveries)
    print(f"Regressions (PASS/WARN->FAIL): {reg_count}")
    print(f"Recoveries  (FAIL->PASS/WARN): {rec_count}")

    if regressions:
        print("Regressions:")
        for r in regressions:
            print(f"  {r['control']}: {r['prev_status']} -> FAIL")
    if recoveries:
        print("Recoveries:")
        for r in recoveries:
            print(f"  {r['control']}: FAIL -> {r['curr_status']}")


if __name__ == "__main__":
    main()
