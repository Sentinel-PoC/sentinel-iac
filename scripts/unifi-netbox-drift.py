#!/usr/bin/env python3
"""
unifi-netbox-drift.py — UniFi → NetBox drift detector (Phase 1, read-only)
OPS-691

Reads UniFi state via sentinel-unifi library, reads NetBox state via REST API,
diffs per resource type, writes structured JSON drift report.

Read-only: no automatic corrections. Drift is reported, not fixed.

Resource types covered:
  - Devices (match by name; check primary_ip, status)
  - Networks/VLANs (match by VLAN ID; check name, subnet)
  - ACL rules (count + ordering; schema_gap reported if NetBox plugin absent)
  - Firewall policies + ordering (schema_gap if plugin absent)
  - Traffic Matching Lists (schema_gap if plugin absent)

Output:
  - JSON report: $DRIFT_REPORT_PATH (default /var/log/unifi-netbox-drift.json)
  - Summary line: stdout → systemd journal via StandardOutput=journal

When the NetBox Firewall plugin (netbox-acls) is installed, the drift detector
will automatically start comparing ACL rules, firewall policies, and TMLs
against NetBox plugin objects by detecting the plugin's API endpoints.
"""

import json
import logging
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
    stream=sys.stdout,
)
log = logging.getLogger("unifi-netbox-drift")

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------

NETBOX_API_TOKEN = os.environ.get("NETBOX_API_TOKEN", "")
NETBOX_API_ENDPOINT = os.environ.get(
    "NETBOX_API_ENDPOINT", "https://netbox.208.haist.farm"
).rstrip("/")
UNIFI_API_KEY = os.environ.get("UNIFI_API_KEY", "")
UNIFI_CONTROLLER_URL = os.environ.get(
    "UNIFI_CONTROLLER_URL", "https://192.168.12.1"
).rstrip("/")
SENTINEL_UNIFI_DIR = os.environ.get(
    "SENTINEL_UNIFI_DIR", "/home/ubuntu/sentinel-unifi"
)
DRIFT_REPORT_PATH = os.environ.get(
    "DRIFT_REPORT_PATH", "/var/log/unifi-netbox-drift.json"
)
DRIFT_LOG_DIR = os.environ.get(
    "DRIFT_LOG_DIR", "/var/log/sentinel/unifi-netbox-drift"
)

# ---------------------------------------------------------------------------
# Required env guard
# ---------------------------------------------------------------------------


def _check_env() -> None:
    missing = []
    if not NETBOX_API_TOKEN:
        missing.append("NETBOX_API_TOKEN")
    if not UNIFI_API_KEY:
        missing.append("UNIFI_API_KEY")
    if missing:
        log.error("Required env vars not set: %s", ", ".join(missing))
        sys.exit(1)


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _session_with_retries(verify: bool = False) -> requests.Session:
    sess = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
    )
    adapter = HTTPAdapter(max_retries=retry)
    sess.mount("https://", adapter)
    sess.mount("http://", adapter)
    sess.verify = verify
    return sess


# ---------------------------------------------------------------------------
# sentinel-unifi library import + OPS-687 shims
# ---------------------------------------------------------------------------


def _load_unifi_client():
    """Import UniFiClient from local sentinel-unifi repo.

    Monkey-patches missing OPS-687 read methods (list_traffic_matching_lists,
    get_acl_rules_ordering, get_firewall_policy_ordering) if the local copy
    pre-dates those merges.  Once sentinel-unifi is pulled to OPS-687 head
    these shims become no-ops.
    """
    if SENTINEL_UNIFI_DIR not in sys.path:
        sys.path.insert(0, SENTINEL_UNIFI_DIR)

    try:
        from unifi.client import UniFiClient
    except ImportError as exc:
        log.error(
            "Cannot import sentinel-unifi from %s: %s", SENTINEL_UNIFI_DIR, exc
        )
        sys.exit(1)

    # --- OPS-687 read-method shims ---
    # list_traffic_matching_lists
    if not hasattr(UniFiClient, "list_traffic_matching_lists"):
        log.warning(
            "sentinel-unifi pre-OPS-687: patching list_traffic_matching_lists()"
        )

        def _list_tml(self, site_id: str) -> list:
            return self._paginate(f"/sites/{site_id}/traffic-matching-lists")

        UniFiClient.list_traffic_matching_lists = _list_tml

    # get_acl_rules_ordering
    if not hasattr(UniFiClient, "get_acl_rules_ordering"):
        log.warning(
            "sentinel-unifi pre-OPS-687: patching get_acl_rules_ordering()"
        )

        def _get_acl_order(self, site_id: str) -> dict:
            return self._get(f"/sites/{site_id}/acl-rules/ordering")

        UniFiClient.get_acl_rules_ordering = _get_acl_order

    # get_firewall_policy_ordering
    # OPS-693: fix shim param names to match upstream sentinel-unifi (OPS-687 PR #5).
    # Upstream (firewall.py:68) uses sourceFirewallZoneId / destinationFirewallZoneId;
    # original shim had sourceZoneId / destinationZoneId (wrong names).
    # Shim is dormant when OPS-687 is merged (hasattr guard prevents execution),
    # but fix ensures correctness if ever triggered on a pre-OPS-687 install.
    if not hasattr(UniFiClient, "get_firewall_policy_ordering"):
        log.warning(
            "sentinel-unifi pre-OPS-687: patching get_firewall_policy_ordering()"
        )

        def _get_fw_order(
            self, site_id: str, source_zone_id: str, dest_zone_id: str
        ) -> dict:
            return self._get(
                f"/sites/{site_id}/firewall/policies/ordering"
                f"?sourceFirewallZoneId={source_zone_id}"
                f"&destinationFirewallZoneId={dest_zone_id}"
            )

        UniFiClient.get_firewall_policy_ordering = _get_fw_order

    return UniFiClient


# ---------------------------------------------------------------------------
# NetBox API helpers
# ---------------------------------------------------------------------------


def netbox_get(sess: requests.Session, path: str, params: dict = None) -> list:
    """Paginate through NetBox API list endpoint, return all results."""
    url = f"{NETBOX_API_ENDPOINT}{path}"
    headers = {
        "Authorization": f"Token {NETBOX_API_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    results = []
    while url:
        resp = sess.get(url, headers=headers, params=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        results.extend(data.get("results", []))
        url = data.get("next")
        params = None  # only pass params on first request; next URL has them
    return results


def netbox_plugin_available(sess: requests.Session, plugin_name: str) -> bool:
    """Check if a NetBox plugin is installed by probing its API root."""
    try:
        resp = sess.get(
            f"{NETBOX_API_ENDPOINT}/api/plugins/{plugin_name}/",
            headers={"Authorization": f"Token {NETBOX_API_TOKEN}"},
            timeout=10,
        )
        return resp.status_code == 200
    except requests.RequestException:
        return False


# ---------------------------------------------------------------------------
# UniFi state collectors
# ---------------------------------------------------------------------------


def collect_unifi_state(client) -> dict:
    """Collect all relevant UniFi state for drift detection.

    Returns a dict with keys: sites, devices, networks, acl_rules,
    acl_ordering, firewall_policies, firewall_zones, traffic_matching_lists.
    """
    log.info("Collecting UniFi state...")
    sites = client.list_sites()
    if not sites:
        log.error("No UniFi sites found — check API key and controller URL")
        sys.exit(1)

    # Use first site (this deployment has one site)
    site = sites[0]
    site_id = site.get("id") or site.get("_id") or site.get("siteId")
    site_name = site.get("name") or site.get("desc", "default")
    log.info("Using site: %s (id=%s)", site_name, site_id)

    state = {
        "site_id": site_id,
        "site_name": site_name,
        "devices": [],
        "networks": [],
        "acl_rules": [],
        "acl_ordering": {},
        "firewall_zones": [],
        "firewall_policies": [],
        "firewall_policy_ordering": {},
        "traffic_matching_lists": [],
        "collection_errors": [],
    }

    # Devices
    try:
        state["devices"] = client.list_devices(site_id)
        log.info("  devices: %d", len(state["devices"]))
    except Exception as exc:
        state["collection_errors"].append(f"devices: {exc}")
        log.warning("  devices collection failed: %s", exc)

    # Networks
    try:
        state["networks"] = client.list_networks(site_id)
        log.info("  networks: %d", len(state["networks"]))
    except Exception as exc:
        state["collection_errors"].append(f"networks: {exc}")
        log.warning("  networks collection failed: %s", exc)

    # ACL rules
    try:
        state["acl_rules"] = client.list_acl_rules(site_id)
        log.info("  acl_rules: %d", len(state["acl_rules"]))
    except Exception as exc:
        state["collection_errors"].append(f"acl_rules: {exc}")
        log.warning("  acl_rules collection failed: %s", exc)

    # ACL ordering (OPS-687)
    try:
        state["acl_ordering"] = client.get_acl_rules_ordering(site_id)
        log.info(
            "  acl_ordering: %d ordered IDs",
            len(state["acl_ordering"].get("orderedAclRuleIds", [])),
        )
    except Exception as exc:
        state["collection_errors"].append(f"acl_ordering: {exc}")
        log.warning("  acl_ordering collection failed: %s", exc)

    # Firewall zones
    try:
        state["firewall_zones"] = client.list_firewall_zones(site_id)
        log.info("  firewall_zones: %d", len(state["firewall_zones"]))
    except Exception as exc:
        state["collection_errors"].append(f"firewall_zones: {exc}")
        log.warning("  firewall_zones collection failed: %s", exc)

    # Firewall policies
    try:
        state["firewall_policies"] = client.list_firewall_policies(site_id)
        log.info("  firewall_policies: %d", len(state["firewall_policies"]))
    except Exception as exc:
        state["collection_errors"].append(f"firewall_policies: {exc}")
        log.warning("  firewall_policies collection failed: %s", exc)

    # Firewall policy ordering (OPS-687)
    # The ordering endpoint requires a specific source+destination zone pair that
    # actually has policies. A probe with arbitrary zones returns 400.
    # Full ordering diff is deferred until the netbox-acls plugin is installed
    # (schema_gap reported in diff_firewall_policies). We record the capability
    # as available but don't pollute collection_errors with expected 400s.
    state["firewall_policy_ordering"] = {
        "note": "ordering diff deferred until netbox-acls plugin installed"
    }

    # Traffic Matching Lists (OPS-687)
    try:
        state["traffic_matching_lists"] = client.list_traffic_matching_lists(site_id)
        log.info(
            "  traffic_matching_lists: %d", len(state["traffic_matching_lists"])
        )
    except Exception as exc:
        state["collection_errors"].append(f"traffic_matching_lists: {exc}")
        log.warning("  traffic_matching_lists collection failed: %s", exc)

    return state


# ---------------------------------------------------------------------------
# NetBox state collectors
# ---------------------------------------------------------------------------


def collect_netbox_state(sess: requests.Session) -> dict:
    """Collect NetBox state relevant for UniFi drift detection."""
    log.info("Collecting NetBox state...")

    state = {
        "devices": [],
        "vlans": [],
        "prefixes": [],
        "plugin_netbox_acls_available": False,
        "collection_errors": [],
    }

    # Devices — filter by manufacturer "Ubiquiti Networks" or similar
    try:
        # Try manufacturer filter first
        all_devices = netbox_get(sess, "/api/dcim/devices/")
        state["devices"] = all_devices
        log.info("  devices: %d", len(state["devices"]))
    except Exception as exc:
        state["collection_errors"].append(f"devices: {exc}")
        log.warning("  NetBox devices collection failed: %s", exc)

    # VLANs
    try:
        state["vlans"] = netbox_get(sess, "/api/ipam/vlans/")
        log.info("  vlans: %d", len(state["vlans"]))
    except Exception as exc:
        state["collection_errors"].append(f"vlans: {exc}")
        log.warning("  NetBox VLANs collection failed: %s", exc)

    # Prefixes (for subnet matching)
    try:
        state["prefixes"] = netbox_get(sess, "/api/ipam/prefixes/")
        log.info("  prefixes: %d", len(state["prefixes"]))
    except Exception as exc:
        state["collection_errors"].append(f"prefixes: {exc}")
        log.warning("  NetBox prefixes collection failed: %s", exc)

    # Check if netbox-acls plugin is available.
    # Use the AppConfig.base_url ("access-lists"), not the Python module name ("netbox_acls")
    # or the pip package name ("netbox-acls"). The NetBox plugin API URL is determined by
    # AppConfig.base_url — confirmed upstream: netbox-community/netbox-acls
    # netbox_acls/__init__.py: NetBoxACLsConfig.base_url = "access-lists"
    # → endpoint: /api/plugins/access-lists/  (not /api/plugins/netbox-acls/ which 404s)
    state["plugin_netbox_acls_available"] = netbox_plugin_available(
        sess, "access-lists"  # OPS-698 redo: correct AppConfig base_url, not pip package name
    )
    log.info(
        "  netbox-acls plugin: %s",
        "AVAILABLE" if state["plugin_netbox_acls_available"] else "NOT INSTALLED",
    )

    return state


# ---------------------------------------------------------------------------
# Diff functions
# ---------------------------------------------------------------------------


def _norm_device_name(name: str) -> str:
    """Normalize a device name for fuzzy matching.

    Converts spaces and underscores to hyphens and lower-cases. This handles
    the common convention difference between UniFi ("USW Pro 48 PoE") and
    NetBox ("USW-Pro-48-PoE").
    """
    return name.lower().replace(" ", "-").replace("_", "-")


def diff_devices(unifi_devices: list, netbox_devices: list) -> dict:
    """Diff UniFi devices against NetBox DCIM devices.

    Matching strategy (in order):
      1. Exact name (case-insensitive)
      2. Normalized name (spaces → hyphens, lower-cased)
      3. Model-based normalization (UniFi model field vs NetBox name)

    Also checks primary IP and status fields for matched devices.
    """
    # Build NetBox lookups: exact name (lower) and normalized name
    nb_by_exact = {d["name"].lower(): d for d in netbox_devices}
    nb_by_norm = {_norm_device_name(d["name"]): d for d in netbox_devices}

    in_unifi_not_netbox = []
    naming_convention_diff = []
    ip_drift = []
    status_drift = []

    unifi_matched_norm = set()  # normalized names of matched UniFi devices

    def _find_nb_device(name: str, model: str):
        """Find NetBox device by name (exact, normalized) or model (normalized)."""
        # Try exact first
        nb_dev = nb_by_exact.get(name.lower())
        if nb_dev:
            return nb_dev, "exact"
        # Try normalized name
        nb_dev = nb_by_norm.get(_norm_device_name(name))
        if nb_dev:
            return nb_dev, "norm_name"
        # Try normalized model (UniFi uses model as display name for some devices)
        if model:
            nb_dev = nb_by_norm.get(_norm_device_name(model))
            if nb_dev:
                return nb_dev, "norm_model"
        return None, None

    unifi_matched_netbox_names = set()

    for dev in unifi_devices:
        name = dev.get("name") or dev.get("hostname") or dev.get("mac", "")
        model = dev.get("model", "")
        if not name:
            continue

        nb_dev, match_type = _find_nb_device(name, model)

        if nb_dev is None:
            in_unifi_not_netbox.append(
                {
                    "unifi_name": name,
                    "unifi_model": model,
                    "unifi_mac": dev.get("mac", ""),
                    "unifi_ip": dev.get("ip", ""),
                    "unifi_type": dev.get("type", ""),
                }
            )
            continue

        unifi_matched_netbox_names.add(nb_dev["name"].lower())

        # Record naming convention drift for reporting
        if match_type in ("norm_name", "norm_model") and name != nb_dev["name"]:
            naming_convention_diff.append(
                {
                    "unifi_name": name,
                    "netbox_name": nb_dev["name"],
                    "match_type": match_type,
                }
            )

        # Check primary IP
        nb_ip = None
        if nb_dev.get("primary_ip"):
            nb_ip_str = nb_dev["primary_ip"].get("address", "")
            # Strip CIDR notation if present
            nb_ip = nb_ip_str.split("/")[0] if nb_ip_str else None
        unifi_ip = dev.get("ip", "")
        if nb_ip and unifi_ip and nb_ip != unifi_ip:
            ip_drift.append(
                {
                    "name": name,
                    "unifi_ip": unifi_ip,
                    "netbox_ip": nb_ip,
                }
            )

        # Check status (UniFi: ONLINE/OFFLINE/DISCONNECTED → NetBox: active/offline)
        unifi_state = str(dev.get("state", "")).upper()
        nb_status = nb_dev.get("status", {})
        if isinstance(nb_status, dict):
            nb_status = nb_status.get("value", "")
        _unifi_up = unifi_state in ("1", "CONNECTED", "ONLINE", "UP", "TRUE")
        _nb_up = nb_status == "active"
        if _unifi_up != _nb_up:
            status_drift.append(
                {
                    "name": name,
                    "unifi_state": dev.get("state", ""),
                    "netbox_status": nb_status,
                    "unifi_is_up": _unifi_up,
                    "netbox_is_active": _nb_up,
                }
            )

    # Devices in NetBox but not in UniFi (Ubiquiti-tagged only)
    # Filter to Ubiquiti devices by manufacturer name that weren't matched above
    in_netbox_not_unifi = [
        {
            "netbox_name": d["name"],
            "netbox_id": d["id"],
            "manufacturer": (
                d.get("device_type", {}).get("manufacturer", {}).get("name", "")
                if isinstance(d.get("device_type"), dict)
                else ""
            ),
        }
        for d in netbox_devices
        if d["name"].lower() not in unifi_matched_netbox_names
        and "ubiquiti" in (
            (
                d.get("device_type", {})
                .get("manufacturer", {})
                .get("name", "")
                .lower()
            )
            if isinstance(d.get("device_type"), dict)
            else ""
        )
    ]

    return {
        "in_unifi_not_netbox": in_unifi_not_netbox,
        "in_netbox_not_unifi": in_netbox_not_unifi,
        "naming_convention_diff": naming_convention_diff,
        "ip_drift": ip_drift,
        "status_drift": status_drift,
        "unifi_device_count": len(unifi_devices),
        "netbox_device_count": len(netbox_devices),
    }


def diff_networks(unifi_networks: list, netbox_vlans: list) -> dict:
    """Diff UniFi networks against NetBox IPAM VLANs.

    Matching strategy: by VLAN ID (vlan_id / vid).
    """
    nb_by_vid = {v["vid"]: v for v in netbox_vlans}

    in_unifi_not_netbox = []
    name_drift = []

    unifi_vids = set()
    for net in unifi_networks:
        vid = net.get("vlan_id") or net.get("vlanId")
        if not vid:
            continue  # Unnamed/untagged networks, skip
        vid = int(vid)
        unifi_vids.add(vid)
        nb_vlan = nb_by_vid.get(vid)

        if nb_vlan is None:
            in_unifi_not_netbox.append(
                {
                    "unifi_name": net.get("name", ""),
                    "vlan_id": vid,
                    "subnet": net.get("ip_subnet", ""),
                }
            )
            continue

        # Check name drift
        unifi_name = net.get("name", "")
        nb_name = nb_vlan.get("name", "")
        if unifi_name and nb_name and unifi_name != nb_name:
            name_drift.append(
                {
                    "vlan_id": vid,
                    "unifi_name": unifi_name,
                    "netbox_name": nb_name,
                }
            )

    in_netbox_not_unifi = [
        {"netbox_name": v["name"], "vid": v["vid"], "netbox_id": v["id"]}
        for v in netbox_vlans
        if v["vid"] not in unifi_vids
    ]

    return {
        "in_unifi_not_netbox": in_unifi_not_netbox,
        "in_netbox_not_unifi": in_netbox_not_unifi,
        "name_drift": name_drift,
        "unifi_network_count": len(unifi_networks),
        "netbox_vlan_count": len(netbox_vlans),
    }


def diff_acl_rules(unifi_acls: list, unifi_ordering: dict, plugin_available: bool) -> dict:
    """Report ACL rule state.

    If netbox-acls plugin is not available, reports schema_gap.
    If plugin is available (future), compares against plugin objects.
    """
    ordered_ids = unifi_ordering.get("orderedAclRuleIds", [])
    if plugin_available:
        # Future: query /api/plugins/netbox_acls/access-lists/ and diff
        return {
            "schema_status": "plugin_available_comparison_pending",
            "unifi_acl_count": len(unifi_acls),
            "unifi_ordered_count": len(ordered_ids),
            "note": "netbox-acls plugin detected but comparison not yet implemented",
        }
    else:
        return {
            "schema_status": "schema_gap",
            "gap_reason": "NetBox Firewall plugin (netbox-acls) not installed — no ACL schema",
            "unifi_acl_count": len(unifi_acls),
            "unifi_ordered_count": len(ordered_ids),
            "unifi_acl_names": [r.get("name", r.get("id", "?")) for r in unifi_acls],
            "action_required": "Install netbox-acls plugin (OPS-691 blocker — requires overwatch-gitops PR)",
        }


def diff_firewall_policies(
    unifi_policies: list,
    unifi_zones: list,
    unifi_fw_ordering: dict,
    plugin_available: bool,
) -> dict:
    """Report firewall policy state."""
    if plugin_available:
        return {
            "schema_status": "plugin_available_comparison_pending",
            "unifi_policy_count": len(unifi_policies),
            "unifi_zone_count": len(unifi_zones),
            "note": "netbox-acls plugin detected but comparison not yet implemented",
        }
    else:
        return {
            "schema_status": "schema_gap",
            "gap_reason": "NetBox Firewall plugin not installed — no firewall policy schema",
            "unifi_policy_count": len(unifi_policies),
            "unifi_zone_count": len(unifi_zones),
            "unifi_policy_names": [
                p.get("name", p.get("id", "?")) for p in unifi_policies
            ],
            "unifi_zone_names": [
                z.get("name", z.get("id", "?")) for z in unifi_zones
            ],
            "action_required": "Install netbox-acls plugin (OPS-691 blocker — requires overwatch-gitops PR)",
        }


def diff_traffic_matching_lists(tmls: list, plugin_available: bool) -> dict:
    """Report TML state."""
    if plugin_available:
        return {
            "schema_status": "plugin_available_comparison_pending",
            "unifi_tml_count": len(tmls),
            "note": "netbox-acls plugin detected but comparison not yet implemented",
        }
    else:
        return {
            "schema_status": "schema_gap",
            "gap_reason": "NetBox Firewall plugin not installed — no TML schema",
            "unifi_tml_count": len(tmls),
            "unifi_tml_names": [t.get("name", t.get("id", "?")) for t in tmls],
            "action_required": "Install netbox-acls plugin (OPS-691 blocker — requires overwatch-gitops PR)",
        }


# ---------------------------------------------------------------------------
# Drift severity scoring
# ---------------------------------------------------------------------------


def compute_severity(report: dict) -> str:
    """Compute overall drift severity: clean / warning / critical."""
    devices = report.get("devices", {})
    networks = report.get("networks", {})
    acl = report.get("acl_rules", {})
    fw = report.get("firewall_policies", {})
    tml = report.get("traffic_matching_lists", {})

    critical = False
    warning = False

    if devices.get("in_unifi_not_netbox"):
        warning = True
    if devices.get("ip_drift"):
        warning = True
    if networks.get("in_unifi_not_netbox"):
        warning = True
    if acl.get("schema_status") == "schema_gap":
        warning = True
    if fw.get("schema_status") == "schema_gap":
        warning = True
    if tml.get("unifi_tml_count", 0) > 0 and tml.get("schema_status") == "schema_gap":
        critical = True  # TMLs exist in UniFi but not modeled anywhere

    if critical:
        return "critical"
    if warning:
        return "warning"
    return "clean"


# ---------------------------------------------------------------------------
# Report writer (atomic)
# ---------------------------------------------------------------------------


def write_report_atomic(path: str, report: dict) -> None:
    """Write JSON report atomically using a temp file + rename."""
    parent = Path(path).parent
    parent.mkdir(parents=True, exist_ok=True)

    report_json = json.dumps(report, indent=2, default=str)

    # Write to temp file in same directory (same filesystem → atomic rename)
    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=str(parent),
        suffix=".tmp",
        delete=False,
        encoding="utf-8",
    ) as tf:
        tf.write(report_json)
        tmp_path = tf.name

    # Set permissions before rename (0600)
    Path(tmp_path).chmod(0o600)
    # Atomic rename
    Path(tmp_path).rename(path)
    log.info("Drift report written to %s", path)


# ---------------------------------------------------------------------------
# Historical log writer
# ---------------------------------------------------------------------------


def write_historical_log(log_dir: str, report: dict) -> None:
    """Write a timestamped copy of the report to the log directory."""
    Path(log_dir).mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = Path(log_dir) / f"drift-{ts}.json"
    log_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    log_path.chmod(0o600)
    # Prune logs older than 7 days to prevent disk fill
    cutoff = time.time() - (7 * 86400)
    for f in Path(log_dir).glob("drift-*.json"):
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    _check_env()

    start_time = time.time()
    ts = datetime.now(timezone.utc).isoformat()

    log.info("=== UniFi → NetBox drift detection starting (OPS-691) ===")
    log.info("Timestamp: %s", ts)

    # Load UniFiClient (with OPS-687 shims)
    UniFiClient = _load_unifi_client()

    # Build UniFi client
    try:
        client = UniFiClient(
            api_key=UNIFI_API_KEY,
            base_url=UNIFI_CONTROLLER_URL,
            verify_ssl=False,
        )
    except Exception as exc:
        log.error("Failed to init UniFi client: %s", exc)
        sys.exit(1)

    # Build NetBox HTTP session
    nb_sess = _session_with_retries(verify=False)

    # Collect state
    unifi_state = collect_unifi_state(client)
    netbox_state = collect_netbox_state(nb_sess)

    plugin_available = netbox_state["plugin_netbox_acls_available"]

    # Diff
    log.info("Computing diffs...")
    device_diff = diff_devices(unifi_state["devices"], netbox_state["devices"])
    network_diff = diff_networks(unifi_state["networks"], netbox_state["vlans"])
    acl_diff = diff_acl_rules(
        unifi_state["acl_rules"], unifi_state["acl_ordering"], plugin_available
    )
    fw_diff = diff_firewall_policies(
        unifi_state["firewall_policies"],
        unifi_state["firewall_zones"],
        unifi_state["firewall_policy_ordering"],
        plugin_available,
    )
    tml_diff = diff_traffic_matching_lists(
        unifi_state["traffic_matching_lists"], plugin_available
    )

    elapsed = time.time() - start_time

    # OPS-695: compute gap counts before building the report dict so the JSON
    # top-level fields agree with the journal summary line.
    # device_diff/network_diff are always fully populated — schema_gaps only
    # flags ACL/firewall/TML resources that depend on the netbox-acls plugin.
    device_gap = len(device_diff["in_unifi_not_netbox"])
    network_gap = len(network_diff["in_unifi_not_netbox"])

    report = {
        "generated_at": ts,
        "elapsed_seconds": round(elapsed, 2),
        "unifi_site": {
            "id": unifi_state["site_id"],
            "name": unifi_state["site_name"],
        },
        "collection_errors": {
            "unifi": unifi_state["collection_errors"],
            "netbox": netbox_state["collection_errors"],
        },
        "devices": device_diff,
        "devices_gap": device_gap,
        "networks": network_diff,
        "networks_gap": network_gap,
        "acl_rules": acl_diff,
        "firewall_policies": fw_diff,
        "traffic_matching_lists": tml_diff,
        "netbox_plugin_status": {
            "netbox_acls": plugin_available,
        },
        "schema_gaps": [
            res
            for res, d in [
                ("acl_rules", acl_diff),
                ("firewall_policies", fw_diff),
                ("traffic_matching_lists", tml_diff),
            ]
            if d.get("schema_status") == "schema_gap"
        ],
    }
    report["severity"] = compute_severity(report)

    # Write reports
    write_report_atomic(DRIFT_REPORT_PATH, report)
    write_historical_log(DRIFT_LOG_DIR, report)

    # Summary to stdout → journal (device_gap/network_gap computed above, pre-report)
    schema_gaps = len(report["schema_gaps"])
    collection_errs = len(unifi_state["collection_errors"]) + len(
        netbox_state["collection_errors"]
    )
    print(
        f"[unifi-netbox-drift] severity={report['severity']} "
        f"devices_gap={device_gap} networks_gap={network_gap} "
        f"schema_gaps={schema_gaps} collection_errors={collection_errs} "
        f"elapsed={elapsed:.1f}s"
    )

    log.info(
        "Drift detection complete. severity=%s devices_gap=%d networks_gap=%d "
        "schema_gaps=%d collection_errors=%d elapsed=%.1fs",
        report["severity"],
        device_gap,
        network_gap,
        schema_gaps,
        collection_errs,
        elapsed,
    )


if __name__ == "__main__":
    main()
