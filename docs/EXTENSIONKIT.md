# Out-of-process plugins (ExtensionKit) — developer & integration notes

Third-party plugins run **out of process** as sandboxed, crash-isolated ExtensionKit
extensions. A plugin crash stays in the plugin's process; the host keeps running and the
supervisor restarts or quarantines it. This is the decided model for any non-first-party
plugin (see [PLUGIN-PLATFORM.md](../PLUGIN-PLATFORM.md)).

## How it fits together

```
Container (host process)                 Plugin (.appex, separate sandboxed process)
  ExtensionPluginSource ──discovers──▶  EXExtensionPointIdentifier = org.vu3esv.radiosuite.plugin
  EXHostViewController  ──embeds UI──▶  the extension's SwiftUI scene
  PluginSupervisor      ──restart/quarantine on crash
        ▲                                     │
        └──── typed channel (Codable) ────────┘
              HostToExtensionMessage / ExtensionToHostMessage  (RadioPluginKit 1.2)
```

- **Discovery** — the host browses installed extensions declaring our extension point id
  (`RadioExtensionPoint.identifier`) and lists them in *Manage Plugins*, reading each
  `plugin.json` manifest for name/version/capabilities without launching code.
- **Hosting** — `EXHostViewController` connects to the extension process and embeds its UI
  in the plugin's tab.
- **Channel** — host and extension exchange the `RadioPluginKit` Codable messages
  (`activate`/`deactivate`/state, and `report`/`notify`/`setBadge`/`log` back).
- **Crash control** — `PluginSupervisor` (implemented + tested in the host) records crashes;
  it restarts with exponential backoff and, on a crash-loop (N within a window), quarantines
  the plugin ("Try again" clears it). **Safe Mode** disables all non-built-in plugins.

## ⚠️ Build requirement: an Xcode app-extension target

**SwiftPM cannot build `.appex` extension bundles.** Producing a real extension (and the
host's `EXHostViewController` wiring, which needs the matching entitlements/signing) requires
an **Xcode** project with:

- a host **app** target (the suite) with the *Extension Host* capability, and
- one or more **app-extension** targets whose `Info.plist` declares the extension point.

This is done: the [`Xcode/`](../Xcode/) workspace provides the host app + a sample
`DemoSDRExtension.appex` target.

### Building the Xcode workspace

```sh
cd Xcode
xcodegen generate        # only if you changed project.yml; the .xcodeproj is committed
open RadioSuite.xcodeproj
# or headless:
xcodebuild -project RadioSuite.xcodeproj -scheme RadioSuiteHost \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

- `RadioSuiteHost` (app) reuses the package's `Sources/RadioSuite` verbatim (**excluding
  `RadioSuiteApp.swift`** — the Xcode target's `@main` is `Host/HostApp.swift`) and links
  **only `RadioPluginKit`** — no plugin apps. It adds the `Host/` layer:
  `HostApp.swift` (the host `@main`, which installs the out-of-process provider),
  `ExtensionHostView.swift` (`EXHostViewController` hosting + `ExtensionDiscovery`), and
  `ExtensionHosting.swift` (`ExtensionHostProvider` + `ExtensionPluginSource`).
- `DemoSDRExtension` (`.appex`, `type: extensionkit-extension`) is the sample out-of-process
  plugin; the app embeds it under `Contents/Extensions/`.
- The project is **XcodeGen-authored** (`Xcode/project.yml`) but the generated `.xcodeproj` is
  committed — open and edit it in Xcode directly; XcodeGen is only needed to regenerate.

### How the live tab is wired (done)

`Sources/RadioSuite` exposes an `OutOfProcessHosting` **seam** (a provider protocol + the
`bootstrap` hook). The plain SwiftPM build leaves it nil, so `swift build` stays a lean
in-process build with no ExtensionKit. The Xcode `HostApp` fills it: at launch it installs
`ExtensionHostProvider`, which

1. discovers installed extensions via `AppExtensionIdentity.matching(appExtensionPointIDs:)`
   and surfaces each as a `.discovered` `PluginEntry` (through `ExtensionPluginSource`) — no
   `plugin.json` required for embedded/installed `.appex`es;
2. makes such an entry **runnable** (`PluginEntry.isRunnable`) and renders its UI by handing
   the matching `AppExtensionIdentity` to `ExtensionHostView` (`EXHostViewController`).

**Correlation convention:** an out-of-process plugin's `manifest.id` **equals its extension's
bundle identifier**. That is the key the provider hosts by, so a discovered extension and an
on-disk `plugin.json` with the same `id` refer to the same plugin (and de-duplicate).

**Remaining for a *running* demo:** see the three gates below. The code path — discover →
entry → `EXHostViewController` — is complete and compiles; the project builds and embeds the
extension with ad-hoc signing.

## What it takes to actually *run* a plugin — the gates (verified)

Developer-ID signing alone does **not** make a plugin appear. Four conditions must all hold —
and the one most easily missed is #2, the host *declaring* its custom extension point.
**Verified empirically:** with #1–#4 in place, `pluginkit` registers the embedded extension
and the host loads it — and on the local machine this needs **no notarization** (see the note
on #4).

### 1 — the Suite must be the **Xcode host** build
A plugin is hostable only when `OutOfProcessHosting.provider != nil`. The released DMG is the
plain `swift build` (SwiftPM) artifact, which **never installs a provider** — so
`canHost(_:)` is always `false` there. Only the `RadioSuiteHost` Xcode target installs
`ExtensionHostProvider` (see [`Xcode/Host/ExtensionHosting.swift`](../Xcode/Host/ExtensionHosting.swift)).

### 2 — the host must **declare the custom extension point** (the easily-missed one)
macOS only registers extensions for a custom extension point if a **host declares that point**
via a `<point-id>.appextensionpoint` plist embedded under `Contents/Extensions/`. Our host ships
[`Xcode/Host/org.vu3esv.radiosuite.plugin.appextensionpoint`](../Xcode/Host/org.vu3esv.radiosuite.plugin.appextensionpoint)
(`EXPresentsUserInterface = true`). **Without it, `AppExtensionIdentity.matching` returns
nothing — no plugin is ever discovered, no matter how it's signed.** This was the actual cause
of the long-standing empty plugins view.

### 3 — the `.appex` must be **registered with macOS**, not just on disk
Discovery goes through the **system extension registry**:

```swift
AppExtensionIdentity.matching(appExtensionPointIDs: RadioExtensionPoint.identifier)
```

macOS registers an extension only when it is **embedded inside an installed, launched container
app** (under `Contents/Extensions/`). The *Browse → Add Plugin from File…* flow only unzips the
`.appex` into Application Support, which macOS never registers — so a loose `.appex` there is
never discovered.

### 4 — the extension must be **signed (Developer ID) and sandboxed**
The `.appex` needs a real signature (ad-hoc is rejected by the registrar) with hardened runtime,
and the App Sandbox entitlement (`com.apple.security.app-sandbox`; plus `network.client` for
networked plugins). **Notarization is *not* required to run on the machine that built/signed it**
— a locally-built, Developer-ID-signed app registers its extension fine. Notarization + stapling
are required only to **distribute to other Macs** (Gatekeeper clears the quarantine flag).

### 5 — the user must **enable** a third-party extension (disabled by default)
macOS **disables every newly-discovered third-party extension by default**; `AppExtensionIdentity.matching`
returns only the ones the user has **enabled** via `EXAppExtensionBrowserViewController`. The host
presents that browser from *Manage Plugins → Installed → "Enable Extensions…"* (see
[`Xcode/Host/ExtensionManagerWindow.swift`](../Xcode/Host/ExtensionManagerWindow.swift)). The host's
**own embedded** extension (DemoSDR) is auto-trusted and skips this; an **external** app's extension
(e.g. LP-100A) shows the placeholder until enabled there. The provider observes `matching`
continuously, so a tab flips placeholder → hosted the moment the user toggles it on.

> **Verified end-to-end:** with 1–5, the suite host renders LP-100A-App's real UI out-of-process.

| # | Requirement | Released DMG today | Verified fix |
|---|-------------|--------------------|--------------|
| 1 | Host provider present | ✗ (DMG is the SwiftPM build) | ship the **Xcode host** build |
| 2 | Host declares the extension point | ✗ (was missing) | `…/Host/*.appextensionpoint` embedded |
| 3 | `.appex` registered (embedded in installed app) | ✗ (browse-install only drops a folder) | embed the `.appex` in an installed, launched app |
| 4 | Developer-ID signed + sandboxed | ✗ (ad-hoc) | sign + entitlements (notarize only to ship to others) |
| 5 | Third-party extension enabled by the user | ✗ (no UI) | "Enable Extensions…" → `EXAppExtensionBrowserViewController` |

### What the `.radioplugin` flow actually is
Today the browse/install flow is a **catalog / manifest-display** mechanism: it lets the Suite
*show* a plugin (name, version, capabilities, the "runs out-of-process" placeholder tab)
before any code runs. It is **not** the mechanism that makes macOS load the extension.

### The recommended path to "it just works"
To make signed plugins genuinely load, the extension must get **system-registered**, which on
macOS practically means one of:

- **Each plugin ships as its own app** whose `.dmg`/bundle already embeds the `.appex` under
  `Contents/Extensions/` (e.g. `LP-100A-App.app`). Installing it to `/Applications` and
  launching once registers the embedded extension; the Xcode-host Suite then discovers and
  hosts it. The `.radioplugin`/catalog becomes pure discovery metadata pointing at that app.
- **or** the Suite embeds approved extensions at build time (as the in-repo `DemoSDR` sample
  does).

This collapses the three gates into a single install step (plus the Apple Developer account
for Gate 3): the standalone app install *also* registers the extension for the Suite to host.

### Proving it end-to-end

[SIGNING-RUNBOOK.md](SIGNING-RUNBOOK.md) is the step-by-step to open all three gates by hand
on a Mac with the Developer-ID identity: sign + notarize the `RadioSuiteHost` build (it embeds
the `DemoSDR` sample) to prove hosting, then embed + sign LP-100A's `.appex` in its app to
prove the external-app registration path. The extension entitlements this requires
(`com.apple.security.app-sandbox`, plus `network.client` for networked plugins) are wired in
`Xcode/Extension/*.entitlements` and `Xcode/project.yml`.

## Extension `Info.plist` (required keys)

```xml
<key>EXAppExtensionAttributes</key>
<dict>
    <key>EXExtensionPointIdentifier</key>
    <string>org.vu3esv.radiosuite.plugin</string>
</dict>
```

Ship a `plugin.json` (see [sample-plugin/plugin.json](sample-plugin/plugin.json)) alongside the
extension so the host can show it pre-launch with `isolation: "out-of-process"`.

## Reference skeleton

[extension-template/](extension-template/) contains a starting point: the SwiftUI view, the
`AppExtension` entry, and the `Info.plist`. It is **reference material for an Xcode extension
target** — it is intentionally not part of the SwiftPM build.
