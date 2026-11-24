#!/usr/bin/env bash
# Run on the DEVELOPER'S / ADMIN'S OWN machine. Needs: wireguard-tools.
# Usage: ./gen-keypair.sh <name>
# Creates <name>.key (SECRET, stays on this machine) and <name>.pub (send this to the admin).
set -euo pipefail
name=${1:?usage: gen-keypair.sh <name>}
umask 077
wg genkey | tee "${name}.key" | wg pubkey > "${name}.pub"
echo "Public key (send to admin):"; cat "${name}.pub"
