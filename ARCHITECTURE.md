# Architecture and configuration structure

![Architecture diagram](architecture.svg)

(`architecture.png` is the same diagram as an image. The SVG is the source.)

## 1. Machines, subnets, address plan

| Machine | Role | Network | Address | Public? |
|---|---|---|---|---|
| `vpn-gw` | WireGuard server, bastion host, NAT for the private subnet | Public subnet `10.20.1.0/24` and VPN subnet `10.99.0.0/24` | `10.20.1.10` + Elastic IP, `10.99.0.1` on `wg0` | Yes, UDP 51820 only |
| `gitlab` | GitLab CE + GitLab Runner (Docker executor) | Private subnet `10.20.2.0/24` | `10.20.2.10` | No public IP, no route to the Internet Gateway |
| `gitlab-restore-test` | Throw-away host for the restore test (created only when `create_restore_vm = true`) | Private subnet | `10.20.2.11` | No |
| Admin laptop | VPN client, admin | VPN subnet | `10.99.0.2` | Outside the VPC |
| Developer laptops | VPN clients, developers | VPN subnet | `10.99.0.11`, `10.99.0.12` | Outside the VPC |

| Network | CIDR |
|---|---|
| VPC | `10.20.0.0/16` |
| Public subnet | `10.20.1.0/24` |
| Private subnet | `10.20.2.0/24` |
| WireGuard (VPN) subnet | `10.99.0.0/24` |

The VPN subnet must not overlap the VPC. Region: `ap-south-1`.

## 2. Open ports

| Host | Port | Source allowed | Purpose | Enforced by |
|---|---|---|---|---|
| vpn-gw | UDP 51820 | Internet (`0.0.0.0/0`) | WireGuard, the only public service | Security group + iptables `INPUT` |
| vpn-gw | TCP 22 | Admin peer only, over the VPN (`wg0`) | Admin SSH and bastion | iptables chain `WG_SSH`, sshd `AllowUsers` |
| vpn-gw | TCP 22 | One admin IP, **temporary** (`bootstrap_ssh_cidr`) | First setup only; removed afterwards | Security group + iptables |
| gitlab | TCP 443 | VPN subnet `10.99.0.0/24` | GitLab web, HTTPS clone, API | Security group + ufw + vpn-gw per-peer rule |
| gitlab | TCP 22 | VPN subnet `10.99.0.0/24`; vpn-gw `10.20.1.10` | Git over SSH (`git` user); admin SSH (`ubuntu`) | Security group + ufw + sshd `AllowUsers` |
| gitlab | TCP 443 | Docker range `172.16.0.0/12` (CI job containers) | Jobs clone the repository from this host | ufw |
| gitlab | TCP 9090 | `127.0.0.1` only | Prometheus, reached with an SSH tunnel | Bound to localhost |
| gitlab (outbound) | TCP 80, 443 | to the internet via vpn-gw NAT | apt, Docker Hub, GitLab package repositories | Security group egress + vpn-gw FORWARD rule |
| gitlab (outbound) | TCP 443 | to S3 over the gateway endpoint | Backups | Security group egress |

Anything not listed is closed (default deny on every layer).

## 3. Path of a developer's request (`git clone`)

1. The laptop resolves `gitlab.company.internal` to `10.20.2.10` (hosts file). Its WireGuard `AllowedIPs` (`10.20.2.0/24`) sends the packet into `wg0`.
2. WireGuard encrypts it and sends it as UDP 51820 to the vpn-gw Elastic IP. Only a registered peer key is accepted; a revoked key fails here.
3. vpn-gw decrypts it. iptables checks the per-peer rule in `WG_PEERS`: this peer, destination `10.20.2.10`, TCP 22 or 443.
4. vpn-gw forwards it into the VPC **without NAT**, so GitLab logs the real `10.99.0.x` address. The gitlab security group allows source `10.99.0.0/24`.
5. `ufw` on gitlab allows it. nginx (443) or sshd (22) answers.
6. The reply goes to `10.99.0.x`. The private route table sends `10.99.0.0/24` to vpn-gw's network interface, which encrypts it back to that one peer.

Admin path: laptop, `wg0`, `vpn-gw 10.99.0.1:22`, then `ProxyJump` to `gitlab 10.20.2.10:22`.

## 4. Configuration files structure

```
.
├── README.md                    how to rebuild from zero + design choices and reasons
├── EVIDENCE.md                  index of screenshots and command output
├── SECURITY.md                  Part 5 risk list + Part 4 written answers
├── RUNBOOK.md                   Part 6 handover runbook
├── evidence/                    screenshots and command output, by part
├── docs/
│   ├── ARCHITECTURE.md          this file
│   ├── architecture.svg / .png  the diagram
│   └── github-actions.md        CI/CD setup (OIDC roles, variables, approval)
├── terraform/                   the AWS infrastructure (Terraform)
│   ├── versions.tf              Terraform and provider versions, default tags
│   ├── variables.tf             addressing plan, sizes, bootstrap SSH CIDR, restore VM flag
│   ├── network.tf               VPC, subnets, route tables, return route, S3 endpoint
│   ├── security_groups.tf       outer firewall for vpn-gw and gitlab
│   ├── compute.tf               vpn-gw, Elastic IP, gitlab, optional restore VM
│   ├── iam.tf                   gitlab role: write to the backup bucket only
│   ├── s3.tf                    private, versioned, encrypted backup bucket
│   ├── outputs.tf               public IP, private IPs, bucket name
│   ├── templates/vpn-gw.cloud-init.yaml.tftpl   first-boot config for vpn-gw
│   ├── terraform.tfvars.example copy to terraform.tfvars (git-ignored)
│   └── backend.tf.example       remote state (used by CI)
├── vpn/                         installed on vpn-gw by cloud-init
│   ├── gw-bootstrap.sh          first boot: forwarding, server key, wg0
│   ├── gw-firewall.sh           iptables default deny + NAT + MSS clamp + per-peer rules
│   ├── gw-lib.sh                shared helpers (peer rules add/remove)
│   ├── add-peer.sh              add a developer or admin (public key in, client config out)
│   ├── revoke-peer.sh           revoke exactly one peer
│   └── client/
│       ├── gen-keypair.sh       run on the client: private key stays there
│       └── client.conf.example  placeholders only
├── gitlab/
│   ├── ca/make-ca.sh            internal CA + server certificate (run on the admin laptop)
│   ├── gitlab.rb.template       GitLab settings (HTTPS, Prometheus on localhost, backups, memory)
│   ├── install-gitlab.sh        install GitLab CE with the internal-CA certificate
│   └── provision.sh             API: settings, groups, users, roles, projects, protection, variable, runner
├── runner/
│   ├── install-runner.sh        Docker + runner, group-scoped registration
│   └── config.toml.example      runner config, token replaced by a placeholder
├── sample-project/              committed to company/team-web/web-sample
│   ├── .gitlab-ci.yml           lint, security (gitleaks), test, build, deploy
│   ├── app.py, test_app.py, pyproject.toml, .flake8
├── tunnel/ssh-config.example    ~/.ssh/config with ProxyJump and LocalForward
├── hardening/harden.sh          SSH, firewall, fail2ban, unattended-upgrades (both servers)
├── backup/
│   ├── gitlab-backup.sh         backup + encrypted config archive + copy to S3
│   ├── gitlab-backup.service / .timer   daily 02:30 UTC
│   ├── install-backup.sh        installs AWS CLI, passphrase, timer
│   ├── backup.env.example       bucket name placeholder
│   ├── restore.sh               restore onto a fresh instance
│   └── verify-restore.sh        evidence that data and secrets came back
└── .github/
    ├── workflows/ci.yml         shellcheck, terraform validate, trivy, gitleaks, app tests, lint
    ├── workflows/terraform-deploy.yml   plan on PR; plan/apply/destroy with approval
    └── dependabot.yml
```

### Where each file runs

| Runs on | Files |
|---|---|
| Your laptop | `terraform/`, `gitlab/ca/make-ca.sh`, `vpn/client/gen-keypair.sh`, `tunnel/ssh-config.example` |
| vpn-gw | everything in `vpn/` (installed by cloud-init), `hardening/harden.sh gw` |
| gitlab | `gitlab/install-gitlab.sh`, `gitlab/provision.sh`, `runner/install-runner.sh`, `hardening/harden.sh gitlab`, `backup/install-backup.sh` and the backup timer |
| restore VM | `backup/restore.sh`, `backup/verify-restore.sh` |
| GitHub Actions | `.github/workflows/` |
| GitLab runner | `sample-project/.gitlab-ci.yml` |

### What must never be committed
`pki/` (the CA private key), `*.tfstate`, `terraform.tfvars`, `*.key`, real `*.conf` client configs, `/root/lab-provision/*`, the backup passphrase. All are in `.gitignore`. Placeholders only: `client.conf.example`, `config.toml.example`, `backup.env.example`.
