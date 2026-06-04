#!/bin/bash
# package-plugin-app.sh — build a radio-plugin app with its ExtensionKit extension EMBEDDED
# and Developer-ID signed, so installing the app registers the extension for the Amateur Radio
# Suite host to discover and load. This is the local, verifiable path (the basis for later CI).
#
#   ./scripts/package-plugin-app.sh <app>      # app: lp100a | lp700 | bpf | antenna | all
#
# What it does, per app:
#   build standalone .app  ->  build .appex  ->  embed .appex in Contents/Extensions/
#   ->  sign inside-out (Developer ID + hardened runtime)  ->  [notarize + staple]
#   ->  install to /Applications  ->  print pluginkit registration
#
# Env (all optional):
#   PROJECTS        parent dir holding the app repos (default: dir above this repo)
#   DEV_ID          Developer ID Application identity (auto-detected from the keychain)
#   NOTARY          notarytool keychain profile (default: RADIO_NOTARY)
#   SKIP_NOTARIZE=1 sign + install but DON'T notarize — fine to run on THIS Mac
#                   (notarization is only needed to distribute to other Macs)
#   NO_INSTALL=1    build + sign only; don't copy into /Applications
#
# After running: open the Suite, Manage Plugins -> Installed -> "Enable Extensions…",
# turn the plugin on, and select its tab.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECTS="${PROJECTS:-$(cd "$HERE/../.." && pwd)}"
NOTARY="${NOTARY:-RADIO_NOTARY}"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all

# --- per-app config: repo | build-subdir | build-cmd | app(rel to build-subdir) |
#                     xcode-subdir(rel to repo) | project | scheme | appex | entitlements(rel to xcode-subdir)
config() {
  case "$1" in
    lp100a)
      REPO="$PROJECTS/LP-100A-App"; BUILD_SUBDIR="."; BUILD_CMD="VERSION=0.2.9 ./scripts/build-app.sh"
      APP_REL="dist/LP-100A-App.app"; XCODE_SUBDIR="Xcode"; PROJECT="LP100APlugin.xcodeproj"
      SCHEME="LP100AExtension"; APPEX="LP100AExtension.appex"; ENT="Extension/LP100A.entitlements" ;;
    lp700)
      REPO="$PROJECTS/LP-700-App"; BUILD_SUBDIR="."; BUILD_CMD="VERSION=0.1.7 ./scripts/build-app.sh"
      APP_REL="dist/LP-700-App.app"; XCODE_SUBDIR="Xcode"; PROJECT="LP700Plugin.xcodeproj"
      SCHEME="LP700Extension"; APPEX="LP700Extension.appex"; ENT="Extension/LP700.entitlements" ;;
    bpf)
      REPO="$PROJECTS/BandPassFilterControllerApp"; BUILD_SUBDIR="."; BUILD_CMD="./build-app.sh"
      APP_REL="dist/Band Pass Filter Controller.app"; XCODE_SUBDIR="Xcode"; PROJECT="BandPassFilterControllerPlugin.xcodeproj"
      SCHEME="BPFExtension"; APPEX="BPFExtension.appex"; ENT="Extension/BPF.entitlements" ;;
    antenna)
      REPO="$PROJECTS/AntennaSwitchController"; BUILD_SUBDIR="App"; BUILD_CMD="UNIVERSAL=1 ./build-app.sh"
      APP_REL="dist/Antenna Switch Controller.app"; XCODE_SUBDIR="App/Xcode"; PROJECT="AntennaSwitchPlugin.xcodeproj"
      SCHEME="AntennaSwitchExtension"; APPEX="AntennaSwitchExtension.appex"; ENT="Extension/AntennaSwitch.entitlements" ;;
    *) echo "Unknown app '$1' (use: lp100a | lp700 | bpf | antenna | all)" >&2; exit 2 ;;
  esac
}

resolve_identity() {
  if [ -z "${DEV_ID:-}" ]; then
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
              | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  fi
}

package_one() {
  local key="$1"; config "$key"
  echo "============================================================"
  echo "  Packaging plugin app: $key"
  echo "============================================================"

  # 1. standalone .app
  echo "==> Building standalone app"
  ( cd "$REPO/$BUILD_SUBDIR" && eval "$BUILD_CMD" ) >/tmp/ppa-$key-app.log 2>&1 \
    || { echo "  build-app FAILED — see /tmp/ppa-$key-app.log"; tail -15 /tmp/ppa-$key-app.log; return 1; }
  local APP="$REPO/$BUILD_SUBDIR/$APP_REL"
  [ -d "$APP" ] || { echo "  app not found at $APP"; return 1; }

  # 2. .appex
  echo "==> Building extension (.appex)"
  ( cd "$REPO/$XCODE_SUBDIR" && xcodegen generate >/dev/null )
  local D; D="$(mktemp -d)"
  xcodebuild -project "$REPO/$XCODE_SUBDIR/$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$D" CODE_SIGNING_ALLOWED=NO build \
    >/tmp/ppa-$key-appex.log 2>&1 \
    || { echo "  appex build FAILED — see /tmp/ppa-$key-appex.log"; tail -15 /tmp/ppa-$key-appex.log; rm -rf "$D"; return 1; }
  local APPEX_BUILT; APPEX_BUILT="$(find "$D/Build/Products" -name "$APPEX" | head -1)"

  # 3. embed
  echo "==> Embedding $APPEX into the app"
  mkdir -p "$APP/Contents/Extensions"
  rm -rf "$APP/Contents/Extensions/$APPEX"
  cp -R "$APPEX_BUILT" "$APP/Contents/Extensions/"
  rm -rf "$D"

  # 4. sign inside-out
  if [ -n "${DEV_ID:-}" ]; then
    echo "==> Signing with: $DEV_ID"
    codesign --force -s "$DEV_ID" -o runtime --timestamp \
      --entitlements "$REPO/$XCODE_SUBDIR/$ENT" "$APP/Contents/Extensions/$APPEX"
    codesign --force -s "$DEV_ID" -o runtime --timestamp "$APP"
  else
    echo "==> WARNING: no Developer ID identity — ad-hoc signing (extension will NOT register)"
    codesign --force -s - --deep "$APP"
  fi
  codesign --verify --strict "$APP" && echo "  signature valid"

  # 5. notarize (optional)
  if [ -z "${SKIP_NOTARIZE:-}" ] && [ -n "${DEV_ID:-}" ] && xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1; then
    echo "==> Notarizing (a few minutes)…"
    local Z; Z="$(mktemp -d)/app.zip"
    ditto -c -k --keepParent "$APP" "$Z"
    xcrun notarytool submit "$Z" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$APP"
  else
    echo "==> Skipping notarization (SKIP_NOTARIZE set, no identity, or no '$NOTARY' profile) — OK for this Mac"
  fi

  # 6. install
  if [ -z "${NO_INSTALL:-}" ]; then
    local NAME; NAME="$(basename "$APP")"
    echo "==> Installing /Applications/$NAME"
    osascript -e "quit app \"${NAME%.app}\"" 2>/dev/null || true; sleep 1
    rm -rf "/Applications/$NAME"; ditto "$APP" "/Applications/$NAME"
    open "/Applications/$NAME"   # launching once registers the embedded extension
  fi
  echo "==> Done $key. Registered extensions:"
  sleep 3
  pluginkit -m -v -p org.vu3esv.radiosuite.plugin 2>/dev/null | sed 's/^/    /' || true
}

resolve_identity
if [ "${1:-}" = "all" ]; then
  for k in lp100a lp700 bpf antenna; do package_one "$k"; done
else
  package_one "${1:?usage: package-plugin-app.sh <lp100a|lp700|bpf|antenna|all>}"
fi
echo
echo "Now in the Suite: Manage Plugins -> Installed -> 'Enable Extensions…' -> turn the plugin(s) on."
