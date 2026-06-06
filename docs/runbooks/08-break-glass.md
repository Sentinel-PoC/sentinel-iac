# Break Glass — Emergency Access Without Operator

## When to Use
Operator is unavailable and platform needs urgent intervention.

## Access Chain
1. **Proxmox WebUI**: https://192.168.12.6:8006 — root@pam credentials in password manager
2. **Vault root token**: Stored offline. If transit auto-unseal works, Vault unseals on restart without operator.
3. **SSH to iac-control**: Need Vault SSH cert. If Vault is up:
   ```bash
   vault write ssh/sign/admin public_key=@~/.ssh/id_ed25519.pub valid_principals=ubuntu ttl=30m
   ```
4. **OKD access**: kubeconfig at /home/ubuntu/.kube/config on iac-control
5. **GitLab**: PAT stored in Vault at secret/gitlab

## If Vault is Sealed and Auto-Unseal Failed
1. Access Proxmox → open Vault VM 205 console
2. Run: `vault operator unseal` with key shares (stored offline with operator)
3. Requires threshold number of shares (usually 3 of 5)

## If iac-control is Down
1. SSH directly to OKD nodes requires Vault SSH cert (circular dependency)
2. Alternative: Proxmox console → iac-control VM 200 → login at console
3. Or: any machine on 192.168.12.0/24 with the kubeconfig can manage OKD

## Emergency Contacts
- Platform operator: Jim (Haists IT Consulting)
- All credentials: Vault (primary), offline backup (secondary)
