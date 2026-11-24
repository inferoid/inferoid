#!/bin/bash
# Release builds only: sign build/Inferoid.app with the Developer ID certificate (hardened runtime), have Apple notarize it,
# staple the ticket, and write build/Inferoid.zip. Runs in GitHub Actions on notes-v* tags.
# Needs: DEVELOPER_ID_P12 (base64 .p12), DEVELOPER_ID_P12_PASSWORD, NOTARY_KEY_P8 (base64 .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
set -euo pipefail
cd "$(dirname "$0")/build"
APP=Inferoid.app; W=$(mktemp -d); KC="$W/signing.keychain-db"; KCPW=$(uuidgen)
trap 'security delete-keychain "$KC" 2>/dev/null || true; rm -rf "$W"' EXIT

echo "$DEVELOPER_ID_P12" | base64 --decode > "$W/cert.p12"
echo "$NOTARY_KEY_P8" | base64 --decode > "$W/key.p8"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$W/cert.p12" -k "$KC" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
ID=$(security find-identity -v -p codesigning "$KC" | grep -o 'Developer ID Application: [^"]*' | head -1)
[ -n "$ID" ] || { echo "No Developer ID Application identity in the .p12"; exit 1; }
echo "Signing as: $ID"

ENT=../Inferoid.entitlements
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$ID" --keychain "$KC" "$APP/Contents/MacOS/InferoidNotes"
codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$ID" --keychain "$KC" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f Inferoid.zip; ditto -c -k --keepParent "$APP" Inferoid.zip
xcrun notarytool submit Inferoid.zip --key "$W/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
xcrun stapler staple "$APP"
rm -f Inferoid.zip; ditto -c -k --keepParent "$APP" Inferoid.zip    # zip again so the download carries the ticket
spctl -a -t exec -vv "$APP"
