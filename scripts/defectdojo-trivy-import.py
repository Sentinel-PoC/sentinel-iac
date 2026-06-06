#!/usr/bin/env python3
"""SEC-50 Phase 1 — push the latest Trivy IaC scan into DefectDojo.

Runs daily via the defectdojo-trivy-import.timer systemd unit (07:30 UTC,
30 min after evidence-pipeline collects the scan into compliance-vault).

Pipeline:
  1. Read the Vault token from /etc/sentinel/compliance.env
  2. Use the Vault token to fetch the DefectDojo API token from
     secret/defectdojo field api_token
  3. Find the newest trivy-iac-scan-*.json in the local
     compliance-vault checkout
  4. Look up the latest Trivy-Scan test in DefectDojo engagement 3
     (Sentinel IaC product, "Main Branch CI/CD — IaC" engagement)
  5. If a test exists: reimport-scan into it (auto-mitigates findings
     that disappeared from the new scan)
     If no test exists: import-scan (first-run path)
  6. Log the test_id + per-severity counts, exit non-zero on failure

NIST: RA-5 Vulnerability Monitoring, RA-5(2) Update Vulnerabilities,
SI-2 Flaw Remediation. The reimport flow IS the documented fix
verification.
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
from glob import glob
from pathlib import Path

VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://vault.208.haist.farm")
DD_URL = "https://defectdojo.208.haist.farm"
DD_PRODUCT_ID = 1                # "Sentinel IaC"
DD_ENGAGEMENT_ID = 3             # "Main Branch CI/CD — IaC"
DD_SCAN_TYPE = "Trivy Scan"
COMPLIANCE_VAULT = Path("/home/ubuntu/compliance-vault")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def log(msg: str) -> None:
    print(msg, flush=True)


def vault_token_from_compliance_env() -> str:
    """Compliance.env is the canonical secrets-bridge for iac-control jobs."""
    for line in Path("/etc/sentinel/compliance.env").read_text().splitlines():
        if line.startswith("VAULT_TOKEN="):
            return line.split("=", 1)[1].strip().strip("'\"")
    raise RuntimeError("VAULT_TOKEN not found in /etc/sentinel/compliance.env")


def http(url: str, method: str = "GET", *, headers=None, data=None, files=None) -> dict:
    """Minimal HTTP client. Supports JSON GET/POST and multipart upload."""
    headers = dict(headers or {})
    body = None
    if files is not None:
        boundary = "----dd-trivy-import-boundary"
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        chunks = []
        for k, v in (data or {}).items():
            chunks.append(f"--{boundary}\r\n".encode())
            chunks.append(f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode())
            chunks.append(str(v).encode())
            chunks.append(b"\r\n")
        for k, path in files.items():
            fname = os.path.basename(path)
            chunks.append(f"--{boundary}\r\n".encode())
            chunks.append(
                f'Content-Disposition: form-data; name="{k}"; filename="{fname}"\r\n'.encode()
            )
            chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
            chunks.append(Path(path).read_bytes())
            chunks.append(b"\r\n")
        chunks.append(f"--{boundary}--\r\n".encode())
        body = b"".join(chunks)
    elif data is not None:
        body = json.dumps(data).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, context=CTX, timeout=30) as resp:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
        return json.loads(resp.read())


def get_dd_api_token(vault_token: str) -> str:
    r = http(
        f"{VAULT_ADDR}/v1/secret/data/defectdojo",
        headers={"X-Vault-Token": vault_token},
    )
    return r["data"]["data"]["api_token"]


def latest_trivy_scan() -> Path:
    pattern = str(COMPLIANCE_VAULT / "scan-results" / "trivy-iac-scan-*.json")
    matches = sorted(glob(pattern), reverse=True)
    if not matches:
        raise RuntimeError(f"no trivy-iac-scan files matching {pattern}")
    return Path(matches[0])


def find_existing_test(dd_token: str) -> int | None:
    """Return the most-recent test_id of scan_type in our engagement, or None."""
    qs = urllib.parse.urlencode({
        "engagement": DD_ENGAGEMENT_ID,
        "scan_type": DD_SCAN_TYPE,
        "limit": 50,
    })
    r = http(
        f"{DD_URL}/api/v2/tests/?{qs}",
        headers={"Authorization": f"Token {dd_token}"},
    )
    results = r.get("results", [])
    if not results:
        return None
    # DefectDojo returns by created descending — pick first
    return results[0]["id"]


def reimport(dd_token: str, test_id: int, scan_path: Path) -> dict:
    return http(
        f"{DD_URL}/api/v2/reimport-scan/",
        method="POST",
        headers={"Authorization": f"Token {dd_token}"},
        data={
            "test": test_id,
            "scan_type": DD_SCAN_TYPE,
            "active": "true",
            "verified": "false",
        },
        files={"file": str(scan_path)},
    )


def first_import(dd_token: str, scan_path: Path) -> dict:
    return http(
        f"{DD_URL}/api/v2/import-scan/",
        method="POST",
        headers={"Authorization": f"Token {dd_token}"},
        data={
            "engagement": DD_ENGAGEMENT_ID,
            "scan_type": DD_SCAN_TYPE,
            "active": "true",
            "verified": "false",
            "auto_create_context": "false",
            "deduplication_on_engagement": "true",
        },
        files={"file": str(scan_path)},
    )


def stats_summary(stats) -> str:
    if not isinstance(stats, dict):
        return "(no stats)"
    after = stats.get("after", stats)
    parts = []
    for sev in ("critical", "high", "medium", "low", "info"):
        b = after.get(sev) or {}
        parts.append(f"{sev}={b.get('total', 0)}")
    return " ".join(parts)


def main() -> int:
    vault_token = vault_token_from_compliance_env()
    dd_token = get_dd_api_token(vault_token)
    scan = latest_trivy_scan()
    log(f"latest scan: {scan.name} ({scan.stat().st_size} bytes)")

    test_id = find_existing_test(dd_token)
    if test_id:
        log(f"reimport into existing test_id={test_id}")
        result = reimport(dd_token, test_id, scan)
    else:
        log("no existing test in engagement; first-time import")
        result = first_import(dd_token, scan)

    if result.get("test_id") is None:
        log(f"FAIL: detail={result.get('detail')}")
        return 1
    log(f"ok test_id={result['test_id']} engagement={result.get('engagement_id', DD_ENGAGEMENT_ID)} stats: {stats_summary(result.get('statistics'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
