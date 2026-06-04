import SwiftUI

/// Entry point for the **Xcode host app target** (the out-of-process / ExtensionKit build).
/// It is identical to the SwiftPM `RadioSuiteApp` except it installs the ExtensionKit
/// hosting layer before rendering, so discovered `.appex` plugins actually load. The Xcode
/// target excludes `RadioSuiteApp.swift` (see project.yml) so there is a single `@main`.
@main
struct HostApp: App {
    @StateObject private var model: SuiteModel

    init() {
        // Wire the out-of-process seam BEFORE the model is built/rendered.
        OutOfProcessHosting.provider = ExtensionHostProvider.shared
        OutOfProcessHosting.bootstrap = { await ExtensionHostProvider.shared.bootstrap($0) }
        OutOfProcessHosting.showExtensionManager = { ExtensionManagerWindow.shared.show() }
        OutOfProcessHosting.appIcon = { PluginIconResolver.shared.icon(for: $0) }
        _model = StateObject(wrappedValue: SuiteModel())
    }

    var body: some Scene {
        SuiteScene.make(model: model)
    }
}
