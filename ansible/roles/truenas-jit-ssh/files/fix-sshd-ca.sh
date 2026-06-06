#!/bin/bash
# OPS-759: Patch sshd_config TrustedUserCAKeys into global context
# Called by systemd ExecStartPost after SSH starts.
# Uses background delayed reload to avoid HUP-in-ExecStartPost issues.
SSHD_CONFIG=/etc/ssh/sshd_config
CA_KEY_FILE=/data/vault-ssh-ca.pem
PRINCIPALS_DIR=/data/auth_principals
mkdir -p "$PRINCIPALS_DIR"
printf "root\n" > "$PRINCIPALS_DIR/root"
printf "koiakoia\n" > "$PRINCIPALS_DIR/koiakoia"
chmod 755 "$PRINCIPALS_DIR"
chmod 644 "$PRINCIPALS_DIR/root" "$PRINCIPALS_DIR/koiakoia"
[ ! -f "$CA_KEY_FILE" ] && exit 0
# Check if TrustedUserCAKeys is already in global context (before any Match block)
awk '/^Match/{exit 1} /^TrustedUserCAKeys/{found=1} END{exit !found}' "$SSHD_CONFIG" 2>/dev/null && exit 0
# Inject TrustedUserCAKeys before the first Match line
sed -i "s|^Match |TrustedUserCAKeys ${CA_KEY_FILE}\nAuthorizedPrincipalsFile ${PRINCIPALS_DIR}/%u\n\nMatch |" "$SSHD_CONFIG"
logger -t fix-sshd-ca "sshd_config patched — scheduling reload"
# Background delayed reload — exits 0 before HUP so systemd doesn't track it
(sleep 3 && kill -HUP $(pgrep -ox sshd) 2>/dev/null && logger -t fix-sshd-ca "sshd HUP sent") &
exit 0
