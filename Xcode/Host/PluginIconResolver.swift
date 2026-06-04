import AppKit

/// Resolves a plugin's icon for the suite UI. A plugin id is its ExtensionKit extension's
/// bundle identifier; `AppExtensionIdentity` doesn't expose a URL, so we find the installed
/// app that *contains* a matching `.appex` and use that app's icon. The host app is not
/// sandboxed, so it can read `/Applications` (and `~/Applications`). Results are cached; call
/// `refresh()` when the set of installed extensions changes.
@MainActor
final class PluginIconResolver {
    static let shared = PluginIconResolver()
    private init() {}

    private var iconCache: [String: NSImage] = [:]   // extension bundle id -> app icon
    private var appForExtension: [String: URL] = [:] // extension bundle id -> containing .app URL
    private var scanned = false

    /// The app icon for the app containing the extension with this bundle id, or nil if not found.
    func icon(for extensionID: String) -> NSImage? {
        if let cached = iconCache[extensionID] { return cached }
        if !scanned { scan() }
        guard let appURL = appForExtension[extensionID] else { return nil }
        let icon = highResIcon(forApp: appURL)
        iconCache[extensionID] = icon
        return icon
    }

    /// Load the app's full-resolution icon. Prefer the bundle's `.icns` (which carries reps up
    /// to 512/1024 px) over `NSWorkspace.icon(forFile:)`, which can return a small cached
    /// composite that SwiftUI then upsamples into a soft image.
    private func highResIcon(forApp app: URL) -> NSImage {
        if let bundle = Bundle(url: app),
           let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String {
            let base = (iconFile as NSString).deletingPathExtension
            if let icns = bundle.url(forResource: base, withExtension: "icns"),
               let img = NSImage(contentsOf: icns) {
                return img
            }
        }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    /// Drop caches so the next lookup rescans (e.g. after a plugin app is installed/removed).
    func refresh() {
        scanned = false
        appForExtension.removeAll()
        iconCache.removeAll()
    }

    private func scan() {
        scanned = true
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let apps = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { continue }
            for app in apps where app.pathExtension == "app" {
                let extensionsDir = app.appendingPathComponent("Contents/Extensions")
                guard let appexes = try? fm.contentsOfDirectory(at: extensionsDir,
                                                                includingPropertiesForKeys: nil) else { continue }
                for appex in appexes where appex.pathExtension == "appex" {
                    let info = appex.appendingPathComponent("Contents/Info.plist")
                    guard let data = try? Data(contentsOf: info),
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                          let dict = plist as? [String: Any],
                          let bundleID = dict["CFBundleIdentifier"] as? String
                    else { continue }
                    // First containing app wins (apps installed in /Applications take precedence).
                    if appForExtension[bundleID] == nil { appForExtension[bundleID] = app }
                }
            }
        }
    }
}
