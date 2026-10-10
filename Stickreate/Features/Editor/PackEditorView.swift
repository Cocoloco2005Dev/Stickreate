import SwiftUI

/// Editor for one pack. A numbered slot grid with per-tile menus, drag to
/// reorder, and edit/emoji/cover/duplicate/delete actions. The grid is content
/// layer; the single prominent action is the empty state's "Add Sticker" (or the
/// export action once the pack is exportable).
struct PackEditorView: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var showingExport = false
    @State private var activeAlert: ActiveAlert?
    @State private var draftName = ""

    @State private var editTask: EditTask?
    @State private var droppedSource: DroppedSource?
    @State private var emojiTarget: StickerItem?
    @State private var previewItem: StickerItem?
    @State private var pendingPreviewAction: PreviewAction?

    @State private var showingFolder = false
    @State private var shareItem: ShareItem?

    @State private var selectionPulse = 0
    @State private var impactPulse = 0
    @State private var errorPulse = 0

    /// Deferred so it can run after the large preview sheet closes.
    private enum PreviewAction {
        case edit(StickerItem)
        case emojis(StickerItem)
        case delete(StickerItem)
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// A just-dropped source waiting for its editor sheet.
    private struct DroppedSource: Identifiable {
        let id = UUID()
        let source: StickerSource
    }

    /// One alert channel so rename, delete, and errors can never fight over
    /// presentation and always anchor to the screen.
    private enum ActiveAlert {
        case rename
        case error(String)
        case deletePack
        case deleteSticker(StickerItem)
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

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: DS.Space.md)]

    private var pack: StickerPack? { store.pack(with: packID) }

    private var canExport: Bool {
        // A mixed pack has no kind WhatsApp can import in one go, so it can't
        // export until the user removes the extra kind.
        guard let pack, !pack.isMixed else { return false }
        return pack.stickers.count >= Limits.minStickers
    }

    var body: some View {
        content
            .stickerDrop { sources in
                handleDrop(sources)
            } onError: { message in
                presentDropError(message)
            }
            .navigationTitle(pack?.name ?? "Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingAdd) {
                AddStickerSheet(store: store, packID: packID)
            }
            .sheet(isPresented: $showingExport) {
                ExportSheet(store: store, packID: packID)
            }
            .sheet(item: $droppedSource) { dropped in
                droppedEditor(for: dropped.source)
            }
            .sheet(item: $editTask) { task in
                editSheet(for: task)
            }
            .sheet(item: $emojiTarget) { item in
                EmojiPickerSheet(initialEmojis: item.emojis) { emojis in
                    store.setEmojis(emojis, for: item.id, in: packID)
                }
            }
            .sheet(item: $previewItem, onDismiss: runPreviewAction) { item in
                StickerPreviewSheet(
                    item: item,
                    isCover: pack?.stickers.first?.id == item.id,
                    canDuplicate: (pack?.stickers.count ?? 0) < Limits.maxStickers,
                    onEdit: { pendingPreviewAction = .edit(item) },
                    onEmojis: { pendingPreviewAction = .emojis(item) },
                    onSetCover: { setCover(item) },
                    onDuplicate: { duplicate(item) },
                    onDelete: { pendingPreviewAction = .delete(item) }
                )
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
            .haptic(.selection, trigger: selectionPulse)
            .haptic(.impact, trigger: impactPulse)
            .haptic(.error, trigger: errorPulse)
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
            // The pack was removed (e.g. deleted from the library). Show a
            // recoverable state for the single frame before popping.
            EmptyState(
                symbol: "questionmark.folder",
                title: "Pack Not Found",
                message: "This pack was removed."
            ) {
                Button("Back") { dismiss() }
                    .buttonStyle(.glassProminent)
            }
            .onAppear { dismiss() }
        }
    }

    private var emptyState: some View {
        EmptyState(
            symbol: "photo.badge.plus",
            title: "No Stickers Yet",
            message: "Add at least \(Limits.minStickers) stickers to make this pack WhatsApp-ready."
        ) {
            Button("Add Sticker", systemImage: "plus") {
                showingAdd = true
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func grid(for pack: StickerPack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                header(for: pack)

                exportHintRow(for: pack)

                LazyVGrid(columns: columns, spacing: DS.Space.md) {
                    ForEach(pack.stickers) { item in
                        let index = pack.stickers.firstIndex(of: item) ?? 0

                        StickerCell(
                            item: item,
                            index: index,
                            isCover: index == 0,
                            onAdd: nil,
                            onTap: { previewItem = item }
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
            .padding(DS.Space.lg)
        }
    }

    private func header(for pack: StickerPack) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Label(kindLabel(for: pack), systemImage: kindSymbol(for: pack))
                Spacer()
                Text("\(pack.stickers.count) of \(Limits.maxStickers)")
            }
            .accessibilityElement(children: .combine)

            // Readiness toward WhatsApp's minimum, so the area above a short
            // grid carries real information instead of a void.
            if needsMoreStickers(pack) {
                ProgressView(
                    value: Double(min(pack.stickers.count, Limits.minStickers)),
                    total: Double(Limits.minStickers)
                )
                .progressViewStyle(.linear)
                .accessibilityLabel("Progress to WhatsApp-ready")
                .accessibilityValue(
                    "\(min(pack.stickers.count, Limits.minStickers)) of \(Limits.minStickers) stickers"
                )
            }
        }
        .font(DS.TextRole.supporting)
        .foregroundStyle(.secondary)
    }

    /// True when the pack is a single kind but still short of WhatsApp's minimum.
    private func needsMoreStickers(_ pack: StickerPack) -> Bool {
        !pack.isMixed && pack.stickers.count < Limits.minStickers
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Label("The first sticker is the pack's cover", systemImage: "star")

            if let folder = pack.folder {
                Label("Folder: \(folder)", systemImage: "folder")
            }

            if canExport {
                Label("Ready to add to WhatsApp", systemImage: "checkmark.seal")
            }
        }
        .font(DS.TextRole.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Space.xs)
    }

    // MARK: - Export guidance

    /// Informational line shown while the pack can't be exported yet. The single
    /// primary "Add to WhatsApp" action lives in the navigation bar.
    @ViewBuilder
    private func exportHintRow(for pack: StickerPack) -> some View {
        if !canExport {
            Label(exportHint(for: pack), systemImage: "info.circle")
                .font(DS.TextRole.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(exportHint(for: pack))
        }
    }

    private func exportHint(for pack: StickerPack) -> String {
        if pack.isMixed {
            return "This pack mixes photos and videos. Remove the extras to export."
        }
        let needed = max(0, Limits.minStickers - pack.stickers.count)
        return needed == 1
            ? "Add 1 more sticker to export to WhatsApp."
            : "Add \(needed) more stickers to export to WhatsApp."
    }

    /// Runs the deferred preview action once the large preview sheet is gone.
    private func runPreviewAction() {
        guard let action = pendingPreviewAction else { return }
        pendingPreviewAction = nil

        switch action {
        case .edit(let item):
            edit(item)
        case .emojis(let item):
            emojiTarget = item
        case .delete(let item):
            activeAlert = .deleteSticker(item)
        }
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
            setCover(item)
        }
        .disabled(isCover)

        Button("Duplicate", systemImage: "plus.square.on.square") {
            duplicate(item)
        }
        .disabled((pack?.stickers.count ?? 0) >= Limits.maxStickers)

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive) {
            activeAlert = .deleteSticker(item)
        }
    }

    private func setCover(_ item: StickerItem) {
        store.setCover(item.id, in: packID)
        selectionPulse += 1
    }

    private func duplicate(_ item: StickerItem) {
        store.duplicateSticker(item.id, in: packID)
        selectionPulse += 1
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
        impactPulse += 1
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
                if case .gif = source {
                    GIFTrimView(source: source) { updated in
                        store.updateSticker(updated, in: packID)
                    }
                } else {
                    VideoTrimView(source: source) { updated in
                        store.updateSticker(updated, in: packID)
                    }
                }
            }
        }
    }

    // MARK: - Dropping new stickers

    /// A drop adds to this pack. Capacity and the single-kind rule are checked up
    /// front so the user gets a clear message instead of a half-open editor.
    private func handleDrop(_ sources: [StickerSource]) {
        guard let pack, let source = sources.first else { return }

        // Only the first dropped item is handled; discard the rest cleanly.
        for extra in sources.dropFirst() { StickerSourceStore.delete(extra) }

        guard pack.stickers.count < Limits.maxStickers else {
            StickerSourceStore.delete(source)
            presentDropError("This pack is full — it holds at most \(Limits.maxStickers) stickers.")
            return
        }

        if let packKind = pack.kind, packKind != dropKind(for: source) {
            StickerSourceStore.delete(source)
            presentDropError(
                packKind == .animated
                    ? "This pack holds videos. Add a video or GIF, or start a new pack."
                    : "This pack holds photos. Add a photo, or start a new pack."
            )
            return
        }

        droppedSource = DroppedSource(source: source)
    }

    /// A source's kind: stills are static, GIFs and videos animated.
    private func dropKind(for source: StickerSource) -> StickerKind {
        switch source {
        case .image: .static
        case .video, .gif: .animated
        }
    }

    private func presentDropError(_ message: String) {
        activeAlert = .error(message)
        errorPulse += 1
    }

    @ViewBuilder
    private func droppedEditor(for source: StickerSource) -> some View {
        switch source {
        case .image:
            StickerEditorView(source: source) { sticker in
                addDropped(sticker)
            }
        case .video:
            VideoTrimView(source: source) { sticker in
                addDropped(sticker)
            }
        case .gif:
            GIFTrimView(source: source) { sticker in
                addDropped(sticker)
            }
        }
    }

    private func addDropped(_ sticker: StickerItem) {
        do {
            try store.add(sticker, to: packID)
            selectionPulse += 1
        } catch {
            activeAlert = .error(error.localizedDescription)
            errorPulse += 1
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The bar carries the options menu plus the single primary action. The
        // only add affordance is the dashed tile in the grid.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename…", systemImage: "pencil") {
                    draftName = pack?.name ?? ""
                    activeAlert = .rename
                }
                Button("Folder…", systemImage: "folder") {
                    showingFolder = true
                }

                // The toolbar primary is the WhatsApp import, so this menu only
                // carries the `.stickreatepack` backup file.
                Button("Export Pack File…", systemImage: "square.and.arrow.up") {
                    exportFile()
                }

                Divider()

                Button("Delete Pack…", systemImage: "trash", role: .destructive) {
                    activeAlert = .deletePack
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Pack options")
        }

        if canExport {
            PrimaryActionItem(
                title: "Add to WhatsApp",
                systemImage: "plus.message",
                iconOnly: true
            ) {
                showingExport = true
            }
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
        case .deletePack: "Delete this pack?"
        case .deleteSticker: "Delete this sticker?"
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
        case .deletePack:
            Button("Delete Pack", role: .destructive) { deletePack() }
            Button("Cancel", role: .cancel) {}
        case .deleteSticker(let item):
            Button("Delete Sticker", role: .destructive) {
                store.removeSticker(item.id, from: packID)
            }
            Button("Cancel", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var alertMessage: some View {
        switch activeAlert {
        case .rename: Text("Give this pack a name.")
        case .error(let message): Text(message)
        case .deletePack: Text("This removes the pack and all its stickers. You can't undo this.")
        case .deleteSticker: Text("This removes the sticker from the pack. You can't undo this.")
        case nil: EmptyView()
        }
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

    /// Writes a `.stickreatepack` and opens the share sheet. This is the data
    /// backup/transfer path; the WhatsApp import is the primary action.
    private func exportFile() {
        guard let pack else { return }
        Task { @MainActor in
            do {
                // ZIP build + disk write off the main actor.
                let url = try await Task.detached(priority: .userInitiated) {
                    try PackArchive.writeTemporaryFile(pack)
                }.value
                shareItem = ShareItem(url: url)
            } catch {
                activeAlert = .error(error.localizedDescription)
                errorPulse += 1
            }
        }
    }
}

// MARK: - Previews

private func editorPreviewStore() -> (PackStore, UUID) {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return (store, pack.id)
}

/// A pack long enough to expose title truncation, with enough stickers that the
/// export primary (now icon-only) is present.
private func exportablePreviewStore() -> (PackStore, UUID) {
    let store = PackStore()
    let stickers = (0..<3).map { _ in
        StickerItem(kind: .static, stickerData: Data(), previewData: Data())
    }
    let pack = StickerPack(name: "Weekend Trip Photos", stickers: stickers)
    _ = store.importPack(pack)
    return (store, pack.id)
}

#Preview("Exportable title") {
    let (store, id) = exportablePreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
}

#Preview("Light") {
    let (store, id) = editorPreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
}

#Preview("Dark") {
    let (store, id) = editorPreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
    .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    let (store, id) = editorPreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
    .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    let (store, id) = editorPreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
    .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    let (store, id) = editorPreviewStore()
    NavigationStack {
        PackEditorView(store: store, packID: id)
    }
    .frame(width: 430, height: 932)
}

