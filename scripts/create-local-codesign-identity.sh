#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${1:-Clew Local Development}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if security find-identity -v -p codesigning "${KEYCHAIN}" | grep -Fq "\"${IDENTITY_NAME}\""; then
  echo "Code-signing identity already exists: ${IDENTITY_NAME}"
  exit 0
fi

if security find-certificate -c "${IDENTITY_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
  cat >&2 <<EOF
A certificate named "${IDENTITY_NAME}" exists, but macOS does not trust it for code signing.
To use it: open Keychain Access, double-click "${IDENTITY_NAME}", open Trust, set
"Code Signing" to "Always Trust", close the window (enter your password), and rerun.
EOF
  exit 1
fi

P12_PASSWORD="$(uuidgen)"

OPENSSL_CONFIG="${TMP_DIR}/openssl.cnf"
cat > "${OPENSSL_CONFIG}" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_codesign
prompt = no

[ req_distinguished_name ]
CN = ${IDENTITY_NAME}

[ v3_codesign ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
EOF

openssl req \
  -newkey rsa:2048 \
  -nodes \
  -x509 \
  -days 3650 \
  -sha256 \
  -keyout "${TMP_DIR}/identity.key" \
  -out "${TMP_DIR}/identity.crt" \
  -config "${OPENSSL_CONFIG}" >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -legacy \
  -name "${IDENTITY_NAME}" \
  -inkey "${TMP_DIR}/identity.key" \
  -in "${TMP_DIR}/identity.crt" \
  -out "${TMP_DIR}/identity.p12" \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg sha1 \
  -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1

security import "${TMP_DIR}/identity.p12" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASSWORD}" \
  -T /usr/bin/codesign >/dev/null

if security find-identity -v -p codesigning "${KEYCHAIN}" | grep -Fq "\"${IDENTITY_NAME}\""; then
  echo "Created code-signing identity: ${IDENTITY_NAME}"
  echo "Rebuild Clew once; later builds keep the same signature, so macOS keeps its data access."
else
  cat >&2 <<EOF
The certificate was imported, but macOS does not list it as a valid code-signing identity.
Open Keychain Access and verify that "${IDENTITY_NAME}" is valid for code signing.
EOF
  exit 1
fi
