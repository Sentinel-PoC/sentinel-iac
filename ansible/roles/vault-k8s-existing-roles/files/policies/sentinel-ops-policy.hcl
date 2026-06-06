# sentinel-ops-policy — Vault policy for sentinel-ops CronJobs
#
# Grants sentinel-ops workloads read access to platform credentials:
# Wazuh, GitLab (read+write), Proxmox, Unifi, MinIO, Grafana, Cloudflare.
# Also allows sys/health for Vault liveness checks.
#
# Bound to: auth/kubernetes/role/sentinel-ops
# Service account: sentinel-ops/sentinel-ops-sa (OKD cluster)
#
# Codified from live Vault — OPS-1206 (originally provisioned out-of-band)

path "secret/data/wazuh/*" { capabilities = ["read"] }
path "secret/data/gitlab" { capabilities = ["read", "create", "update"] }
path "secret/data/proxmox/*" { capabilities = ["read"] }
path "secret/data/proxmox" { capabilities = ["read"] }
path "secret/data/unifi" { capabilities = ["read"] }
path "secret/data/minio" { capabilities = ["read"] }
path "secret/data/minio/*" { capabilities = ["read"] }
path "secret/data/minio-config/*" { capabilities = ["read"] }
path "secret/data/grafana" { capabilities = ["read"] }
path "secret/data/cloudflare/*" { capabilities = ["read"] }
path "sys/health" { capabilities = ["read"] }
