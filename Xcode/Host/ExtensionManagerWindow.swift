import AppKit
import ExtensionKit

/// Hosts ExtensionKit's `EXAppExtensionBrowserViewController` in a panel so the user can
/// enable/disable the third-party plugin extensions installed for the suite's extension point.
///
/// macOS disables every newly-discovered third-party extension **by default**; only the ones
/// the user enables here are returned by `AppExtensionIdentity.matching` (and thus become
/// hostable). The host's own embedded `DemoSDR` is auto-trusted and so works without this —
/// external plugins (e.g. LP-100A) need to be switched on here once.
@MainActor
final class ExtensionManagerWindow {
    static let shared = ExtensionManagerWindow()
    private init() {}

    private lazy var controller: NSWindowController = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Available Plugins"
        let browser = EXAppExtensionBrowserViewController()
        browser.preferredContentSize = NSSize(width: 480, height: 340)
        panel.contentViewController = browser
        return NSWindowController(window: panel)
    }()

    func show() {
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}
