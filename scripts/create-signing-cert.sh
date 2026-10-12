#!/bin/zsh
# Creates a self-signed "MenuMail Local Signing" code-signing identity in the login keychain.
# Signing builds with a stable identity (instead of ad-hoc) keeps the app's designated
# requirement constant, so Keychain "Always Allow" grants survive rebuilds.
set -euo pipefail

NAME="MenuMail Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# macOS's LibreSSL writes PKCS#12 files that `security import` understands (OpenSSL 3+ doesn't by default).
OPENSSL=/usr/bin/openssl
PASS="menumail-$RANDOM$RANDOM"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in the login keychain."
