# SC-7(5): Deny by Default / Allow by Exception - Implementation Report

**Date:** 2026-02-06  
**System:** iac-control.haist.farm (192.168.12.210)  
**Compliance:** NIST 800-53 SC-7(5)

## Implemented Controls

### 1. NTP Traffic Restriction ✅
**Previous State:**
- Allowed UDP 123 to ANY destination (0.0.0.0/0)
- No egress filtering on NTP

**Current State:**
- NTP traffic restricted to specific approved servers only
- iptables rules with IP-specific filtering:
  - 162.244.81.139 (ntp6.kernfusion.at)
  - 141.11.228.173 (nyc2.us.ntp.li)
  - 104.234.61.117 (lax1.us.ntp.li)
  - 170.187.142.180 (Linode NTP)

**Verification:**
```bash
sudo iptables -L FORWARD -n -v --line-numbers | grep NTP
```

**Limitation:**
- NTP pool servers may change IPs dynamically
- Future maintenance: Update rules if pool resolves to new IPs
- Consider: Deploy internal NTP server to avoid external dependency

### 2. Squid-OpenSSL Installation ✅
**Previous State:**
- Squid 6.13 with GnuTLS
- No SSL bumping capability
- Cannot inspect HTTPS SNI for filtering

**Current State:**
- Squid 6.13 with OpenSSL support
- SSL bumping infrastructure available
- ssl-crtd enabled for certificate generation

**Status:** INSTALLED BUT NOT CONFIGURED

### 3. HTTPS Filtering Analysis ⚠️

**Risk Assessment:**
Container registries (docker.io, quay.io, registry.redhat.io) use certificate pinning, which will break if Squid performs SSL bumping/MITM.

**Testing Results:**
- ✅ Basic HTTPS CONNECT tunneling works (no inspection)
- ⚠️ SSL bump peek-and-splice NOT enabled (would break OKD)
- ❌ Full SNI-based HTTPS filtering NOT implemented

**Design Decision:**
To maintain OKD cluster stability, HTTPS traffic is tunneled through Squid via CONNECT without deep inspection. Full SSL bumping would break:
- Container image pulls (cert pinning)
- OKD internal registry
- Kubernetes API server communication

**Alternative Approaches Considered:**
1. **Selective SSL Bump:** Peek-and-splice for approved domains, splice for registries
   - Risk: Complex configuration, may still break
   - Not implemented to avoid OKD disruption

2. **DNS-based filtering:** Block unwanted HTTPS destinations at DNS level
   - Current: No DNS filtering implemented
   - Could supplement firewall-based egress controls

3. **Firewall-only HTTPS control:** Use iptables to allow specific HTTPS IPs
   - Current approach for critical services
   - Implemented for NTP, can extend to others

## Compliance Status

### SC-7(5) Requirements
✅ Deny by default: Default FORWARD policy = DROP  
✅ Allow by exception: Explicit ACCEPT rules for approved traffic  
✅ Documentation: All exceptions documented with justification  
⚠️ HTTPS inspection: Limited to CONNECT method (no SNI filtering)

### Current Egress Rules (Summary)
| Protocol | Port(s) | Destination | Purpose | Rule # |
|----------|---------|-------------|---------|--------|
| UDP | 53 | 1.1.1.1, 8.8.8.8 | DNS | 3-4 |
| UDP | 123 | NTP servers | Time sync | 5-8 |
| TCP | 443 | Any | HTTPS | 6 |
| TCP | 80 | Any | HTTP | 7 |
| TCP | 2049,111 | 192.168.12.205 | NFS | 8 |
| ICMP | - | Any | Ping | 9 |
| UDP | 21820, 51820 | Any | WireGuard | 10-11 |
| TCP | 9000 | 192.168.12.58 | Portainer | 12 |
| TCP | 22,80,443 | 192.168.12.68 | GitLab | 13 |

## Recommendations

### Short-term (Next Sprint)
1. Implement DNS-based filtering on Unbound (192.168.12.206)
2. Add iptables rules for HTTPS to known-good IPs only
3. Document all external dependencies (registries, APIs, etc.)

### Medium-term (1-3 months)
1. Deploy internal NTP server (eliminate external NTP dependency)
2. Deploy internal container registry mirror (reduce external pulls)
3. Implement split-horizon DNS with allowlist

### Long-term (3-6 months)
1. Evaluate Istio service mesh for pod-level egress control
2. Consider air-gapped deployment with internal registries
3. Implement regular egress traffic audits

## Rollback Procedure

If squid-openssl causes issues:
```bash
sudo apt remove squid-openssl -y
sudo apt install squid -y
sudo cp /etc/squid/squid.conf.before-openssl /etc/squid/squid.conf
sudo systemctl restart squid
```

## Change Log
- 2026-02-06: NTP restricted to specific servers
- 2026-02-06: squid-openssl installed (not configured for bumping)
- 2026-02-06: Documented HTTPS inspection limitation

## Next Review
- **Date:** 2026-05-06 (quarterly)
- **Focus:** Verify NTP server IPs still valid, assess HTTPS filtering options
