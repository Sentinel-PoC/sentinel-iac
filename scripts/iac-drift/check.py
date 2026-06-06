#!/usr/bin/env python3
"""iac-drift/check.py — IaC vs live-config drift detector. OPS-193.

Reads scripts/iac-drift/rules.yaml, queries each system's live API,
applies declarative expectations, emits one JSON line per check to stdout
plus journald (via logger). Exit codes follow the vault-health-probe
convention:

    0 — all rules PASS
    1 — at least one rule WARN, none CRIT
    2 — at least one rule CRIT or scheduler error

Designed to run as a systemd timer on iac-control alongside
vault-autounseal-token-ttl + vault-health-probe + vault-unseal-transit.
Can also be run ad-hoc from the operator workstation given the right
Vault token in environment.

Auth sources are read from Vault using the token in env VAULT_TOKEN. The
script never logs any token; only resource-attribute fingerprints (last 8
chars) and rule-result classifications appear in output.

Usage:
    iac-drift/check.py
    iac-drift/check.py --rules custom-rules.yaml
    iac-drift/check.py --verbose       # include diff details on FAIL
    iac-drift/check.py --rule-id NAME  # run a single rule (debugging)
    iac-drift/check.py --dry-run       # no logger / no log-file emission
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

try:
    import yaml  # type: ignore[import-not-found]
except ImportError:
    print("ERROR: PyYAML required (apt install python3-yaml)", file=sys.stderr)
    sys.exit(2)


def vault_kv_read(vault_addr: str, token: str, path: str) -> dict:
    """Read a KV v2 secret. Returns the data.data dict."""
    if path.startswith("secret/"):
        kv_path = "secret/data/" + path[len("secret/"):]
    else:
        kv_path = path
    url = f"{vault_addr.rstrip('/')}/v1/{kv_path}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": token})
    with urllib.request.urlopen(req, timeout=10) as r:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
        body = json.loads(r.read())
    return body["data"]["data"]


def vault_policy_read(vault_addr: str, token: str, name: str) -> str | None:
    """Read a Vault ACL policy by name. Returns the HCL string or None."""
    url = f"{vault_addr.rstrip('/')}/v1/sys/policies/acl/{urllib.parse.quote(name)}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": token})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
            body = json.loads(r.read())
        return body.get("data", {}).get("policy")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def http_get(url: str, headers: dict[str, str] | None = None) -> tuple[int, dict | str]:
    """Best-effort GET. Returns (status, parsed_json_or_raw_body). Never raises."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
            body = r.read().decode("utf-8", errors="replace")
            try:
                return r.status, json.loads(body)
            except json.JSONDecodeError:
                return r.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, body
    except urllib.error.URLError as e:
        return 0, f"URLError: {e.reason}"


def http_post(url: str, headers: dict, data: bytes) -> tuple[int, dict | str]:
    req = urllib.request.Request(url, headers=headers, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
            body = r.read().decode("utf-8", errors="replace")
            try:
                return r.status, json.loads(body)
            except json.JSONDecodeError:
                return r.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, body


def jq_extract(blob: Any, expr: str) -> Any:
    """Use jq if available, otherwise raise. Lets us reuse jq syntax in rules."""
    if not shutil.which("jq"):
        raise RuntimeError("jq not on PATH — install jq to use rules with .jq filters")
    proc = subprocess.run(
        ["jq", expr],
        input=json.dumps(blob).encode(),
        capture_output=True,
        timeout=10,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"jq failed: {proc.stderr.decode().strip()}")
    out = proc.stdout.decode().strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out


def get_wazuh_token(addr: str, user: str, password: str) -> str:
    parsed = urllib.parse.urlparse(addr)
    auth = f"{user}:{password}".encode()
    import base64
    headers = {
        "Authorization": "Basic " + base64.b64encode(auth).decode(),
        "Content-Type": "application/json",
    }
    status, body = http_post(f"{addr.rstrip('/')}/security/user/authenticate", headers, b"{}")
    if status != 200 or not isinstance(body, dict):
        raise RuntimeError(f"wazuh auth failed: status={status} body={str(body)[:200]}")
    return body["data"]["token"]


def fetch_source(rule: dict, vault_addr: str, vault_token: str, cache: dict) -> Any:
    src = rule["source"]
    kind = src["kind"]

    if kind == "wazuh-api":
        if "wazuh_token" not in cache:
            wz = vault_kv_read(vault_addr, vault_token, "secret/wazuh/api")
            cache["wazuh_token"] = get_wazuh_token(
                "https://wazuh-api.208.haist.farm", wz["username"], wz["password"]
            )
        token = cache["wazuh_token"]
        url = f"https://wazuh-api.208.haist.farm{src['path']}"
        status, body = http_get(url, {"Authorization": f"Bearer {token}"})
        if status != 200:
            raise RuntimeError(f"wazuh-api {src['path']} returned {status}")
        if "jq" in src:
            return jq_extract(body, src["jq"])
        return body

    if kind == "vault-policy":
        return vault_policy_read(vault_addr, vault_token, src["name"])

    if kind == "http":
        method = src.get("method", "GET").upper()
        if method != "GET":
            raise RuntimeError(f"http kind only supports GET; got {method}")
        status, body = http_get(src["url"])
        return {"status": status, "body": body}

    raise RuntimeError(f"unknown source kind: {kind}")


def evaluate_expect(expect: dict, observed: Any) -> tuple[bool, str]:
    """Return (passed, diff_summary)."""
    if "equals" in expect:
        want = expect["equals"]
        if observed == want:
            return True, ""
        return False, f"expected {want!r}, got {observed!r}"

    if "subset" in expect:
        # All key/values in expect.subset must appear in observed; extra keys in
        # observed are tolerated (covers the "live config has additional benign
        # fields" case without weakening the contract on the named fields).
        want = expect["subset"]
        if not isinstance(observed, dict):
            return False, f"subset check requires dict observed; got {type(observed).__name__}"
        missing = {k: v for k, v in want.items() if observed.get(k) != v}
        if not missing:
            return True, ""
        return False, f"subset mismatch: expected {missing!r} (within {observed!r})"

    if "contains" in expect:
        needle = expect["contains"]
        if isinstance(observed, list):
            if needle in observed:
                return True, ""
            return False, f"list missing {needle!r}; have {observed!r}"
        if isinstance(observed, str):
            if needle in observed:
                return True, ""
            return False, f"string missing {needle!r}"
        return False, f"contains check on unsupported type: {type(observed).__name__}"

    if "paths_contain" in expect:
        # observed is the Vault HCL policy text
        if not isinstance(observed, str):
            return False, "policy not retrieved (None)"
        missing = [p for p in expect["paths_contain"] if f'path "{p}"' not in observed]
        if not missing:
            return True, ""
        return False, f"policy missing path declarations: {missing!r}"

    if "json_field_contains" in expect:
        # observed should be {"status": int, "body": dict|str}
        spec = expect["json_field_contains"]
        body = observed.get("body") if isinstance(observed, dict) else None
        if not isinstance(body, dict):
            return False, f"body is not JSON dict: {str(body)[:120]}"
        # Use jq to dig into body
        try:
            found = jq_extract(body, spec["path"])
        except RuntimeError as e:
            return False, str(e)
        if found is None:
            return False, f"json path {spec['path']} returned null"
        if isinstance(found, str) and spec["value"] in found:
            return True, ""
        return False, f"json field at {spec['path']} = {found!r}, expected substring {spec['value']!r}"

    return False, f"unknown expect kind: {list(expect.keys())}"


def emit(record: dict, dry_run: bool) -> None:
    line = json.dumps(record)
    print(line)
    if dry_run:
        return
    try:
        log_dir = os.path.dirname("/var/log/iac-drift-check.json")
        if os.access(log_dir, os.W_OK):
            with open("/var/log/iac-drift-check.json", "a") as f:
                f.write(line + "\n")
    except OSError:
        pass
    if shutil.which("logger"):
        sev_map = {"OK": "user.info", "WARN": "user.warning", "CRIT": "user.crit"}
        pri = sev_map.get(record.get("status", "CRIT"), "user.crit")
        subprocess.run(["logger", "-t", "iac-drift-check", "-p", pri, line], check=False)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", default=os.path.join(os.path.dirname(__file__), "rules.yaml"))
    ap.add_argument("--rule-id", help="run only the named rule (debugging)")
    ap.add_argument("--verbose", action="store_true", help="include observed-value details on FAIL")
    ap.add_argument("--dry-run", action="store_true", help="no logger/log-file emission, stdout only")
    args = ap.parse_args()

    if not os.path.exists(args.rules):
        print(f"ERROR: rules file not found: {args.rules}", file=sys.stderr)
        sys.exit(2)
    with open(args.rules) as f:
        config = yaml.safe_load(f)

    vault_token = os.environ.get("VAULT_TOKEN")
    if not vault_token:
        token_file = "/etc/iac-drift/vault-token"
        if os.access(token_file, os.R_OK):
            vault_token = open(token_file).read().strip()
    if not vault_token:
        print("ERROR: VAULT_TOKEN env unset and /etc/iac-drift/vault-token unreadable", file=sys.stderr)
        sys.exit(2)

    vault_addr = config.get("vault", {}).get("addr", os.environ.get("VAULT_ADDR", "https://vault.208.haist.farm"))

    rules = config.get("rules", [])
    if args.rule_id:
        rules = [r for r in rules if r.get("id") == args.rule_id]
        if not rules:
            print(f"ERROR: no rule with id={args.rule_id}", file=sys.stderr)
            sys.exit(2)

    cache: dict = {}
    counts = {"OK": 0, "WARN": 0, "CRIT": 0}
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    for rule in rules:
        rule_id = rule.get("id", "<unnamed>")
        severity = (rule.get("severity") or "warn").lower()
        try:
            observed = fetch_source(rule, vault_addr, vault_token, cache)
            passed, diff = evaluate_expect(rule["expect"], observed)
        except Exception as e:
            passed, diff = False, f"fetch/eval error: {type(e).__name__}: {e}"
            severity = "crit"

        if passed:
            status = "OK"
        elif severity == "crit":
            status = "CRIT"
        elif severity == "warn":
            status = "WARN"
        else:
            status = "OK"  # info-only rules log but never alert

        counts[status] = counts.get(status, 0) + 1
        record = {
            "check": "iac_drift",
            "ts": ts,
            "rule_id": rule_id,
            "system": rule.get("system", "?"),
            "status": status,
            "severity_planned": severity,
            "description": rule.get("description"),
        }
        if not passed:
            record["diff"] = diff
            if args.verbose:
                record["observed"] = observed
            if rule.get("rationale"):
                record["rationale"] = rule["rationale"]
        emit(record, dry_run=args.dry_run)

    summary = {
        "check": "iac_drift",
        "ts": ts,
        "rule_id": "_summary",
        "status": "CRIT" if counts["CRIT"] else "WARN" if counts["WARN"] else "OK",
        "totals": counts,
    }
    emit(summary, dry_run=args.dry_run)

    if counts["CRIT"]:
        sys.exit(2)
    if counts["WARN"]:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
