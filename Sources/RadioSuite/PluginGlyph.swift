import SwiftUI

/// A plugin's icon: the containing app's real icon when the host can resolve it
/// (`OutOfProcessHosting.appIcon`), otherwise the manifest's SF Symbol. Used in the sidebar,
/// the tab bar, and the Plugin Manager so enabled/installed plugins show their app branding.
struct PluginGlyph: View {
    let id: String
    let systemImage: String
    var size: CGFloat = 18
    @Environment(\.radioTheme) private var theme

    var body: some View {
        if let icon = OutOfProcessHosting.appIcon?(id) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: systemImage)
                .foregroundStyle(theme.accent)
                .frame(width: size, alignment: .center)
        }
    }
}
