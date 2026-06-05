# The plugin bible — make any app a Radio Suite plugin (both tiers + pipeline)

The **canonical, end-to-end reference** for turning a macOS radio app into an
[Amateur Radio Suite](https://github.com/VU3ESV/AmateurRadioSuite) plugin. Follow it for a
**brand-new app** or to convert an existing one. It covers all three layers:

1. the **in-process plugin** (the `RadioPlugin` adapter) — for first-party/embedded use;
2. the **out-of-process plugin** — a sandboxed, crash-isolated ExtensionKit **`.appex`**
   packaged as a **`.radioplugin`** the suite browses + installs; and
3. the **build & release pipeline** — so the app's own CI/release builds and ships both
   forms automatically, and registers the plugin in the suite catalog.

It is written so a **fresh Claude session (or any developer)** can apply it to one app at a
time. **LP-700** ([LP-700-App](https://github.com/VU3ESV/LP-700-App)) and **LP-100A**
([LP-100A-App](https://github.com/VU3ESV/LP-100A-App)) are the worked references — every
step links the real files. To do another app, repeat the steps and substitute the values
in §0.

> Deeper background: [ARCHITECTURE.md](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/ARCHITECTURE.md)
> (the contract, the two tiers, the hosting seam) and
> [docs/EXTENSIONKIT.md](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/docs/EXTENSIONKIT.md).

---

## 0. Per-app variables (substitute these everywhere)

| Variable | LP-700 value | Used in |
|---|---|---|
| `<Repo>` | `LP-700-App` | the GitHub repo |
| `<RepoModule>` | `LP700App` | the SwiftPM **library** product that holds the app's views |
| `<RootView>` | `ContentView(vm: MeterViewModel())` | the SwiftUI root the plugin shows |
| `<Adapter>` | `LP700Plugin` | the in-process `RadioPlugin` type (§1) |
| `<Factory>` | `LP700Extension` | the public out-of-process root-view factory (§2) |
| `<PluginName>` | `LP-700` | display name (manifest + Info.plist) |
| `<pluginID>` (in-process) | `lp700` | short id for the in-process manifest |
| `<BundleID>` (out-of-process) | `org.vu3esv.radiosuite.LP700` | the `.appex` bundle id **and** `plugin.json` `id` — they MUST match |
| `<SystemImage>` | `gauge.with.dots.needle.bottom.50percent` | SF Symbol for the sidebar/tab |
| `<capabilities>` | `[.networkClient, .notifications]` | what the plugin touches |
| `<ExtTarget>` | `LP700Extension` | the Xcode `.appex` target/scheme name |
| `<pkg>` | `LP700.radioplugin` | the installable package filename (`dist/`) |
| `<catalogPkg>` | `lp700.radioplugin` | the package committed in the suite catalog |

**The one rule that matters:** for the out-of-process tier, the `.appex` **bundle
identifier** must equal the `plugin.json` **`id`**. That is the key the suite correlates a
discovered extension to its manifest by. Use a stable reverse-DNS id and never change it.

---

## 1. The in-process plugin (the `RadioPlugin` adapter)

Every plugin — in- or out-of-process — is fundamentally a type conforming to `RadioPlugin`
from [RadioPluginKit](https://github.com/VU3ESV/RadioPluginKit). Add **one** `public`
adapter to your library; keep every other type `internal`.

Reference: [`LP700Plugin.swift`](https://github.com/VU3ESV/LP-700-App/blob/main/Sources/LP700App/LP700Plugin.swift).
Full contract + rules: [ARCHITECTURE.md §2, §6](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/ARCHITECTURE.md).

1. **Depend on the contract** in `Package.swift`:
   ```swift
   .package(url: "https://github.com/VU3ESV/RadioPluginKit.git", from: "1.2.0"),
   // ...and add `.product(name: "RadioPluginKit", package: "RadioPluginKit")` to the library target.
   ```
2. **Conform one `public` type:**
   ```swift
   import SwiftUI
   import RadioPluginKit

   @MainActor
   public final class <Adapter>: RadioPlugin {          // e.g. LP700Plugin
       public static let manifest: RadioPluginManifest? = RadioPluginManifest(
           id: "<pluginID>", name: "<PluginName>", version: "1.0",
           isolation: .inProcess,                        // first-party / embedded
           capabilities: <capabilities>,
           systemImage: "<SystemImage>", author: "VU3ESV")
       public static var metadata: PluginMetadata { manifest!.metadata }

       private let host: PluginHost
       private let vm: MeterViewModel
       private var started = false

       public init(host: PluginHost) {
           self.host = host
           AppDefaults.store = host.defaults(for: Self.metadata.id)   // per-plugin storage, BEFORE any view
           self.vm = MeterViewModel()
       }
       public func makeRootView() -> AnyView { AnyView(<RootView>) }
       public func activate() { /* idempotent connect; see reference */ }
       public var menuCommands: [PluginCommand] { /* optional */ [] }
   }
   ```

**Rules** (full list in ARCHITECTURE §6): one `public` type; **never** touch
`UserDefaults.standard` (use `host.defaults(for:)`); never draw window chrome; make
`activate()` idempotent; report problems via `host.report` / `host.notify`.

This adapter is what `swift build` compiles and `swift test` exercises — so **CI already
covers it** (see §7). It's used directly when a build embeds the plugin in-process; the
out-of-process tier (§2+) reuses the same views through a thin factory.

---

## 2. Expose a public root-view factory (for the out-of-process module)

The `.appex` is a **separate module**, so it can't see your app's `internal` views. Add one
small `public` factory — nothing else becomes public.

Reference: [`LP700Extension.swift`](https://github.com/VU3ESV/LP-700-App/blob/main/Sources/LP700App/LP700Extension.swift)

```swift
import SwiftUI

public enum <Factory> {                        // e.g. LP700Extension
    @MainActor
    public static func rootView(defaults: UserDefaults? = nil) -> AnyView {
        if let defaults { AppDefaults.store = defaults }   // your app's @AppStorage backing
        return AnyView(<RootView>)
    }
}
```

Verify the plain build is unaffected: `swift build && swift test`.

---

## 3. Add the ExtensionKit `.appex` target (Xcode, via XcodeGen)

SwiftPM **cannot** build `.appex` bundles, so add a tiny Xcode project. Create three files
under `Xcode/`:

**`Xcode/Extension/<ExtTarget>.swift`** — the extension entry point.
Reference: [`LP700PluginExtension.swift`](https://github.com/VU3ESV/LP-700-App/blob/main/Xcode/Extension/LP700PluginExtension.swift)

```swift
import SwiftUI
import ExtensionFoundation
import ExtensionKit
import <RepoModule>                            // e.g. LP700App

@main
struct <ExtTarget>: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: "primary") { <Factory>.rootView() }
        )
    }
}
```

**`Xcode/Extension/Info.plist`** — must declare the suite's extension point.
Reference: [`Info.plist`](https://github.com/VU3ESV/LP-700-App/blob/main/Xcode/Extension/Info.plist)

```xml
<key>EXAppExtensionAttributes</key>
<dict>
    <key>EXExtensionPointIdentifier</key>
    <string>org.vu3esv.radiosuite.plugin</string>
</dict>
```

**`Xcode/project.yml`** — XcodeGen spec. Links **only** RadioPluginKit + your own library.
Reference: [`project.yml`](https://github.com/VU3ESV/LP-700-App/blob/main/Xcode/project.yml)

```yaml
name: <PluginName>Plugin
options: { bundleIdPrefix: org.vu3esv.radiosuite, deploymentTarget: { macOS: "14.0" } }
packages:
  RadioPluginKit: { url: https://github.com/VU3ESV/RadioPluginKit.git, from: "1.2.0" }
  <RepoModule>:   { path: .. }                 # this repo's SwiftPM package
targets:
  <ExtTarget>:
    type: extensionkit-extension
    platform: macOS
    sources: [ { path: Extension, excludes: [ plugin.json ] } ]
    info:
      path: Extension/Info.plist
      properties:
        EXAppExtensionAttributes: { EXExtensionPointIdentifier: org.vu3esv.radiosuite.plugin }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: <BundleID>   # MUST equal plugin.json id
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"                  # ad-hoc for dev/CI
    dependencies:
      - { package: RadioPluginKit, product: RadioPluginKit }
      - { package: RadioPluginKit, product: RadioPluginUI }
      - { package: <RepoModule>,   product: <RepoModule> }
```

> Keep the generated `.xcodeproj` **gitignored** (your repo's `.gitignore` likely already
> ignores `*.xcodeproj/`); regenerate with `xcodegen generate`. Commit only `project.yml`
> + `Extension/`.

---

## 4. Write `plugin.json`

`Xcode/Extension/plugin.json` — the manifest the suite reads (without loading code).
Reference: [`plugin.json`](https://github.com/VU3ESV/LP-700-App/blob/main/Xcode/Extension/plugin.json)

```json
{
  "id": "<BundleID>",                 // == the .appex bundle id
  "name": "<PluginName>",
  "version": "1.0.0",
  "sdkVersion": "1.2",
  "minHostVersion": "1.0",
  "isolation": "out-of-process",
  "capabilities": ["network.client", "notifications"],
  "systemImage": "<SystemImage>",
  "author": "VU3ESV",
  "homepage": "https://github.com/VU3ESV/<Repo>"
}
```

---

## 5. Package the `.radioplugin`

Add `scripts/make-radioplugin.sh` (generates the project, builds the `.appex`, zips the
package with `plugin.json` at the **archive root**).
Reference: [`make-radioplugin.sh`](https://github.com/VU3ESV/LP-700-App/blob/main/scripts/make-radioplugin.sh)

```sh
./scripts/make-radioplugin.sh        # -> dist/<pkg> + prints its sha256
```

Key details the script handles (and why):
- **`GIT_CONFIG_COUNT=1 … safe.bareRepository=all`** — lets `xcodebuild`'s SwiftPM resolve
  past a common global `safe.bareRepository=explicit` git setting, without editing config.
  (Harmless on CI runners, which don't set it.)
- **`ditto -c -k --norsrc --noextattr`** with `plugin.json` at the root — a clean zip with
  **no `__MACOSX/` AppleDouble dir** (a second top-level dir would break the suite's
  payload-root detection in `PackageInstaller`).
- **Pure-ASCII script** — a multibyte char right after a `$VAR` is absorbed into the name
  under a C locale (`PKG…: unbound variable`). Keep echoes ASCII.
- **Never `rm -rf dist/`** — only `mkdir -p dist` + remove its own `*.radioplugin`. In a
  release pipeline `dist/` also holds the `.app`/`.dmg` built just before; wiping it deletes
  them and fails the release.

---

## 6. Register in the suite catalog

The catalog ([`docs/catalog/catalog.json`](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/docs/catalog/catalog.json))
points each plugin at the **`.radioplugin` published by that app's GitHub Release** (§7) —
the suite repo does **not** store built plugin binaries (the plugin build belongs to the
app). Add an entry that references the release asset:

1. After the app cuts a release (§7), grab the `.radioplugin` asset's download URL and digest:
   ```sh
   gh -R VU3ESV/<Repo> release download <tag> -p '*.radioplugin' -O /tmp/p.radioplugin
   shasum -a 256 /tmp/p.radioplugin
   ```
2. Append to `catalog.json`, pinning the specific release tag + that digest:

```json
{
  "id": "<BundleID>",
  "name": "<PluginName>",
  "latestVersion": "1.0.0",
  "minHostVersion": "1.0",
  "url": "https://github.com/VU3ESV/<Repo>/releases/download/<tag>/<asset-name>.radioplugin",
  "sha256": "<digest of the release asset>",
  "systemImage": "<SystemImage>",
  "author": "VU3ESV"
}
```

The suite verifies this `sha256` on install, so it must match the asset exactly. **`ditto`
zips aren't reproducible**, so pin the **specific release** (not `latest/download`) + its
digest, and bump `url`+`sha256` when the app releases a new plugin (the §7c auto-PR
automates that). *(The bundled `demosdr` sample is the one exception — it has no app repo,
so its package stays committed under `docs/catalog/`.)*

---

## 7. The build & release pipeline (do this once per app)

Goal: the app's **own** CI/release builds and ships **both** the in-process plugin (already
covered by `swift build`/`swift test`) **and** the out-of-process `.radioplugin`. Reference
workflows: each app's [`ci.yml`](https://github.com/VU3ESV/LP-700-App/blob/main/.github/workflows/ci.yml)
/ [`release.yml`](https://github.com/VU3ESV/LP-700-App/blob/main/.github/workflows/release.yml).

### 7a. CI — verify the `.appex` on every PR (macOS 14)

The in-process adapter is already built/tested by the existing `swift build` + `swift test`
steps. Add **one step** to also build the out-of-process package so a broken `.appex` is
caught immediately:

```yaml
      - name: Build plugin package (.appex / .radioplugin)
        run: |
          # The runner's DEFAULT Xcode may be too old to read XcodeGen's project format
          # (objectVersion 77) — select the newest installed Xcode first, or the build
          # fails with "future Xcode project file format".
          sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
          brew list xcodegen >/dev/null 2>&1 || brew install xcodegen   # not preinstalled
          ./scripts/make-radioplugin.sh
```

### 7b. Release — attach the `.radioplugin` to the GitHub Release

Your apps release on a `v*` tag and already attach the `.dmg`. Build the package and add it
to the uploaded files. With `softprops/action-gh-release` (what the apps use), add a build
step and one line to `files:`:

```yaml
      # Run AFTER the .app/.dmg build. make-radioplugin.sh must NOT wipe dist/ (see §5),
      # or it deletes the .dmg built moments earlier and the release fails.
      - name: Build plugin package
        run: |
          sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
          brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
          ./scripts/make-radioplugin.sh        # -> dist/<pkg>
          cp dist/<pkg> "dist/<Repo>-${VERSION}.radioplugin"   # versioned name to attach

      - name: Create GitHub release
        uses: softprops/action-gh-release@v2
        with:
          # ...existing config (still builds + attaches the .dmg, unchanged)...
          files: |
            dist/<Repo>-*.dmg
            dist/<Repo>-*.dmg.sha256
            dist/<Repo>-*.radioplugin           # <-- the plugin, ADDITIONAL to the .dmg
```

Now every release publishes the standalone `.dmg` **and** the `.radioplugin` — one repo,
one pipeline, both forms. The `.radioplugin` is strictly **additional**; the app's existing
`.dmg` build and release are untouched.

### 7c. Keep the catalog in sync

**The adopted model (A): release-asset.** The plugin build belongs to the app, so the suite
**does not store built `.radioplugin` binaries** — each catalog `url` points at the app's
**release asset** (§6), pinned to a specific release tag + that asset's `sha256`. On a new
plugin release, bump the entry's `url`+`sha256` in the suite catalog.

That bump is the only manual step; automate it by having the app's release job **open a PR
to the suite** updating the entry (needs a cross-repo **PAT secret**) — e.g.:

Sketch of **B** as a release step (after building `dist/<pkg>`):

```yaml
      - name: Publish to suite catalog
        if: startsWith(github.ref, 'refs/tags/v')
        env:
          GH_TOKEN: ${{ secrets.SUITE_CATALOG_PAT }}   # repo-scoped PAT for AmateurRadioSuite
        run: |
          SHA=$(shasum -a 256 dist/<pkg> | awk '{print $1}')
          gh repo clone VU3ESV/AmateurRadioSuite suite -- --depth 1
          cp dist/<pkg> suite/docs/catalog/<catalogPkg>
          # update url+sha+version for "<BundleID>" in suite/docs/catalog/catalog.json (jq),
          # then: git -C suite checkout -b update-<pluginID>-$SHA && commit && push && gh pr create
```

Until a PAT exists, do §6 by hand after each release (copy `dist/<pkg>` → suite, update the
entry). **Recommended rollout:** add 7a + 7b now (no secrets), add 7c-B once the PAT is set.

### 7d. The signing gate (unchanged)

CI/release produces an **ad-hoc-signed** `.radioplugin` — valid for building, discovery, and
the catalog listing. A *runnable* third-party extension needs **Developer-ID signing +
notarization**, which in a pipeline means adding signing **secrets** (cert + notary creds)
and a signing step. That's an Apple-account/credentials step, not workflow plumbing. See §8.

---

## 8. What works vs. the signing gate (be honest)

After these steps the suite can, for your plugin: **browse** it (catalog), **install** it
(checksum-verified), **discover** it, and — in the Xcode host build — **host** it via
`EXHostViewController`. The full code path is in place and compiles.

**Running a third-party plugin needs *three* gates open, not just signing** (full treatment:
[EXTENSIONKIT.md "the three gates"](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/docs/EXTENSIONKIT.md#what-it-takes-to-actually-run-a-plugin--the-three-gates)):

1. **Host build** — the Suite must be the **Xcode host** build (the released SwiftPM/DMG build
   installs no `OutOfProcessHosting.provider`, so `canHost` is always false there).
2. **Registration** — the `.appex` must be **registered with macOS**. Discovery is via
   `AppExtensionIdentity.matching`, which reads the *system* extension registry — macOS only
   registers an extension that is **embedded in an installed, launched app** (`Contents/
   Extensions/`). A `.appex` merely unzipped into Application Support by the install flow is
   **never** discovered.
3. **Signing** — Developer-ID signed + notarized + approved (ad-hoc, what the script/CI use,
   is fine for building and the discovery/catalog flow, not for loading an untrusted one).

So the `.radioplugin` browse/install flow is a **catalog/manifest-display** mechanism, not the
load mechanism. The cleanest path to "it just works" is to **embed the `.appex` in the app's
own installed bundle** (`Contents/Extensions/`) so a single standalone-app install also
registers the extension for the Xcode-host Suite to host. Until all three gates are open, an
installed out-of-process plugin lists as **discovered** and shows the "runs out-of-process"
placeholder:

![A discovered out-of-process plugin showing the "runs out-of-process" placeholder pane](images/out-of-process.png)

---

## Checklist (per app)

**Plugin code**
- [ ] `Package.swift` depends on `RadioPluginKit`; library target links it.
- [ ] One `public` `<Adapter>: RadioPlugin` (manifest, `makeRootView`, idempotent `activate`); everything else `internal`.
- [ ] Public `<Factory>.rootView()` for the out-of-process module.
- [ ] `swift build && swift test` green.

**Out-of-process packaging**
- [ ] `Xcode/Extension/<ExtTarget>.swift`, `Info.plist` (extension point), `project.yml`.
- [ ] `plugin.json` with `id` **==** the `.appex` `PRODUCT_BUNDLE_IDENTIFIER`.
- [ ] `scripts/make-radioplugin.sh` builds the `.appex` and produces `dist/<pkg>`.
- [ ] `.xcodeproj` stays gitignored; commit `project.yml` + `Extension/` + the script + the factory.

**Pipeline**
- [ ] CI builds the `.radioplugin` (`brew install xcodegen` + the script).
- [ ] Release attaches `dist/<pkg>` to the GitHub Release.
- [ ] Catalog kept in sync (auto-PR with a PAT, or §6 by hand).

**Suite catalog**
- [ ] Committed `docs/catalog/<catalogPkg>` + a `catalog.json` entry whose `sha256` matches.

*Worked references: [LP-700-App](https://github.com/VU3ESV/LP-700-App) ·
[LP-100A-App](https://github.com/VU3ESV/LP-100A-App) ·
[AmateurRadioSuite catalog](https://github.com/VU3ESV/AmateurRadioSuite/tree/main/docs/catalog).*
