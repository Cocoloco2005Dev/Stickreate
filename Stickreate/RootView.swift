import SwiftUI

/// Root shell. On iOS 26 the tab bar is a floating Liquid Glass element
/// automatically — we only opt into the minimize-on-scroll behavior.
///
/// Also receives files shared/opened into the app (images, videos, GIFs, and
/// `.stickreatepack` archives) via the document types declared in `project.yml`.
struct RootView: View {
    enum Section: Hashable {
        case packs
        case settings
    }

    @State private var selection: Section = .packs
    @State private var incoming: IncomingMedia?
    @State private var importError: String?
    @State private var store = PackStore.shared
    @State private var successPulse = 0
    @State private var errorPulse = 0

    /// Wrapper so `.sheet(item:)` can present a received media source.
    private struct IncomingMedia: Identifiable {
        let id = UUID()
        let source: StickerSource
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Packs", systemImage: "square.grid.2x2", value: Section.packs) {
                LibraryView()
            }

            Tab("Settings", systemImage: "gearshape", value: Section.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .alert(
            "Library problem",
            isPresented: Binding(
                get: { store.persistenceError != nil },
                set: { if !$0 { store.clearPersistenceError() } }
            )
        ) {
            Button("OK", role: .cancel) { store.clearPersistenceError() }
        } message: {
            Text(store.persistenceError ?? "")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .haptic(.success, trigger: successPulse)
        .haptic(.error, trigger: errorPulse)
        .onOpenURL { url in
            handleIncoming(url)
        }
        .sheet(item: $incoming) { media in
            ImportMediaSheet(source: media.source, store: PackStore.shared) {
                incoming = nil
            }
        }
        .alert(
            "Couldn't open that file",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func handleIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == PackArchive.fileExtension || ext == "stickreatepack" {
            importPackArchive(url)
            return
        }

        Task {
            do {
                let source = try await StickerSourceStore.importFile(at: url)
                await MainActor.run {
                    incoming = IncomingMedia(source: source)
                    successPulse += 1
                }
            } catch {
                await MainActor.run {
                    importError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    errorPulse += 1
                }
            }
        }
    }

    private func importPackArchive(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let pack = try PackArchive.importPack(from: data)
            PackStore.shared.importPack(pack)
            selection = .packs
            successPulse += 1
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorPulse += 1
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    RootView()
}

#Preview("Dark") {
    RootView()
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    RootView()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    RootView()
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    RootView()
        .frame(width: 430, height: 932)
}

