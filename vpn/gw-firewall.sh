#!/usr/bin/env bash
# Builds the vpn-gw firewall from scratch and re-adds all known peers from peers.db.
# Safe to re-run. Installed at /usr/local/sbin/gw-firewall.sh.
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/lib/gw-lib.sh

WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')   # e.g. ens5

# ---- reset (policies ACCEPT first so a re-run over SSH does not cut itself off)
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X
iptables -t nat -F
iptables -t mangle -F

iptables -N WG_PEERS   # per-peer FORWARD rules (VPN client -> GitLab)
iptables -N WG_SSH     # per-peer INPUT rules (admin -> SSH on vpn-gw)

# ---- INPUT: traffic addressed to vpn-gw itself --------------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i "$WAN_IF" -p udp --sport 67 --dport 68 -j ACCEPT          # DHCP lease renewal
iptables -A INPUT -i "$WAN_IF" -p udp --dport "$WG_PORT" -j ACCEPT             # WireGuard: the only public service
if [[ -n "${BOOTSTRAP_SSH_CIDR:-}" ]]; then
  iptables -A INPUT -i "$WAN_IF" -p tcp --dport 22 -s "$BOOTSTRAP_SSH_CIDR" -j ACCEPT   # temporary
fi
iptables -A INPUT -i "$WG_IF" -p icmp --icmp-type echo-request -j ACCEPT       # let VPN clients ping the gateway
iptables -A INPUT -i "$WG_IF" -p tcp --dport 22 -j WG_SSH                      # SSH only for peers listed in WG_SSH

# ---- FORWARD: traffic passing THROUGH vpn-gw ---------------------------------
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# VPN clients -> GitLab only; the per-peer allow rules live in WG_PEERS, anything unmatched is dropped.
iptables -A FORWARD -i "$WG_IF" -o "$WAN_IF" -d "$GITLAB_IP" -j WG_PEERS
# GitLab -> internet: web ports only, and never to other VPC addresses.
iptables -A FORWARD -i "$WAN_IF" -o "$WAN_IF" -s "$PRIVATE_CIDR" ! -d "$VPC_CIDR" \
  -p tcp -m multiport --dports 80,443 -j ACCEPT

# ---- NAT: only the private subnet's internet-bound traffic is masqueraded ----
# VPN -> GitLab traffic is NOT NATed, so GitLab logs the real 10.99.0.x client address.
iptables -t nat -A POSTROUTING -s "$PRIVATE_CIDR" ! -d "$VPC_CIDR" -o "$WAN_IF" -j MASQUERADE

# ---- MSS clamp: TCP through the tunnel must fit the WireGuard MTU (1420). Without it, big packets
# (SSH key exchange, TLS certificates) can be black-holed while small ones work: "web opens, ssh hangs".
iptables -t mangle -A FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -i "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# ---- default deny --------------------------------------------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# ---- re-add peers --------------------------------------------------------------
if [[ -f $PEERS_DB ]]; then
  while read -r name role ip _rest; do
    [[ -z ${name:-} || $name == \#* ]] && continue
    peer_fw_add "$name" "$role" "$ip"
  done < "$PEERS_DB"
fi

# Flushing above removed fail2ban's chains; restart recreates them.
systemctl try-restart fail2ban 2>/dev/null || true
netfilter-persistent save >/dev/null
echo "firewall applied (WAN interface: $WAN_IF)"
