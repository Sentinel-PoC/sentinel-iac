# Upstream Image Inventory — Harbor Mirror Trust Assessment

**SEC-64** | Upstream Cosign signature verification at Harbor mirror time
**Assessed:** 2026-04-19
**Method:** `cosign tree` + `cosign verify` run on iac-control (cosign v2.4.3) against live upstream registries
**Total images in manifest:** 15
**Verifiable upstream (cosign keyless):** 2
**Exception (no upstream sig):** 12
**Exception (sig artifact present, key-type TBD):** 1

---

## Summary Table

| # | Harbor Target | Upstream Source | Registry | Sig Policy | Verified at Mirror | Exception? |
|---|---------------|-----------------|----------|------------|-------------------|------------|
| 1 | sentinel/postgres:16 | `docker.io/library/postgres:16` | Docker Official | none | no | YES — see E-01 |
| 2 | sentinel/keycloak:26.0 | `quay.io/keycloak/keycloak:26.0` | Quay.io | none | no | YES — see E-02 |
| 3 | sentinel/homepage:latest | `ghcr.io/gethomepage/homepage:latest` | GHCR | none | no | YES — see E-03 |
| 4 | sentinel/busybox:1.36 | `docker.io/library/busybox:1.36` | Docker Official | none | no | YES — see E-04 |
| 5 | sentinel/hello-openshift:latest | `docker.io/openshift/hello-openshift:latest` | Docker Hub | none | no | YES — see E-06 |
| 6 | sentinel/newt:1.10.2 | `docker.io/fosrl/newt:1.10.2` | Docker Hub | none | no | YES — see E-07 |
| 7 | sentinel/jellyfin:latest | `docker.io/jellyfin/jellyfin:latest` | Docker Hub | none | no | YES — see E-08 |
| 8 | sentinel/jaeger-all-in-one:1.62.0 | `docker.io/jaegertracing/all-in-one:1.62.0` | Docker Hub | none | no | YES — see E-09 |
| 9 | sentinel/grafana:12.3.1 | `docker.io/grafana/grafana:12.3.1` | Docker Hub | none | no | YES — see E-10 |
| 10 | sentinel/k8s-sidecar:1.28.0 | `quay.io/kiwigrid/k8s-sidecar:1.28.0` | Quay.io | none | no | YES — see E-11 |
| 11 | sentinel/netbox:v4.5.2 | `ghcr.io/netbox-community/netbox:v4.5.2` | GHCR | none | no | YES — see E-12 |
| 12 | sentinel/valkey:9.0.2 | `docker.io/bitnami/valkey:latest` | Docker Hub | static-key (unconfirmed) | PARTIAL — see E-13 | YES — see E-13 |
| 13 | sentinel/synapse:v1.139.2 | `docker.io/matrixdotorg/synapse:v1.139.2` | Docker Hub | cosign-keyless | **YES** | no |
| 14 | sentinel/element-web:v1.12.11 | `docker.io/vectorim/element-web:v1.12.11` | Docker Hub | cosign-keyless | **YES** | no |
| 15 | sentinel/ntfy:v2.18.0 | `docker.io/binwiederhier/ntfy:v2.18.0` | Docker Hub | none | no | YES — see E-14 |

**Verified:** 2 (synapse, element-web)
**Exception:** 13

---

## Verified Images — Verification Details

### synapse:v1.139.2

```
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github.com/element-hq/synapse/.+' \
  docker.io/matrixdotorg/synapse:v1.139.2
```

**Result:** PASS — claims validated, Rekor transparency log entry verified offline.
**Signer:** `element-hq/synapse` GitHub Actions workflow `docker.yml` at tag `refs/tags/v1.139.2`
**Digest signed:** `sha256:89b1f98ae38bea1d8a7d73295752b083b2ebbdaa8f226697e4637e03f9d0c745`

### element-web:v1.12.11

```
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github.com/element-hq/element-web/.+' \
  docker.io/vectorim/element-web:v1.12.11
```

**Result:** PASS — claims validated, Rekor transparency log entry verified offline.
**Signer:** `element-hq/element-web` GitHub Actions workflow `docker.yaml` at tag `refs/tags/v1.12.11`
**Digest signed:** `sha256:f6b3ce26c42804f39afc40fe0ba14d95ab4c41e55e7343ebf6972e042b41f031`

---

## Exception Entries

### E-01 — postgres:16 (Docker Official Library)

**Image:** `docker.io/library/postgres:16`
**Cosign tree:** No supply chain artifacts found
**Rationale:** Docker Official Images (`library/`) are maintained by Docker, Inc. and do not publish Cosign signatures as of 2026-04. They are built from source in the Docker Official Images GitHub org and go through Docker's internal build/audit pipeline. The supply-chain risk is partially mitigated by Docker Content Trust (DCT/Notary v1) which is separate from Cosign. This image is critical infrastructure (PostgreSQL used by Harbor, Keycloak, NetBox, Backstage).
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to tag `:16` (not `:latest`); digest-lock recommended as next step
- Source: https://github.com/docker-library/postgres — public, audited
**Quarterly review:** Yes — if Docker Official Library adopts Cosign, enable verification immediately

### E-02 — keycloak:26.0 (Quay.io / Red Hat)

**Image:** `quay.io/keycloak/keycloak:26.0`
**Cosign tree:** No supply chain artifacts found
**Rationale:** Keycloak is maintained by Red Hat. Red Hat uses their own container signing infrastructure (RPM GPG, Red Hat Container Catalog signatures) rather than Sigstore/Cosign for images published to quay.io. Cosign keyless verification is not applicable. Static key verification is possible via Red Hat's GPG key but requires Notary-style tooling rather than `cosign verify`.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned version `:26.0`; should be digest-locked
- Keycloak is auth infrastructure — high-value target, should be upgraded to digest pinning
**Quarterly review:** Yes — Red Hat roadmap for Sigstore adoption should be checked

### E-03 — homepage:latest (gethomepage on GHCR)

**Image:** `ghcr.io/gethomepage/homepage:latest`
**Cosign tree:** No supply chain artifacts found
**Rationale:** The gethomepage project does not publish Cosign signatures as of 2026-04. This is a community project with no formal security signing process documented. The `:latest` tag is a risk; digest pinning is strongly recommended.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Action item: pin to digest or specific version tag, not `:latest`
- Low criticality: this is a dashboard app, not on auth or data path
**Quarterly review:** Yes

### E-04 — busybox:1.36 (Docker Official Library)

**Image:** `docker.io/library/busybox:1.36`
**Cosign tree:** No supply chain artifacts found
**Rationale:** Same as E-01 — Docker Official Library does not use Cosign. BusyBox is used only as a homepage init container for volume population; its access surface is minimal.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:1.36`
- Minimal attack surface (init container, terminates on completion)
**Quarterly review:** Yes — bundle with postgres DCT review

### E-06 — hello-openshift (OpenShift Demo)

**Image:** `docker.io/openshift/hello-openshift:latest`
**Cosign tree:** No supply chain artifacts found
**Rationale:** This is a demo/test application. The `openshift` namespace on Docker Hub is the old Red Hat OpenShift demo repository. It is unmaintained upstream and has not been updated with Cosign signatures. Low criticality — used for admission testing only.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Low risk: demo app, no sensitive data access
- Action item: replace with a signed alternative or retire if unused
**Quarterly review:** Yes — assess whether this image is still needed

### E-07 — newt:1.10.2 (fosrl/newt)

**Image:** `docker.io/fosrl/newt:1.10.2`
**Cosign tree:** No supply chain artifacts found
**Rationale:** fosrl/newt is a community tunnel client (Pangolin/Newt). The project does not publish Cosign signatures as of 2026-04. The image is pinned to version `:1.10.2` which is better than `:latest`. This is the outbound tunnel client for the Pangolin reverse proxy.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:1.10.2`
- Source: https://github.com/fosrl/newt — public repository
- Action item: open upstream issue requesting Cosign signing
**Quarterly review:** Yes

### E-08 — jellyfin:latest (Jellyfin)

**Image:** `docker.io/jellyfin/jellyfin:latest`
**Cosign tree:** No supply chain artifacts found
**Rationale:** The Jellyfin project does not publish Cosign signatures as of 2026-04. It is a media server with active community development. The `:latest` tag is a risk factor.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Action item: pin to specific version tag (e.g., `:10.10.7`)
- Jellyfin publishes SHA digests in release notes — manual digest verification possible
**Quarterly review:** Yes

### E-09 — jaeger-all-in-one:1.62.0 (CNCF/Jaeger)

**Image:** `docker.io/jaegertracing/all-in-one:1.62.0`
**Cosign tree:** No supply chain artifacts found
**Rationale:** Jaeger is a CNCF graduated project. The jaegertracing organization does not publish Cosign signatures on Docker Hub as of 2026-04. CNCF has been rolling out signing across projects but Jaeger has not yet adopted it for Docker Hub images.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:1.62.0`
- Source: https://github.com/jaegertracing/jaeger — public CNCF project
**Quarterly review:** Yes — check CNCF Jaeger release notes for signing adoption

### E-10 — grafana:12.3.1 (Grafana Labs)

**Image:** `docker.io/grafana/grafana:12.3.1`
**Cosign tree:** No supply chain artifacts found for Docker Hub
**Rationale:** Grafana Labs publishes images to Docker Hub. As of 2026-04, `cosign tree` returns no supply chain artifacts for `grafana/grafana` on Docker Hub. Grafana has discussed supply chain hardening but has not yet published Cosign signatures for their main distribution image. Note: the GHCR copy at `ghcr.io/grafana/grafana` may have different signing status — this has not been evaluated but is a recommended next step.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:12.3.1`
- Source: https://github.com/grafana/grafana — public Apache 2.0 project
**Quarterly review:** Yes — check ghcr.io/grafana/grafana as alternative source with potential signing

### E-11 — k8s-sidecar:1.28.0 (kiwigrid)

**Image:** `quay.io/kiwigrid/k8s-sidecar:1.28.0`
**Cosign tree:** No supply chain artifacts found
**Rationale:** The kiwigrid/k8s-sidecar project (Grafana sidecar for ConfigMap/Secret watching) does not publish Cosign signatures as of 2026-04. This is a Helm chart dependency for Grafana.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:1.28.0`
- Source: https://github.com/kiwigrid/k8s-sidecar
**Quarterly review:** Yes

### E-12 — netbox:v4.5.2 (netbox-community)

**Image:** `ghcr.io/netbox-community/netbox:v4.5.2`
**Cosign tree:** No supply chain artifacts found
**Rationale:** The NetBox community project does not publish Cosign signatures for their Docker images as of 2026-04. NetBox is IPAM/DCIM infrastructure.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:v4.5.2`
- Source: https://github.com/netbox-community/netbox — public Apache 2.0 project
- Action item: open upstream issue requesting Cosign signing
**Quarterly review:** Yes

### E-13 — valkey:9.0.2 (Bitnami)

**Image:** `docker.io/bitnami/valkey:latest` → pinned as `sentinel/valkey:9.0.2`
**Cosign tree:** HAS artifacts — `.sig` and `.att` OCI tags present
**Verification result:** `cosign verify --certificate-identity-regexp=.../bitnami/...` → "no matching signatures: nil certificate provided" — artifact exists but is not keyless/Sigstore. Bitnami uses a private static key for signing, not published to a known URL via standard cosign conventions.
**Rationale:** This image has signature artifacts suggesting Bitnami does sign their images, but the exact key URL could not be confirmed from public documentation during this assessment. This is a PARTIAL exception — signing exists, verification method is unconfirmed. A follow-up task should identify the Bitnami static key URL.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- The `:latest` tag is a risk — digest pinning is critical given Valkey's role as NetBox's Redis
- Action item: SEC-64 follow-up — identify Bitnami cosign key URL and enable static-key verification
**Quarterly review:** Yes — highest priority among exceptions due to existing sig artifact

### E-14 — ntfy:v2.18.0 (binwiederhier)

**Image:** `docker.io/binwiederhier/ntfy:v2.18.0`
**Cosign tree:** No supply chain artifacts found
**Rationale:** ntfy is a community push notification service. The binwiederhier project does not publish Cosign signatures as of 2026-04.
**Compensating controls:**
- SEC-61 OSV-Scanner + Trivy at mirror time
- Pinned to version `:v2.18.0`
- Source: https://github.com/binwiederhier/ntfy — public Apache 2.0 project
**Quarterly review:** Yes

---

## Priority Action Items

| Priority | Item | Image(s) |
|----------|------|----------|
| HIGH | Identify Bitnami static key URL; enable static-key cosign verify | valkey |
| HIGH | Digest-pin all `:latest` tags | homepage, jellyfin, hello-openshift |
| MEDIUM | Open upstream issues requesting Cosign signing | newt, netbox, ntfy |
| MEDIUM | Evaluate ghcr.io/grafana/grafana as alternative source with signing | grafana |
| LOW | Assess whether hello-openshift is still needed; retire if not | hello-openshift |
| LOW | Monitor Docker Official Library for Cosign adoption | postgres, busybox |

---

## Review Schedule

**Quarterly review:** Every 3 months, re-run `cosign tree` against all exception entries. If an upstream begins publishing signatures, remove from exception list, add to trust-policy.yaml, and update this inventory.

**Review owner:** Platform ops (operator / Judge agent)
**Next review due:** 2026-07-19
