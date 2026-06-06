# Runbook 06 — Certificate Renewal

**Scenario:** A certificate has expired or is near expiry. This covers two distinct certificate types used in this platform:
1. **SSH host / user certificates** (signed by Vault CA) — short-lived by design
2. **TLS certificates** (issued by Let's Encrypt via cert-manager) — 90-day lifespan, auto-renewed

---

## Part A: SSH Certificates

SSH certificates are signed by Vault's SSH CA. They are intentionally short-lived (JIT — just-in-time signing). This is not a failure mode; it is the intended behavior. A "certificate expired" SSH error means you need to sign a fresh cert.

### A1. Sign a fresh SSH certificate

```bash
export VAULT_ADDR=https://vault.208.haist.farm
export VAULT_TOKEN=<your-vault-token>

# Sign for standard user access
vault write -field=signed_key ssh/sign/admin \
  public_key=@~/.ssh/id_ed25519.pub \
  valid_principals=ubuntu \
  ttl=8h > ~/.ssh/signed-cert.pub

# Verify the cert
ssh-keygen -L -f ~/.ssh/signed-cert.pub

# SSH using the signed cert
ssh -i ~/.ssh/id_ed25519 -i ~/.ssh/signed-cert.pub ubuntu@<host-ip>
```

Note: `ssh-keygen -L` has a display bug with principals on some versions. If principals show empty, test SSH directly rather than relying on the display output. See memory entry `feedback_sshkeygen_L_principals_display_bug.md`.

### A2. Valid principals by host type

| Host type | Principal |
|-----------|-----------|
| iac-control (192.168.12.210) | `ubuntu` |
| OKD nodes | `core` |
| TrueNAS (192.168.12.205) | `root` |
| Vault VM (192.168.12.206) | `ubuntu` |
| Proxmox nodes | Uses PVE native auth (not Vault CA) |

### A3. Vault SSH CA trust is not working

If SSH rejects the cert with "no matching host key found":

```bash
# Verify the host has the Vault CA configured in authorized_keys
ssh ubuntu@<host-ip> "sudo cat /etc/ssh/authorized_keys"
# Should contain: cert-authority <vault-ca-public-key>

# If not present, the Vault CA was not provisioned on this host
# Run Ansible SSH CA role (sentinel-iac/ansible/roles/vault-ssh-ca/)
cd /home/ubuntu/overwatch-repo  # or from workstation
ansible-playbook -i inventory/hosts.ini playbooks/vault-ssh-ca.yml --limit <hostname>
```

---

## Part B: TLS Certificates

TLS certificates are managed by cert-manager in OKD. Let's Encrypt issues them via DNS-01 or HTTP-01 challenge. cert-manager auto-renews at 60 days (30 days before expiry).

### B1. Check certificate status

```bash
export KUBECONFIG=/home/ubuntu/overwatch-repo/auth/kubeconfig.new

# List all certificates and their status
oc get certificate -A

# Check a specific certificate
oc describe certificate <cert-name> -n <namespace>
```

Healthy cert shows: `Ready: True` and `Not After` at least 30 days in the future.

### B2. Certificate not renewing (stuck)

```bash
# Check the CertificateRequest and Order objects
oc get certificaterequest -A | grep -v True
oc get order -A

# Check cert-manager controller logs
oc logs -n cert-manager -l app=cert-manager --tail=50 | grep -iE 'error|fail|<cert-name>'
```

Common causes:
- DNS challenge failed — DNS provider credentials expired in Vault/ESO
- HTTP-01 challenge unreachable — Pangolin tunnel down
- Rate limit hit — Let's Encrypt rate limits per domain per week

### B3. Force certificate renewal

```bash
# Delete the Certificate secret — cert-manager will reissue
oc delete secret <tls-secret-name> -n <namespace>

# Or annotate to trigger renewal
oc annotate certificate <cert-name> -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true"

# Watch the new CertificateRequest
oc get certificaterequest -A -w
```

### B4. Certificate for a specific service

Known cert locations:

| Service | Namespace | Secret |
|---------|-----------|--------|
| Keycloak | `keycloak` | `keycloak-tls` (or check Ingress) |
| Harbor | `harbor` | `harbor-tls` |
| Grafana | `monitoring` | check Ingress annotation |
| Plane | `plane` | check Ingress |
| Backstage | `backstage` | check Ingress |

To find the cert for any ingress:
```bash
oc get ingress -n <namespace> -o yaml | grep -A2 "tls:"
```

### B5. Wildcard certificate

The platform uses `*.208.haist.farm` wildcard via DNS-01 challenge (Cloudflare). If the wildcard cert is expired or not renewing:

```bash
# Check Cloudflare credential secret
oc get externalsecret -n cert-manager | grep cloudflare

# Check the secret is populated
oc get secret cloudflare-api-token -n cert-manager -o jsonpath='{.data.api-token}' | base64 -d | wc -c
# Should be non-zero
```

If ESO is not syncing the Cloudflare token, check Vault at `secret/cloudflare/admin`.

---

## Part C: Internal CA (Vault PKI)

Some services use Vault PKI-issued certificates (internal mTLS). Check:

```bash
export VAULT_ADDR=https://vault.208.haist.farm
VAULT_TOKEN=<token> vault pki list-intermediate
VAULT_TOKEN=<token> vault read pki/cert/ca | grep -A2 "Not After"
```

If the intermediate CA cert is near expiry, file an OPS issue — this requires a planned rotation with a broader impact.

---

## Related Runbooks
- [01-vault-unseal.md](01-vault-unseal.md) — if Vault is down and SSH certs cannot be signed
- [08-break-glass.md](08-break-glass.md) — if SSH access is broken and Vault is unavailable
