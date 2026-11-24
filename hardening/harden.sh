#!/usr/bin/env bash
# Baseline hardening. Run as root on each server:   ./harden.sh gitlab    |    ./harden.sh gw
#   SSH: key-only, no root, restricted users | host firewall | fail2ban | unattended security updates
# KEEP YOUR CURRENT SSH SESSION OPEN and test a second login before you close it.
set -euo pipefail
ROLE=${1:?usage: harden.sh <gitlab|gw>}
VPN_CIDR=${VPN_CIDR:-10.99.0.0/24}
GW_IP=${GW_IP:-10.20.1.10}          # vpn-gw's private address = source of ProxyJump connections
ADMIN_VPN_IP=${ADMIN_VPN_IP:-10.99.0.2}
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ $ROLE == gitlab || $ROLE == gw ]] || { echo "role must be gitlab or gw"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y fail2ban python3-systemd unattended-upgrades
[[ $ROLE == gitlab ]] && apt-get install -y ufw

# ---- 1. SSH ----------------------------------------------------------------------------------
# Named 00-* because sshd uses the FIRST value it reads and cloud-init ships its own drop-in.
if [[ $ROLE == gitlab ]]; then
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
# "git" = GitLab SSH clones for every developer. ubuntu = admin only, and only via vpn-gw or the admin's VPN address.
AllowUsers git ubuntu@${GW_IP} ubuntu@${ADMIN_VPN_IP}
Match User ubuntu
    AllowTcpForwarding yes
EOF
else
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowUsers ubuntu
# vpn-gw is the bastion: it may forward SSH to the gitlab server (and the restore VM) and nothing else.
AllowTcpForwarding yes
PermitOpen 10.20.2.10:22 10.20.2.11:22
EOF
fi
sshd -t
systemctl reload ssh

# ---- 2. Host firewall ----------------------------------------------------------------------------
if [[ $ROLE == gitlab ]]; then
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from "$VPN_CIDR" to any port 443 proto tcp comment 'GitLab HTTPS from VPN'
  ufw allow from "$VPN_CIDR" to any port 22  proto tcp comment 'GitLab SSH from VPN'
  ufw allow from "$GW_IP"    to any port 22  proto tcp comment 'admin ProxyJump via vpn-gw'
  # CI job containers clone over HTTPS from this very host (source = Docker bridge range).
  ufw allow from 172.16.0.0/12 to any port 443 proto tcp comment 'CI job containers -> GitLab'
  ufw logging low
  ufw --force enable
else
  # vpn-gw's host firewall is the iptables policy built by gw-firewall.sh (default DROP on INPUT and
  # FORWARD, plus per-peer rules). ufw would fight with it, so it is intentionally not used here.
  /usr/local/sbin/gw-firewall.sh
fi

# ---- 3. fail2ban -----------------------------------------------------------------------------------
# GitLab's Git-over-SSH goes through this same sshd, so this jail also protects git clones.
# vpn-gw is exempt on the gitlab side: every ProxyJump session appears to come from it, banning it would lock out the admin.
IGNORE="127.0.0.1/8 ::1"; [[ $ROLE == gitlab ]] && IGNORE="$IGNORE $GW_IP"
BANACTION=""; [[ $ROLE == gitlab ]] && BANACTION="banaction = ufw"
cat > /etc/fail2ban/jail.d/lab.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd
ignoreip = ${IGNORE}
${BANACTION}

[sshd]
enabled = true
mode    = aggressive
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---- 4. Automatic security updates --------------------------------------------------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Security pocket only (Ubuntu default). No automatic reboot: reboots are scheduled (RUNBOOK.md).
# gitlab-ce / gitlab-runner / docker come from third-party repos and are NOT in the allowed origins.
cat > /etc/apt/apt.conf.d/52lab-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades

# ---- verification (copy this output into your evidence) -----------------------------------------------------
echo; echo "=== VERIFY ($ROLE) ==="
sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|authenticationmethods|allowusers|allowtcpforwarding) '
[[ $ROLE == gitlab ]] && ufw status verbose || iptables -S | head -20
fail2ban-client status sshd
systemctl is-active unattended-upgrades
unattended-upgrade --dry-run 2>&1 | tail -3 || true
