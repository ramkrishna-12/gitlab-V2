#!/usr/bin/env bash
# One-time first-boot setup of vpn-gw. Run by cloud-init; idempotent.
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/lib/gw-lib.sh

# 1. Allow the kernel to route packets between interfaces (VPN <-> private subnet <-> internet).
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-gw-forward.conf
sysctl --system >/dev/null

# 2. WireGuard server keypair, generated ON this host. The private key never leaves it
#    and never touches Terraform state.
install -d -m 700 /etc/wireguard
if [[ ! -f /etc/wireguard/server.key ]]; then
  ( umask 077; wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub )
fi

# 3. Server config. Peers are appended later by add-peer.sh.
if [[ ! -f /etc/wireguard/wg0.conf ]]; then
  ( umask 077
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${VPN_GW_WG_IP}/${VPN_CIDR#*/}
ListenPort = ${WG_PORT}
PrivateKey = $(cat /etc/wireguard/server.key)
EOF
  )
fi
touch "$PEERS_DB"; chmod 600 "$PEERS_DB"

systemctl enable --now wg-quick@wg0

# 4. Firewall (default deny + NAT).
/usr/local/sbin/gw-firewall.sh
