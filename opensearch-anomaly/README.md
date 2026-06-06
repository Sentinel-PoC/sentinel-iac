# OpenSearch Anomaly Detection — RCF Detector Definitions

**Tracking:** OPS-575 (G'/02 — entity-side per-host baselines)
**Architecture umbrella:** OPS-555 (Plan G' adaptive threat intelligence)
**Last Updated:** 2026-05-29

## Overview

This directory contains Random Cut Forest (RCF) detector definitions for OpenSearch
Anomaly Detection, implementing entity-side per-host baselines per Plan G'.

RCF detectors provide adaptive anomaly thresholds without static alerting rules.
Each detector groups by a host/entity dimension, so baselines are per-entity rather
than global. This avoids the single-operator UEBA degeneracy noted in the OPS-563
architecture review.

## Detector Index

| File | Detector Name | Input Index | Entity Field |
|------|--------------|-------------|--------------|
| `det-per-host-alert-rate.yaml` | per-host-alert-rate | wazuh-alerts-* | agent.id |
| `det-per-host-network-volume.yaml` | per-host-network-volume | zeek-conn-* | host + direction |
| `det-per-host-process-launch-freq.yaml` | per-host-process-launch-freq | auditd-* / osquery-process-events-* | host |
| `det-per-canary-token-activation.yaml` | per-canary-token-activation | canarytokens-* | token_id |

## Deployment

See `compliance-vault/runbooks/rcf-tuning.md` for:
- How to apply these definitions to OpenSearch via API
- How to monitor detector training status
- How to adjust grade thresholds post-training

## Hard Limits (G' legal edge — CFAA)

- NO reverse-shell payloads
- NO hack-back actions
- NO active C2 into attacker systems
- All credentials via Vault + ESO; no hardcoded secrets

## NIST Controls

- SI-4 (System Monitoring)
- SI-7 (Software, Firmware, and Information Integrity)
- AU-6 (Audit Record Review, Analysis, and Reporting)
