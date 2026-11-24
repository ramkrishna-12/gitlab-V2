#!/usr/bin/env bash
# Daily GitLab backup: (1) application data, (2) configuration + secrets (encrypted), (3) copy off the box to S3.
# Installed at /usr/local/sbin/gitlab-backup.sh, run by gitlab-backup.timer.
set -euo pipefail
source /etc/gitlab-lab/backup.env
DIR=/var/opt/gitlab/backups
TS=$(date -u +%Y%m%dT%H%M%SZ)

# 1. Application data: Git repositories, PostgreSQL (users, projects, CI/CD variables - ENCRYPTED values),
#    uploads, LFS, CI artifacts. CRON=1 = quiet output.
gitlab-backup create CRON=1
APP=$(ls -t "$DIR"/*_gitlab_backup.tar | head -1)

# 2. Configuration + secrets. gitlab-backup deliberately EXCLUDES these:
#    gitlab-secrets.json holds the keys that decrypt CI/CD variables, 2FA secrets and runner tokens in the database.
#    The file contains secrets, so it is encrypted before it leaves the machine (AES-256, passphrase file).
CFG="$DIR/config_${TS}.tar.gz.enc"
mapfile -t HOSTKEYS < <(ls /etc/ssh/ssh_host_* | sed 's|^/||')   # SSH host keys, so clients do not see a MITM warning after a rebuild
tar -C / -czf - etc/gitlab/gitlab.rb etc/gitlab/gitlab-secrets.json etc/gitlab/ssl etc/gitlab/trusted-certs \
    "${HOSTKEYS[@]}" \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:${PASSFILE}" -out "$CFG"
chmod 600 "$CFG"

# 3. Off-box copy. The instance role allows writing to this one bucket only.
aws s3 cp "$APP" "s3://${BUCKET}/gitlab/" --region "$REGION" --only-show-errors
aws s3 cp "$CFG" "s3://${BUCKET}/gitlab/" --region "$REGION" --only-show-errors

# 4. Local retention for the config archives (application backups are pruned by backup_keep_time in gitlab.rb).
find "$DIR" -name 'config_*.tar.gz.enc' -mtime +3 -delete
echo "backup ok: $(basename "$APP") + $(basename "$CFG") -> s3://${BUCKET}/gitlab/"
