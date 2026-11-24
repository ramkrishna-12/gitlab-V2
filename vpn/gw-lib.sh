#!/usr/bin/env bash
# shellcheck disable=SC2034  # WG_IF and PEERS_DB are used by the scripts that source this file
# Shared helpers for the vpn-gw scripts. Sourced, never executed.
# Installed at /usr/local/lib/gw-lib.sh by cloud-init.

# Terraform-generated, non-secret settings (CIDRs, ports, GitLab IP).
# shellcheck disable=SC1091
source /etc/gw/gw.env

WG_IF=wg0
PEERS_DB=/etc/wireguard/peers.db   # one line per peer: name role vpn-ip public-key created-at

die() { echo "ERROR: $*" >&2; exit 1; }

# Firewall rules for ONE peer.
# Every rule carries a comment "peer:<name>" so revoke can find and delete exactly its own rules.
peer_fw_add() {
  local name=$1 role=$2 ip=$3

  # Developers AND admins: GitLab on HTTPS and SSH, nothing else, nowhere else.
  iptables -A WG_PEERS -s "$ip" -d "$GITLAB_IP" -p tcp -m multiport --dports 22,443 \
    -m comment --comment "peer:${name}" -j ACCEPT

  # Admins only: SSH to vpn-gw itself (evaluated in the INPUT chain via WG_SSH).
  # SSH to gitlab is already covered by the rule above (port 22).
  if [[ $role == admin ]]; then
    iptables -A WG_SSH -s "$ip" -m comment --comment "peer:${name}" -j ACCEPT
  fi
}

# Remove every rule belonging to one peer, from both chains.
peer_fw_del() {
  local name=$1 chain rule
  for chain in WG_PEERS WG_SSH; do
    while read -r rule; do
      [[ -n $rule ]] || continue
      # "-A WG_PEERS ..." printed by `iptables -S` becomes "-D WG_PEERS ..."
      # shellcheck disable=SC2086
      iptables ${rule/-A/-D}
    done < <(iptables -S "$chain" | grep -F -- "--comment peer:${name} -j" || true)
  done
}
