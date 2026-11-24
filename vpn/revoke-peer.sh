#!/usr/bin/env bash
# Revoke ONE VPN peer without touching anyone else.
# Usage: sudo revoke-peer.sh <name>
set -euo pipefail
# shellcheck disable=SC1091
source /usr/local/lib/gw-lib.sh
[[ $EUID -eq 0 ]] || die "run as root"

name=${1:?usage: revoke-peer.sh <name>}
line=$(grep "^${name} " "$PEERS_DB") || die "no such peer: $name"
pub=$(awk '{print $4}' <<<"$line")
ip=$(awk '{print $3}' <<<"$line")

# 1. Drop the key from the LIVE interface: the tunnel dies now, other peers keep running.
wg set "$WG_IF" peer "$pub" remove

# 2. Remove it from wg0.conf so it does not come back after a reboot.
sed -i "/^# BEGIN peer ${name} /,/^# END peer ${name}\$/d" /etc/wireguard/wg0.conf

# 3. Remove registry entry and firewall rules.
sed -i "/^${name} /d" "$PEERS_DB"
peer_fw_del "$name"
netfilter-persistent save >/dev/null

echo "revoked ${name} (${ip}). Remaining peers:"
wg show "$WG_IF" peers
