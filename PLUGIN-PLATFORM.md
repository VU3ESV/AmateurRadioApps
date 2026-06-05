# Radio Suite — Open Plugin Platform Plan

**Goal:** evolve `RadioPlugin` from a static, first-party, recompile-to-add contract into a
**standardized open platform**. Any developer implements the contract; their plugin becomes
**browsable and installable** into the container at runtime — with platform-grade styling,
error/notification handling, crash isolation, and usability.

This builds on the shipped foundation: [RadioPluginKit](https://github.com/VU3ESV/RadioPluginKit)
(the contract), the container ([Sources/RadioSuite/](Sources/RadioSuite/)), and three
first-party plugins. See [PLAN.md](PLAN.md) for that base.

---

## 1. The core decision: where does a third-party plugin run?

| Model | Add 3rd-party w/o recompile | Crash isolation | Sandbox/security | UI fidelity | Complexity |
|---|---|---|---|---|---|
| **Static SwiftPM** (today) | ❌ (recompile) | ❌ shared process | ❌ | ✅ full | low |
| **In-process dynamic bundle** | ✅ drop-in `.bundle` | ❌ a crash kills the host | ❌ needs `disable-library-validation` | ✅ full | medium |
| **Out-of-process (ExtensionKit `.appex`)** | ✅ installed extension | ✅ crash stays in the plugin | ✅ sandboxed appex | ✅ hosted via `EXHostViewController` | high |
| **Out-of-process (custom XPC child)** | ✅ | ✅ | ✅ | ⚠️ harder view bridging | high |

**A hard `fatalError`/`SIGSEGV` cannot be caught inside the same process.** Real crash control
therefore requires the plugin to run in its **own process**. The Apple-sanctioned way to host a
third party's UI out-of-process, crash-isolated and sandboxed, is **ExtensionKit** (macOS 13+):
the host defines an *extension point*, third parties ship `.appex` extensions, and
`EXHostViewController` embeds their SwiftUI/AppKit view in your window while the extension runs
in a separate, sandboxed process.

### Recommended: a two-tier model
- **Trusted tier (in-process):** first-party + vetted plugins load in-process for full speed and
  fidelity (static today; optionally dynamic bundles later).
- **Untrusted tier (out-of-process):** any third-party plugin runs as an **ExtensionKit `.appex`**
  (or a custom XPC child if ExtensionKit's constraints don't fit), giving crash isolation +
  sandbox. The `RadioPlugin` contract is the *same* abstraction in both tiers; only the transport
  differs.

The SDK is designed so the **same plugin source** can be built for either tier. The container
treats both uniformly behind a `LoadedPlugin` façade.

---

## 2. Standardizing the contract (the SDK)

`RadioPluginKit` becomes a **stable, versioned public SDK**. Additions:

### 2.1 Capability & metadata manifest
Every plugin ships a declarative `plugin.json` manifest (read *without* loading code — safe for
browsing/validation):
```json
{
  "id": "com.vendor.myrig",
  "name": "My Rig Controller",
  "version": "1.2.0",
  "sdkVersion": "1.0",                 // RadioPlugin contract version it targets
  "minHostVersion": "1.0",
  "isolation": "out-of-process",       // or "in-process" (trusted only)
  "capabilities": ["network.client", "serial", "notifications"],
  "icon": "icon.png",
  "author": "VU3ESV",
  "homepage": "https://…",
  "signature": "…"                     // notarization / Developer-ID identity
}
```

### 2.2 Contract additions (backward-compatible)
- `RadioPluginManifest` — typed mirror of `plugin.json`.
- `PluginCapability` — declared up front; the host maps to entitlements/permission prompts.
- `PluginContext` (extends today's `PluginHost`): namespaced defaults, **logging**, **error
  reporting**, **notification posting**, **theme tokens**, lifecycle/state callbacks.
- `PluginLifecycle` — explicit `willActivate/didActivate/willDeactivate/willTerminate` and a
  `restoreState(_:)/persistState()` pair for usability + crash recovery.

### 2.3 Versioning policy
- **Semantic versioning** of the SDK; the contract version (`sdkVersion`) is negotiated at load.
- The host refuses or warns on `sdkVersion`/`minHostVersion` mismatch (clear message, no crash).
- Deprecations carry one minor-version grace period; document in `SDK-CHANGELOG.md`.

---

## 3. Distribution, discovery & "browse + install"

### 3.1 Where plugins live
```
~/Library/Application Support/AmateurRadioSuite/Plugins/
    com.vendor.myrig/
        plugin.json
        MyRig.appex            (out-of-process)  OR  MyRig.bundle (in-process)
        Resources/
```
Plus a **built-in** set (first-party) shipped inside the app bundle.

### 3.2 Plugin catalog (the "store")
A signed **catalog index** (a JSON file in a Git repo or a small static server) lists available
plugins with metadata + download URL + checksum + min host version:
```json
{ "plugins": [ { "id": "com.vendor.myrig", "name": "...", "latest": "1.2.0",
                 "url": "https://.../MyRig-1.2.0.radioplugin", "sha256": "...",
                 "minHostVersion": "1.0" } ] }
```
- Start with **one official catalog**; allow users to add **custom catalog URLs** (community feeds).
- A `.radioplugin` package = a zip of the manifest + the `.appex`/`.bundle` + resources, signed
  and notarized.

### 3.3 In-app Plugin Browser (UX)
A dedicated host surface (sidebar item / window): **Browse**, **Installed**, **Updates**.
- Browse: cards from the catalog (icon, name, author, capabilities, version, "Install").
- Install flow: download → **verify signature/notarization + checksum** → unpack to Application
  Support → read manifest → **show requested capabilities & request permission** → register →
  appears as a tab. No app restart required.
- Installed: enable/disable, update, uninstall, "open plugin folder", view logs.
- **Sideload**: "Install from file…" for a local `.radioplugin` (dev/testing), gated behind a
  trust prompt.

### 3.4 Registry evolution
Today's static `PluginRegistry` becomes a **`PluginManager`** that merges three sources:
built-in (compiled-in), installed (Application Support), and dev (sideloaded), then loads each via
the tier-appropriate loader. The `HostShell` renders whatever the manager publishes — no code
change to add a plugin.

---

## 4. App styling / design system

To keep third-party plugins visually coherent, ship a **design system** the SDK injects:

- **`RadioPluginUI`** module (part of the SDK): theme tokens (color roles, typography scale,
  spacing, corner radii, the LP dark-LCD palette), plus reusable components — `MeterGauge`,
  `StatusBadge`, `ConnectButton`, `SettingsForm`, `Banner`, `EmptyState`.
- **Theme via Environment:** the host injects a `RadioTheme` (light/dark/high-contrast +
  accent) into every plugin's view tree; components read it so all tabs match and respond to the
  host's appearance setting.
- **Layout contract:** plugins fill a provided content area; the **host owns chrome** (sidebar/
  tabs, toolbar slots, title). Plugins contribute toolbar items / menu commands via the contract,
  never their own window chrome.
- **Guidelines + a "style lint":** a validation tool flags raw colors/fonts instead of theme
  tokens. Optional, advisory.

---

## 5. Error handling

- **Typed errors:** `PluginError` (recoverable / fatal / permission / connectivity), reported via
  `context.report(error:)`. The host decides presentation; the plugin never shows raw alerts.
- **Host error surface:** a consistent **inline banner** within the plugin's pane for plugin-scoped
  issues (e.g. "Disconnected — retrying"), and a **global notification** for host-level issues.
- **Recovery affordances:** errors carry optional `recoveryActions` (Retry, Open Settings,
  Reconnect) the host renders as buttons.
- **No silent failure:** every caught error is logged with plugin id + timestamp to a per-plugin
  log the user can view/export from the Plugin Browser.

---

## 6. Notifications

- **In-app notification center:** host-owned. Plugins post via `context.notify(.init(level:…))`;
  levels = info / success / warning / error. Rendered as transient toasts + a persistent list.
- **System notifications:** routed through the host (one `UNUserNotificationCenter` registration);
  plugins request via the contract so the host can rate-limit, de-dupe, and respect Focus.
- **Badges:** a plugin can set a sidebar/tab badge (count or dot) for attention (e.g. alarm),
  cleared on activation.
- **Quiet by default:** plugins must declare the `notifications` capability; user can mute per
  plugin.

---

## 7. Crash control & resilience

- **Process isolation (the foundation):** out-of-process plugins crash in their own process; the
  host stays up. The tab shows a **"Plugin stopped" state** with **Restart** + **Report**.
- **Watchdog & auto-restart:** the host pings each plugin process; on crash/hang it tears down the
  remote view, marks the tab degraded, and offers (or auto-does, with backoff) a restart.
- **Crash-loop quarantine:** N crashes within a window → the plugin is **auto-disabled** ("Safe
  mode for this plugin") so it can't wedge the suite on every launch.
- **Resource guards:** per-plugin limits where feasible (the sandbox + process model bounds memory/
  CPU blast radius); surface a plugin's resource use in the Browser.
- **Host safe mode:** launch flag / key-held start that loads **first-party only**, for recovering
  from a bad third-party install.
- **State preservation:** `persistState()` is called pre-deactivate and periodically, so a restart
  restores the plugin's last view/connection rather than starting cold.
- **In-process tier caveat:** trusted in-process plugins share the host fate — document clearly;
  reserve that tier for code you vet.

---

## 8. Security & trust

- **Signing & notarization:** installed plugins must be Developer-ID signed + notarized; the host
  verifies on install and (cheaply) on load. Unsigned = sideload-only behind an explicit trust
  prompt.
- **Sandbox + entitlements:** out-of-process plugins are sandboxed `.appex`; the host maps each
  declared `capability` to the minimal entitlement and **surfaces it to the user at install**
  ("This plugin wants: Local network, Serial port"). No capability → no access.
- **Trust model:** official catalog (curated) vs custom catalogs (user-added, warned) vs sideload
  (explicit). The host never auto-installs.
- **Privacy:** per-plugin defaults are namespaced and isolated; plugins can't read each other's
  storage or `UserDefaults.standard`.

---

## 9. Usability

- **Consistent navigation:** host owns sidebar/tabs toggle, ordering (drag to reorder, pin
  favorites), and per-plugin show/hide.
- **Onboarding:** first-run explains the suite; per-plugin "first activation" can show a short
  setup card (connection target, permissions).
- **Keyboard & accessibility:** host provides a command palette; plugins contribute commands
  through the contract (routed to the active plugin). VoiceOver/Dynamic Type honored via the design
  system; a11y is part of the style lint.
- **State & restoration:** window layout, active tab, and per-plugin state restore across launches.
- **Settings:** a unified **Settings hub** aggregates each plugin's `settingsView` plus a Plugins
  pane (catalogs, updates, safe mode).
- **Discoverability of failures:** degraded/disabled plugins are clearly marked in the sidebar with
  a one-tap path to logs and restart.

The first-run onboarding card (below) orients the user to the three host affordances — the
layout toggle, plugin management, and the command palette:

![First-run onboarding card explaining the layout toggle, plugin management, and command palette](docs/images/onboarding.png)

---

## 10. Developer experience

- **Plugin template repo:** `radio-plugin-template` — a ready SwiftPM/Xcode project building both
  tiers, with the manifest, a sample meter view using `RadioPluginUI`, and tests.
- **`radioplugin` CLI / validator:** lints the manifest, checks capabilities vs entitlements,
  validates signing, and produces a `.radioplugin` package.
- **Docs site:** contract reference, design system, capability list, submission guide for the
  official catalog.
- **Versioned, semver'd SDK** with a published changelog and migration notes.

---

## 11. Phased roadmap

1. ✅ **DONE — SDK hardening (no behavior change):** contract documented; `PluginContext`,
   manifest types, capability enum, error/notification types added; `RadioPluginUI` design system
   shipped (RadioPluginKit 1.1.0). First-party plugins adopted manifests.
2. ✅ **DONE (discovery) — PluginManager + dynamic discovery:** `PluginManager` merges built-in +
   installed (Application Support) sources; installed plugins are discovered from `plugin.json`
   without recompiling, shown in a "Manage Plugins" UI with capabilities/status/enable toggles
   (tested). *Running* installed plugins is the out-of-process step in phase 3 — discovered installed
   plugins show as "out-of-process (soon)" rather than loading in-process.
3. 🟡 **IN PROGRESS — Out-of-process tier (ExtensionKit):** extension point + typed Codable
   channel (RadioPluginKit 1.2); `PluginSupervisor` (restart/backoff/quarantine) + host **Safe
   Mode** (tested). An **Xcode workspace** (`Xcode/`, XcodeGen-authored, committed) now builds the
   host app + a sample out-of-process `DemoSDRExtension.appex` (ExtensionKit), embedded into the
   app bundle, with `EXHostViewController` hosting (`ExtensionHostView`) and identity discovery
   (`ExtensionDiscovery`) compiling. **Remaining:** Developer-ID signing + runtime extension
   approval, and wiring `ExtensionHostView` into the live tab via discovery. See docs/EXTENSIONKIT.md.
4. 🟢 **DONE (groundwork) — Browse + install:** `PluginCatalog`/`CatalogEntry` index format +
   `CatalogService` (multi-source, custom catalogs); `PackageInstaller` (`.radioplugin` =
   checksum-verified zip → validated manifest → installed where discovery finds it);
   Plugin Browser (Installed/Browse tabs, install/update/uninstall, sideload, sources). A sample
   catalog + `.radioplugin` ship under `docs/catalog/`. Tested. **Deferred:** code-signature /
   notarization verification (needed before *running* untrusted plugins — gated on a signing
   identity); installs are checksum-verified for now and land as `discovered` (out-of-process tier).
5. 🟢 **DONE (core) — Polish:** unified Settings hub (General + per-plugin `settingsView`), single
   suite About panel, command palette (⌘⇧P), tab/layout state restoration, onboarding, Safe Mode,
   design system in use. _Remaining nice-to-haves:_ a style lint and a plugin-validator CLI.

---

## 12. Key decisions
- **Isolation for the third-party tier:** ✅ **DECIDED — ExtensionKit `.appex`** (system-supported,
  sandboxed, crash-isolated; UI hosted via `EXHostViewController`). The SDK value types that cross
  the process boundary (manifest, capabilities, notifications) are therefore `Codable` + `Sendable`.
- **Catalog hosting:** a GitHub-hosted static JSON index (simplest) vs a small service (ratings,
  telemetry, search).
- **In-process tier:** keep it (fast, first-party) or go *all* out-of-process for uniformity at a
  fidelity/perf cost.
- **Distribution gate:** open sideloading vs catalog-only vs curated official catalog + community
  feeds.
