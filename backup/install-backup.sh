#!/usr/bin/env bash
# Install the backup job on the gitlab server. Run as root: ./install-backup.sh <bucket-name>
set -euo pipefail
BUCKET=${1:?usage: install-backup.sh <bucket-name>   (terraform output backup_bucket)}
HERE=$(cd "$(dirname "$0")" && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# AWS CLI v2 (official installer; reached over the NAT on vpn-gw).
if ! command -v aws >/dev/null; then
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi

install -d -m 755 /etc/gitlab-lab
cat > /etc/gitlab-lab/backup.env <<EOF
BUCKET=${BUCKET}
REGION=ap-south-1
PASSFILE=/root/.gitlab-backup-passphrase
EOF

# Encryption passphrase for the config archive. Generated once; YOU must also store a copy OFFLINE
# (password manager). Lose it and every config backup is unreadable.
if [[ ! -f /root/.gitlab-backup-passphrase ]]; then
  ( umask 077; openssl rand -base64 32 > /root/.gitlab-backup-passphrase )
  echo "!! NEW passphrase created in /root/.gitlab-backup-passphrase -- copy it to your password manager NOW."
fi

install -m 750 "$HERE/gitlab-backup.sh" /usr/local/sbin/gitlab-backup.sh
install -m 644 "$HERE/gitlab-backup.service" "$HERE/gitlab-backup.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now gitlab-backup.timer
systemctl list-timers gitlab-backup.timer --no-pager
echo "Run once now for evidence:  systemctl start gitlab-backup.service && journalctl -u gitlab-backup -n 20"
