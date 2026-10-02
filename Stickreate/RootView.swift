import SwiftUI

/// Root shell. On iOS 26 the tab bar is a floating Liquid Glass element
/// automatically — we only opt into the minimize-on-scroll behavior.
struct RootView: View {
    enum Section: Hashable {
        case packs
        case settings
    }

    @State private var selection: Section = .packs

    var body: some View {
        TabView(selection: $selection) {
            Tab("Packs", systemImage: "square.grid.2x2", value: Section.packs) {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: Section.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootView()
}
