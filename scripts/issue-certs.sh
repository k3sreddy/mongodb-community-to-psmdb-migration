#!/usr/bin/env bash
# Issue the TLS PKI for a replica set — run on the CONTROL HOST or an admin workstation, never on a DB node.
#
#   ./scripts/issue-certs.sh                       # → artifacts/tls/{ca.crt,ca.key,*.pem}
#   ./scripts/issue-certs.sh --ca-only             # reuse an existing CA, re-issue node certificates
#   MEMBERS="a:a.example.internal:10.0.0.11 …" ./scripts/issue-certs.sh
#
# Design decisions (all three matter):
#   * SAN contains BOTH the member hostname and its IP — members replicate by hostname, and clients in
#     many estates connect by IP. A certificate that validates for only one of those fails half the time,
#     and it fails at 03:00.
#   * Each <member>.pem is certificate + key concatenated, because mongod takes a single file
#     (`net.tls.certificateKeyFile`) and will not accept them separately.
#   * The CA private key is the trust root: mode 600, backed up like the encryption key, and it must
#     never be copied onto a database host. Losing it means re-issuing every certificate.
#
# Certificate lifetime: the CA is long-lived (10 y), the member certificates are short (2 y) and MUST be
# renewed before they expire — an expired member certificate stops replication under preferTLS exactly
# like a broken config. Put the expiry in a calendar or a monitoring check. See README §13 item 6.
set -euo pipefail

OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/artifacts/tls}"
DAYS_CA="${DAYS_CA:-3650}"
DAYS_NODE="${DAYS_NODE:-730}"
CA_SUBJECT="${CA_SUBJECT:-/C=US/O=Example Corp/OU=Infrastructure/CN=MongoDB-Example-CA}"
BASE_DOMAIN="${BASE_DOMAIN:-example.internal}"

# member:hostname:ip  — the first field is the file name and must match the Ansible inventory host name,
# because 05-tls.yml copies artifacts/tls/<inventory_hostname>.pem to each node.
MEMBERS="${MEMBERS:-mongo1:mongo1:10.0.0.11 mongo2:mongo2:10.0.0.12 mongo3:mongo3:10.0.0.13}"

CA_KEY="$OUT_DIR/ca.key"
CA_CRT="$OUT_DIR/ca.crt"

umask 077
mkdir -p "$OUT_DIR"

if [[ "${1:-}" != "--ca-only" ]]; then
  if [[ -f "$CA_CRT" ]]; then
    echo "CA already exists at $CA_CRT — refusing to overwrite the trust root."
    echo "Use --ca-only to re-issue node certificates with the existing CA."
    exit 1
  fi
  echo "==> Creating cluster CA"
  openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS_CA" -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" -subj "$CA_SUBJECT"
fi

[[ -f "$CA_CRT" ]] || { echo "No CA at $CA_CRT"; exit 1; }

for entry in $MEMBERS; do
  IFS=':' read -r name host ip <<< "$entry"
  [[ -n "${name:-}" && -n "${host:-}" && -n "${ip:-}" ]] || {
    echo "Bad MEMBERS entry: '$entry' (want member:hostname:ip)"; exit 1; }
  echo "==> Issuing certificate for $host ($ip)"

  openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "$OUT_DIR/$name.key" -out "$OUT_DIR/$name.csr" \
    -subj "/C=US/O=Example Corp/OU=Infrastructure/CN=$host"

  # basicConstraints=CA:FALSE is not optional: some drivers refuse a leaf that claims to be a CA.
  cat > "$OUT_DIR/$name.ext" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:$host, DNS:$host.$BASE_DOMAIN, IP:$ip
EOF

  openssl x509 -req -in "$OUT_DIR/$name.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -days "$DAYS_NODE" -sha256 -extfile "$OUT_DIR/$name.ext" \
    -out "$OUT_DIR/$name.crt"

  cat "$OUT_DIR/$name.crt" "$OUT_DIR/$name.key" > "$OUT_DIR/$name.pem"
  chmod 600 "$OUT_DIR/$name.key" "$OUT_DIR/$name.pem"
  rm -f "$OUT_DIR/$name.csr" "$OUT_DIR/$name.ext"

  openssl verify -CAfile "$CA_CRT" "$OUT_DIR/$name.crt"
  # Same check 05-tls.yml performs on the node before installing the file:
  openssl x509 -in "$OUT_DIR/$name.pem" -noout -checkhost "$name"
done

chmod 600 "$CA_KEY" "$CA_CRT"
echo
echo "PKI written to $OUT_DIR"
echo "  ca.crt          → distributed to every member (net.tls.CAFile)"
echo "  <member>.pem    → cert+key for that member (net.tls.certificateKeyFile)"
echo "  ca.key          → KEEP OFF THE DATABASE HOSTS. Back it up like the encryption key."
echo
echo "Next: ansible-playbook playbooks/05-tls.yml -e change_ticket=CHG-xxxx -e confirm_window=YES"
