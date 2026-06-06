#!/usr/bin/env python3
"""
OPS-576: Atomic Red Team detection-validation runner.

Executes configured atomic tests against the isolated atomic-target VM,
queries Wazuh OpenSearch for expected detections, records PASS/FAIL per
technique, and calls gap-filer.py for any technique with no detection.

Weekly cadence: driven by Forgejo Actions schedule (see
.forgejo/workflows/atomic-red-team-weekly.yml).

Hard limits enforced here:
  - No reverse-shell payloads (atoms.yml must not include such techniques)
  - No hack-back, no active C2 into attacker systems (CFAA)
  - All credentials via environment variables — never hardcoded

Usage:
    python3 atom-runner.py [--config atoms.yml] [--dry-run] [--technique T1059.004]

Environment variables (all required unless --dry-run):
    ATOMIC_TARGET_HOST        - IP/hostname of the test VM
    ATOMIC_TARGET_USER        - SSH username (default: ubuntu)
    ATOMIC_TARGET_SSH_KEY     - Path to SSH private key (default: ~/.ssh/id_sentinel)
    OPENSEARCH_URL            - Wazuh OpenSearch endpoint (https://192.168.12.100:9200)
    OPENSEARCH_USER           - OpenSearch username
    OPENSEARCH_PASSWORD       - OpenSearch password
    PLANE_API_KEY             - Plane API key (for gap-filer)
    TELEGRAM_BOT_TOKEN        - Telegram bot token (optional — skip if not set)
    TELEGRAM_OPS_CHAT_ID      - Telegram chat ID for notifications (optional)
    COMPLIANCE_VAULT_PATH     - Local path to compliance-vault repo checkout
                                (for coverage matrix update)
"""

import argparse
import json
import logging
import os
import random
import re
import subprocess
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional

import paramiko
import requests
import yaml
from urllib3.exceptions import InsecureRequestWarning

requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("atom-runner")


# ---------------------------------------------------------------------------
# Constants / env-chain
# ---------------------------------------------------------------------------
ATOMIC_TARGET_HOST = os.environ.get("ATOMIC_TARGET_HOST", "")
ATOMIC_TARGET_USER = os.environ.get("ATOMIC_TARGET_USER", "ubuntu")
ATOMIC_TARGET_SSH_KEY = os.path.expanduser(
    os.environ.get("ATOMIC_TARGET_SSH_KEY", "~/.ssh/id_sentinel")
)
OPENSEARCH_URL = os.environ.get("OPENSEARCH_URL", "https://192.168.12.100:9200")
OPENSEARCH_USER = os.environ.get("OPENSEARCH_USER", "admin")
OPENSEARCH_PASSWORD = os.environ.get("OPENSEARCH_PASSWORD", "")
PLANE_API_KEY = os.environ.get("PLANE_API_KEY", "")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_OPS_CHAT_ID = os.environ.get("TELEGRAM_OPS_CHAT_ID", "")
COMPLIANCE_VAULT_PATH = os.environ.get(
    "COMPLIANCE_VAULT_PATH",
    os.path.expanduser("~/repos/compliance-vault"),
)

# ---------------------------------------------------------------------------
# SSH helper
# ---------------------------------------------------------------------------

class SSHSession:
    """Thin wrapper around paramiko for executing commands on the test VM."""

    def __init__(self, host: str, user: str, key_path: str, timeout: int = 30):
        self.host = host
        self.user = user
        self.key_path = key_path
        self.timeout = timeout
        self._client: Optional[paramiko.SSHClient] = None

    def connect(self) -> None:
        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self._client.connect(
            hostname=self.host,
            username=self.user,
            key_filename=self.key_path,
            timeout=self.timeout,
        )
        log.info("SSH connected to %s@%s", self.user, self.host)

    def run(self, command: str, timeout: int = 120) -> tuple[int, str, str]:
        """
        Execute command, return (exit_code, stdout, stderr).
        Timeout is per-command in seconds.
        """
        if self._client is None:
            raise RuntimeError("SSH session not connected")
        _, stdout, stderr = self._client.exec_command(command, timeout=timeout)
        stdout_data = stdout.read().decode("utf-8", errors="replace")
        stderr_data = stderr.read().decode("utf-8", errors="replace")
        exit_code = stdout.channel.recv_exit_status()
        return exit_code, stdout_data, stderr_data

    def close(self) -> None:
        if self._client:
            self._client.close()
            self._client = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *_):
        self.close()


# ---------------------------------------------------------------------------
# Atomic Red Team repo management
# ---------------------------------------------------------------------------

def ensure_art_repo(art_repo_url: str, art_repo_path: str, dry_run: bool) -> Path:
    """Clone or update the Atomic Red Team repo on the runner host."""
    repo_path = Path(art_repo_path)
    if dry_run:
        log.info("[dry-run] Would clone/update ART repo to %s", repo_path)
        return repo_path

    if not repo_path.exists():
        log.info("Cloning Atomic Red Team repo to %s ...", repo_path)
        result = subprocess.run(
            ["git", "clone", "--depth", "1", art_repo_url, str(repo_path)],
            capture_output=True, text=True, timeout=180,
        )
        if result.returncode != 0:
            raise RuntimeError(f"git clone failed: {result.stderr}")
    else:
        log.info("Updating ART repo at %s ...", repo_path)
        result = subprocess.run(
            ["git", "-C", str(repo_path), "pull", "--ff-only"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            log.warning("git pull failed (proceeding with cached repo): %s", result.stderr)

    return repo_path


def load_atom_yaml(art_path: Path, technique: str) -> Optional[dict]:
    """
    Parse the Atomic Red Team YAML for a given technique.
    Returns the parsed dict or None if not found.
    """
    yaml_file = art_path / "atomics" / technique / f"{technique}.yaml"
    if not yaml_file.exists():
        log.warning("Atom YAML not found: %s", yaml_file)
        return None
    with open(yaml_file) as f:
        return yaml.safe_load(f)


def get_atom_command(
    art_data: dict, atom_index: int, platform: str
) -> Optional[tuple[str, Optional[str]]]:
    """
    Extract the executor command and cleanup_command for the specified atom.

    Returns (command, cleanup_command) tuple, or None if index out of range
    or platform not supported.
    """
    tests = art_data.get("atomic_tests", [])
    # Filter to supported platform
    platform_tests = [
        t for t in tests
        if platform in (t.get("supported_platforms") or [])
    ]
    if atom_index >= len(platform_tests):
        log.warning(
            "atom_index=%d out of range (found %d %s tests)",
            atom_index, len(platform_tests), platform,
        )
        return None

    test = platform_tests[atom_index]
    executor = test.get("executor", {})
    command = executor.get("command", "")
    cleanup = executor.get("cleanup_command", None)

    # Substitute default input_arguments
    input_args = test.get("input_arguments", {})
    for arg_name, arg_def in input_args.items():
        default_val = str(arg_def.get("default", ""))
        command = command.replace(f"#{{{arg_name}}}", default_val)
        if cleanup:
            cleanup = cleanup.replace(f"#{{{arg_name}}}", default_val)

    return command.strip(), cleanup.strip() if cleanup else None


# ---------------------------------------------------------------------------
# Wazuh OpenSearch detection check
# ---------------------------------------------------------------------------

def check_wazuh_detections(
    agent_name: str,
    start_time: datetime,
    end_time: datetime,
    expected_rule_ids: list[int],
    index: str,
    dry_run: bool,
) -> tuple[bool, list[dict]]:
    """
    Query Wazuh OpenSearch for alerts from the test VM in [start_time, end_time].

    If expected_rule_ids is non-empty, requires at least one match.
    If expected_rule_ids is empty, any alert from agent_name counts as PASS.

    Returns (detected: bool, matching_hits: list).
    """
    if dry_run:
        log.info("[dry-run] Would query OpenSearch for alerts from agent=%s", agent_name)
        return True, [{"_source": {"rule": {"id": "99999", "description": "dry-run hit"}}}]

    start_iso = start_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    end_iso = end_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    # Build query
    must_clauses: list[dict] = [
        {"term": {"agent.name": agent_name}},
        {"range": {"timestamp": {"gte": start_iso, "lte": end_iso}}},
    ]

    if expected_rule_ids:
        rule_id_strings = [str(r) for r in expected_rule_ids]
        must_clauses.append({"terms": {"rule.id": rule_id_strings}})

    query = {
        "size": 20,
        "query": {"bool": {"must": must_clauses}},
        "sort": [{"timestamp": {"order": "asc"}}],
    }

    url = f"{OPENSEARCH_URL}/{index}/_search"
    try:
        resp = requests.post(
            url,
            json=query,
            auth=(OPENSEARCH_USER, OPENSEARCH_PASSWORD),
            verify=False,
            timeout=30,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("OpenSearch query failed: %s", exc)
        return False, []

    data = resp.json()
    hits = data.get("hits", {}).get("hits", [])
    log.info(
        "OpenSearch returned %d hit(s) for agent=%s window=[%s, %s]",
        len(hits), agent_name, start_iso, end_iso,
    )
    return len(hits) > 0, hits


# ---------------------------------------------------------------------------
# Telegram notification
# ---------------------------------------------------------------------------

def send_telegram(message: str) -> None:
    """Send a Telegram message. Skips silently if tokens not configured."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_OPS_CHAT_ID:
        log.info("Telegram tokens not configured — skipping notification")
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TELEGRAM_OPS_CHAT_ID,
        "parse_mode": "HTML",
        "text": message,
    }
    try:
        resp = requests.post(url, json=payload, timeout=15)
        resp.raise_for_status()
        log.info("Telegram notification sent")
    except requests.RequestException as exc:
        log.warning("Telegram notification failed: %s", exc)


# ---------------------------------------------------------------------------
# Run a single atom
# ---------------------------------------------------------------------------

def run_atom(
    atom_cfg: dict,
    art_path: Path,
    ssh: SSHSession,
    runner_cfg: dict,
    dry_run: bool,
) -> dict:
    """
    Execute one atom against the test VM and check for Wazuh detection.

    Returns a result dict:
        technique, atom_index, name, status (PASS/FAIL/ERROR),
        execution_time, detection_hits, elapsed_seconds
    """
    technique = atom_cfg["technique"]
    atom_index = atom_cfg.get("atom_index", 0)
    name = atom_cfg.get("name", technique)
    platform = atom_cfg.get("platform", "linux")
    expected_rule_ids = atom_cfg.get("expected_rule_ids", [])
    detection_window = atom_cfg.get("detection_window_seconds", 300)
    do_cleanup = atom_cfg.get("cleanup", True)

    result: dict = {
        "technique": technique,
        "atom_index": atom_index,
        "name": name,
        "platform": platform,
        "expected_rule_ids": expected_rule_ids,
        "status": "ERROR",
        "execution_time": None,
        "detection_hits": [],
        "error": None,
    }

    log.info("--- Running atom: %s [%s] ---", technique, name)

    # 1. Parse the atom YAML
    art_data = load_atom_yaml(art_path, technique)
    if art_data is None:
        result["error"] = f"Atom YAML not found for {technique}"
        log.error(result["error"])
        return result

    cmd_tuple = get_atom_command(art_data, atom_index, platform)
    if cmd_tuple is None:
        result["error"] = f"No {platform} test at index {atom_index} for {technique}"
        log.error(result["error"])
        return result

    command, cleanup_command = cmd_tuple

    log.info("Atom command:\n%s", command)

    exec_start = datetime.now(timezone.utc)
    result["execution_time"] = exec_start.isoformat()

    # 2. Execute atom on test VM
    if not dry_run:
        try:
            exit_code, stdout, stderr = ssh.run(command, timeout=120)
            log.info("Atom exit_code=%d stdout=%s stderr=%s",
                     exit_code, stdout[:200], stderr[:200])
        except Exception as exc:
            result["error"] = f"SSH execution failed: {exc}"
            log.error(result["error"])
            return result
    else:
        log.info("[dry-run] Would execute atom command via SSH")

    # 3. Wait detection window
    log.info("Waiting %ds for Wazuh detection window ...", detection_window)
    if not dry_run:
        time.sleep(detection_window)

    exec_end = datetime.now(timezone.utc)

    # 4. Query Wazuh for detections
    # Add a 30s buffer before the execution time for clock skew tolerance
    query_start = exec_start - timedelta(seconds=30)
    query_end = exec_end + timedelta(seconds=60)

    detected, hits = check_wazuh_detections(
        agent_name=runner_cfg.get("wazuh_agent_name", "atomic-target"),
        start_time=query_start,
        end_time=query_end,
        expected_rule_ids=expected_rule_ids,
        index=runner_cfg.get("wazuh_index", "wazuh-alerts-4.x-*"),
        dry_run=dry_run,
    )

    result["status"] = "PASS" if detected else "FAIL"
    result["detection_hits"] = [
        {
            "rule_id": h.get("_source", {}).get("rule", {}).get("id", "?"),
            "rule_desc": h.get("_source", {}).get("rule", {}).get("description", "?"),
            "timestamp": h.get("_source", {}).get("timestamp", "?"),
        }
        for h in hits[:5]  # cap at 5 for readability
    ]

    log.info("Atom %s result: %s (%d detection hits)", technique, result["status"],
             len(result["detection_hits"]))

    # 5. Cleanup
    if do_cleanup and cleanup_command and not dry_run:
        try:
            exit_code, _, _ = ssh.run(cleanup_command, timeout=60)
            log.info("Cleanup exit_code=%d", exit_code)
        except Exception as exc:
            log.warning("Cleanup failed (non-fatal): %s", exc)

    return result


# ---------------------------------------------------------------------------
# Coverage matrix update
# ---------------------------------------------------------------------------

def update_coverage_matrix(results: list[dict], coverage_path: Path) -> None:
    """
    Append/update the MITRE ATT&CK coverage matrix in the compliance-vault.
    Writes a markdown table with run date, technique, status.
    """
    run_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    run_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    table_rows = []
    for r in results:
        status_icon = {"PASS": "✅ PASS", "FAIL": "❌ FAIL", "ERROR": "⚠️ ERROR"}.get(
            r["status"], r["status"]
        )
        hits_summary = ", ".join(
            f"Rule {h['rule_id']}" for h in r.get("detection_hits", [])[:3]
        )
        table_rows.append(
            f"| {run_date} | {r['technique']} | {r['name']} | {status_icon} "
            f"| {hits_summary or '—'} |"
        )

    new_section = f"""
## Run: {run_ts}

| Date | Technique | Atom Name | Detection Status | Wazuh Rules Fired |
|------|-----------|-----------|-----------------|-------------------|
""" + "\n".join(table_rows) + "\n"

    if not coverage_path.exists():
        log.warning("Coverage matrix not found at %s — creating placeholder", coverage_path)
        header = (
            "# Atomic Red Team — MITRE ATT&CK Coverage Matrix\n\n"
            "> Auto-generated by `atom-runner.py` (OPS-576). "
            "Updated weekly by Forgejo Actions.\n"
        )
        coverage_path.write_text(header + new_section)
    else:
        existing = coverage_path.read_text()
        coverage_path.write_text(existing + new_section)

    log.info("Coverage matrix updated at %s", coverage_path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Atomic Red Team weekly atom runner (OPS-576)")
    p.add_argument(
        "--config",
        default=str(Path(__file__).parent / "atoms.yml"),
        help="Path to atoms.yml config (default: atoms.yml in same directory)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse config, log actions, skip SSH execution and OpenSearch queries",
    )
    p.add_argument(
        "--technique",
        metavar="T1059.004",
        help="Run only the specified technique (overrides atoms_per_run limit)",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # --- Validate required env vars (unless dry-run) ---
    if not args.dry_run:
        missing = [
            v for v in ["ATOMIC_TARGET_HOST", "OPENSEARCH_URL",
                        "OPENSEARCH_USER", "OPENSEARCH_PASSWORD", "PLANE_API_KEY"]
            if not os.environ.get(v)
        ]
        if missing:
            log.error("Missing required environment variables: %s", ", ".join(missing))
            return 1

    # --- Load config ---
    with open(args.config) as f:
        cfg = yaml.safe_load(f)

    runner_cfg = cfg.get("runner", {})
    all_atoms = [a for a in cfg.get("atoms", []) if a.get("enabled", True)]

    # Filter by platform (linux only in v1)
    linux_atoms = [a for a in all_atoms if a.get("platform", "linux") == "linux"]

    # Optionally restrict to one technique
    if args.technique:
        linux_atoms = [a for a in linux_atoms if a["technique"] == args.technique]
        if not linux_atoms:
            log.error("No enabled Linux atoms found for technique %s", args.technique)
            return 1

    # Random selection up to atoms_per_run
    atoms_per_run = runner_cfg.get("atoms_per_run", 5)
    selected_atoms = (
        random.sample(linux_atoms, min(atoms_per_run, len(linux_atoms)))
        if not args.technique
        else linux_atoms
    )

    log.info("Selected %d atom(s) for this run", len(selected_atoms))
    for a in selected_atoms:
        log.info("  %s — %s", a["technique"], a["name"])

    # --- Ensure ART repo ---
    art_path = ensure_art_repo(
        art_repo_url=runner_cfg.get("art_repo_url",
                                    "https://github.com/redcanaryco/atomic-red-team.git"),
        art_repo_path=runner_cfg.get("art_repo_path", "/tmp/atomic-red-team"),
        dry_run=args.dry_run,
    )

    # --- Run atoms ---
    results: list[dict] = []

    if args.dry_run:
        # In dry-run, skip SSH entirely
        for atom_cfg in selected_atoms:
            result = run_atom(
                atom_cfg=atom_cfg,
                art_path=art_path,
                ssh=None,      # type: ignore[arg-type]
                runner_cfg=runner_cfg,
                dry_run=True,
            )
            results.append(result)
    else:
        with SSHSession(
            host=ATOMIC_TARGET_HOST,
            user=ATOMIC_TARGET_USER,
            key_path=ATOMIC_TARGET_SSH_KEY,
        ) as ssh:
            for atom_cfg in selected_atoms:
                result = run_atom(
                    atom_cfg=atom_cfg,
                    art_path=art_path,
                    ssh=ssh,
                    runner_cfg=runner_cfg,
                    dry_run=False,
                )
                results.append(result)

    # --- Summarise ---
    passed = [r for r in results if r["status"] == "PASS"]
    failed = [r for r in results if r["status"] == "FAIL"]
    errored = [r for r in results if r["status"] == "ERROR"]

    log.info(
        "Run summary: %d PASS  %d FAIL  %d ERROR  (total %d)",
        len(passed), len(failed), len(errored), len(results),
    )

    # --- Gap-file for each FAIL ---
    if failed and not args.dry_run:
        gap_filer_script = Path(__file__).parent / "gap-filer.py"
        for r in failed:
            log.info("Filing gap issue for %s ...", r["technique"])
            gap_input = json.dumps(r)
            try:
                proc = subprocess.run(
                    [sys.executable, str(gap_filer_script)],
                    input=gap_input,
                    capture_output=True,
                    text=True,
                    timeout=30,
                    env={**os.environ, "PLANE_API_KEY": PLANE_API_KEY},
                )
                if proc.returncode == 0:
                    log.info("Gap issue filed: %s", proc.stdout.strip())
                else:
                    log.error("gap-filer failed: %s", proc.stderr.strip())
            except Exception as exc:
                log.error("gap-filer invocation error: %s", exc)

    elif failed and args.dry_run:
        for r in failed:
            log.info("[dry-run] Would file gap issue for %s — %s", r["technique"], r["name"])

    # --- Update coverage matrix ---
    coverage_path = Path(COMPLIANCE_VAULT_PATH) / "atomic-red-team-coverage.md"
    if not args.dry_run:
        try:
            update_coverage_matrix(results, coverage_path)
        except Exception as exc:
            log.error("Coverage matrix update failed: %s", exc)
    else:
        log.info("[dry-run] Would update coverage matrix at %s", coverage_path)

    # --- Telegram notification ---
    pass_list = "\n".join(f"  ✅ {r['technique']} — {r['name']}" for r in passed)
    fail_list = "\n".join(f"  ❌ {r['technique']} — {r['name']}" for r in failed)
    err_list = "\n".join(f"  ⚠️ {r['technique']} — {r['error']}" for r in errored)

    msg = (
        f"<b>🔴 Atomic Red Team Weekly Run</b>\n"
        f"<b>Date:</b> {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n"
        f"<b>Summary:</b> {len(passed)} PASS  {len(failed)} FAIL  {len(errored)} ERROR\n"
    )
    if pass_list:
        msg += f"\n<b>Detected:</b>\n{pass_list}\n"
    if fail_list:
        msg += f"\n<b>Gaps (Plane issues filed):</b>\n{fail_list}\n"
    if err_list:
        msg += f"\n<b>Errors:</b>\n{err_list}\n"

    if not args.dry_run:
        send_telegram(msg)
    else:
        log.info("[dry-run] Would send Telegram:\n%s", msg)

    # --- Emit JSON results to stdout for CI artifact ---
    print(json.dumps({"run_timestamp": datetime.now(timezone.utc).isoformat(),
                      "results": results}, indent=2))

    # Exit non-zero only on ERROR (FAIL is expected and handled via gap-filer)
    return 1 if errored else 0


if __name__ == "__main__":
    sys.exit(main())
