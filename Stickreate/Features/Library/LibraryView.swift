import SwiftUI

/// Pack library. This is the content layer — cards stay opaque and Liquid Glass
/// lives in the navigation bar plus the single primary action of the empty state.
struct LibraryView: View {
    @State private var store = PackStore()
    @State private var path: [UUID] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.packs.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Sticker Packs")
            .navigationDestination(for: UUID.self) { id in
                PackEditorView(store: store, packID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Pack", systemImage: "plus") {
                        createPack()
                    }
                    .accessibilityLabel("New sticker pack")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sticker Packs", systemImage: "square.grid.2x2")
        } description: {
            Text("Create a pack to start making stickers for WhatsApp.")
        } actions: {
            Button("New Pack", systemImage: "plus") {
                createPack()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.packs) { pack in
                    NavigationLink(value: pack.id) {
                        PackCard(pack: pack)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func createPack() {
        let pack = store.createPack()
        path.append(pack.id)
    }
}

#Preview {
    LibraryView()
}
