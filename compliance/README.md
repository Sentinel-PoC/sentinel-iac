# Compliance Documentation

**NIST 800-53 compliance artifacts for iac-control infrastructure**

This directory contains compliance documentation created during security hardening activities. All documents are maintained under version control for audit trail and change management.

## Documents

### ac2-account-inventory.md
**Control**: AC-2 (Account Management)
**Date**: 2026-02-06
**System**: iac-control.haist.farm (192.168.12.210)

Account inventory documenting:
- All shell-enabled accounts (root, ubuntu, sync)
- Service accounts (gitlab-runner)
- Authentication mechanisms (Vault-signed SSH certificates)
- Account hardening measures (nologin shells, no password auth)
- Compliance mapping to AC-2 requirements

**Next Review**: 2026-05-06 (quarterly)

### sc7-5-implementation.md
**Control**: SC-7(5) (Boundary Protection | Deny by Default / Allow by Exception)
**Date**: 2026-02-06
**System**: iac-control.haist.farm (192.168.12.210)

Implementation details for:
- NTP egress filtering (specific trusted servers)
- Squid proxy upgrade and HTTPS filtering readiness
- Domain-based egress allowlisting
- Firewall rule documentation

## Maintenance

These documents should be updated:
- When accounts are added/removed/modified (AC-2)
- When boundary protection rules change (SC-7)
- During quarterly compliance reviews
- As part of configuration change management (CM-2)

## Related Systems

- **Configuration Management**: `/ansible/` - Infrastructure as Code
- **Rollback Procedures**: `/rollback/` - CP-2 contingency scripts
- **Network Documentation**: See network-hardening-docs.md in claude-memory

## References

- NIST SP 800-53 Rev 5: https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final
- Sentinel IAC Repository: http://192.168.12.68/root/sentinel-iac
