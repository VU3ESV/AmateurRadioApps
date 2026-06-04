import SwiftUI
import ExtensionFoundation
import RadioPluginKit

/// The Xcode host's implementation of the out-of-process tier. It fills the
/// `OutOfProcessHosting` seam from `Sources/RadioSuite`:
///
///  - as a `PluginSource`, it surfaces installed ExtensionKit `.appex`es (discovered via
///    `AppExtensionIdentity`) as `.discovered` plugin entries — no `plugin.json` required;
///  - as an `OutOfProcessHostProvider`, it renders a matching extension's UI through
///    `ExtensionHostView` (`EXHostViewController`).
///
/// Correlation convention: an entry's `manifest.id` is the extension's **bundle identifier**,
/// which is also the key this provider hosts by — so a discovered entry and an on-disk
/// `plugin.json` whose `id` matches the same bundle id refer to the same plugin.
@MainActor
final class ExtensionHostProvider: OutOfProcessHostProvider {
    static let shared = ExtensionHostProvider()

    /// Installed matching extensions, keyed by bundle identifier.
    private var identities: [String: AppExtensionIdentity] = [:]
    private var sourceInstalled = false
    private weak var model: SuiteModel?
    private var observation: Task<Void, Never>?

    private init() {}

    // MARK: OutOfProcessHostProvider

    func canHost(_ manifest: RadioPluginManifest) -> Bool {
        identities[manifest.id] != nil
    }

    func makeView(_ manifest: RadioPluginManifest) -> AnyView? {
        identities[manifest.id].map { AnyView(ExtensionHostView(identity: $0)) }
    }

    // MARK: Launch wiring (invoked from SuiteScene's .task via OutOfProcessHosting.bootstrap)

    func bootstrap(_ model: SuiteModel) async {
        self.model = model
        if !sourceInstalled {
            model.manager.addSource(ExtensionPluginSource(provider: self))
            sourceInstalled = true
        }
        startObserving()
    }

    /// Continuously observe the system's set of matching extensions. `AppExtensionIdentity.matching`
    /// emits a fresh snapshot whenever extensions are installed/removed (and its first emission can
    /// lag externally-installed `.appex`es), so we keep listening rather than taking one snapshot —
    /// a plugin installed AFTER launch then flips from placeholder to hosted without a relaunch.
    private func startObserving() {
        observation?.cancel()
        observation = Task { [weak self, weak model] in
            guard let self else { return }
            do {
                let stream = try AppExtensionIdentity.matching(
                    appExtensionPointIDs: RadioExtensionPoint.identifier)
                for await found in stream {
                    self.identities = Dictionary(found.map { ($0.bundleIdentifier, $0) },
                                                 uniquingKeysWith: { first, _ in first })
                    PluginIconResolver.shared.refresh()   // a plugin app may have just been installed
                    model?.extensionsDidChange()
                }
            } catch {
                // Discovery unavailable — in-process plugins still work.
            }
        }
    }

    /// Discovered extensions as plugin entries (read by `ExtensionPluginSource`).
    func entries() -> [PluginEntry] {
        identities.map { bundleID, identity in
            let manifest = RadioPluginManifest(
                id: bundleID,
                name: identity.localizedName,
                version: "—",
                isolation: .outOfProcess,
                systemImage: "puzzlepiece.extension")
            return PluginEntry(manifest: manifest, sourceKind: .installed,
                               status: .discovered, make: nil)
        }
    }
}

/// Surfaces installed ExtensionKit extensions (via `ExtensionHostProvider`) as plugin
/// entries, so they appear in the suite without an on-disk `plugin.json`.
@MainActor
struct ExtensionPluginSource: PluginSource {
    let kind: PluginSourceKind = .installed
    let provider: ExtensionHostProvider
    func discover() -> [PluginEntry] { provider.entries() }
}
