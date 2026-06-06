#!/usr/bin/env python3
"""Simple Grafana alert webhook receiver - logs alerts to file and syslog."""
import json
import sys
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone

LOG_FILE = "/var/log/grafana-alerts.log"

# Set up file logging
file_handler = logging.FileHandler(LOG_FILE)
file_handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
syslog_handler = logging.handlers.SysLogHandler(address='/dev/log') if hasattr(logging, 'handlers') else None

logger = logging.getLogger('grafana-alerts')
logger.setLevel(logging.INFO)
logger.addHandler(file_handler)

import logging.handlers
syslog = logging.handlers.SysLogHandler(address='/dev/log', facility=logging.handlers.SysLogHandler.LOG_LOCAL0)
syslog.setFormatter(logging.Formatter('grafana-alert: %(message)s'))
logger.addHandler(syslog)

class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')
        try:
            payload = json.loads(body)
            alerts = payload.get('alerts', [payload]) if isinstance(payload, dict) else payload
            for alert in alerts:
                status = alert.get('status', 'unknown')
                labels = alert.get('labels', {})
                annotations = alert.get('annotations', {})
                name = labels.get('alertname', 'unknown')
                severity = labels.get('severity', 'unknown')
                summary = annotations.get('summary', '')
                msg = f"[{status.upper()}] {name} (severity={severity}): {summary}"
                logger.info(msg)
                print(f"{datetime.now(timezone.utc).isoformat()} {msg}", flush=True)
        except json.JSONDecodeError:
            logger.info(f"Raw alert: {body[:500]}")
            print(f"{datetime.now(timezone.utc).isoformat()} Raw alert: {body[:500]}", flush=True)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, format, *args):
        pass  # Suppress default HTTP logging

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 9095), AlertHandler)  # nosec B104 — service binds 0.0.0.0 by design; host-level ufw restricts source CIDR (firewall coverage audit at OPS-342)
    print(f"Grafana alert receiver listening on :9095", flush=True)
    server.serve_forever()
