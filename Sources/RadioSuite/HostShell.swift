import SwiftUI
import RadioPluginKit
import RadioPluginUI

/// The container window: hosts plugins either as a vertical sidebar or as
/// horizontal tabs, switchable from the View menu (⌘⌥S).
struct HostShell: View {
    @ObservedObject var model: SuiteModel
    @ObservedObject var events: SuiteEvents
    @ObservedObject var manager: PluginManager
    @AppStorage("suite.layout") private var layout = Layout.sidebar
    @AppStorage("suite.didOnboard") private var didOnboard = false
    @State private var showingManager = false

    /// Design-system theme injected into every plugin's view tree.
    private let theme = RadioTheme.dark

    enum Layout: String { case sidebar, tabs }

    private var activeIDs: [String] { manager.visibleEntries.map(\.id) }

    var body: some View {
        content
            .onAppear { model.activateInitial() }
            .onChange(of: activeIDs) { _ in model.reconcile() }   // enable/disable → update tabs
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        layout = (layout == .sidebar) ? .tabs : .sidebar
                    } label: {
                        Image(systemName: layout == .sidebar ? "rectangle.topthird.inset.filled"
                                                              : "sidebar.left")
                    }
                    .help("Switch between sidebar and tabs")
                }
                ToolbarItem {
                    Button {
                        manager.reload()
                        showingManager = true
                    } label: { Image(systemName: "puzzlepiece.extension") }
                    .help("Manage plugins")
                }
            }
            .sheet(isPresented: $showingManager) {
                PluginManagerView(model: model).radioTheme(theme)
            }
            .sheet(isPresented: $model.paletteOpen) {
                CommandPaletteView(model: model).radioTheme(theme)
            }
            .sheet(isPresented: Binding(get: { !didOnboard }, set: { if $0 == false { didOnboard = true } })) {
                OnboardingView().radioTheme(theme)
            }
    }

    @ViewBuilder private var content: some View {
        switch layout {
        case .sidebar: sidebar
        case .tabs:    tabs
        }
    }

    private var sidebar: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(model.entries) { e in
                    HStack {
                        Label { Text(e.title) } icon: { PluginGlyph(id: e.id, systemImage: e.systemImage) }
                        Spacer()
                        badge(for: e.id)
                    }
                    .tag(e.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            // Keep every activated plugin's pane in the hierarchy (only the selected one
            // visible) so out-of-process hosts aren't torn down on tab switch — preserving
            // their live connection/state. Recreating the detail per selection would dismiss
            // the EXHostViewController and drop the plugin's connection.
            ZStack {
                ForEach(model.liveEntries) { e in
                    pane(for: e.id)
                        .opacity(e.id == model.selection ? 1 : 0)
                        .allowsHitTesting(e.id == model.selection)
                }
            }
            .frame(minWidth: 600, minHeight: 480)
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelection) {
            ForEach(model.entries) { e in
                pane(for: e.id)
                    .tabItem { Label { Text(e.title) } icon: { PluginGlyph(id: e.id, systemImage: e.systemImage) } }
                    .tag(e.id)
            }
        }
    }

    /// A plugin's pane: an optional host-rendered error/notification banner above
    /// the plugin view, with the design-system theme injected into the subtree.
    @ViewBuilder private func pane(for id: String) -> some View {
        VStack(spacing: 0) {
            if let note = events.banner[id] {
                Banner(level: note.level, title: note.title, message: note.body)
                    .padding([.horizontal, .top], 12)
            }
            model.view(for: id)
        }
        .radioTheme(theme)
    }

    @ViewBuilder private func badge(for id: String) -> some View {
        switch events.badges[id] {
        case .dot:            Circle().fill(theme.danger).frame(width: 8, height: 8)
        case .count(let n):   Text("\(n)").font(.caption2).padding(.horizontal, 6)
                                  .background(theme.danger, in: Capsule()).foregroundStyle(.white)
        case .text(let t):    Text(t).font(.caption2).padding(.horizontal, 6)
                                  .background(theme.accent, in: Capsule()).foregroundStyle(.white)
        case .none:           EmptyView()
        }
    }

    // Bindings that route selection changes through the model so activate/
    // deactivate fire. Sidebar selection is optional (List requirement).
    private var sidebarSelection: Binding<String?> {
        Binding(get: { model.selection },
                set: { if let id = $0 { model.select(id) } })
    }

    private var tabSelection: Binding<String> {
        Binding(get: { model.selection },
                set: { model.select($0) })
    }
}
