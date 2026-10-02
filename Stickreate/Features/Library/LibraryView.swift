import SwiftUI

/// Pack library. This is the content layer — cards are opaque; Liquid Glass
/// stays in the navigation bar and the single primary action.
struct LibraryView: View {
    @State private var packs: [StickerPack] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            if packs.isEmpty {
                ContentUnavailableView {
                    Label("No Sticker Packs", systemImage: "face.smiling")
                } description: {
                    Text("Create a pack to start making stickers for WhatsApp.")
                } actions: {
                    Button("New Pack", systemImage: "plus") {
                        createPack()
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.top, 64)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach($packs) { $pack in
                        NavigationLink(value: pack) {
                            PackCard(pack: pack)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Sticker Packs")
        .navigationDestination(for: StickerPack.self) { pack in
            Text(pack.name)
                .navigationTitle(pack.name)
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

    private func createPack() {
        withAnimation {
            packs.append(StickerPack(name: "Untitled Pack"))
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
}
