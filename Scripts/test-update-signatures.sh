#!/bin/bash
# Opt-in native signing regression test. Uses only a disposable keychain and
# harmless binaries that are inspected, never executed. No trust settings change.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$(mktemp -d "${TMPDIR:-/tmp/}tabtype-signatures.XXXXXX")"
KEYCHAIN="$FIXTURES/test.keychain-db"
PASSWORD="$(uuidgen)"
cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$FIXTURES"
}
trap cleanup EXIT
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
cat > "$FIXTURES/certificate.cnf" <<'EOF'
[req]
distinguished_name=dn
prompt=no
x509_extensions=signing
[dn]
CN=TabType Security Test
[signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
EOF
for identity in a b; do
    openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
        -config "$FIXTURES/certificate.cnf" \
        -keyout "$FIXTURES/$identity.key" -out "$FIXTURES/$identity.crt" >/dev/null 2>&1
    openssl pkcs12 -export -in "$FIXTURES/$identity.crt" -inkey "$FIXTURES/$identity.key" \
        -out "$FIXTURES/$identity.p12" -passout "pass:$PASSWORD" >/dev/null 2>&1
    security import "$FIXTURES/$identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
done
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fingerprint() { openssl x509 -in "$FIXTURES/$1.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':'; }
SIGNER_A="$(fingerprint a)"
SIGNER_B="$(fingerprint b)"
printf 'int main(void) { return 0; }\n' > "$FIXTURES/main.c"
printf 'int main(void) { return 1; }\n' > "$FIXTURES/changed.c"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 "$FIXTURES/main.c" -o "$FIXTURES/installed"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 "$FIXTURES/changed.c" -o "$FIXTURES/genuine"
xcrun clang -arch x86_64 -mmacosx-version-min=14.0 "$FIXTURES/main.c" -o "$FIXTURES/alternate"
cp "$FIXTURES/genuine" "$FIXTURES/same-name-different-key"
cp "$FIXTURES/genuine" "$FIXTURES/different-identifier"
sign() { codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$2" --identifier "$3" "$FIXTURES/$1"; }
sign installed "$SIGNER_A" app.tabtype.TabType
sign genuine "$SIGNER_A" app.tabtype.TabType
sign same-name-different-key "$SIGNER_B" app.tabtype.TabType
sign different-identifier "$SIGNER_A" different.app
sign alternate "$SIGNER_B" app.tabtype.TabType
xcrun lipo -create "$FIXTURES/installed" "$FIXTURES/alternate" -output "$FIXTURES/mixed-signers"
cp "$FIXTURES/genuine" "$FIXTURES/tampered"
printf '\001' | dd of="$FIXTURES/tampered" bs=1 seek=4096 conv=notrunc 2>/dev/null
cd "$ROOT"
TABTYPE_SIGNING_FIXTURES="$FIXTURES" DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift test --filter UpdateSignatureTests
