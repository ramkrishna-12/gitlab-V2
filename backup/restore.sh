#!/usr/bin/env bash
# Restore onto a FRESH server (the restore VM, 10.20.2.11). Run as root.
#   1. put the backup passphrase in /root/.gitlab-backup-passphrase (from your OFFLINE copy)
#   2. ./restore.sh <bucket> <..._gitlab_backup.tar> <config_..._.tar.gz.enc>
# Order matters: config + secrets FIRST, then the same GitLab version, then the data.
set -euo pipefail
BUCKET=${1:?bucket}; APP=${2:?app backup file name}; CFG=${3:?config archive file name}
PASSFILE=/root/.gitlab-backup-passphrase
REGION=ap-south-1
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -s $PASSFILE ]] || { echo "missing $PASSFILE"; exit 1; }

# The backup file name carries the GitLab version it was made with: <epoch>_<date>_<version>_gitlab_backup.tar
ID=${APP%_gitlab_backup.tar}
VER=${ID##*_}
echo "restoring backup id=$ID (GitLab $VER)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y curl ca-certificates openssh-server perl jq unzip
if ! command -v aws >/dev/null; then
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
fi

# 1. Fetch both archives.
install -d -m 755 /var/opt/gitlab/backups
aws s3 cp "s3://${BUCKET}/gitlab/${APP}" /var/opt/gitlab/backups/ --region "$REGION" --only-show-errors
aws s3 cp "s3://${BUCKET}/gitlab/${CFG}" /root/ --region "$REGION" --only-show-errors

# 2. Config + secrets back in place BEFORE GitLab is installed, so the first reconfigure uses them.
#    SSH host keys are skipped on purpose here (RESTORE_SSH_HOSTKEYS=yes for a real disaster recovery,
#    so clients do not see a changed-host-key warning).
if [[ ${RESTORE_SSH_HOSTKEYS:-no} == yes ]]; then PATTERN=(); else PATTERN=(--wildcards 'etc/gitlab/*'); fi
openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${PASSFILE}" -in "/root/${CFG}" | tar -xzf - -C / "${PATTERN[@]}"

# 3. Same GitLab version as the backup (a restore across versions is refused).
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
apt-get install -y "gitlab-ce=${VER}-ce.0"
apt-mark hold gitlab-ce
grep -q ' gitlab.company.internal' /etc/hosts || echo "127.0.0.1 gitlab.company.internal" >> /etc/hosts

# 4. Restore the data.
chown git:git "/var/opt/gitlab/backups/${APP}"; chmod 600 "/var/opt/gitlab/backups/${APP}"
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
gitlab-backup restore BACKUP="$ID" GITLAB_ASSUME_YES=1
gitlab-ctl reconfigure
gitlab-ctl restart

# 5. Health + proof that the secrets match the database.
gitlab-rake gitlab:check SANITIZE=true || true
gitlab-rake gitlab:doctor:secrets
echo "Restore finished. Run backup/verify-restore.sh for the evidence."
