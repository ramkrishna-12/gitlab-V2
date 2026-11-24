# Private GitLab behind WireGuard (AWS, ap-south-1)

> Status: code written for Parts 1-6, **not yet run end to end**. See "Known gaps" at the bottom. SECURITY.md (risk list + Part 4 answers) and RUNBOOK.md (handover) are in the repo root.

## Layout
| Path | What |
|---|---|
| `terraform/` | VPC, subnets, routes, security groups, `vpn-gw`, `gitlab`, backup bucket, IAM |
| `vpn/` | Scripts installed on vpn-gw by cloud-init: firewall, add/revoke peer |
| `vpn/client/` | Client-side key generation + config example (placeholders only) |
| `gitlab/` | Internal CA script (run on the laptop), `gitlab.rb` template, install script, API provisioning |
| `sample-project/` | App + `.gitlab-ci.yml` committed to `company/team-web/web-sample` by `provision.sh` |
| `runner/` | Docker + GitLab Runner install and group-scoped registration |
| `tunnel/` | `~/.ssh/config` with ProxyJump + LocalForward |
| `hardening/` | SSH, firewall, fail2ban, unattended-upgrades for both servers |
| `backup/` | Daily backup + S3 copy, restore script, restore verification |
| `.github/workflows/` | `ci.yml` (lint, validate, scan) and `terraform-deploy.yml` (plan/apply/destroy with approval); setup in `docs/github-actions.md` |

## Design (Part 1)
| Item | Value |
|---|---|
| VPC | `10.20.0.0/16` |
| Public subnet (vpn-gw) | `10.20.1.0/24`, vpn-gw = `10.20.1.10` + Elastic IP |
| Private subnet (gitlab) | `10.20.2.0/24`, gitlab = `10.20.2.10`, no public IP, no IGW route |
| VPN subnet | `10.99.0.0/24`: gw `.1`, admin `.2`, devs `.11`, `.12` |
| Internet-exposed | **UDP 51820 only** (TCP 22 temporarily, bootstrap only) |

Choices and why:
- **WireGuard**: one UDP port, small attack surface, per-peer public keys, instant revocation.
- **Client-generated keys**: the server only ever receives public keys. No private key is shared or sent.
- **Split tunnel**: clients route only `10.20.2.0/24` (admin also `10.99.0.1/32`) through the VPN. Only GitLab needs the tunnel; sending all laptop traffic through a t3.micro adds cost and a bottleneck for no security gain here.
- **vpn-gw as NAT** instead of a NAT Gateway: saves about $32/month; gitlab only needs outbound 80/443.
- **No NAT for VPN to GitLab traffic**: GitLab logs real client IPs. Needs the VPC route `10.99.0.0/24 -> vpn-gw ENI` and `source_dest_check = false`.
- **Two firewall layers**: AWS security groups (outer) and iptables on vpn-gw (inner, per-peer).

## Build from zero
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set bootstrap_ssh_cidr to your IP/32
terraform init && terraform apply
```

### Create VPN profiles (no shared keys)
On **each client machine** (here: your laptop, once per profile):
```bash
cd vpn/client
./gen-keypair.sh admin ; ./gen-keypair.sh dev1 ; ./gen-keypair.sh dev2
```
On **vpn-gw** (`ssh ubuntu@<eip>` -- wait for `cloud-init status --wait`):
```bash
sudo add-peer.sh admin admin 10.99.0.2  '<contents of admin.pub>'
sudo add-peer.sh dev1  dev   10.99.0.11 '<contents of dev1.pub>'
sudo add-peer.sh dev2  dev   10.99.0.12 '<contents of dev2.pub>'
```
Each call prints a client config. Save it as `/etc/wireguard/<name>.conf` on the client and paste that client's own private key in. Connect with `sudo wg-quick up <name>`. One laptop can hold only one profile up at a time (they all claim `10.20.2.0/24`): `wg-quick down` before switching.

### Close the bootstrap hole
1. Set `bootstrap_ssh_cidr = ""` in `terraform.tfvars`, `terraform apply` (removes the SG rule).
2. Over the VPN as admin: `ssh ubuntu@10.99.0.1`, then `sudo sed -i 's/^BOOTSTRAP_SSH_CIDR=.*/BOOTSTRAP_SSH_CIDR=""/' /etc/gw/gw.env && sudo gw-firewall.sh`.

### Revoke one developer
```bash
sudo revoke-peer.sh dev2     # on vpn-gw; dev1 and admin are untouched
```
Evidence: `wg show` no longer lists dev2's key; on dev2's laptop `ping 10.20.2.10` fails and `wg show` never shows a handshake.

### Evidence for Part 1
- Outside the VPN: `nmap -Pn -sS -p- <eip>` shows everything filtered. UDP 51820 shows `open|filtered`, because WireGuard silently ignores unauthenticated packets. `10.20.2.10` is a private address with no route from the internet.
- Inside the VPN as dev1: `nmap -Pn -p- 10.20.2.10` shows only 22 (and 443 once GitLab is installed).
- Dev1 cannot SSH to the gateway: `ssh ubuntu@10.99.0.1` times out; admin can.

## Cost
Stop or `terraform destroy` when not working. The Elastic IP and EC2 instances bill while they exist.


---
# Parts 2-6: build order (after Part 1 works)
Copy files to the gitlab server through the bastion (VPN profile `admin` up, `~/.ssh/config` from `tunnel/ssh-config.example`):
```bash
ssh gitlab 'mkdir -p /tmp/lab'
scp -r gitlab runner hardening backup sample-project gitlab:/tmp/lab/
scp -r pki gitlab:/tmp/lab/          # server cert + key + ca.crt only; ca.key never leaves the laptop (see below)
```
**Part 2 -- GitLab**
1. Laptop: `gitlab/ca/make-ca.sh` creates `pki/` (CA + server cert for `gitlab.company.internal`). Before copying `pki/` to the server, **move `pki/ca.key` out of it** (keep it offline on the laptop).
2. Laptop: `echo '10.20.2.10 gitlab.company.internal' | sudo tee -a /etc/hosts`, and trust `pki/ca.crt`.
3. gitlab: `export GITLAB_ROOT_PASSWORD='<choose>'; sudo -E /tmp/lab/gitlab/install-gitlab.sh /tmp/lab/pki`
4. gitlab: `sudo /tmp/lab/gitlab/provision.sh` -- applies the security settings, creates `company/team-web`, `company/team-mobile`, four users, roles, two projects, protects `main`, creates the masked+protected variable and the group runner. Passwords land in `/root/lab-provision/` on the server.
Roles (what each can and cannot do):

| User | Role | Scope | Can | Cannot |
|---|---|---|---|---|
| alice-owner | Owner | `company` (inherited by both subgroups) | everything: manage groups, members, settings, delete projects, manage runners and variables | (nothing within the group) |
| bob-maintainer | Maintainer | `team-web` | merge MRs into protected `main`, manage branches/protection rules, CI/CD variables, runners of the project | delete the group, change group-level membership above his role, see `team-mobile` |
| carol-developer | Developer | `team-web` + `team-mobile` | clone, create branches, push to **non-protected** branches, open MRs, run pipelines | push directly to `main`, merge into `main`, change protection rules, read masked/protected variable values |
| dave-reporter | Reporter | `team-mobile` | read code, clone, view pipelines and issues, create issues | push anything, create branches, merge; cannot see `team-web` at all (private) |

**Part 3 -- runner and pipeline**
`sudo /tmp/lab/runner/install-runner.sh` on gitlab, then in the UI (as alice-owner) run a pipeline on `main` of `web-sample`. To demonstrate branches: carol pushes a branch and opens a MR; a Maintainer merges it.
**Part 4 -- tunnel**
Prometheus is bound to `localhost:9090` by `gitlab.rb`. Prove it: `ss -tlnp | grep 9090` on gitlab shows `127.0.0.1:9090`. Then on the laptop `ssh -N gitlab` and open `http://localhost:9090`. Written answers: SECURITY.md.
**Part 5 -- hardening**
Open a second SSH session first. `sudo /tmp/lab/hardening/harden.sh gitlab` on gitlab and `sudo ./harden.sh gw` on vpn-gw (copy the folder there too). Verification output is printed at the end of the script.
**Part 6 -- backup and restore**
1. gitlab: `sudo /tmp/lab/backup/install-backup.sh $(terraform output -raw backup_bucket)`. **Copy `/root/.gitlab-backup-passphrase` to your password manager now.** Then `sudo systemctl start gitlab-backup.service` for a first backup.
2. Why the application backup alone is not enough: `gitlab-backup` deliberately excludes `/etc/gitlab/gitlab-secrets.json` and `gitlab.rb`. The database holds CI/CD variables, 2FA secrets and runner tokens *encrypted* with keys that live only in `gitlab-secrets.json`. Restore the data without that file and every variable and 2FA enrolment is unreadable. The config also holds the TLS key and the settings the instance runs with.
3. Restore test: set `create_restore_vm = true`, `terraform apply`; copy `backup/` to the new VM (`ssh -J ubuntu@10.99.0.1 ubuntu@10.20.2.11`), put the passphrase in `/root/.gitlab-backup-passphrase`, run `sudo ./restore.sh <bucket> <app-backup.tar> <config.enc>` then `sudo ./verify-restore.sh`. Reach the web UI with `ssh -L 8443:127.0.0.1:443 ubuntu@10.20.2.11` (via ProxyJump) if you want a screenshot. Afterwards set `create_restore_vm = false` and apply to destroy it.

# Evidence checklist (you capture these)
| Evidence | How |
|---|---|
| Scan outside the VPN: nothing | `nmap -Pn -sS -p- <eip>` (all filtered); `nmap -Pn 10.20.2.10` from outside = no route/timeout |
| Scan inside the VPN: only 443 + 22 | `nmap -Pn -p- 10.20.2.10` as dev1 |
| Sign-up off, 2FA enforced | Admin > Settings > General > Sign-up restrictions / Sign-in restrictions |
| Rejected direct push to main | as carol-developer: `git push origin main` -> "protected branch" error |
| Passing pipeline, masked variable | pipeline view + the `use-masked-variable` job log showing `[MASKED]` |
| SSH tunnel to localhost-only service | `ss -tlnp` on gitlab + Prometheus in the browser via the tunnel |
| Revoked developer cannot connect | `sudo revoke-peer.sh dev2`, then `wg show` on dev2's laptop: no handshake |
| Restored instance | `verify-restore.sh` output + UI screenshot |

# Known gaps (be upfront about these in the review)
- Nothing here has been executed yet; expect small fixes on first run. Terraform and shellcheck were not available when it was written, so only `bash -n` syntax checks were done.
- `secret-scan` uses `zricethezav/gitleaks:latest`; pin a version tag before submitting.
- `provision.sh` step "default branch protection defaults" and the temporary-token creation use GitLab internals/APIs that vary between versions; both have a documented manual fallback (Admin UI).
- The runner shares a host with GitLab (risk #4). A separate runner VM is the fix.
- No automatic reboot and no monitoring/alerting (optional bonuses not done). vpn-gw failure plan = rebuild from Terraform + restore `/etc/wireguard` (RUNBOOK section 3).
