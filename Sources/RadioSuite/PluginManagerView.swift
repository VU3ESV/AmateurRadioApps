import SwiftUI
import AppKit
import RadioPluginKit
import RadioPluginUI

/// "Manage Plugins" sheet: an **Installed** tab (built-in + on-disk plugins with enable/
/// uninstall) and a **Browse** tab (catalog entries with install/update). Installed plugins
/// appear without recompiling the container; browse/install lands packages on disk where
/// discovery finds them. (Running third-party plugins is the out-of-process tier, gated on
/// code-signing — see docs/EXTENSIONKIT.md.)
struct PluginManagerView: View {
    @ObservedObject var model: SuiteModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.radioTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                installedTab.tabItem { Label("Installed", systemImage: "checklist") }
                browseTab.tabItem { Label("Browse", systemImage: "square.and.arrow.down") }
            }
            .padding(.top, 4)
        }
        // Flexible size so the window can grow; ResizableSheet makes the host sheet
        // user-resizable (SwiftUI sheets are fixed-size by default) with a sane minimum.
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity,
               minHeight: 480, idealHeight: 600, maxHeight: .infinity)
        .background(ResizableSheet(minSize: CGSize(width: 640, height: 480)))
    }

    private var header: some View {
        HStack {
            Text("Plugins").font(.title2.weight(.semibold))
            Toggle("Safe Mode", isOn: Binding(get: { model.manager.safeMode },
                                              set: { model.manager.safeMode = $0 }))
                .toggleStyle(.switch)
                .help("When on, only built-in (first-party) plugins run.")
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Installed

    private var installedTab: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.manager.entries) { entry in
                    installedRow(entry)
                }
                if model.manager.entries.isEmpty {
                    Text("No plugins found.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            // Solid footer bar (not a transparent overlay) so list rows never bleed
            // through behind the action buttons.
            Divider()
            HStack {
                Button { model.manager.reload() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                Button("Install from File…") { sideload() }
                // Out-of-process (ExtensionKit) plugins are disabled by macOS until the user
                // enables them here. Only shown in the host build that can present the browser.
                if let openManager = OutOfProcessHosting.showExtensionManager {
                    Button { openManager() } label: { Label("Enable Extensions…", systemImage: "puzzlepiece.extension") }
                        .help("Turn on installed out-of-process plugin extensions so the suite can load them.")
                }
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(InstalledPluginSource.defaultDirectory()) }
            }
            .padding(8)
            .background(.bar)
        }
    }

    @ViewBuilder private func installedRow(_ entry: PluginEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PluginGlyph(id: entry.manifest.id, systemImage: entry.manifest.systemImage, size: 28)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.manifest.name).font(.headline)
                    Text("v\(entry.manifest.version)").font(.caption).foregroundStyle(.secondary)
                    sourceTag(entry.sourceKind)
                    statusTag(entry.status)
                }
                capabilityChips(entry.manifest.capabilities)
            }
            Spacer()
            if entry.sourceKind == .installed {
                Button(role: .destructive) { try? model.uninstall(id: entry.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).help("Uninstall")
            }
            Toggle("", isOn: Binding(get: { model.manager.isEnabled(entry.id) },
                                     set: { model.manager.setEnabled($0, for: entry.id) }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(isIncompatible(entry.status))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Browse

    @State private var installing: Set<String> = []
    @State private var newSource = ""

    private var browseTab: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.catalog.entries) { entry in
                        browseRow(entry)
                    }
                    if model.catalog.entries.isEmpty {
                        Text(model.catalog.lastError ?? "No plugins yet. Use “Add Plugin from File…” to browse a .radioplugin, or add a catalog source below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Catalog Sources") {
                    ForEach(model.catalog.sources, id: \.self) { url in
                        HStack {
                            Text(url.absoluteString).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.catalog.removeSource(url); refresh() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("https://…/catalog.json", text: $newSource)
                        Button("Add") {
                            if let u = URL(string: newSource), !newSource.isEmpty {
                                model.catalog.addSource(u); newSource = ""; refresh()
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button { addFromFile() } label: { Label("Add Plugin from File…", systemImage: "plus") }
                Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }
        .task { refresh() }
    }

    @ViewBuilder private func browseRow(_ entry: CatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PluginGlyph(id: entry.id, systemImage: entry.systemImage ?? "puzzlepiece.extension", size: 28)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name).font(.headline)
                    Text("v\(entry.latestVersion)").font(.caption).foregroundStyle(.secondary)
                }
                if let summary = entry.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.catalog.isLocal(entry.id) {
                Button { model.removeCatalogPlugin(id: entry.id); refresh() } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).help("Remove from catalog")
            }
            installButton(entry)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func installButton(_ entry: CatalogEntry) -> some View {
        if installing.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch entry.installState(installedVersion: model.installedVersion(id: entry.id)) {
            case .notInstalled:           Button("Install") { doInstall(entry) }.buttonStyle(.borderedProminent)
            case .updateAvailable:        Button("Update") { doInstall(entry) }.buttonStyle(.bordered)
            case .upToDate:               Text("Installed").font(.caption).foregroundStyle(.secondary)
            case .incompatible(let why):  Text(why).font(.caption).foregroundStyle(theme.danger)
            }
        }
    }

    // MARK: - Actions

    private func refresh() { Task { await model.catalog.refresh() } }

    private func doInstall(_ entry: CatalogEntry) {
        installing.insert(entry.id)
        Task {
            defer { installing.remove(entry.id) }
            do { try await model.install(entry) }
            catch { model.host.notify(.init(level: .error, title: "Install failed",
                                             body: error.localizedDescription), from: entry.id) }
        }
    }

    private func sideload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.installFromFile(url) }
            catch { model.host.notify(.init(level: .error, title: "Install failed",
                                             body: error.localizedDescription), from: "sideload") }
        }
    }

    /// Browse a `.radioplugin` and add it to the catalog (it then appears in Browse, where it
    /// can be installed). Lets the suite start empty and be populated by the user.
    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose a .radioplugin to add to the catalog"
        if panel.runModal() == .OK, let url = panel.url {
            do { _ = try model.addCatalogPlugin(fromFile: url); refresh() }
            catch { model.host.notify(.init(level: .error, title: "Couldn't add plugin",
                                             body: error.localizedDescription), from: "catalog") }
        }
    }

    // MARK: - Bits

    private func isIncompatible(_ status: PluginStatus) -> Bool {
        if case .incompatible = status { return true }; return false
    }

    private func sourceTag(_ kind: PluginSourceKind) -> some View {
        Text(kind == .builtIn ? "Built-in" : kind == .installed ? "Installed" : "Dev")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.surface, in: Capsule())
    }

    @ViewBuilder private func statusTag(_ status: PluginStatus) -> some View {
        switch status {
        case .ready:                  StatusBadge("Ready", kind: .success)
        case .discovered:             StatusBadge("Out-of-process (soon)", kind: .warning)
        case .incompatible(let r):    StatusBadge(r, kind: .danger)
        }
    }

    @ViewBuilder private func capabilityChips(_ caps: [PluginCapability]) -> some View {
        if !caps.isEmpty {
            HStack(spacing: 6) {
                ForEach(caps, id: \.self) { cap in
                    Text(cap.displayName).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

/// Makes the presenting sheet window user-resizable and enforces a minimum content size.
/// SwiftUI `.sheet` windows are fixed-size by default; inserting `.resizable` into the host
/// window's style mask restores the drag-to-resize affordance.
private struct ResizableSheet: NSViewRepresentable {
    let minSize: CGSize
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = minSize
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
