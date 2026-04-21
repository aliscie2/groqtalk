#!/bin/bash
# Creates a self-signed code-signing cert in the login keychain so that
# every rebuild of GroqTalk produces an identical TCC signing identity.
# TCC Accessibility grants then persist across rebuilds (unlike ad-hoc
# signing, where the cdhash changes every build and TCC rejects the grant).
#
# Run once. Idempotent — exits cleanly if the identity already exists.
# Reversible: delete "GroqTalk Local" from Keychain Access.
set -e

IDENTITY="GroqTalk Local"

if security find-certificate -c "$IDENTITY" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Identity '$IDENTITY' already exists in login keychain — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3

[dn]
CN = $IDENTITY

[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.conf" 2>/dev/null
openssl pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:groqtalk \
  -legacy 2>/dev/null

KC="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/cert.p12" -k "$KC" -P groqtalk \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Allow codesign to use the private key without prompting.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$KC" >/dev/null 2>&1 || true

echo "Created '$IDENTITY' in login keychain."
echo "Now rebuild (bash build.sh) and grant Accessibility once; it will persist."
