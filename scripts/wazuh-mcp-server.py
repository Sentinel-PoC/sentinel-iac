#!/usr/bin/env python3
"""Wazuh MCP Server — rules + alerts + agents as queryable tools

Wraps the Wazuh REST API (v4.x) for use as a Claude MCP server.
Exposes three read-only tools:
  wazuh_rules_search   — search rules by id / level / group / text
  wazuh_alerts_search  — query daily alert stats by rule_id / level / date
  wazuh_agents_list    — list all registered agents with status

Auth: Wazuh JWT fetched from credentials stored in Vault secret/wazuh.
The JWT TTL is 900s by default; the server re-fetches on 401 Unauthorized.
This server has no write access — all requests are GET or POST-to-authenticate only.

Installation:
  uv tool install mcp            # installs mcp SDK globally via uv
  pip install hvac               # python-hvac for Vault reads (already present)

Run directly (stdio transport, for MCP client use):
  /path/to/wazuh-mcp-server.py

Or register in claude-config/settings.json mcpServers:
  "wazuh": {
    "command": "/home/koiakoia/.local/share/uv/tools/mcp/bin/python3",
    "args": ["/home/koiakoia/repos/sentinel-iac/scripts/wazuh-mcp-server.py"]
  }

Relates to: OPS-382
"""

import json
import os
import ssl
import time
import urllib.error
import urllib.request
from typing import Any

import hvac
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://vault.208.haist.farm")
VAULT_TOKEN_FILE = os.path.expanduser("~/.vault-token")
WAZUH_SECRET_PATH = "secret/wazuh"

# Session state — lazy-loaded
_wazuh_url: str = ""
_wazuh_api_user: str = ""
_wazuh_api_password: str = ""
_wazuh_jwt: str = ""
_wazuh_jwt_fetched_at: float = 0.0
_JWT_TTL = 800  # seconds before proactive refresh (JWT default TTL is 900s)

mcp = FastMCP("wazuh")


# ---------------------------------------------------------------------------
# Vault + Wazuh auth helpers
# ---------------------------------------------------------------------------

def _load_wazuh_creds() -> None:
    """Read Wazuh API credentials from Vault secret/wazuh."""
    global _wazuh_url, _wazuh_api_user, _wazuh_api_password

    vault_token = os.environ.get("VAULT_TOKEN", "")
    if not vault_token:
        try:
            with open(VAULT_TOKEN_FILE) as fh:
                vault_token = fh.read().strip()
        except OSError:
            raise RuntimeError(
                "No VAULT_TOKEN env var and ~/.vault-token not readable. "
                "Cannot load Wazuh credentials."
            )

    client = hvac.Client(url=VAULT_ADDR, token=vault_token)
    secret = client.secrets.kv.v2.read_secret_version(
        path="wazuh", raise_on_deleted_version=True
    )
    data = secret["data"]["data"]
    _wazuh_url = data["url"].rstrip("/")
    _wazuh_api_user = data["api_user"]
    _wazuh_api_password = data["api_password"]


def _fetch_jwt() -> str:
    """Authenticate against the Wazuh API and return a JWT."""
    if not _wazuh_url:
        _load_wazuh_creds()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # nosec B501 — Wazuh uses self-signed cert; internal network only

    import base64

    creds = base64.b64encode(
        f"{_wazuh_api_user}:{_wazuh_api_password}".encode()
    ).decode()
    req = urllib.request.Request(
        f"{_wazuh_url}:55000/security/user/authenticate",
        method="POST",
        headers={"Authorization": f"Basic {creds}"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:  # nosec B310
        body = json.loads(resp.read())
    token = body["data"]["token"]
    return token


def _ensure_jwt() -> str:
    """Return a valid Wazuh JWT, refreshing if near expiry or missing."""
    global _wazuh_jwt, _wazuh_jwt_fetched_at
    if not _wazuh_url:
        _load_wazuh_creds()
    now = time.monotonic()
    if not _wazuh_jwt or (now - _wazuh_jwt_fetched_at) > _JWT_TTL:
        _wazuh_jwt = _fetch_jwt()
        _wazuh_jwt_fetched_at = now
    return _wazuh_jwt


def _wazuh_get(path: str, *, params: dict[str, Any] | None = None) -> dict:
    """GET from the Wazuh API at the given path, retrying once on 401."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # nosec B501 — internal only

    if params:
        from urllib.parse import urlencode
        qs = urlencode({k: v for k, v in params.items() if v is not None})
        url = f"{_wazuh_url}:55000{path}?{qs}"
    else:
        url = f"{_wazuh_url}:55000{path}"

    for attempt in range(2):
        jwt = _ensure_jwt()
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {jwt}"},
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:  # nosec B310
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            if exc.code == 401 and attempt == 0:
                # Force JWT refresh on next attempt
                global _wazuh_jwt_fetched_at
                _wazuh_jwt_fetched_at = 0.0
                continue
            raise


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------

@mcp.tool()
def wazuh_rules_search(
    rule_ids: str = "",
    level: int = 0,
    group: str = "",
    search: str = "",
    limit: int = 25,
) -> str:
    """Search Wazuh detection rules.

    Args:
        rule_ids: Comma-separated rule IDs to look up (e.g. '521,1002'). Optional.
        level:    Minimum rule severity level (1-15). 0 means no filter.
        group:    Rule group filter (e.g. 'rootcheck', 'syslog', 'ossec'). Optional.
        search:   Free-text search against rule description. Optional.
        limit:    Max results to return (default 25, max 500).

    Returns JSON array of matching rules with id, level, description, groups,
    filename, pci_dss, nist_800_53, mitre fields.
    """
    params: dict[str, Any] = {"limit": min(limit, 500)}
    if rule_ids:
        params["rule_ids"] = rule_ids
    if level > 0:
        params["level"] = f"{level}-15"
    if group:
        params["group"] = group
    if search:
        params["search"] = search

    data = _wazuh_get("/rules", params=params)
    items = data.get("data", {}).get("affected_items", [])
    total = data.get("data", {}).get("total_affected_items", 0)

    result = {
        "total_matching": total,
        "returned": len(items),
        "rules": [
            {
                "id": r.get("id"),
                "level": r.get("level"),
                "description": r.get("description"),
                "groups": r.get("groups", []),
                "filename": r.get("filename"),
                "pci_dss": r.get("pci_dss", []),
                "nist_800_53": r.get("nist_800_53", []),
                "gdpr": r.get("gdpr", []),
                "mitre": r.get("mitre", []),
                "status": r.get("status"),
            }
            for r in items
        ],
    }
    return json.dumps(result, indent=2)


@mcp.tool()
def wazuh_alerts_search(
    date: str = "",
    rule_id: int = 0,
    min_level: int = 0,
    limit: int = 50,
) -> str:
    """Query Wazuh alert statistics for a given day.

    Uses the manager/stats endpoint which returns per-hour alert counts grouped
    by rule ID and level. Suitable for understanding alert volumes, trending
    rules, and level-filtered summaries.

    Args:
        date:      Date in YYYY-MM-DD format (defaults to today UTC).
        rule_id:   Filter to a specific rule ID (sigid). 0 means no filter.
        min_level: Minimum rule level to include (0 = include all).
        limit:     Max hours to include (default 50 = full day).

    Returns JSON with per-hour alert counts. Each hour entry lists rules fired
    with sigid (rule ID), level, and times (count). Also includes a summary of
    top rules across the day sorted by total alert count.
    """
    if not date:
        date = time.strftime("%Y-%m-%d", time.gmtime())

    params: dict[str, Any] = {"date": date}
    data = _wazuh_get("/manager/stats", params=params)
    items = data.get("data", {}).get("affected_items", [])

    # Aggregate across hours
    rule_totals: dict[int, dict] = {}
    filtered_hours = []

    for hour_data in items[:limit]:
        hour = hour_data.get("hour", "?")
        hour_alerts = []
        for alert in hour_data.get("alerts", []):
            sigid = alert.get("sigid", 0)
            level = alert.get("level", 0)
            count = alert.get("times", 0)

            if rule_id and sigid != rule_id:
                continue
            if min_level and level < min_level:
                continue

            hour_alerts.append({"sigid": sigid, "level": level, "count": count})

            if sigid not in rule_totals:
                rule_totals[sigid] = {"sigid": sigid, "level": level, "total": 0}
            rule_totals[sigid]["total"] += count

        if hour_alerts:
            filtered_hours.append({"hour": hour, "alerts": hour_alerts})

    top_rules = sorted(rule_totals.values(), key=lambda x: x["total"], reverse=True)[:20]

    result = {
        "date": date,
        "hours_with_alerts": len(filtered_hours),
        "top_rules_by_count": top_rules,
        "hourly_breakdown": filtered_hours,
    }
    return json.dumps(result, indent=2)


@mcp.tool()
def wazuh_agents_list(
    status: str = "",
    search: str = "",
    limit: int = 100,
) -> str:
    """List registered Wazuh agents.

    Args:
        status: Filter by agent status: 'active', 'disconnected', 'never_connected',
                'pending'. Empty means return all.
        search: Free-text search against agent name or IP. Optional.
        limit:  Max agents to return (default 100).

    Returns JSON array of agents with id, name, ip, os, status, version,
    last_keepalive, and group fields.
    """
    params: dict[str, Any] = {"limit": min(limit, 500)}
    if status:
        params["status"] = status
    if search:
        params["search"] = search

    data = _wazuh_get("/agents", params=params)
    items = data.get("data", {}).get("affected_items", [])
    total = data.get("data", {}).get("total_affected_items", 0)

    result = {
        "total_agents": total,
        "returned": len(items),
        "agents": [
            {
                "id": a.get("id"),
                "name": a.get("name"),
                "ip": a.get("ip"),
                "status": a.get("status"),
                "version": a.get("version"),
                "os_name": a.get("os", {}).get("name") if a.get("os") else None,
                "os_version": a.get("os", {}).get("version") if a.get("os") else None,
                "last_keepalive": a.get("lastKeepAlive"),
                "groups": a.get("group", []),
            }
            for a in items
        ],
    }
    return json.dumps(result, indent=2)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Pre-load credentials so first tool call is fast
    try:
        _load_wazuh_creds()
    except Exception as exc:
        import sys
        print(f"[wazuh-mcp] WARNING: Could not pre-load creds: {exc}", file=sys.stderr)

    mcp.run(transport="stdio")
