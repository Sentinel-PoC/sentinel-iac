#!/usr/bin/env python3
"""Wazuh Vulnerability Prometheus Exporter

Queries Wazuh OpenSearch index for vulnerability data and exposes
Prometheus metrics on port 9101.

Runs on wazuh-server (192.168.12.100) using local admin certs.
Scraped by Prometheus on iac-control (192.168.12.210:9099).

Deployed via: ansible-playbook site.yml --tags wazuh-vuln-exporter
Relates to: sentinel-iac#34
"""

import json
import ssl
import time
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread, Lock

# Configuration
OPENSEARCH_URL = "https://127.0.0.1:9200"
CERT_PATH = "/etc/wazuh-indexer/certs/admin.pem"
KEY_PATH = "/etc/wazuh-indexer/certs/admin-key.pem"
CA_PATH = "/etc/wazuh-indexer/certs/root-ca.pem"
LISTEN_PORT = 9101
CACHE_TTL = 300  # 5 minutes between OpenSearch queries
INDEX = "wazuh-states-vulnerabilities-wazuh"

# Global state
metrics_cache = ""
cache_lock = Lock()
last_fetch = 0


def create_ssl_context():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(CERT_PATH, KEY_PATH)
    ctx.load_verify_locations(CA_PATH)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def query_opensearch(ctx, body):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"{OPENSEARCH_URL}/{INDEX}/_search",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:  # nosec B310 — internal API call to operator-configured https endpoint; same authorized pattern as claude-config audit_*.py
        return json.loads(resp.read())


def fetch_metrics():
    ctx = create_ssl_context()
    lines = []

    # 1. Total vulns by severity
    agg_severity = query_opensearch(ctx, {
        "size": 0,
        "aggs": {
            "by_severity": {
                "terms": {"field": "vulnerability.severity", "size": 10}
            }
        }
    })
    lines.append("# HELP wazuh_vulnerabilities_total Total vulnerabilities by severity")
    lines.append("# TYPE wazuh_vulnerabilities_total gauge")
    total_all = 0
    for bucket in agg_severity.get("aggregations", {}).get("by_severity", {}).get("buckets", []):
        sev = bucket["key"]
        count = bucket["doc_count"]
        total_all += count
        lines.append(f'wazuh_vulnerabilities_total{{severity="{sev}"}} {count}')

    # 2. Vulns by severity and agent
    agg_agent_sev = query_opensearch(ctx, {
        "size": 0,
        "aggs": {
            "by_agent": {
                "terms": {"field": "agent.name", "size": 20},
                "aggs": {
                    "by_severity": {
                        "terms": {"field": "vulnerability.severity", "size": 10}
                    }
                }
            }
        }
    })
    lines.append("# HELP wazuh_agent_vulnerabilities Vulnerabilities per agent and severity")
    lines.append("# TYPE wazuh_agent_vulnerabilities gauge")
    for agent_bucket in agg_agent_sev.get("aggregations", {}).get("by_agent", {}).get("buckets", []):
        agent = agent_bucket["key"]
        for sev_bucket in agent_bucket.get("by_severity", {}).get("buckets", []):
            sev = sev_bucket["key"]
            count = sev_bucket["doc_count"]
            lines.append(f'wazuh_agent_vulnerabilities{{agent="{agent}",severity="{sev}"}} {count}')

    # 3. Critical CVE details (top 20)
    agg_critical = query_opensearch(ctx, {
        "size": 0,
        "query": {"term": {"vulnerability.severity": "Critical"}},
        "aggs": {
            "by_cve": {
                "terms": {"field": "vulnerability.id", "size": 20},
                "aggs": {
                    "agents": {
                        "terms": {"field": "agent.name", "size": 20}
                    }
                }
            }
        }
    })
    lines.append("# HELP wazuh_critical_cve_count Hosts affected per critical CVE")
    lines.append("# TYPE wazuh_critical_cve_count gauge")
    for cve_bucket in agg_critical.get("aggregations", {}).get("by_cve", {}).get("buckets", []):
        cve_id = cve_bucket["key"]
        agent_count = len(cve_bucket.get("agents", {}).get("buckets", []))
        total_hits = cve_bucket["doc_count"]
        lines.append(f'wazuh_critical_cve_count{{cve="{cve_id}"}} {total_hits}')
        lines.append(f'wazuh_critical_cve_agents{{cve="{cve_id}"}} {agent_count}')

    # 4. Total count (single number for quick dashboards)
    lines.append("# HELP wazuh_vulnerabilities_grand_total Total vulnerability findings")
    lines.append("# TYPE wazuh_vulnerabilities_grand_total gauge")
    lines.append(f"wazuh_vulnerabilities_grand_total {total_all}")

    # 5. Exporter health
    lines.append("# HELP wazuh_vuln_exporter_last_scrape_timestamp Unix timestamp of last successful scrape")
    lines.append("# TYPE wazuh_vuln_exporter_last_scrape_timestamp gauge")
    lines.append(f"wazuh_vuln_exporter_last_scrape_timestamp {int(time.time())}")

    return "\n".join(lines) + "\n"


def refresh_cache():
    global metrics_cache, last_fetch
    now = time.time()
    if now - last_fetch < CACHE_TTL:
        return
    try:
        new_metrics = fetch_metrics()
        with cache_lock:
            metrics_cache = new_metrics
            last_fetch = now
    except Exception as e:
        error_metric = (
            "# HELP wazuh_vuln_exporter_errors_total Exporter errors\n"
            "# TYPE wazuh_vuln_exporter_errors_total counter\n"
            f"wazuh_vuln_exporter_errors_total 1\n"
            f"# error: {e}\n"
        )
        with cache_lock:
            if not metrics_cache:
                metrics_cache = error_metric


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            refresh_cache()
            with cache_lock:
                body = metrics_cache.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress request logs


def main():
    # Initial fetch
    refresh_cache()
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), MetricsHandler)  # nosec B104 — service binds 0.0.0.0 by design; host-level ufw restricts source CIDR (firewall coverage audit at OPS-342)
    print(f"Wazuh vulnerability exporter listening on :{LISTEN_PORT}/metrics")
    server.serve_forever()


if __name__ == "__main__":
    main()
