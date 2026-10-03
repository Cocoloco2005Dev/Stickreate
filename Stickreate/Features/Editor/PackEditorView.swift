import SwiftUI

/// Editor for one pack. A numbered slot grid with per-tile menus, drag to
/// reorder, and edit/emoji/cover/duplicate/delete actions. The grid is content
/// layer; the single prominent action is the empty state's "Add Sticker".
struct PackEditorView: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var settings = SettingsStore.shared
    @State private var showingAdd = false
    @State private var showingExport = false
    @State private var deleteTarget: DeleteTarget?
    @State private var activeAlert: ActiveAlert?
    @State private var draftName = ""

    @State private var editTask: EditTask?
    @State private var emojiTarget: StickerItem?

    @State private var showingFolder = false
    @State private var shareItem: ShareItem?

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// One alert channel so rename and error can never fight over presentation.
    private enum ActiveAlert {
        case rename
        case error(String)
    }

    private enum DeleteTarget {
        case pack
        case sticker(StickerItem)
    }

    private enum EditTask: Identifiable {
        case staticSticker(StickerItem)
        case animatedSticker(StickerItem)

        var id: UUID {
            switch self {
            case .staticSticker(let item), .animatedSticker(let item): item.id
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var pack: StickerPack? { store.pack(with: packID) }

    private var canExport: Bool {
        guard let pack else { return false }
        return pack.stickers.count >= Limits.minStickers
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
            .sheet(item: $editTask) { task in
                editSheet(for: task)
            }
            .sheet(item: $emojiTarget) { item in
                EmojiPickerSheet(initialEmojis: item.emojis) { emojis in
                    store.setEmojis(emojis, for: item.id, in: packID)
                }
            }
            .sheet(isPresented: $showingFolder) {
                FolderPickerSheet(
                    currentFolder: pack?.folder,
                    folders: store.folders
                ) { folder in
                    store.setFolder(folder, for: packID)
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url) {
                    shareItem = nil
                }
            }
            .alert(alertTitle, isPresented: alertIsPresented) {
                alertActions
            } message: {
                alertMessage
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: deleteIsPresented,
                titleVisibility: .visible
            ) {
                deleteActions
            } message: {
                Text(deleteMessage)
            }
    }

    // MARK: - Content

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
            .buttonStyle(.glassProminent)
        }
    }

    private func grid(for pack: StickerPack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(for: pack)

                exportAction(for: pack)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(pack.stickers) { item in
                        let index = pack.stickers.firstIndex(of: item) ?? 0

                        StickerCell(
                            item: item,
                            index: index,
                            isCover: index == 0,
                            onAdd: nil
                        ) {
                            tileMenu(for: item, isCover: index == 0)
                        }
                        .draggable(item.id.uuidString)
                        .dropDestination(for: String.self) { payloads, _ in
                            reorder(payloads: payloads, onto: item)
                        }
                    }

                    if pack.stickers.count < Limits.maxStickers {
                        StickerCell(
                            item: nil,
                            index: pack.stickers.count,
                            isCover: false,
                            onAdd: { showingAdd = true }
                        ) {
                            EmptyView()
                        }
                    }
                }

                footer(for: pack)
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

    /// Kind from the actual stickers: a sticker's preview is always a still, so
    /// the cover alone can't tell you whether the pack is animated.
    private func kindLabel(for pack: StickerPack) -> String {
        guard !pack.stickers.isEmpty else { return "Empty" }
        return pack.animatedStickers.count > pack.staticStickers.count ? "Animated" : "Static"
    }

    private func kindSymbol(for pack: StickerPack) -> String {
        guard !pack.stickers.isEmpty else { return "photo" }
        return pack.animatedStickers.count > pack.staticStickers.count ? "play.rectangle" : "photo"
    }

    /// Subtle footer so the screen doesn't end in a void below a short grid.
    private func footer(for pack: StickerPack) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The first sticker is the pack's cover", systemImage: "star")

            if let folder = pack.folder {
                Label("Folder: \(folder)", systemImage: "folder")
            }

            if canExport {
                Label("Ready to add to WhatsApp", systemImage: "checkmark.seal")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Primary export action

    @ViewBuilder
    private func exportAction(for pack: StickerPack) -> some View {
        if canExport {
            Button {
                showingExport = true
            } label: {
                Label(exportTitle, systemImage: exportSymbol)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(settings.exportMode == .file ? Color.accentColor : .green)
            .accessibilityHint("Opens the export options")
        } else {
            Label(exportHint(for: pack), systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(exportHint(for: pack))
        }
    }

    private var exportTitle: String {
        settings.exportMode == .file ? "Export Pack" : "Add to WhatsApp"
    }

    private var exportSymbol: String {
        settings.exportMode == .file ? "square.and.arrow.up" : "plus.message"
    }

    private func exportHint(for pack: StickerPack) -> String {
        let needed = max(0, Limits.minStickers - pack.stickers.count)
        return needed == 1
            ? "Add 1 more sticker to export to WhatsApp."
            : "Add \(needed) more stickers to export to WhatsApp."
    }

    // MARK: - Tile menu

    @ViewBuilder
    private func tileMenu(for item: StickerItem, isCover: Bool) -> some View {
        Button("Edit", systemImage: "pencil") {
            edit(item)
        }
        .disabled(item.source == nil)
        .accessibilityHint(item.source == nil ? "This sticker has no editable source" : "Opens the editor")

        Button("Emojis…", systemImage: "face.smiling") {
            emojiTarget = item
        }

        Button("Set as Cover", systemImage: "star") {
            store.setCover(item.id, in: packID)
        }
        .disabled(isCover)

        Button("Duplicate", systemImage: "plus.square.on.square") {
            store.duplicateSticker(item.id, in: packID)
        }
        .disabled((pack?.stickers.count ?? 0) >= Limits.maxStickers)

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive) {
            deleteTarget = .sticker(item)
        }
    }

    private func reorder(payloads: [String], onto target: StickerItem) -> Bool {
        guard let pack,
              let first = payloads.first,
              let draggedID = UUID(uuidString: first),
              let from = pack.stickers.firstIndex(where: { $0.id == draggedID }),
              let to = pack.stickers.firstIndex(where: { $0.id == target.id }),
              from != to else { return false }

        let destination = from < to ? to + 1 : to
        store.moveStickers(in: packID, fromOffsets: IndexSet(integer: from), toOffset: destination)
        return true
    }

    // MARK: - Editing existing stickers

    private func edit(_ item: StickerItem) {
        guard item.source != nil else { return }
        editTask = item.kind == .animated ? .animatedSticker(item) : .staticSticker(item)
    }

    @ViewBuilder
    private func editSheet(for task: EditTask) -> some View {
        switch task {
        case .staticSticker(let sticker):
            if let source = sticker.source {
                StickerEditorView(source: source) { updated in
                    store.updateSticker(updated, in: packID)
                }
            }

        case .animatedSticker(let sticker):
            if let source = sticker.source {
                VideoTrimView(source: source) { updated in
                    store.updateSticker(updated, in: packID)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The only add affordance is the dashed tile in the grid, so the bar
        // just carries the options menu (kept separate from anything else).
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename…", systemImage: "pencil") {
                    draftName = pack?.name ?? ""
                    activeAlert = .rename
                }
                Button("Folder…", systemImage: "folder") {
                    showingFolder = true
                }
                Button("Share Pack…", systemImage: "square.and.arrow.up") {
                    sharePack()
                }
                Button("Export…", systemImage: "plus.message") {
                    showingExport = true
                }
                .disabled(!canExport)

                Divider()

                Button("Delete Pack…", systemImage: "trash", role: .destructive) {
                    deleteTarget = .pack
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Pack options")
        }
    }

    // MARK: - Alerts & dialogs

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch activeAlert {
        case .rename: "Rename Pack"
        case .error: "Something went wrong"
        case nil: ""
        }
    }

    @ViewBuilder
    private var alertActions: some View {
        switch activeAlert {
        case .rename:
            TextField("Pack name", text: $draftName)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) {}
        case .error:
            Button("OK", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var alertMessage: some View {
        switch activeAlert {
        case .rename: Text("Give this pack a name.")
        case .error(let message): Text(message)
        case nil: EmptyView()
        }
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var deleteTitle: String {
        switch deleteTarget {
        case .pack: "Delete this pack?"
        case .sticker: "Delete this sticker?"
        case nil: ""
        }
    }

    private var deleteMessage: String {
        switch deleteTarget {
        case .pack: "This removes the pack and all its stickers. You can't undo this."
        case .sticker: "This removes the sticker from the pack. You can't undo this."
        case nil: ""
        }
    }

    @ViewBuilder
    private var deleteActions: some View {
        switch deleteTarget {
        case .pack:
            Button("Delete Pack", role: .destructive) { deletePack() }
        case .sticker(let item):
            Button("Delete Sticker", role: .destructive) {
                store.removeSticker(item.id, from: packID)
            }
        case nil:
            EmptyView()
        }

        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Actions

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.rename(packID, to: trimmed)
    }

    private func deletePack() {
        store.removePack(packID)
        dismiss()
    }

    private func sharePack() {
        guard let pack else { return }
        do {
            let url = try PackArchive.writeTemporaryFile(pack)
            shareItem = ShareItem(url: url)
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return NavigationStack {
        PackEditorView(store: store, packID: pack.id)
    }
}
