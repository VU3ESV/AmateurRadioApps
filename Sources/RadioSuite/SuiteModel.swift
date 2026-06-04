import SwiftUI
import RadioPluginKit

/// Owns the plugin manager, lazily instantiates active plugins, caches their root
/// views, and tracks the active selection. Views/instances are built once and kept
/// so switching tabs never recreates a plugin or drops its connection.
@MainActor
final class SuiteModel: ObservableObject {
    let host = SuitePluginHost()
    let manager: PluginManager
    let supervisor = PluginSupervisor()
    let catalog: CatalogService

    @Published var selection: String = ""
    /// Drives the command-palette sheet (toggled from the menu / ⌘⇧P).
    @Published var paletteOpen = false

    private let selectionKey = "suite.lastSelection"

    /// Plain, view-friendly description of an active plugin for List/TabView.
    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
        let systemImage: String
    }

    private var instances: [String: any RadioPlugin] = [:]
    private var cache: [String: AnyView] = [:]
    private var activated: Set<String> = []

    init() {
        let supervisor = self.supervisor
        // No built-in source: the host links no plugin apps. Plugins are discovered
        // on disk (installed/sideloaded) and run out-of-process via ExtensionKit.
        manager = PluginManager(sources: [
            InstalledPluginSource(directory: InstalledPluginSource.defaultDirectory()),
        ])
        manager.isQuarantined = { supervisor.isQuarantined($0) }   // quarantined → drop from active
        // Start with an empty catalog — no baked-in sources. The user populates it by
        // browsing `.radioplugin` files (addCatalogPlugin(fromFile:)) or adding a source URL.
        catalog = CatalogService()
        manager.reload()
        selection = Self.restoredSelection(saved: UserDefaults.standard.string(forKey: selectionKey),
                                           active: manager.visibleEntries.map(\.id))
    }

    /// Restore the last-active plugin if it's still available, else the first, else none.
    static func restoredSelection(saved: String?, active: [String]) -> String {
        (saved.flatMap { active.contains($0) ? $0 : nil }) ?? active.first ?? ""
    }

    // MARK: - Install / uninstall (Phase 4)

    private var pluginsDir: URL { InstalledPluginSource.defaultDirectory() }

    /// Installed version of a plugin id, if present (for catalog update detection).
    func installedVersion(id: String) -> String? {
        manager.entries.first { $0.id == id }?.manifest.version
    }

    /// Download + install a catalog entry, then rescan.
    func install(_ entry: CatalogEntry) async throws {
        guard let url = URL(string: entry.url) else { return }
        let data = try Data(contentsOf: url)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString).radioplugin")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PackageInstaller.install(localPackage: tmp, expectedSHA256: entry.sha256, into: pluginsDir)
        manager.reload(); reconcile()
    }

    /// Sideload a local `.radioplugin` (no catalog checksum), then rescan.
    func installFromFile(_ fileURL: URL) throws {
        try PackageInstaller.install(localPackage: fileURL, expectedSHA256: nil, into: pluginsDir)
        manager.reload(); reconcile()
    }

    /// Stable copy of the packages the user browsed into the catalog (so an entry's `url`
    /// stays valid even if the original file moves).
    private var catalogPackagesDir: URL {
        pluginsDir.deletingLastPathComponent().appendingPathComponent("CatalogPackages", isDirectory: true)
    }

    /// Browse a `.radioplugin` from disk and add it to the (local) catalog: read its manifest,
    /// copy the package to a stable location, compute its checksum, and register a catalog
    /// entry. The plugin then appears in Browse, where it can be installed like any other.
    @discardableResult
    func addCatalogPlugin(fromFile fileURL: URL) throws -> CatalogEntry {
        let manifest = try PackageInstaller.readManifest(fromPackage: fileURL)
        let dir = catalogPackagesDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(manifest.id).radioplugin")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: fileURL, to: dest)
        let entry = CatalogEntry(
            id: manifest.id, name: manifest.name, latestVersion: manifest.version,
            minHostVersion: manifest.minHostVersion, url: dest.absoluteString,
            sha256: try PackageInstaller.sha256Hex(of: dest),
            systemImage: manifest.systemImage, author: manifest.author,
            summary: "Added from file")
        catalog.addLocalEntry(entry)
        return entry
    }

    /// Remove a browsed catalog entry (and its stored package copy).
    func removeCatalogPlugin(id: String) {
        catalog.removeLocalEntry(id: id)
        let pkg = catalogPackagesDir.appendingPathComponent("\(id).radioplugin")
        try? FileManager.default.removeItem(at: pkg)
    }

    func uninstall(id: String) throws {
        try PackageInstaller.uninstall(id: id, from: pluginsDir)
        manager.reload(); reconcile()
    }

    func isInstalledFromDisk(_ id: String) -> Bool {
        manager.entries.first { $0.id == id }?.sourceKind == .installed
    }

    /// Plugins shown as tab/sidebar entries: runnable ones plus installed out-of-process
    /// plugins (which render an explanatory placeholder rather than vanishing).
    var entries: [Entry] {
        manager.visibleEntries.map { Entry(id: $0.id, title: $0.manifest.name, systemImage: $0.manifest.systemImage) }
    }

    private func instance(for id: String) -> (any RadioPlugin)? {
        if let p = instances[id] { return p }
        guard let entry = manager.activeEntries.first(where: { $0.id == id }), let make = entry.make
        else { return nil }
        let p = make()
        instances[id] = p
        return p
    }

    func plugin(for id: String) -> (any RadioPlugin)? { instance(for: id) }

    /// Cached, lazily built root view for a plugin. In-process plugins render their own
    /// `makeRootView()`; out-of-process plugins render their `.appex` UI via the
    /// ExtensionKit host provider (or a placeholder when it can't be hosted yet).
    func view(for id: String) -> AnyView {
        if let v = cache[id] { return v }
        let v: AnyView
        if let entry = manager.visibleEntries.first(where: { $0.id == id }), entry.isOutOfProcess {
            v = OutOfProcessHosting.view(for: entry.manifest)
                ?? AnyView(OutOfProcessUnavailableView(name: entry.manifest.name))
        } else {
            v = instance(for: id)?.makeRootView() ?? AnyView(EmptyView())
        }
        cache[id] = v
        return v
    }

    func activateInitial() { activate(selection) }

    /// Switch active plugin: deactivate the previous, activate the next.
    func select(_ id: String) {
        guard id != selection else { return }
        instances[selection]?.deactivate()
        selection = id
        UserDefaults.standard.set(id, forKey: selectionKey)   // restore on next launch
        activate(id)
    }

    private func activate(_ id: String) {
        guard !id.isEmpty else { return }
        _ = view(for: id)                      // ensure the hosted/instance view exists
        host.clearAttention(for: id)           // selecting a tab clears its badge/banner
        instance(for: id)?.activate()          // in-process only; out-of-process is host-managed
        activated.insert(id)
    }

    /// Reconcile after enable/disable changes: tear down plugins that are no longer
    /// active and fix the selection. Call when the manager's active set changes.
    /// Called by the host's ExtensionKit layer when the set of installed extensions changes
    /// (a plugin app installed/removed at runtime). Drops cached views for out-of-process
    /// plugins so a newly-registered one flips from the placeholder to its hosted view —
    /// then rescans and reconciles. No-op cost in the plain build (the seam is never invoked).
    func extensionsDidChange() {
        for entry in manager.entries where entry.isOutOfProcess {
            cache[entry.id] = nil
        }
        manager.reload()
        reconcile()
    }

    func reconcile() {
        let visible = Set(manager.visibleEntries.map(\.id))
        for id in instances.keys where !visible.contains(id) {
            instances[id]?.deactivate()
            instances[id] = nil
            cache[id] = nil
            activated.remove(id)
        }
        if !visible.contains(selection) {
            selection = manager.visibleEntries.first?.id ?? ""
            if !selection.isEmpty { activate(selection) }
        }
        objectWillChange.send()
    }
}
