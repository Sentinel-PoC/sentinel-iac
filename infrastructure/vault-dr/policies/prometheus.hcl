# Prometheus metrics - read access to sys/metrics
# Created: 2026-03-19
# Purpose: Allow Prometheus to scrape Vault metrics endpoint

path "sys/metrics" {
  capabilities = ["read"]
}
