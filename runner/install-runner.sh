#!/usr/bin/env bash
# Install Docker + GitLab Runner on the gitlab server and register a GROUP runner (company).
# Run as root AFTER provision.sh (it creates the runner on the GitLab side and saves its token).
# Uses the current "runner authentication token" flow; the old registration tokens are deprecated.
set -euo pipefail
FQDN=${FQDN:-gitlab.company.internal}
GITLAB_IP=${GITLAB_IP:-10.20.2.10}
TOKEN_FILE=/root/lab-provision/runner-token
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -s $TOKEN_FILE ]] || { echo "missing $TOKEN_FILE - run provision.sh first"; exit 1; }

apt-get update -y
apt-get install -y docker.io
systemctl enable --now docker

curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
apt-get install -y gitlab-runner

# Docker executor, NOT privileged and no docker.sock mounted into jobs: a job can never control the host's Docker.
#  --tls-ca-file       : runner and its helper container trust our internal CA
#  --docker-extra-hosts: job containers resolve the GitLab name (no DNS server in this lab)
gitlab-runner register --non-interactive \
  --url "https://${FQDN}" \
  --token "$(cat "$TOKEN_FILE")" \
  --executor docker \
  --docker-image python:3.12-slim \
  --docker-pull-policy if-not-present \
  --docker-volumes /cache \
  --docker-extra-hosts "${FQDN}:${GITLAB_IP}" \
  --tls-ca-file /etc/gitlab/trusted-certs/lab-ca.crt

sed -i 's/^concurrent = .*/concurrent = 2/' /etc/gitlab-runner/config.toml
systemctl restart gitlab-runner
gitlab-runner verify
echo "Runner registered. Trigger a pipeline on company/team-web/web-sample (branch main)."
