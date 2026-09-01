#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate a self-signed TLS certificate + an admin basic-auth htpasswd file.
# Run once during installation:  ./generate-cert.sh signage.example.local
# -----------------------------------------------------------------------------
set -euo pipefail

CN="${1:-noc-signage.local}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Generating self-signed certificate for CN=${CN}"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${DIR}/signage.key" \
  -out "${DIR}/signage.crt" \
  -days 825 \
  -subj "/C=AT/O=NOC/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1"

chmod 600 "${DIR}/signage.key"
echo ">> Certificate written to ${DIR}/signage.{crt,key}"

# --- Admin basic-auth credentials (used by nginx /admin location) ------------
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 12)}"

# bcrypt via openssl passwd (-apr1 fallback if -6 unavailable on alpine host).
HASH="$(openssl passwd -apr1 "${ADMIN_PASS}")"
echo "${ADMIN_USER}:${HASH}" > "${DIR}/.htpasswd"
chmod 600 "${DIR}/.htpasswd"

echo ">> Admin login  -> user: ${ADMIN_USER}  pass: ${ADMIN_PASS}"
echo ">> Store this password now; it is not saved anywhere else."
