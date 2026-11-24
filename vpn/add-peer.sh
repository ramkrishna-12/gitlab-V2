#!/usr/bin/env bash
# Add one VPN peer (developer or admin) on vpn-gw.
# Usage: sudo add-peer.sh <name> <admin|dev> <vpn-ip> <client-public-key>
# The client generates its own keypair (vpn/client/gen-keypair.sh) and sends ONLY the public
# key. The server never sees a client private key, so no key is ever shared or emailed.
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/lib/gw-lib.sh
[[ $EUID -eq 0 ]] || die "run as root"

name=${1:?usage: add-peer.sh <name> <admin|dev> <vpn-ip> <client-public-key>}
role=${2:?role: admin or dev}
ip=${3:?vpn ip, e.g. 10.99.0.11}
pub=${4:?client public key}

[[ $name =~ ^[a-z0-9-]+$ ]]       || die "name must be lowercase letters, digits, dashes"
[[ $role == admin || $role == dev ]] || die "role must be admin or dev"
[[ ${#pub} -eq 44 && $pub == *= ]] || die "that does not look like a WireGuard public key"
python3 - "$ip" "$VPN_CIDR" "$VPN_GW_WG_IP" <<'PY' || die "$ip must be a free address inside $VPN_CIDR (not the gateway's)"
import ipaddress, sys
ip, net, gw = (ipaddress.ip_address(sys.argv[1]), ipaddress.ip_network(sys.argv[2]), ipaddress.ip_address(sys.argv[3]))
sys.exit(0 if ip in net and ip != gw and ip != net.network_address and ip != net.broadcast_address else 1)
PY

grep -q  "^${name} "  "$PEERS_DB" && die "peer name '$name' already exists"
grep -q  " ${ip} "    "$PEERS_DB" && die "address $ip already assigned"
grep -qF " ${pub} "   "$PEERS_DB" && die "that public key is already registered"

# 1. Persist in wg0.conf (survives reboot). AllowedIPs = /32 means: the server only accepts
#    packets from this key if their source is exactly this address -> peers cannot spoof each other.
{
  echo
  echo "# BEGIN peer ${name} (${role})"
  echo "[Peer]"
  echo "PublicKey = ${pub}"
  echo "AllowedIPs = ${ip}/32"
  echo "# END peer ${name}"
} >> /etc/wireguard/wg0.conf

# 2. Apply to the running interface immediately (no restart, other peers unaffected).
wg set "$WG_IF" peer "$pub" allowed-ips "${ip}/32"

# 3. Registry + firewall rules.
echo "${name} ${role} ${ip} ${pub} $(date -u +%FT%TZ)" >> "$PEERS_DB"
peer_fw_add "$name" "$role" "$ip"
netfilter-persistent save >/dev/null

# 4. Print the client config. Split tunnel: only the GitLab subnet (and, for admins, the gateway) is routed via the VPN.
token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
endpoint=$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4)
allowed="$PRIVATE_CIDR"
[[ $role == admin ]] && allowed="$PRIVATE_CIDR, ${VPN_GW_WG_IP}/32"

cat <<EOF

=== client config for ${name} (save as ${name}.conf on the CLIENT, add its own private key) ===
[Interface]
PrivateKey = <PASTE_${name}_PRIVATE_KEY_HERE>
Address = ${ip}/32

[Peer]
PublicKey = $(cat /etc/wireguard/server.pub)
Endpoint = ${endpoint}:${WG_PORT}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
