#!/usr/bin/env bash
# Install GitLab CE (Omnibus) with HTTPS from the internal CA. Run as root on the gitlab server.
#   export GITLAB_ROOT_PASSWORD='...'          # >= 12 chars; NOT stored anywhere in the repo
#   export GITLAB_VERSION=17.5.1-ce.0          # optional: pin (needed for restore tests); empty = latest
#   ./install-gitlab.sh /tmp/lab/pki           # directory holding <fqdn>.crt, <fqdn>.key, ca.crt
set -euo pipefail
: "${GITLAB_ROOT_PASSWORD:?export GITLAB_ROOT_PASSWORD first}"
FQDN=${FQDN:-gitlab.company.internal}
PKI=${1:-/tmp/lab/pki}
HERE=$(cd "$(dirname "$0")" && pwd)
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# 1. Swap: GitLab on 4 GB RAM gets OOM-killed during upgrades without it.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. The server resolves its own name locally (clients use their hosts file / the VPN DNS).
grep -q " ${FQDN}" /etc/hosts || echo "127.0.0.1 ${FQDN}" >> /etc/hosts

# 3. Packages and the official GitLab apt repository (reached via the NAT on vpn-gw).
apt-get update -y
apt-get install -y curl ca-certificates openssh-server perl jq unzip
curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash

# 4. Certificates. trusted-certs lets GitLab trust its own CA (runner, webhooks, API calls from the box).
install -d -m 755 /etc/gitlab/ssl /etc/gitlab/trusted-certs
install -m 644 "$PKI/${FQDN}.crt" "/etc/gitlab/ssl/${FQDN}.crt"
install -m 600 "$PKI/${FQDN}.key" "/etc/gitlab/ssl/${FQDN}.key"
install -m 644 "$PKI/ca.crt"      /etc/gitlab/trusted-certs/lab-ca.crt

# 5. gitlab.rb must exist BEFORE the package is installed, otherwise the first reconfigure
#    runs with Let's Encrypt enabled and fails.
sed "s/__FQDN__/${FQDN}/g" "$HERE/gitlab.rb.template" > /etc/gitlab/gitlab.rb
chmod 600 /etc/gitlab/gitlab.rb

# 6. Install (takes several minutes). GITLAB_ROOT_PASSWORD is read by the first reconfigure.
pkg=gitlab-ce${GITLAB_VERSION:+=$GITLAB_VERSION}
GITLAB_ROOT_PASSWORD="$GITLAB_ROOT_PASSWORD" apt-get install -y "$pkg"

# 7. Upgrades are a deliberate, backed-up procedure (RUNBOOK.md), never an unattended one.
apt-mark hold gitlab-ce

gitlab-ctl status
curl -fsS --cacert /etc/gitlab/trusted-certs/lab-ca.crt "https://${FQDN}/-/health" && echo
echo "GitLab is up. Next: provision.sh"
