import SwiftUI

/// Editor for one pack. Reads the pack from the store on every render so it can
/// never go stale, and keeps exactly one prominent control: the bottom "Add Sticker".
struct PackEditorView: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var showingExport = false
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var draftName = ""
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var pack: StickerPack? { store.pack(with: packID) }

    private var canExport: Bool {
        guard let pack else { return false }
        return (try? pack.validate()) != nil
    }

    var body: some View {
        content
            .navigationTitle(pack?.name ?? "Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingAdd) {
                AddStickerSheet(store: store, packID: packID)
            }
            .sheet(isPresented: $showingExport) {
                if let pack {
                    ExportSheet(pack: pack)
                }
            }
            .alert("Rename Pack", isPresented: $showingRename) {
                TextField("Pack name", text: $draftName)
                Button("Save") { saveName() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Give this pack a name.")
            }
            .confirmationDialog(
                "Delete this pack?",
                isPresented: $showingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Pack", role: .destructive) { deletePack() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the pack and all its stickers. You can't undo this.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let pack {
            if pack.stickers.isEmpty {
                emptyState
            } else {
                grid(for: pack)
            }
        } else {
            Color.clear
                .onAppear { dismiss() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Stickers Yet", systemImage: "photo.badge.plus")
        } description: {
            Text("Add at least \(Limits.minStickers) stickers to make this pack WhatsApp-ready.")
        } actions: {
            Button("Add Sticker", systemImage: "plus") {
                showingAdd = true
            }
            .buttonStyle(.glass)
        }
    }

    private func grid(for pack: StickerPack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(for: pack)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(pack.stickers) { item in
                        StickerCell(item: item, store: store, packID: packID)
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(for pack: StickerPack) -> some View {
        HStack(spacing: 8) {
            Label(kindLabel(for: pack), systemImage: kindSymbol(for: pack))
            Spacer()
            Text("\(pack.stickers.count) of \(Limits.maxStickers)")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func kindLabel(for pack: StickerPack) -> String {
        pack.kind?.label ?? "Empty"
    }

    private func kindSymbol(for pack: StickerPack) -> String {
        pack.kind == .animated ? "play.rectangle" : "photo"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                showingAdd = true
            } label: {
                Label("Add Sticker", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .disabled(pack == nil || (pack?.stickers.count ?? 0) >= Limits.maxStickers)
            .accessibilityLabel("Add sticker")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename…", systemImage: "pencil") {
                    draftName = pack?.name ?? ""
                    showingRename = true
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    showingExport = true
                }
                .disabled(!canExport)

                Divider()

                Button("Delete Pack…", systemImage: "trash", role: .destructive) {
                    showingDelete = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Pack options")
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.rename(packID, to: trimmed)
    }

    private func deletePack() {
        store.removePack(packID)
        dismiss()
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return NavigationStack {
        PackEditorView(store: store, packID: pack.id)
    }
}
