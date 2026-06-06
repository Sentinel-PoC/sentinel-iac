# Check Inventory

This page documents every automated check in `nist-compliance-check.sh`. There are **115 checks** across **17 control families** covering **111 unique NIST 800-53 controls**.

Checks are listed in the order they execute in the `main()` function.

---

## Original Infrastructure Checks (11 checks)

These are the foundational checks that query Wazuh, SSH, and HTTP endpoints.

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 1 | CA-7 | `check_agents_active` | Wazuh agent count via API | >= 9 agents active |
| 2 | CM-6 | `check_sca_scores` | Wazuh SCA (CIS benchmark) scores for hardened agents | All 6 hardened agents >= 55% SCA score |
| 3 | SI-7 | `check_fim_running` | Wazuh FIM (syscheck) last scan age per agent | All 9 agents scanned within 24 hours |
| 4 | SI-4(7) | `check_active_response` | Wazuh active-response blocks in ossec.conf | >= 1 active-response block configured |
| 5 | AU-2 | `check_auditd` | auditd service status across managed hosts | >= 5 of 6 hosts running auditd |
| 6 | SC-23 | `check_vault_health` | Vault TLS health endpoint | HTTP 200 from `/v1/sys/health` |
| 7 | CP-10 | `check_gitlab_accessible` | GitLab HTTP accessibility | HTTP 200 or 302 |
| 8 | CP-9 | `check_backup_timers` | Backup systemd timers on 3 hosts | 3/3 timers active: proxmox-snapshot (iac-control), vault-backup (vault-server), gitlab-backup (gitlab-server) |
| 9 | CM-2 | `check_docker_containers` | Docker container counts on Vault and Seedbox | Vault >= 1 container, Seedbox >= 2 containers |
| 10 | SC-7 | `check_ufw_active` | UFW firewall status across 6 hosts | >= 4 hosts have UFW active |
| 11 | SI-3 | `check_clamav_defs` | ClamAV antivirus definition freshness | freshclam.log updated within 48 hours |

---

## Access Control (AC) Family (16 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 12 | AC-2 | `check_keycloak_health` | Keycloak sentinel realm OIDC discovery endpoint | HTTP 200 from `auth.208.haist.farm/realms/sentinel/.well-known/openid-configuration` |
| 13 | AC-17 | `check_vault_ssh_ca` | Vault SSH CA public key via API | Non-empty public_key in `/ssh/config/ca` response |
| 14 | AC-3 | `check_okd_rbac` | OKD ClusterRole count | > 50 ClusterRoles present |
| 15 | AC-4 | `check_istio_mtls` | Istio PeerAuthentication mode in istio-system | Mode is STRICT |
| 16 | AC-6 | `check_vault_policies` | Vault ACL policy count | >= 3 policies defined |
| 17 | AC-6(1) | `check_scc_restricted` | OKD restricted SecurityContextConstraint | SCC named "restricted" exists |
| 18 | AC-6(2) | `check_ssh_root_disabled` | SSH PermitRootLogin across managed hosts | >= 3 of 5 hosts have PermitRootLogin no |
| 19 | AC-7 | `check_pam_faillock` | PAM account lockout configuration | faillock.conf has deny/unlock_time OR pam_faillock in PAM config |
| 20 | AC-8 | `check_login_banner` | SSH login banner on iac-control | `/etc/issue.net` exists and non-empty, Banner directive in sshd_config |
| 21 | AC-12 | `check_session_timeout` | Shell TMOUT variable set | TMOUT found in /etc/profile, profile.d, or bash.bashrc |
| 22 | AC-17(1) | `check_tailscale_active` | Tailscale VPN service on iac-control | tailscaled service active with IPv4 address |
| 23 | AC-14 | `check_cf_access` | Cloudflare Access on external GitLab endpoint | HTTP 200, 302, or 403 from `gitlab.haist.farm` |
| 24 | AC-10 | `check_concurrent_sessions` | SSH MaxSessions limit | MaxSessions explicitly set <= 10 |
| 25 | AC-1 | `check_policy_doc_exists` | Access control policy document existence | `compliance/ac2-account-inventory.md` exists and < 180 days old |
| 26 | AC-5 | `check_separation_of_duties` | Separation of duties documentation | Documentation mentioning separation/duties/least-privilege in compliance/ |
| 27 | AC-11 | `check_session_lock` | Session lock via timeout script | `/etc/profile.d/session-timeout.sh` with TMOUT variable |

---

## Awareness and Training (AT) Family (3 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 28 | AT-1 | `check_training_policy` | Security training/awareness policy documentation | File matching *training* or *awareness* in compliance/ or docs/, OR grep match in compliance/ |
| 29 | AT-2 | `check_training_records` | Formal security awareness training records | Files matching *training* or *awareness* in compliance-vault/ or docs/ |
| 30 | AT-3 | `check_role_based_training` | Role-based security training documentation | Grep match for "role.based", "privileged.user", or "administrator.training" in docs/ or compliance-vault/ |

---

## Audit and Accountability (AU) Family (11 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 31 | AU-2(3) | `check_auditd_rules` | Loaded audit rules on iac-control | >= 10 audit rules loaded via `auditctl -l` |
| 32 | AU-3 | `check_audit_content` | Audit rules with key tags for categorization | >= 5 audit rules have `-k` key tags |
| 33 | AU-4 | `check_log_storage` | /var/log disk usage on iac-control | < 80% capacity |
| 34 | AU-9 | `check_audit_permissions` | /var/log/audit directory permissions | Permissions 750 or 700 |
| 35 | AU-6 | `check_wazuh_alerts_24h` | Wazuh alert volume in alerts.json | > 0 alerts present (checked via SSH) |
| 36 | AU-8 | `check_chrony_ntp` | NTP synchronization via chrony or timedatectl | Chrony tracking shows "Normal" leap status, or timedatectl shows synchronized |
| 37 | AU-6(4) | `check_log_forwarding` | Remote log forwarding configuration | Rsyslog remote (`@@`) configured, OR Wazuh agent active |
| 38 | AU-11 | `check_log_retention` | Logrotate configuration count | >= 3 configs in /etc/logrotate.d/ |
| 39 | AU-12 | `check_aide_installed` | AIDE file integrity tool installation and database | AIDE binary exists and database present at /var/lib/aide/ |
| 40 | AU-10 | `check_non_repudiation` | Wazuh logall_json for complete event archiving | logall_json in ossec.conf AND archives.json exists |
| 41 | AU-2(3) | `check_keycloak_audit_events` | Keycloak audit event logging environment variable | `KC_SPI_EVENTS_LISTENER_JBOSS_LOGGING_SUCCESS_LEVEL` in Keycloak deployment env |

---

## Security Assessment (CA) Family (3 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 42 | CA-2 | `check_compliance_timer` | NIST compliance check systemd timer | `nist-compliance-check.timer` or `nist-compliance.timer` active |
| 43 | CA-7(1) | `check_drift_detection` | Drift detection systemd timer | `sentinel-drift-detection.timer` or `drift-detection.timer` active |
| 44 | CA-7 | `check_agents_active` | (Same as check #1) Wazuh continuous monitoring via active agents | >= 9 agents active |

Note: CA-7 is satisfied by check #1 (wazuh_agents_active). The CA family grouping here reflects the assessment-specific checks (CA-2 and CA-7(1)).

---

## Configuration Management (CM) Family (9 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 45 | CM-3 | `check_terraform_state` | Terraform state file presence and age | State file < 90 days old, OR remote backend configured |
| 46 | CM-3(2) | `check_argocd_sync` | ArgoCD application sync and health status | All apps Healthy+Synced, OR >= 80% synced |
| 47 | CM-5 | `check_gitops_enforcement` | ArgoCD auto-sync configuration | >= 1 application with automated sync policy |
| 48 | CM-7 | `check_unnecessary_services` | Unnecessary services not running on iac-control | None of telnetd, rsh-server, xinetd, avahi-daemon active |
| 49 | CM-7(2) | `check_kernel_modules_blacklist` | Kernel module blacklisting in /etc/modprobe.d/ | >= 5 blacklist or install-to-true entries |
| 50 | CM-3(3) | `check_ci_security_scanning` | CI security pipeline includes trivy and gitleaks | Both trivy and gitleaks found in ci/security.yml |
| 51 | CM-8 | `check_component_inventory` | NetBox DCIM inventory accessibility | HTTP 200 or 403 from NetBox API, OR NetBox pods running in cluster |
| 52 | CM-2 | `check_docker_containers` | (Same as check #9) Baseline Docker container counts | Vault >= 1, Seedbox >= 2 containers running |
| 53 | CM-6 | `check_sca_scores` | (Same as check #2) CIS benchmark compliance via SCA | All hardened agents >= 55% score |

---

## Contingency Planning (CP) Family (10 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 54 | CP-2 | `check_dr_scripts` | Disaster recovery scripts in infrastructure/recovery/ | >= 2 .sh files in recovery directory |
| 55 | CP-4 | `check_dr_test_evidence` | DR test results log freshness | `/var/log/sentinel/dr-test-results.log` exists and < 90 days old |
| 56 | CP-7 | `check_ha_keepalived` | Keepalived HA with VIP on iac-control | Keepalived active AND VIP 10.0.0.1 present on interface |
| 57 | CP-9(1) | `check_minio_replication` | MinIO primary and replica health | HTTP 200 from both primary (192.168.12.58:9000) and replica (192.168.12.59:9000) |
| 58 | CP-9(2) | `check_etcd_backup` | etcd backup timer or backup files | `etcd-backup.timer` active, OR backup files exist in /var/backup/etcd/ |
| 59 | CP-10 | `check_gitlab_accessible` | (Same as check #7) GitLab service recovery/availability | HTTP 200 or 302 |
| 60 | CP-9 | `check_backup_timers` | (Same as check #8) Backup timer status | 3/3 backup timers active |
| 61 | CP-1 | `check_contingency_plan` | Contingency/IR plan documentation existence | Files matching *incident* or *contingency* in compliance/ |
| 62 | CP-3 | `check_recovery_procedures` | Recovery script count in infrastructure/recovery/ | >= 3 .sh files |
| 63 | CP-6 | `check_alternate_processing` | HA failover site (config-server + keepalived) | Keepalived active AND config-server dnsmasq active (SSH to 192.168.12.132) |

---

## Identification and Authentication (IA) Family (10 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 64 | IA-2 | `check_keycloak_sso` | Keycloak SSO OIDC configuration response | Non-empty issuer in OIDC discovery JSON |
| 65 | IA-2(1) | `check_mfa_configured` | Keycloak realm sentinel active (proxy for MFA) | Realm name "sentinel" returned from realm endpoint |
| 66 | IA-2(12) | `check_vault_auth_methods` | Vault non-token auth methods count | >= 2 non-token auth methods (e.g., kubernetes/, userpass/) |
| 67 | IA-5 | `check_password_policy` | Password quality policy on iac-control | >= 3 strength rules in /etc/security/pwquality.conf (minlen, dcredit, ucredit, lcredit, ocredit) |
| 68 | IA-5(2) | `check_ssh_cert_auth` | SSH certificate-only authentication enforcement | TrustedUserCAKeys set AND AuthorizedKeysFile none in sshd_config |
| 69 | IA-5(13) | `check_vault_token_ttl` | Vault token max lease TTL | max_lease_ttl > 0 from `/sys/auth/token/tune` |
| 70 | IA-4 | `check_identifier_management` | UID_MIN in login.defs | UID_MIN >= 1000 |
| 71 | IA-8 | `check_non_org_users` | Unauthorized UID 0 accounts | Only root has UID 0 in /etc/passwd |
| 72 | IA-5(1) | `check_password_aging` | Password aging policy | PASS_MAX_DAYS <= 365 in /etc/login.defs |
| 73 | IA-5(3) | `check_password_history` | Password history enforcement | pam_pwhistory or remember= in /etc/pam.d/common-password |

---

## Incident Response (IR) Family (4 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 74 | IR-4 | `check_wazuh_active_response_rules` | Wazuh active-response rule blocks count | > 0 active-response blocks in ossec.conf (via SSH to Wazuh server) |
| 75 | IR-6 | `check_discord_alerting` | Discord webhook alerting configuration in Wazuh | Grep for "discord" or "webhook" in ossec.conf or integrations/ |
| 76 | IR-5 | `check_alert_volume_healthy` | Wazuh alert volume sanity check | Alert count between 100 and 100,000 in alerts.json |
| 77 | IR-1 | `check_ir_plan_current` | Incident response plan document age | Files matching *incident* or *ir-plan* in compliance/, < 180 days old |

---

## Maintenance (MA) Family (1 check)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 78 | MA-2 | `check_maintenance_mode` | Maintenance mode script availability | `~/scripts/sentinel-maintenance.sh` exists and is executable |

---

## Media Protection (MP) Family (1 check)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 79 | MP-5 | `check_vault_encryption` | Vault seal status and encryption type | Vault unsealed (sealed=false) with known seal type |

---

## Physical and Environmental Protection (PE) Family (2 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 80 | PE-14 | `check_idrac_monitoring` | iDRAC hardware health monitoring timer | `idrac-health-check.timer` or `idrac-watchdog.timer` active |
| 81 | PE-6 | `check_physical_monitoring` | Physical access monitoring via iDRAC | `idrac-health.timer` or `idrac-watchdog.timer` active (at least one) |

---

## Planning (PL) Family (2 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 82 | PL-1 | `check_security_plan_policy` | Security plan document existence | `docs/security.md` or `docs/security-plan.md` exists |
| 83 | PL-2 | `check_ssp_current` | Compliance documentation freshness | Newest .md file in compliance/ directory < 180 days old |

---

## Program Management (PM) Family (3 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 84 | PM-1 | `check_issp_program` | Information security program documentation | SSP JSON exists in compliance-vault AND nist-gap-analysis.md exists |
| 85 | PM-2 | `check_senior_official` | Senior security official designation in SSP | Grep match for "system.owner", "security.officer", "authorizing.official", or "responsible.individual" in SSP |
| 86 | PM-6 | `check_security_measures` | Security performance metrics tracking | Trend summary AND recent daily report (< 7 days) in compliance-vault/reports/ |

---

## Risk Assessment (RA) Family (3 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 87 | RA-5 | `check_vulnerability_scanning` | Trivy vulnerability scanning in CI pipeline | "trivy" found in ci/security.yml |
| 88 | RA-5(3) | `check_secret_scanning` | Gitleaks secret scanning in CI pipeline | "gitleaks" found in ci/security.yml |
| 89 | RA-3 | `check_risk_assessment` | Risk assessment documentation | Files matching *risk* in compliance/ or docs/, OR grep match for "risk.assessment", "risk.register", or "threat.model" |

---

## System Acquisition (SA) Family (4 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 90 | SA-22 | `check_component_lifecycle` | Component lifecycle documentation | Files matching *lifecycle* or *component* in compliance/ or docs/ |
| 91 | SA-4 | `check_acquisition_policy` | Security scanning for acquired components | "trivy" in .gitlab-ci.yml, OR Harbor ConfigMap exists |
| 92 | SA-8 | `check_secure_development` | Secure development lifecycle in CI | "gitleaks" AND "checkov" in .gitlab-ci.yml |
| 93 | SA-11 | `check_sbom_generation` | SBOM generation in supply chain pipeline | "syft", "sbom", or "cyclonedx" in overwatch-gitops/ci-templates/supply-chain-pipeline.yml |

---

## System and Communications Protection (SC) Family (16 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 94 | SC-2 | `check_namespace_network_policies` | Kubernetes NetworkPolicy or Istio AuthorizationPolicy count | >= 3 NetworkPolicies, OR >= 3 AuthorizationPolicies |
| 95 | SC-5 | `check_crowdsec_active` | CrowdSec and firewall bouncer on pangolin-proxy | Both crowdsec and crowdsec-firewall-bouncer services active |
| 96 | SC-7(5) | `check_squid_egress` | Squid egress proxy on iac-control | Squid service active |
| 97 | SC-7(7) | `check_cloudflare_tunnel` | Cloudflare tunnel on pangolin-proxy | cloudflared service active |
| 98 | SC-8 | `check_traefik_tls` | Traefik TLS termination working | Non-000 HTTP status from `https://vault.208.haist.farm` |
| 99 | SC-8(1) | `check_tls_cert_valid` | TLS certificate validity period | Certificate expires in > 14 days |
| 100 | SC-12 | `check_vault_seal_status` | Vault seal status (unsealed = key management operational) | sealed=false from `/v1/sys/seal-status` |
| 101 | SC-12(1) | `check_transit_unseal_timer` | Transit auto-unseal systemd timer | `vault-unseal-transit.timer` active |
| 102 | SC-28 | `check_minio_tls` | MinIO accessible via TLS proxy | Non-000 HTTP status from `https://minio.208.haist.farm` |
| 103 | SC-39 | `check_process_isolation` | OKD SecurityContextConstraints count | >= 5 SCCs present |
| 104 | SC-13 | `check_crypto_protection` | TLS version enforcement on Traefik endpoints | TLSv1.2 or TLSv1.3 detected, OR minVersion configured in Traefik |
| 105 | SC-10 | `check_network_disconnect` | SSH session disconnect timeout | ClientAliveInterval set > 0 and <= 600 seconds |
| 106 | SC-7 | `check_ufw_active` | (Same as check #10) UFW firewall across hosts | >= 4 of 6 hosts active |
| 107 | SC-23 | `check_vault_health` | (Same as check #6) Vault TLS health | HTTP 200 |
| 108 | SC-1 | `check_comms_policy` | Communications/architecture policy document | `docs/architecture.md` or `docs/network-architecture.md` exists |
| 109 | SC-20 | `check_dns_security` | Internal DNS (dnsmasq) active on iac-control | dnsmasq service active |

---

## System and Information Integrity (SI) Family (13 checks)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 110 | SI-2 | `check_flaw_remediation` | Composite flaw-remediation posture: (1) container CVE debt via DefectDojo API (Critical+High active findings), (2) host patch currency via apt pending security updates | PASS: 0 Crit + <5 High + 0 pending host updates; WARN: 0 Crit + 5-30 High or 1-5 pending; FAIL: any Crit or >30 High or >5 pending |
| 111 | SI-4 | `check_wazuh_rules_loaded` | Total Wazuh rules loaded via API | >= 4,000 rules loaded |
| 112 | SI-4(2) | `check_wazuh_custom_rules` | Custom Wazuh rules in local_rules.xml | >= 5 custom rule definitions (via SSH to Wazuh server) |
| 113 | SI-4(4) | `check_inbound_monitoring` | Traefik reverse proxy for inbound traffic monitoring | Traefik service active or running as Docker container on pangolin |
| 114 | SI-7(1) | `check_kyverno_policies` | Kyverno ClusterPolicy count in OKD | >= 3 ClusterPolicies present |
| 115 | SI-5 | `check_nvd_accessible` | NIST NVD API accessibility | HTTP 200 from NVD REST API (rate-limiting returns 403/429 as WARN) |
| 116 | SI-7(6) | `check_harbor_cosign` | Harbor registry health (cosign signing active in CI) | HTTP 200 from Harbor health API |
| 117 | SI-7(2) | `check_aide_database` | AIDE database freshness | aide.db or aide.db.gz < 30 days old |
| 118 | SI-16 | `check_apparmor_active` | AppArmor enforcement on iac-control | AppArmor enabled with loaded profiles |
| 119 | SI-6 | `check_security_verification` | AIDE check execution recency | AIDE log < 7 days old, OR aide-check timer active |
| 120 | SI-7 | `check_fim_running` | (Same as check #3) Wazuh FIM across all agents | All agents scanned within 24h |
| 121 | SI-4(7) | `check_active_response` | (Same as check #4) Wazuh active-response | >= 1 block configured |
| 122 | SI-3 | `check_clamav_defs` | (Same as check #11) ClamAV definitions | Updated within 48h |
| 123 | SI-4(2) | `check_falco_runtime` | Falco runtime security pods in OKD | >= 3 Falco pods Running in falco-system namespace |

---

## Additional Phase 1 Checks (3 remaining)

| # | Control | Function | What It Tests | Pass Criteria |
|---|---------|----------|---------------|---------------|
| 124 | CM-3(3) | `check_terraform_drift_timer` | Terraform/OpenTofu drift detection timer | `tofu-drift-check.timer` active |
| 125 | RA-5(3) | `check_defectdojo_integration` | DefectDojo vulnerability tracking platform health | ArgoCD application "defectdojo" status is Healthy |

---

## Check Execution Order in main()

For reference, here is the exact call order in the `main()` function, grouped by section comments in the source:

```
Original checks (11):
  check_agents_active, check_sca_scores, check_fim_running,
  check_active_response, check_auditd, check_vault_health,
  check_gitlab_accessible, check_backup_timers, check_docker_containers,
  check_ufw_active, check_clamav_defs

Access Control AC (12+1):
  check_keycloak_health, check_vault_ssh_ca, check_okd_rbac,
  check_istio_mtls, check_vault_policies, check_scc_restricted,
  check_ssh_root_disabled, check_pam_faillock, check_login_banner,
  check_session_timeout, check_tailscale_active, check_cf_access,
  check_concurrent_sessions

Audit AU (9):
  check_auditd_rules, check_audit_content, check_log_storage,
  check_audit_permissions, check_wazuh_alerts_24h, check_chrony_ntp,
  check_log_forwarding, check_log_retention, check_aide_installed

Security Assessment CA (2):
  check_compliance_timer, check_drift_detection

Configuration Management CM (7):
  check_terraform_state, check_argocd_sync, check_gitops_enforcement,
  check_unnecessary_services, check_kernel_modules_blacklist,
  check_ci_security_scanning, check_component_inventory

Contingency Planning CP (5):
  check_dr_scripts, check_dr_test_evidence, check_ha_keepalived,
  check_minio_replication, check_etcd_backup

Identification and Authentication IA (8):
  check_keycloak_sso, check_mfa_configured, check_vault_auth_methods,
  check_password_policy, check_ssh_cert_auth, check_vault_token_ttl,
  check_identifier_management, check_non_org_users

Incident Response IR (3):
  check_wazuh_active_response_rules, check_discord_alerting,
  check_alert_volume_healthy

Maintenance MA (1):
  check_maintenance_mode

Media Protection MP (1):
  check_vault_encryption

Physical PE (1):
  check_idrac_monitoring

Risk Assessment RA (2):
  check_vulnerability_scanning, check_secret_scanning

System Communications SC (12):
  check_namespace_network_policies, check_crowdsec_active,
  check_squid_egress, check_cloudflare_tunnel, check_traefik_tls,
  check_tls_cert_valid, check_vault_seal_status,
  check_transit_unseal_timer, check_minio_tls, check_process_isolation,
  check_crypto_protection, check_network_disconnect

System Integrity SI (10):
  check_flaw_remediation, check_wazuh_rules_loaded,
  check_wazuh_custom_rules, check_inbound_monitoring,
  check_kyverno_policies, check_nvd_accessible, check_harbor_cosign,
  check_aide_database, check_apparmor_active, check_security_verification

Policy and Documentation (14):
  check_training_policy, check_policy_doc_exists,
  check_separation_of_duties, check_session_lock,
  check_contingency_plan, check_recovery_procedures,
  check_password_aging, check_password_history,
  check_security_plan_policy, check_ssp_current,
  check_risk_assessment, check_comms_policy,
  check_ir_plan_current, check_component_lifecycle

Physical PE additional (1):
  check_physical_monitoring

Phase 1 new checks (15):
  check_training_records, check_role_based_training,
  check_acquisition_policy, check_secure_development,
  check_issp_program, check_senior_official, check_security_measures,
  check_dns_security, check_alternate_processing,
  check_non_repudiation, check_falco_runtime,
  check_keycloak_audit_events, check_terraform_drift_timer,
  check_sbom_generation, check_defectdojo_integration
```

**Total**: 115 check function calls producing 115 JSON result objects.

Note: Some NIST controls are tested by checks that appear in different sections of the code (e.g., CA-7 is tested by `check_agents_active` in the "Original checks" section). The control family tables above list cross-references to these shared checks.
