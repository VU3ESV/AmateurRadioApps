import SwiftUI
import ExtensionKit
import ExtensionFoundation
import RadioPluginKit

/// Embeds an out-of-process plugin extension's UI in the suite window via
/// `EXHostViewController`. The extension runs in its own sandboxed process, so a crash
/// stays out of the host (see `PluginSupervisor`).
struct ExtensionHostView: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    var sceneID: String = "primary"

    func makeNSViewController(context: Context) -> EXHostViewController {
        let vc = EXHostViewController()
        vc.configuration = .init(appExtension: identity, sceneID: sceneID)
        return vc
    }

    func updateNSViewController(_ vc: EXHostViewController, context: Context) {
        vc.configuration = .init(appExtension: identity, sceneID: sceneID)
    }
}

// Discovery of installed matching extensions is handled by `ExtensionHostProvider`, which
// observes `AppExtensionIdentity.matching` continuously (see ExtensionHosting.swift).
