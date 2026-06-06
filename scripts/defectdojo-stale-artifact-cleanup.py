#!/usr/bin/env python3
"""OPS-1052 — Mark stale DefectDojo findings out_of_scope for superseded artifacts.

This script marks findings in DefectDojo as out_of_scope when the artifact they
were scanned against is no longer deployed. It also optionally deletes the stale
artifact from Harbor.

Background:
  When an image tag in image-manifest.txt is wrong (e.g. 1.28.0 listed but 2.6.0
  actually deployed), Trivy scans the incorrect tag and findings accumulate in
  DefectDojo against a phantom artifact. After the manifest is corrected and the
  real image re-scanned, the stale findings need to be marked out_of_scope so
  they don't pollute future triage.

OPS-1052 cleanup (2026-05-29):
  Artifact: harbor.208.haist.farm/sentinel/k8s-sidecar:1.28.0 (alpine 3.20.3)
  DefectDojo test: 90 (Trivy Container Image, engagement 6, Sentinel IaC)
  Findings marked out_of_scope: 23 (IDs 14954, 14956-14961, 14963-14975, 14979,
    15892-15895) — all now active=False, out_of_scope=True
  Finding 14965: active=False, mitigated=2026-05-26 (CVE patched in OS, not OOS)
  Harbor artifact 1.28.0: deleted (only 2.6.0 and later remain)
  Reference: OPS-1043 corrected image-manifest.txt (1.28.0 -> 2.6.0 -> 2.7.3)

Usage:
  Pull credentials from Vault before running:
    DD_TOKEN=$(vault kv get -field=api_token secret/defectdojo)
    HARBOR_PASSWORD=$(vault kv get -field=admin_password secret/harbor)

  Mark findings out_of_scope (dry-run first):
    python3 defectdojo-stale-artifact-cleanup.py --dry-run \\
      --dd-token "$DD_TOKEN" --finding-ids 14954,14956,14957

  Execute:
    python3 defectdojo-stale-artifact-cleanup.py \\
      --dd-token "$DD_TOKEN" --finding-ids 14954,14956,14957

  Delete Harbor artifact:
    python3 defectdojo-stale-artifact-cleanup.py \\
      --harbor-password "$HARBOR_PASSWORD" \\
      --harbor-project sentinel --harbor-repo k8s-sidecar --harbor-tag 1.28.0 \\
      --delete-harbor-artifact

NIST: RA-5 Vulnerability Monitoring — ensures stale findings from decommissioned
artifacts do not generate false-positive triage burden.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import urllib.error
import base64
from typing import Optional

DD_URL = "https://defectdojo.208.haist.farm"
HARBOR_URL = "https://harbor.208.haist.farm"
HARBOR_ADMIN_USER = "admin"


def dd_patch_finding(
    token: str,
    finding_id: int,
    out_of_scope: bool = True,
    active: bool = False,
    dry_run: bool = False,
    reason: str = "Superseded artifact — image no longer deployed",
) -> dict:
    """PATCH a DefectDojo finding to mark it out_of_scope and inactive."""
    payload = {
        "out_of_scope": out_of_scope,
        "active": active,
        "notes": [{"entry": reason}] if not dry_run else [],
    }
    if dry_run:
        print(f"  [DRY-RUN] Would PATCH finding {finding_id}: {payload}")
        return {"id": finding_id, "dry_run": True}

    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{DD_URL}/api/v2/findings/{finding_id}/",
        data=data,
        method="PATCH",
        headers={
            "Authorization": f"Token {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"PATCH finding {finding_id} HTTP {e.code}: {body}") from e


def harbor_delete_artifact(
    password: str,
    project: str,
    repo: str,
    tag: str,
    dry_run: bool = False,
) -> bool:
    """Delete a tagged artifact from Harbor by looking up its digest then deleting."""
    creds = base64.b64encode(f"{HARBOR_ADMIN_USER}:{password}".encode()).decode()
    headers = {
        "Authorization": f"Basic {creds}",
        "Content-Type": "application/json",
    }

    # Look up the artifact digest for the given tag
    artifacts_url = (
        f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories"
        f"/{repo}/artifacts?with_tag=true&page_size=50"
    )
    req = urllib.request.Request(artifacts_url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        artifacts = json.load(resp)

    target_digest = None
    for artifact in artifacts:
        tags = artifact.get("tags") or []
        for t in tags:
            if t.get("name") == tag:
                target_digest = artifact["digest"]
                break
        if target_digest:
            break

    if not target_digest:
        print(f"  Harbor artifact {project}/{repo}:{tag} not found — may already be deleted")
        return False

    print(f"  Found digest for {tag}: {target_digest[:20]}...")
    if dry_run:
        print(f"  [DRY-RUN] Would DELETE Harbor artifact {project}/{repo}@{target_digest[:20]}")
        return True

    delete_url = (
        f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories"
        f"/{repo}/artifacts/{target_digest}"
    )
    req = urllib.request.Request(delete_url, method="DELETE", headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"  Deleted Harbor artifact {project}/{repo}:{tag} (HTTP {resp.status})")
            return True
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"DELETE Harbor artifact HTTP {e.code}: {body}") from e


def main() -> int:
    parser = argparse.ArgumentParser(description="Mark stale DefectDojo findings out_of_scope")
    parser.add_argument("--dd-token", help="DefectDojo API token")
    parser.add_argument(
        "--finding-ids",
        help="Comma-separated list of DefectDojo finding IDs to mark out_of_scope",
    )
    parser.add_argument(
        "--reason",
        default="Superseded artifact — image no longer deployed (OPS-1052)",
        help="Reason to record in the finding note",
    )
    parser.add_argument("--harbor-password", help="Harbor admin password")
    parser.add_argument("--harbor-project", default="sentinel", help="Harbor project name")
    parser.add_argument("--harbor-repo", help="Harbor repository name")
    parser.add_argument("--harbor-tag", help="Harbor artifact tag to delete")
    parser.add_argument(
        "--delete-harbor-artifact",
        action="store_true",
        help="Delete the Harbor artifact for the given tag",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be done without making changes",
    )
    args = parser.parse_args()

    exit_code = 0

    # --- DefectDojo findings ---
    if args.finding_ids and args.dd_token:
        ids = [int(x.strip()) for x in args.finding_ids.split(",") if x.strip()]
        print(f"Processing {len(ids)} DefectDojo findings (dry_run={args.dry_run})...")
        ok = 0
        fail = 0
        for fid in ids:
            try:
                result = dd_patch_finding(
                    token=args.dd_token,
                    finding_id=fid,
                    out_of_scope=True,
                    active=False,
                    dry_run=args.dry_run,
                    reason=args.reason,
                )
                status = "DRY-RUN" if args.dry_run else f"active={result.get('active')} oos={result.get('out_of_scope')}"
                print(f"  Finding {fid}: {status}")
                ok += 1
            except Exception as exc:
                print(f"  Finding {fid}: FAILED — {exc}", file=sys.stderr)
                fail += 1
                exit_code = 1
        print(f"DefectDojo: {ok} ok, {fail} failed")

    # --- Harbor artifact deletion ---
    if args.delete_harbor_artifact:
        if not args.harbor_password or not args.harbor_repo or not args.harbor_tag:
            print("ERROR: --harbor-password, --harbor-repo, and --harbor-tag are required for artifact deletion", file=sys.stderr)
            return 1
        print(f"\nHarbor artifact deletion (dry_run={args.dry_run})...")
        try:
            deleted = harbor_delete_artifact(
                password=args.harbor_password,
                project=args.harbor_project,
                repo=args.harbor_repo,
                tag=args.harbor_tag,
                dry_run=args.dry_run,
            )
            if not deleted:
                print("  Nothing to delete (artifact not found)")
        except Exception as exc:
            print(f"  Harbor delete FAILED: {exc}", file=sys.stderr)
            exit_code = 1

    if not args.finding_ids and not args.delete_harbor_artifact:
        parser.print_help()
        return 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
