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

## What it takes to actually *run* a plugin — the three gates

A common misconception is that Developer-ID signing + notarization is the only thing standing
between an installed `.radioplugin` and a running plugin. It is **necessary but not
sufficient**. Three independent gates must *all* be open; signing is only one of them.

### Gate 1 — the Suite must be the **Xcode host** build
A plugin is hostable only when `OutOfProcessHosting.provider != nil`. The released DMG is the
plain `swift build` (SwiftPM) artifact, which **never installs a provider** — so
`canHost(_:)` is always `false` there, regardless of how the `.appex` is signed. Only the
`RadioSuiteHost` Xcode target installs `ExtensionHostProvider` (see
[`Xcode/Host/ExtensionHosting.swift`](../Xcode/Host/ExtensionHosting.swift)). **A signed
plugin still won't load in the SwiftPM/DMG build.**

### Gate 2 — the `.appex` must be **registered with macOS**, not just on disk
Discovery goes through the **system extension registry**, not the Suite's plugins folder:

```swift
AppExtensionIdentity.matching(appExtensionPointIDs: RadioExtensionPoint.identifier)
```

The *Browse → Add Plugin from File… → Install* flow only unzips the `.appex` into
`~/Library/Application Support/AmateurRadioSuite/Plugins/`. macOS does **not** know that
extension exists, so `AppExtensionIdentity.matching` never returns it and
`ExtensionHostProvider.identities[manifest.id]` stays empty. macOS registers an app extension
only when it is **embedded inside an installed, launched container app** (under
`Contents/Extensions/`). **A loose `.appex` in Application Support — even signed and notarized
— is never discovered.**

### Gate 3 — Developer-ID signing + notarization + user approval
Needed so macOS will *load and run* the sandboxed extension process and pass the runtime
approval prompt. Ad-hoc signing (what the scripts/CI use) is fine for building, packaging, and
the discovery/catalog flow — not for loading an untrusted extension. This gate does nothing
about Gates 1 and 2.

| Gate | Released build today | What opens it |
|------|----------------------|---------------|
| 1. Host provider present | ✗ (DMG has none) | ship the Suite as the **Xcode host** build |
| 2. Extension registered with macOS | ✗ (browse-install only drops a folder) | deliver the `.appex` **embedded in an installed app** |
| 3. Signed + notarized + approved | ✗ (ad-hoc) | **Developer-ID + notarization** (Apple Developer account) |

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
