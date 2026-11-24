#!/usr/bin/env bash
# Internal CA + server certificate for GitLab. Run on the ADMIN LAPTOP, never on a server:
# the CA private key (ca.key) must stay offline. Servers only ever get the signed certificate.
# Usage: ./make-ca.sh [fqdn] [ip] [outdir]
# Re-running keeps the existing CA and only issues a NEW server certificate (= certificate renewal).
set -euo pipefail
FQDN=${1:-gitlab.company.internal}
IP=${2:-10.20.2.10}
OUT=${3:-./pki}
mkdir -p "$OUT"; cd "$OUT"; umask 077

# --- CA (5 years). Created once. ---
if [[ ! -f ca.key || ! -f ca.crt ]]; then
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 1825 \
    -subj "/O=Company Lab/CN=Company Lab Internal CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.crt
fi

# --- Server certificate (1 year). SAN is mandatory: modern clients ignore the CN. ---
openssl ecparam -name prime256v1 -genkey -noout -out "${FQDN}.key"
openssl req -new -key "${FQDN}.key" -subj "/CN=${FQDN}" -out server.csr
cat > server.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:${FQDN},IP:${IP}
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 365 -sha256 -extfile server.ext -out server.crt
cat server.crt ca.crt > "${FQDN}.crt"     # nginx wants leaf + chain in one file
rm -f server.csr server.ext server.crt
chmod 600 "${FQDN}.key" ca.key; chmod 644 ca.crt "${FQDN}.crt"

echo "Issued: $(openssl x509 -in "${FQDN}.crt" -noout -subject -enddate)"
echo "Copy ${FQDN}.crt, ${FQDN}.key and ca.crt to the gitlab server. Install ca.crt on every client."
