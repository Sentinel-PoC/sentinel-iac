# etcd-backup-policy — Vault policy for etcd backup service account
#
# Grants the etcd-backup CronJob (SA etcd-backup-sa in sentinel-ops) access
# to transit encrypt/decrypt for etcd snapshot encryption and MinIO credentials
# for upload to object storage.
#
# Bound to: auth/kubernetes/role/etcd-backup
# Service account: sentinel-ops/etcd-backup-sa (OKD cluster)
#
# Codified from live Vault — OPS-1206 (originally provisioned out-of-band)

# Transit encrypt/decrypt for etcd backup
path "transit/encrypt/etcd-backup" {
  capabilities = ["update"]
}
path "transit/decrypt/etcd-backup" {
  capabilities = ["update"]
}
# MinIO credentials for upload
path "secret/data/minio" {
  capabilities = ["read"]
}
