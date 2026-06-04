# Signing runbook — prove the out-of-process plugins actually load (once, by hand)

This walks VU2CPL through making the **plugins view actually work** end-to-end, manually, on
one Mac with the Developer-ID signing identity. The goal is to **prove the architecture once**
before we automate it in CI across every repo.

Why manual first: the three gates ([EXTENSIONKIT.md → the three gates](EXTENSIONKIT.md#what-it-takes-to-actually-run-a-plugin--the-three-gates))
can only be exercised on a machine that has the signing identity — and registration (Gate 2)
does not happen until the extension is **properly signed** (ad-hoc is rejected by macOS).

There are two proofs:

- **Proof 1 — the host can host.** Sign + notarize the `RadioSuiteHost` build (it embeds the
  `DemoSDR` sample extension). If the **Demo SDR** tab loads, Gates 1 + 2 + 3 are all proven
  with zero dependency on the apps.
- **Proof 2 — an external app's extension registers.** Embed LP-100A's `.appex` in
  `LP-100A-App.app`, sign + notarize it, install + launch it once. The host from Proof 1 then
  discovers and hosts **LP-100A**.

---

## 0. Prerequisites (one-time)

- **Apple Developer Program** membership (VU2CPL's team).
- A **Developer ID Application** certificate in the login keychain. Confirm:
  ```sh
  security find-identity -v -p codesigning
  # -> "Developer ID Application: <Name> (<TEAMID>)"
  ```
- A **notarytool keychain profile** (stores the Apple ID + app-specific password once):
  ```sh
  xcrun notarytool store-credentials RADIO_NOTARY \
    --apple-id "you@example.com" --team-id "<TEAMID>" --password "<app-specific-password>"
  ```
- `xcodegen` (`brew install xcodegen`) and Xcode 16+.

Set these in your shell for the commands below:
```sh
export DEV_ID="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY=RADIO_NOTARY
# SwiftPM's bare-repo cache trips a common global git setting under xcodebuild:
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
```

> **Signing rule that bites:** sign **inside-out** — the `.appex` (and anything inside it)
> first, the containing `.app` last. Always `-o runtime --timestamp`. Never use `--deep`.

---

## Proof 1 — the host hosts its embedded Demo SDR

> **Shortcut:** [`scripts/proof1-host.sh`](../scripts/proof1-host.sh) runs 1a–1c in one go
> (auto-detects your Developer ID, signs inside-out, notarizes via `$NOTARY`, staples,
> installs). Dry run without notarizing: `SKIP_NOTARIZE=1 ./scripts/proof1-host.sh`.
> The manual steps below are what it does.

### 1a. Build the host (ad-hoc), then re-sign with Developer ID

```sh
cd AmateurRadioSuite/Xcode
xcodegen generate
DERIVED="$(mktemp -d)"
xcodebuild -project RadioSuite.xcodeproj -scheme RadioSuiteHost -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build
APP="$DERIVED/Build/Products/Release/RadioSuiteHost.app"

# inside-out: the embedded extension first (with its sandbox entitlements), then the app.
codesign --force -s "$DEV_ID" -o runtime --timestamp \
  --entitlements Extension/DemoSDR.entitlements \
  "$APP/Contents/Extensions/DemoSDRExtension.appex"
codesign --force -s "$DEV_ID" -o runtime --timestamp "$APP"

# verify before notarizing
codesign --verify --deep --strict --verbose=2 "$APP"
```

### 1b. Notarize + staple

```sh
ditto -c -k --keepParent "$APP" /tmp/RadioSuiteHost.zip
xcrun notarytool submit /tmp/RadioSuiteHost.zip --keychain-profile "$NOTARY" --wait
# on "status: Accepted":
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"        # -> "accepted", source=Notarized Developer ID
```

### 1c. Install + run

```sh
rm -rf "/Applications/Amateur Radio Suite.app"
ditto "$APP" "/Applications/Amateur Radio Suite.app"
open "/Applications/Amateur Radio Suite.app"
```

### 1d. ✅ Verify Proof 1

```sh
# macOS now knows the embedded extension:
pluginkit -m -v -p org.vu3esv.radiosuite.plugin    # -> lists org.vu3esv.radiosuite.DemoSDR
```

In the Suite window you should see a **Demo SDR** tab that renders the extension's UI (not the
"runs out-of-process" placeholder). **If you see it, the host + hosting + signing all work.**

---

## Proof 2 — LP-100A's extension registers and the host loads it

### 2a. Build the standalone app and its extension

```sh
cd LP-100A-App
VERSION=0.2.10 ./scripts/build-app.sh         # -> dist/LP-100A-App.app (the standalone app)
( cd Xcode && xcodegen generate )
DERIVED="$(mktemp -d)"
xcodebuild -project Xcode/LP100APlugin.xcodeproj -scheme LP100AExtension -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build
APPEX="$(find "$DERIVED/Build/Products" -name 'LP100AExtension.appex' | head -1)"
APP="dist/LP-100A-App.app"
```

### 2b. Embed the `.appex` in the app, sign inside-out

```sh
mkdir -p "$APP/Contents/Extensions"
rm -rf "$APP/Contents/Extensions/LP100AExtension.appex"
cp -R "$APPEX" "$APP/Contents/Extensions/"

# extension first (sandbox + network.client), then the whole app.
codesign --force -s "$DEV_ID" -o runtime --timestamp \
  --entitlements Xcode/Extension/LP100A.entitlements \
  "$APP/Contents/Extensions/LP100AExtension.appex"
codesign --force -s "$DEV_ID" -o runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
```

### 2c. Notarize + staple + install + launch once

```sh
ditto -c -k --keepParent "$APP" /tmp/LP-100A-App.zip
xcrun notarytool submit /tmp/LP-100A-App.zip --keychain-profile "$NOTARY" --wait
xcrun stapler staple "$APP"
rm -rf "/Applications/LP-100A-App.app"
ditto "$APP" "/Applications/LP-100A-App.app"
open "/Applications/LP-100A-App.app"     # launching once registers the embedded extension
```

### 2d. ✅ Verify Proof 2

```sh
pluginkit -m -v -p org.vu3esv.radiosuite.plugin
# -> now lists BOTH org.vu3esv.radiosuite.DemoSDR AND org.vu3esv.radiosuite.LP100A
```

Open the Suite (the host from Proof 1). It should now show an **LP-100A** tab that loads the
extension's real UI. That confirms the full external-app path: install app → extension
registered → host discovers + hosts it.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `pluginkit` lists nothing | extension not signed with a real identity, or app never launched after install; re-check `codesign --verify` and `open` the app once |
| `spctl` says "rejected" | not notarized/stapled, or signed without `-o runtime --timestamp` |
| tab shows the "runs out-of-process" placeholder, not the UI | the Suite running is the lean SwiftPM/DMG build, not the signed `RadioSuiteHost` from Proof 1 (Gate 1) |
| notarytool "Invalid" | run `xcrun notarytool log <submission-id> --keychain-profile "$NOTARY"` — usually a nested binary missing hardened runtime |
| extension loads standalone but not in the host | bundle id ≠ `plugin.json` `id`; they must be identical (the correlation key) |

---

## After the proof — then we automate

Once both proofs pass, the same steps become CI:
- **B (Suite):** the release workflow runs `xcodebuild` on `RadioSuiteHost`, then the sign +
  notarize + staple steps above, gated on signing **secrets** (cert `.p12` + password +
  notary creds) being present — falling back to the current ad-hoc DMG when they're absent.
- **A (each app):** `build-app.sh` embeds the `.appex` under `Contents/Extensions/` and the
  release signs + notarizes the app (not just the standalone binary).

Required GitHub Actions secrets (per repo that signs): the exported Developer ID cert
(`.p12`, base64) + its password, the keychain password, and notary credentials
(`APPLE_ID` / `TEAM_ID` / app-specific password, or an App Store Connect API key).
