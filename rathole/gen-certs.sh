#!/usr/bin/env bash
# Generate a CA plus a server certificate for the rathole TLS transport.
#
#   ./gen-certs.sh <server-hostname> [output-dir] [p12-password]
#
# Outputs (output-dir defaults to this script's directory):
#   ca.pem / ca.key          CA certificate and key (client trusted_root)
#   server.pem / server.key  server certificate and key
#   server.p12               PKCS#12 bundle for [server.transport.tls]
#
# Run it once per instance. The same CA can sign several server certificates
# (one per public hostname); keep ca.key offline after the certificates exist.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <server-hostname> [output-dir] [p12-password]" >&2
  exit 2
fi

host=$1
out=${2:-$(cd "$(dirname "$0")" && pwd)}
pass=${3:-${P12_PASSWORD:-$(openssl rand -hex 16)}}

case "$host" in
  *[!0-9.]*) san="DNS:$host" ;;
  *) san="IP:$host" ;;
esac

mkdir -p "$out"
cd "$out"

for f in ca.key ca.pem server.key server.pem server.p12; do
  if [ -e "$f" ]; then
    echo "refusing to overwrite $out/$f" >&2
    exit 1
  fi
done

openssl genrsa -out ca.key 4096
openssl req -x509 -new -sha256 -days 3650 -key ca.key \
  -subj "/CN=btcexp rathole CA" -out ca.pem

openssl genrsa -out server.key 2048
openssl req -new -key server.key -subj "/CN=$host" -out server.csr
printf 'subjectAltName = %s\nextendedKeyUsage = serverAuth\n' "$san" > server.ext

openssl x509 -req -sha256 -days 825 -in server.csr \
  -CA ca.pem -CAkey ca.key -CAcreateserial -extfile server.ext -out server.pem

rm -f server.csr server.ext ca.srl
openssl pkcs12 -export -name rathole -inkey server.key -in server.pem \
  -certfile ca.pem -out server.p12 -passout "pass:$pass"
chmod 600 ca.key server.key server.p12

cat <<EOF

Generated in $out:
  ca.pem       -> client RATHOLE_CA_FILE (trusted_root)
  server.p12   -> server RATHOLE_P12_FILE
  PKCS#12 password: $pass
                -> [server.transport.tls].pkcs12_password
  client hostname:  $host
                -> [client.transport.tls].hostname
EOF
