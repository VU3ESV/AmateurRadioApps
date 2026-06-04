#!/usr/bin/env bash
# Build RadioSuiteHost — the out-of-process plugin HOST build of the Amateur Radio Suite, with
# the DemoSDR sample extension embedded — Developer-ID sign it inside-out, stamp the release
# version, notarize + staple, and produce AmateurRadioSuite-<version>.{zip,dmg} at the repo root.
#
# This is the build that can actually HOST out-of-process plugins; the lean ./build-app.sh build
# links only RadioPluginKit and declares no extension point, so it shows placeholders. Used by
# the release workflow; also runnable locally.
#
# Signing is GATED on secrets — with none set it falls back to ad-hoc so the build still
# succeeds (but an ad-hoc Suite can't host third-party extensions on another Mac).
#
#   VERSION=0.2.0 ./scripts/package-host-signed.sh
#
# Env — signing (from CI secrets):
#   MACOS_CERT_P12_BASE64   base64 of the Suite's Developer ID Application .p12 (cert + key)
#   MACOS_CERT_PASSWORD     the .p12 export password
#   KEYCHAIN_PASSWORD       password for the temp keychain (any value)
# Env — notarization (optional; needs the signing cert too):
#   NOTARY_APPLE_ID         Apple ID email
#   NOTARY_TEAM_ID          team id (Y6FT52BKDA)
#   NOTARY_PASSWORD         app-specific password for that Apple ID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
APP="dist/Amateur Radio Suite.app"
APPEX_NAME="DemoSDRExtension.appex"
ENTITLEMENTS="Xcode/Extension/DemoSDR.entitlements"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
# SwiftPM's bare-repo cache trips a common global git setting under xcodebuild.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all

echo "==> Building RadioSuiteHost (unsigned) v$VERSION"
( cd Xcode && xcodegen generate >/dev/null )
DERIVED="$(mktemp -d)"
xcodebuild -project Xcode/RadioSuite.xcodeproj -scheme RadioSuiteHost -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build >/dev/null
BUILT="$DERIVED/Build/Products/Release/RadioSuiteHost.app"
[ -d "$BUILT/Contents/Extensions/$APPEX_NAME" ] || { echo "ERROR: embedded $APPEX_NAME not found" >&2; exit 1; }

echo "==> Staging as $APP"
mkdir -p dist
rm -rf "$APP"
ditto "$BUILT" "$APP"
rm -rf "$DERIVED"

# The host Info.plist hardcodes 1.0 — stamp the release version BEFORE signing so the
# signature covers it and the About box matches the published tag.
echo "==> Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# --- import the signing cert into a throwaway keychain (CI) -----------------------------
IDENTITY=""
if [ -n "${MACOS_CERT_P12_BASE64:-}" ]; then
  echo "==> Importing Developer ID certificate into a temporary keychain"
  KC="$TMP/ars-signing.keychain-db"
  KCPW="${KEYCHAIN_PASSWORD:-ars-ci-temp}"
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
  security import "$TMP/cert.p12" -k "$KC" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
  # Make the temp keychain searchable (keep the existing ones too).
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  rm -f "$TMP/cert.p12"
  # In the fresh keychain there is exactly one Developer ID identity, so name-selection is unambiguous.
  IDENTITY="$(security find-identity -v -p codesigning "$KC" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

# --- sign inside-out (extension with sandbox entitlements first, then the app) ----------
APPEX="$APP/Contents/Extensions/$APPEX_NAME"
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with: $IDENTITY"
  codesign --force -s "$IDENTITY" -o runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APPEX"
  codesign --force -s "$IDENTITY" -o runtime --timestamp "$APP"
else
  echo "==> WARNING: no MACOS_CERT_P12_BASE64 — ad-hoc signing (can't host third-party extensions on other Macs)"
  codesign --force -s - --deep "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# --- notarize the app + staple it, so both the .zip and .dmg ship a stapled bundle ------
if [ -n "$IDENTITY" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  echo "==> Notarizing (a few minutes)…"
  NZIP="$(mktemp -d)/RadioSuiteHost.zip"
  ditto -c -k --keepParent "$APP" "$NZIP"
  xcrun notarytool submit "$NZIP" \
    --apple-id "$NOTARY_APPLE_ID" --team-id "${NOTARY_TEAM_ID:-}" --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$APP"
  echo "==> Notarized + stapled."
else
  echo "==> Skipping notarization (no NOTARY_* secrets) — app signed but not notarized."
fi

# --- package the distributable .zip + .dmg from the (now stapled) app -------------------
ZIP="AmateurRadioSuite-${VERSION}.zip"
DMG="AmateurRadioSuite-${VERSION}.dmg"
echo "==> Packaging $ZIP and $DMG"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
hdiutil create -volname "Amateur Radio Suite" -srcfolder "$APP" -ov -format UDZO "$DMG"
ls -lh "$ZIP" "$DMG"
echo "==> Done."
