#!/bin/bash
# spire-agent-startup.sh — wrapper used by spire-agent.service
# Deployed by Ansible — OPS-533 (parent OPS-351 Phase 4.2b)
# OPS-553: simplified for x509pop NodeAttestor (no join_token state machine)
#
# WHY THIS EXISTS
# ----------------
# Provides a clear pre-flight check before exec'ing the agent: verifies the
# x509pop node identity cert is present and readable before handing off.
# With x509pop, there is no one-shot token, no state machine, no branch on
# agent-data.json presence. The agent simply presents the cert on every start.
#
# DECISION GATE (x509pop, OPS-553)
# ---------------------------------
# Check that the node cert file exists and is readable. If not, fail loud:
# the cert is provisioned by Ansible (--tags spire-node-certs) and its absence
# means the deploy did not complete. This is better than letting the agent
# start and fail silently with a confusing x509pop error.
#
# IDEMPOTENCY
# -----------
# Every start is identical: check cert → exec agent. No file state to manage.
# Restart after sleep: agent re-attests via x509pop cert automatically.
#
# Managed: do not edit manually; changes will be overwritten on next Ansible run.

set -eu

CONFIG_PATH="/etc/spire-agent/agent.conf"
NODE_CERT_FILE="/etc/spire-agent/node-cert.pem"
NODE_KEY_FILE="/etc/spire-agent/node-key.pem"
SPIRE_AGENT_BIN="/usr/local/bin/spire-agent"

# Pre-flight: node identity cert must be present (provisioned by Ansible OPS-553).
# If missing: re-run the workstation playbook with --tags spire-node-certs.
if [ ! -f "${NODE_CERT_FILE}" ]; then
    echo "[spire-agent-startup] ERROR: node cert not found at ${NODE_CERT_FILE}" >&2
    echo "[spire-agent-startup] Run: ansible-playbook workstation.yml --tags spire-node-certs" >&2
    exit 1
fi

if [ ! -f "${NODE_KEY_FILE}" ]; then
    echo "[spire-agent-startup] ERROR: node key not found at ${NODE_KEY_FILE}" >&2
    echo "[spire-agent-startup] Run: ansible-playbook workstation.yml --tags spire-node-certs" >&2
    exit 1
fi

# x509pop: always start with just the config file. Re-attestation is automatic.
exec "${SPIRE_AGENT_BIN}" run -config "${CONFIG_PATH}"
