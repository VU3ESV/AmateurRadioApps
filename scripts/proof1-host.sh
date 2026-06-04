#!/bin/bash
# Proof 1 — sign + notarize the RadioSuiteHost build (which embeds the DemoSDR sample
# extension) and install it, to prove the out-of-process hosting path end-to-end.
# See docs/SIGNING-RUNBOOK.md.
#
#   ./scripts/proof1-host.sh
#
# Env (all optional — sensible defaults / auto-detection):
#   DEV_ID   Developer ID Application identity (auto-detected from the keychain if unset)
#   NOTARY   notarytool keychain profile name           (default: RADIO_NOTARY)
#   SKIP_NOTARIZE=1   stop after signing (no notarization/install) — for a dry run
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY="${NOTARY:-RADIO_NOTARY}"

# SwiftPM's bare-repo cache trips a common global git setting under xcodebuild.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all

# --- Resolve the Developer ID Application identity -------------------------------------
if [ -z "${DEV_ID:-}" ]; then
  DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [ -z "${DEV_ID:-}" ]; then
  echo "ERROR: no 'Developer ID Application' identity in the keychain." >&2
  echo "       Create one (Xcode > Settings > Accounts > Manage Certificates > +)." >&2
  exit 1
fi
echo "==> Signing identity: $DEV_ID"

# --- Build the host (ad-hoc), so we can re-sign it properly ----------------------------
echo "==> Generating + building RadioSuiteHost (unsigned)"
( cd Xcode && xcodegen generate >/dev/null )
DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT
xcodebuild -project Xcode/RadioSuite.xcodeproj -scheme RadioSuiteHost -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$DERIVED/Build/Products/Release/RadioSuiteHost.app"
APPEX="$APP/Contents/Extensions/DemoSDRExtension.appex"
[ -d "$APPEX" ] || { echo "ERROR: embedded DemoSDRExtension.appex not found" >&2; exit 1; }

# --- Sign inside-out: extension (with sandbox entitlements) first, then the app --------
echo "==> Signing extension, then app (hardened runtime + timestamp)"
codesign --force -s "$DEV_ID" -o runtime --timestamp \
  --entitlements Xcode/Extension/DemoSDR.entitlements "$APPEX"
codesign --force -s "$DEV_ID" -o runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> SKIP_NOTARIZE=1 — signed only. App at: $APP"
  exit 0
fi

# --- Notarize + staple -----------------------------------------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
  echo "ERROR: notary profile '$NOTARY' not found. Create it (in YOUR terminal) with:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY --apple-id <email> --team-id Y6FT52BKDA --password <app-specific-pw>" >&2
  exit 1
fi
echo "==> Notarizing (this can take a few minutes)…"
ZIP="$(mktemp -d)/RadioSuiteHost.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY" --wait
echo "==> Stapling"
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP" || true

# --- Install + launch ------------------------------------------------------------------
echo "==> Installing to /Applications and launching"
osascript -e 'quit app "Amateur Radio Suite"' 2>/dev/null || true; sleep 1
rm -rf "/Applications/Amateur Radio Suite.app"
ditto "$APP" "/Applications/Amateur Radio Suite.app"
open "/Applications/Amateur Radio Suite.app"

echo
echo "==> Done. Verify the embedded extension registered:"
echo "    pluginkit -m -v -p org.vu3esv.radiosuite.plugin   # expect org.vu3esv.radiosuite.DemoSDR"
echo "    In the Suite window, the 'Demo SDR' tab should render the extension UI (not the placeholder)."
