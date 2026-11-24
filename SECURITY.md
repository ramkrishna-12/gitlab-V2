# SECURITY.md

## Part 5 -- the five biggest risks in this setup

| # | Risk | Why it matters here | How it is reduced |
|---|------|---------------------|-------------------|
| 1 | **A stolen or compromised developer laptop** (VPN key + SSH key on disk) | The VPN is the only door. Anyone holding a valid WireGuard key is "inside". | One key per person, so one `revoke-peer.sh` kills exactly that access. Per-peer firewall rules: even a valid dev peer reaches GitLab 443/22 and nothing else. GitLab enforces 2FA, so the VPN key alone is not enough. SSH key use needs a passphrase (policy). Offboarding checklist in RUNBOOK.md. |
| 2 | **vpn-gw: single point of entry and single point of failure** | It is the only internet-facing host, and the only copy of the WireGuard server key and peer list. | Exposes one UDP port; WireGuard does not answer unauthenticated packets, so port scans see nothing. Key-only SSH, reachable only over the VPN (bootstrap rule removed), fail2ban, automatic security updates. Rebuildable from Terraform in minutes; `/etc/wireguard` and `/etc/gw` are backed up (RUNBOOK: "VPN is down"). |
| 3 | **Unpatched GitLab** | A self-hosted GitLab holds all source code and CI secrets; critical vulnerabilities are published regularly. | Private subnet, no public IP, reachable only from VPN peers on 443/22. Upgrades are a documented, backed-up procedure (held with `apt-mark hold`, so they are deliberate). Admin subscribes to GitLab security releases and upgrades within days of a critical one. |
| 4 | **CI jobs run untrusted code on the same host as GitLab** | A malicious pipeline could try to break out of its container and reach GitLab's data and secrets. | Docker executor, not privileged, no `docker.sock` mounted, runner scoped to the `company` group only. IMDS hop limit 1 stops containers reaching the instance role. Host firewall limits what job containers can reach. Protected + masked variables only reach protected branches. **Known gap:** a separate runner VM would remove the shared-host risk entirely (next step). |
| 5 | **Backups: loss or leakage** | Backups contain every repository and `gitlab-secrets.json`. Losing the secrets makes encrypted data unrecoverable; leaking them exposes everything. | Off-box copy in a private, versioned, encrypted S3 bucket; the instance role can only write to that bucket. Config archive is AES-256 encrypted with a passphrase that is stored offline. Restore is tested (Part 6) onto a fresh instance, not assumed. 14-day lifecycle on the bucket. |

Smaller items acknowledged: self-signed CA means every client must install `ca.crt` (CA key stays offline on the admin laptop); the S3 bucket uses `force_destroy` only because this is a lab.

### Hardening applied (Part 5.1-5.4)
- **SSH (both servers):** `PermitRootLogin no`, `PasswordAuthentication no`, public-key only, `MaxAuthTries 3`, `AllowUsers` (gitlab: `git` plus `ubuntu` only from vpn-gw or the admin's VPN IP; vpn-gw: `ubuntu` only). TCP forwarding is off everywhere it is not needed. vpn-gw's `PermitOpen` lets the bastion forward only to the GitLab hosts' port 22.
- **Host firewall:** gitlab uses `ufw` (default deny incoming; 443 and 22 only from the VPN subnet, 22 from vpn-gw, 443 from Docker job containers). vpn-gw uses iptables with default DROP on INPUT and FORWARD; ufw is not used there because it would conflict with the per-peer rules.
- **fail2ban:** `sshd` jail, aggressive mode, 4 failures in 10 minutes = 1 hour ban. GitLab's git-over-SSH uses this same sshd, so git clones are covered. On gitlab, vpn-gw is exempt (every ProxyJump session comes from it).
- **Automatic updates:** `unattended-upgrades` for the Ubuntu security pocket. No automatic reboot (a reboot is a planned event for GitLab). GitLab, the runner and Docker come from third-party repos and are upgraded by hand.

---

## Part 4 -- written answers

### When an SSH tunnel, when a VPN
- **VPN (WireGuard here):** for *standing, many-user, many-service* access. Every developer needs GitLab all day over HTTPS and SSH; one tunnel per person, centrally managed and revocable, and applications need no special client configuration.
- **SSH tunnel:** for *one person, one service, a short time*. The admin needs Prometheus on `localhost:9090` of the GitLab host: no firewall rule, no new listening port, nothing to maintain. The service stays bound to localhost, and the access is authenticated by the admin's SSH key and logged by sshd.
- Rule of thumb: if you would otherwise open a port or add a firewall rule for a single person's one-off need, tunnel. If many people need it regularly, put it behind the VPN.

Exact commands (admin laptop, VPN profile `admin` up):
```bash
# one-liner
ssh -N -L 9090:127.0.0.1:9090 -J ubuntu@10.99.0.1 ubuntu@10.20.2.10
# or, with ~/.ssh/config (tunnel/ssh-config.example):
ssh -N gitlab            # LocalForward is defined in the config
# then open http://localhost:9090
```
`~/.ssh/config`:
```
Host vpn-gw
    HostName 10.99.0.1
    User ubuntu
Host gitlab
    HostName 10.20.2.10
    User ubuntu
    ProxyJump vpn-gw
    LocalForward 9090 127.0.0.1:9090
```

### "The GitLab web page opens over VPN, but `git clone` over SSH hangs" -- checks, in order
The web page working proves the VPN tunnel, routing, security group and GitLab itself are alive for port 443. So the problem is specific to port 22 or to SSH. Work from the cheapest, most informative check outward:

1. **Find where it hangs.** `GIT_SSH_COMMAND="ssh -vvv" git clone git@gitlab.company.internal:company/team-web/web-sample.git`. The last line tells you the layer: stuck at "Connecting to" = network/firewall; stuck at "Remote protocol version"/"expecting SSH2_MSG_KEX" = MTU or sshd; "Permission denied" = keys, not a hang.
2. **Is port 22 reachable at all?** `nc -vz -w 5 10.20.2.10 22` (and `nc -vz 10.20.2.10 443` as the control). Closed/timeout on 22 only -> a firewall rule; open -> carry on.
3. **Is this user banned?** On gitlab: `sudo fail2ban-client status sshd`. A banned client looks exactly like a hang (packets silently dropped). Unban with `fail2ban-client set sshd unbanip <ip>`.
4. **Firewall layers for 22, outermost to innermost.** (a) vpn-gw: `sudo iptables -L WG_PEERS -nv --line-numbers`, is there a rule for this peer's IP on port 22, and do its packet counters increase when the dev retries? (b) AWS security group `lab-gitlab`: port 22 from the VPN CIDR. (c) gitlab: `sudo ufw status` and `sudo ufw show raw` (or `journalctl -k | grep UFW`) for blocks on 22.
5. **MTU / MSS black hole.** Hangs *after* the banner during key exchange while HTTPS works is the classic signature: SSH key-exchange packets are large (newer OpenSSH uses post-quantum KEX). Check `ip link show wg0` (MTU 1420), try `ssh -o KexAlgorithms=curve25519-sha256 ...`, or temporarily set `MTU = 1280` in the client config. Fix: the MSS clamp rule on vpn-gw (`iptables -t mangle -S FORWARD`), already in `gw-firewall.sh`.
6. **Is sshd healthy and does it see the attempt?** On gitlab: `systemctl status ssh`, `ss -tlnp | grep ':22'`, and `journalctl -u ssh -f` while the dev retries. No log line at all = the packets never arrive (back to 2-4); a line = sshd is involved (go to 7).
7. **sshd policy.** `AllowUsers`/`AuthenticationMethods` in `/etc/ssh/sshd_config.d/00-hardening.conf`; `git` must be allowed. `sshd -T | grep -i allowusers`.
8. **GitLab-side SSH.** `ssh -T git@gitlab.company.internal` should greet by username. If not: the dev's public key is missing in their GitLab profile, or the `git` user's authorized_keys is broken: `sudo gitlab-rake gitlab:gitlab_shell:check`, `gitlab-ctl status`.
9. **Client side.** Wrong key offered (`ssh -vvv` shows which keys are tried; too many keys hit `MaxAuthTries 3`), `~/.ssh/config` overrides, a local firewall, or a name that resolves differently over SSH (`getent hosts gitlab.company.internal`). Try `-4` to rule out IPv6.
10. **Escalate:** `sudo tcpdump -ni any port 22 and host <dev-vpn-ip>` on vpn-gw, then on gitlab. Packets seen on one and not the other pinpoint the dropping hop.
