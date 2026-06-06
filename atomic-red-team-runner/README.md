# Atomic Red Team Detection-Validation Harness

**Plane:** OPS-576  
**Cadence:** Weekly (Monday 06:00 UTC via Forgejo Actions)  
**Substrate:** Red Canary [atomic-red-team](https://github.com/redcanaryco/atomic-red-team) + Invoke-AtomicRedTeam pattern  

---

## Purpose

Continuous detection-validation using MITRE ATT&CK atomic tests. Weekly runs:

1. Select atoms from `atoms.yml` (up to `runner.atoms_per_run` per week)
2. Execute each atom against the isolated `atomic-target` test VM via SSH
3. Query Wazuh OpenSearch for expected alerts within a 5-minute window
4. **PASS** — detection fired as expected
5. **FAIL** — no detection → auto-file a Plane OPS gap issue (feeds OPS-574 SIGMA pipeline)
6. Update `compliance-vault/atomic-red-team-coverage.md` with run results
7. Send Telegram summary notification

---

## Architecture

```
Forgejo Actions (weekly schedule)
         │
         ▼
   iac-control runner
         │  clones/updates
         ▼
  atomic-red-team repo (/tmp/atomic-red-team)
         │  parses atomics/T*/T*.yaml
         ▼
   atom-runner.py
    ├── SSH → atomic-target VM → executes atom commands
    ├── waits detection window (5 min)
    ├── queries Wazuh OpenSearch (192.168.12.100:9200) for alerts
    ├── FAIL → gap-filer.py → Plane OPS issue (cat-security, origin-agent)
    ├── updates compliance-vault/atomic-red-team-coverage.md
    └── Telegram notification (TELEGRAM_BOT_TOKEN + TELEGRAM_OPS_CHAT_ID)
```

---

## Files

| File | Purpose |
|------|---------|
| `atom-runner.py` | Main orchestrator — SSH execution, detection-check, gap-file, coverage-update |
| `gap-filer.py` | Creates Plane OPS issues for FAIL results. Reads JSON from stdin. |
| `atoms.yml` | Atom selection config — technique IDs, indexes, expected Wazuh rule IDs |
| `requirements.txt` | Python deps: paramiko, requests, pyyaml, urllib3 |

---

## Infrastructure Requirements

### atomic-target VM (pre-condition — must exist before first run)

- **Inventory:** `ansible/inventory/host_vars/atomic-target.yml`
- **Platform:** Linux (Ubuntu 22.04 LTS recommended)
- **Network:** Isolated VLAN with outbound access to:
  - `192.168.12.100:1514` (Wazuh agent registration/event port)
  - `github.com:443` (for Atomic Red Team repo — or pre-stage locally)
- **Wazuh agent:** Must be installed, registered as agent name `atomic-target`
- **Snapshot:** VM should be snapshotted before first use for post-run restore
- **SSH:** Key-based auth; runner uses `ATOMIC_TARGET_SSH_KEY` env var

### Wazuh AR white_list

> **REQUIRED ACTION (out of scope for OPS-576):** The atomic-target VM's subnet
> must be added to `wazuh_ar_whitelist` in
> `ansible/roles/wazuh-server/defaults/main.yml` before running atoms.
>
> Without this, Wazuh active-response may block the test VM's IP during execution,
> invalidating detection results.
>
> Example addition to `wazuh-server/defaults/main.yml`:
> ```yaml
> wazuh_ar_whitelist:
>   - "10.10.20.0/24"   # atomic-target isolated VLAN
> ```
>
> See: `ansible/roles/wazuh-server/templates/ossec-server.conf.j2` lines 211-217

### Forgejo Actions secrets required

| Secret | Description |
|--------|-------------|
| `ATOMIC_TARGET_HOST` | IP/hostname of atomic-target VM |
| `ATOMIC_TARGET_SSH_KEY` | SSH private key for atomic-target (base64 or path on runner) |
| `OPENSEARCH_URL` | Wazuh OpenSearch URL (https://192.168.12.100:9200) |
| `OPENSEARCH_USER` | OpenSearch username |
| `OPENSEARCH_PASSWORD` | OpenSearch password (from Vault `secret/wazuh/opensearch`) |
| `PLANE_API_KEY` | Plane API key (from Vault `secret/plane/api-key.api_key`) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (existing secret) |
| `TELEGRAM_OPS_CHAT_ID` | Telegram ops chat ID (existing secret) |
| `COMPLIANCE_VAULT_PATH` | Path to compliance-vault checkout on runner |

---

## Running Manually

```bash
# Install deps
pip3 install -r requirements.txt

# Dry-run (no SSH, no Wazuh queries)
python3 atom-runner.py --dry-run

# Single technique test
ATOMIC_TARGET_HOST=10.10.20.10 \
OPENSEARCH_URL=https://192.168.12.100:9200 \
OPENSEARCH_USER=admin \
OPENSEARCH_PASSWORD=... \
PLANE_API_KEY=... \
  python3 atom-runner.py --technique T1053.003

# Full run
python3 atom-runner.py  # uses atoms.yml in same directory
```

---

## Adding New Atoms

Edit `atoms.yml`. Each entry needs:
- `technique` — MITRE ATT&CK ID (must exist in `atomic-red-team/atomics/`)
- `atom_index` — 0-based index of the test within that technique
- `platform: linux` — only Linux supported in v1
- `expected_rule_ids` — Wazuh rule IDs expected to fire (empty = any alert counts)

To check available atoms for a technique:
```bash
cat /tmp/atomic-red-team/atomics/T1059.004/T1059.004.yaml | \
  python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); [print(i, t['name']) for i,t in enumerate(d['atomic_tests'])]"
```

---

## Legal Hard-Edge (CFAA)

All atoms in `atoms.yml` must be:
- Local-only execution on `atomic-target` VM
- **No reverse-shell payloads** (no `nc -e`, no `bash -i >& /dev/tcp/...`)
- **No C2 callbacks** to external attacker infrastructure
- **No hack-back** (no outbound attack traffic to real threat actors)
- **No credentials targeting production systems**

The `atomic-target` VM must be isolated so that atom execution cannot reach
production hosts or external networks beyond what's listed above.
