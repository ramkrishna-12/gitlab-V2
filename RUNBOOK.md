# RUNBOOK -- handover (read top to bottom if you are covering for me)

**Map.** Laptop --WireGuard UDP 51820--> `vpn-gw` (public EIP, 10.20.1.10, VPN IP 10.99.0.1) --> `gitlab` (10.20.2.10, private). GitLab = `https://gitlab.company.internal` (hosts-file entry on every client -> 10.20.2.10). Region ap-south-1. Everything is in Terraform (`terraform/`); server scripts are in `vpn/`, `gitlab/`, `runner/`, `hardening/`, `backup/`. Admin SSH: `ssh gitlab` / `ssh vpn-gw` (see `tunnel/ssh-config.example`), VPN profile `admin` must be up.
VPN subnet: admin `.2`, developers from `.11`. The registry of peers is `/etc/wireguard/peers.db` on vpn-gw.

---
## 1. Onboard a new developer
1. **Developer** (own machine): `cd vpn/client && ./gen-keypair.sh <name>` and send you `<name>.pub` (the public key only; the `.key` never leaves their machine).
2. **You**, on vpn-gw: pick the next free address in `peers.db`, then
   `sudo add-peer.sh <name> dev 10.99.0.<N> '<their public key>'`. Send them the printed config; they paste in their own private key as `/etc/wireguard/<name>.conf`, `sudo wg-quick up <name>`.
3. They add to `/etc/hosts`: `10.20.2.10 gitlab.company.internal`, and install `ca.crt` (system trust store / `git config http.sslCAInfo`).
4. **GitLab account** (Admin > Users > New user, or `POST /users`): username, email, `skip_confirmation`. Sign-up is disabled, so accounts exist only because you created them. They log in, are forced to enrol 2FA, and add their SSH public key (Profile > SSH Keys).
5. **Group access:** add them to their team's subgroup (`team-web` or `team-mobile`) as **Developer** (Reporter for read-only). Never at `company` level unless they should see both teams.
6. Verify: `git clone` over SSH and HTTPS (HTTPS needs a personal access token because 2FA is enforced).

## 2. Offboard a developer -- every place their access must be removed
1. **VPN:** `sudo revoke-peer.sh <name>` on vpn-gw (kills the live tunnel immediately, removes config and firewall rules). Confirm with `sudo wg show` (key gone).
2. **GitLab account:** Admin > Users > *Block* (keeps their history and authorship; use Delete only if required). Blocking invalidates web sessions.
3. **Group/project memberships:** removed with the block, but check `company`, both subgroups and any direct project memberships; **transfer ownership** of anything they own.
4. **Credentials they created:** personal access tokens, SSH keys, deploy keys / deploy tokens they added, OAuth applications, project/group access tokens they created (these survive account blocking in some setups, so revoke them: Admin > Users > *user* > Impersonation/Access tokens).
5. **Secrets they could read:** if they were Maintainer/Owner anywhere, they could see CI/CD variables. **Rotate** every project/group variable of those projects and any runner token they could access.
6. **Runner/infra:** if they ever had admin access: remove their key from `~ubuntu/.ssh/authorized_keys` on vpn-gw and gitlab, and from `AllowUsers` if listed.
7. **Outside GitLab:** AWS IAM user/keys, their laptop's copy of `ca.crt` (harmless), any shared password-manager vault.
8. Record the date and what was done.

## 3. VPN is down and nobody can reach GitLab
1. From a client: `sudo wg show` -- "latest handshake" older than ~2 min or absent = tunnel not up. Check the client's internet first.
2. `terraform output vpn_gw_public_ip`; the AWS console: is `vpn-gw` *running*, status checks OK, Elastic IP still associated? Is the security group `lab-vpn-gw` still allowing UDP 51820? (`terraform plan` shows drift.)
3. Get a shell: set `bootstrap_ssh_cidr = "<your IP>/32"`, `terraform apply`, `ssh ubuntu@<eip>` (this opens the SG for you only; remove it afterwards).
4. On vpn-gw: `systemctl status wg-quick@wg0`; `sudo wg show`; `sysctl net.ipv4.ip_forward` (must be 1); `sudo iptables -S | head -30` (INPUT must allow udp 51820; FORWARD has `WG_PEERS`); `sudo systemctl restart wg-quick@wg0 && sudo gw-firewall.sh`.
5. Tunnel up but GitLab unreachable: from vpn-gw `nc -vz 10.20.2.10 443`; check the private route table has `10.99.0.0/24` and `0.0.0.0/0` pointing at vpn-gw's network interface, and `source_dest_check` is false (`terraform plan`).
6. **vpn-gw is unrecoverable:** `terraform apply -replace=aws_instance.vpn_gw` builds a new one (new EIP re-associates). Restore `/etc/wireguard` and `/etc/gw` from the backup (below) and every client keeps working. **No backup = new server key**: re-run `add-peer.sh` for everyone and send them new configs.
   Backup of the gateway state (run monthly and after every peer change): `ssh vpn-gw 'sudo tar czf - /etc/wireguard /etc/gw' | gpg -c > vpn-gw-state-$(date +%F).tgz.gpg`

## 4. GitLab shows a 502 after reboot
502 = nginx is up, the Rails app (Puma) is not (yet).
1. **Wait 3-5 minutes**: GitLab takes that long to boot on 4 GB.
2. `sudo gitlab-ctl status` -- which service is `down`? `sudo gitlab-ctl tail puma` / `postgresql`.
3. Memory: `free -h`, `swapon --show` (swap must exist; `/swapfile` in `/etc/fstab`), `sudo dmesg -T | grep -i 'out of memory'`. Puma OOM-killed -> restart again; if recurring, reduce `sidekiq['max_concurrency']` in `gitlab.rb`.
4. Disk: `df -h /var/opt/gitlab` (full disk breaks PostgreSQL, see section 5).
5. `sudo gitlab-ctl restart`, then `sudo gitlab-ctl reconfigure` if config changed. Check `/var/log/gitlab/gitlab-rails/production.log`.
6. `sudo gitlab-rake gitlab:check SANITIZE=true`. Clock skew or a time-expired certificate also break things: `timedatectl`, section 6.

## 5. Disk on the GitLab server is full
1. `df -h`; `sudo du -xh /var/opt/gitlab --max-depth=2 | sort -h | tail -15`.
2. Quick wins, safest first: old local backups `ls -lh /var/opt/gitlab/backups` (they are also in S3; delete the oldest); `sudo docker system prune -af` (runner images/containers); `sudo journalctl --vacuum-time=7d`; `sudo apt-get clean`.
3. GitLab data: Admin > Settings > CI/CD: expire old job artifacts; delete unused projects' artifacts. `sudo gitlab-rake gitlab:cleanup:orphan_job_artifact_files`.
4. Still full -> **grow the volume**: set `gitlab_volume_gb` higher in `terraform.tfvars`, `terraform apply` (online, no downtime), then on gitlab `sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1`. Take a backup/snapshot first.
5. Afterwards: `gitlab-ctl status`; if services died when the disk filled, `gitlab-ctl restart`.

## 6. TLS certificate is about to expire
Check: `echo | openssl s_client -connect 10.20.2.10:443 -servername gitlab.company.internal 2>/dev/null | openssl x509 -noout -enddate` (server cert valid 1 year, CA 5 years).
1. On the **admin laptop** (where `pki/ca.key` lives): `gitlab/ca/make-ca.sh` -- reuses the CA and issues a new server certificate.
2. `scp` `pki/gitlab.company.internal.crt` and `.key` to gitlab (via ProxyJump), then on gitlab: `sudo install -m 644 ...crt /etc/gitlab/ssl/` and `sudo install -m 600 ...key /etc/gitlab/ssl/`.
3. `sudo gitlab-ctl hup nginx` (or `gitlab-ctl reconfigure`). Re-check with the command above.
4. Clients need no change as long as the **CA** is unchanged. If the CA itself is expiring (year 5): issue a new CA and roll `ca.crt` to every client and to `/etc/gitlab/trusted-certs/`, the runner's `tls-ca-file`.
5. The next backup picks up the new certificate. Calendar reminder 30 days before expiry.

## 7. Upgrade GitLab to a newer version safely
1. Look up the supported **upgrade path** (docs.gitlab.com upgrade path tool) from the current to the target version; large jumps need stops at required versions. Read the release notes for removals and background migrations.
2. Check current version: `sudo gitlab-rake gitlab:env:info | head`. Confirm free disk (`df -h`) and that no pipelines are critical right now (announce a window).
3. **Back up first:** `sudo systemctl start gitlab-backup.service` and confirm the new files in S3. For extra safety take an EBS snapshot of the volume.
4. `sudo apt-mark unhold gitlab-ce && sudo apt-get update && sudo apt-get install gitlab-ce=<next-version>-ce.0` (one hop at a time). Then `sudo apt-mark hold gitlab-ce`.
5. After each hop wait until background migrations finish (Admin > Monitoring > Background Migrations) before the next hop.
6. Verify: `gitlab-ctl status`, `gitlab-rake gitlab:check SANITIZE=true`, log in, clone, run a pipeline. Upgrade the runner to a matching version afterwards: `apt-get install --only-upgrade gitlab-runner`.
7. **Rollback** = restore the pre-upgrade backup onto the previous version (`backup/restore.sh`); there is no in-place downgrade.
