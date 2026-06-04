import SwiftUI
import RadioPluginKit
import RadioPluginUI

/// Seam between the host and the out-of-process (ExtensionKit) tier.
///
/// The plain SwiftPM build links no ExtensionKit and leaves `provider` nil, so
/// out-of-process plugins are discovered but never runnable — `swift build` stays a lean
/// in-process build. The **Xcode host target** installs a provider (see
/// `Host/ExtensionHosting.swift`) that hosts an installed `.appex` via `EXHostViewController`.
///
/// Correlation convention: an out-of-process plugin's `manifest.id` **equals its extension's
/// bundle identifier**, so the provider can match a manifest to a discovered extension.
@MainActor
protocol OutOfProcessHostProvider: AnyObject {
    /// Is an installed extension matching this manifest available to run right now?
    func canHost(_ manifest: RadioPluginManifest) -> Bool
    /// A SwiftUI view embedding the extension's remote UI, or nil if it can't be hosted.
    func makeView(_ manifest: RadioPluginManifest) -> AnyView?
}

@MainActor
enum OutOfProcessHosting {
    /// Set once by the Xcode host layer at launch. Nil under plain `swift build`.
    static weak var provider: (any OutOfProcessHostProvider)?

    /// Host-layer launch hook, awaited once by `SuiteScene`. The Xcode host sets it to
    /// discover installed extensions, register the ExtensionKit source, and refresh the
    /// manager. Nil (no-op) under plain `swift build`.
    static var bootstrap: ((SuiteModel) async -> Void)?

    /// Set by the Xcode host: opens ExtensionKit's enable/disable browser
    /// (`EXAppExtensionBrowserViewController`). Third-party extensions are **disabled by
    /// default** by macOS and only become hostable (returned by `AppExtensionIdentity.matching`)
    /// once the user enables them here. Nil under plain `swift build` (the Manage-Plugins UI
    /// hides the control when there's no host to present it).
    static var showExtensionManager: (() -> Void)?

    static func canHost(_ manifest: RadioPluginManifest) -> Bool {
        provider?.canHost(manifest) ?? false
    }

    static func view(for manifest: RadioPluginManifest) -> AnyView? {
        provider?.makeView(manifest)
    }
}

/// Shown in a tab when an out-of-process plugin is discovered but can't be hosted yet
/// (e.g. the plain SwiftPM build with no ExtensionKit, or the extension isn't approved).
struct OutOfProcessUnavailableView: View {
    let name: String
    var body: some View {
        EmptyStateView(
            systemImage: "puzzlepiece.extension",
            title: "\(name) runs out-of-process",
            message: "This plugin is hosted as a sandboxed ExtensionKit extension. Run the "
                   + "suite built with the Xcode host (and approve the extension) to load it."
        )
    }
}
