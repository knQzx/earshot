#!/bin/sh
# usage: make signing-identity   (once; keeps the Automation permission across local builds)
set -eu

name="Earshot Local"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$keychain" 2>/dev/null | grep -q "\"$name\""; then
    echo "$name already exists"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

legacy=
if openssl version | grep -q '^OpenSSL 3'; then legacy=-legacy; fi
pass=earshot-$$
openssl pkcs12 -export $legacy -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout "pass:$pass"

security import "$tmp/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$keychain" "$tmp/cert.pem"

echo "created $name; run 'make install' again and allow Earshot to control Terminal once"
