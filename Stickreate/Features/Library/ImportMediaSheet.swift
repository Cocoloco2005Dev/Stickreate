import SwiftUI
import UIKit

/// Shown when media is shared/opened into Stickreate. Lets the user pick the
/// destination pack, then runs the right editor (photo/video) or converts a GIF
/// before adding the sticker.
@MainActor
struct ImportMediaSheet: View {
    let source: StickerSource
    let store: PackStore
    let onDone: () -> Void

    @State private var previewImage: UIImage?
    @State private var selectedPackID: UUID?
    @State private var editorTask: EditorTask?
    @State private var didAdd = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    private enum EditorTask: String, Identifiable {
        case photo
        case video
        case gif

        var id: String { rawValue }
    }

    private var mediaTypeLabel: String {
        switch source {
        case .image: "Photo"
        case .video: "Video"
        case .gif: "GIF"
        }
    }

    private var mediaSymbol: String {
        switch source {
        case .image: "photo"
        case .video: "film"
        case .gif: "photo.stack"
        }
    }

    private var selectedPack: StickerPack? {
        selectedPackID.flatMap { store.pack(with: $0) }
    }

    /// The kind this incoming media would become: stills are static, GIFs and
    /// videos animated.
    private var incomingKind: StickerKind {
        switch source {
        case .image: .static
        case .video, .gif: .animated
        }
    }

    /// An empty pack takes any kind; a non-empty pack only takes its own kind, so
    /// a pack never mixes photos and videos.
    private func isCompatible(_ pack: StickerPack) -> Bool {
        pack.stickers.isEmpty || pack.kind == incomingKind
    }

    private func incompatibleReason(_ pack: StickerPack) -> String {
        switch incomingKind {
        case .static: "Holds videos"
        case .animated: "Holds photos"
        }
    }

    private var incompatibleMessage: String {
        switch incomingKind {
        case .static: "This pack holds videos. Pick a pack for photos, or create a new one."
        case .animated: "This pack holds photos. Pick a pack for videos, or create a new one."
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isBusy {
                    LoadingState(title: "Preparing…")
                } else if store.packs.isEmpty {
                    emptyState
                } else {
                    packList
                }
            }
            .navigationTitle("Add to Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .task { await loadPreview() }
        .onAppear { selectFirstPack() }
        .sheet(item: $editorTask, onDismiss: editorDismissed) { task in
            editor(for: task)
        }
        .haptic(.selection, trigger: selectedPackID)
        .haptic(.success, trigger: didAdd)
        .haptic(.error, trigger: errorMessage)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        CancelActionItem(isDisabled: isBusy) { onDone() }

        if let pack = selectedPack {
            PrimaryActionItem(title: "Add to \(pack.name)", isDisabled: isBusy) {
                performAdd()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.xl) {
            mediaRow
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.sm)

            EmptyState(
                symbol: "square.grid.2x2",
                title: "No Packs Yet",
                message: "Create a pack to add this \(mediaTypeLabel.lowercased()) to."
            ) {
                Button("New Pack", systemImage: "plus") {
                    createPack()
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    // MARK: - Pack list

    private var packList: some View {
        List {
            Section {
                mediaRow
            }

            Section("Choose a pack") {
                ForEach(store.packs) { pack in
                    packRow(pack)
                }

                Button {
                    createPack()
                } label: {
                    Label("New Pack", systemImage: "plus")
                }
                .accessibilityHint("Creates a new pack and selects it")
            }
        }
    }

    private var mediaRow: some View {
        HStack(spacing: DS.Space.md) {
            mediaThumb

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(mediaTypeLabel)
                    .font(DS.TextRole.cardTitle)

                Text("Choose a pack to add it to.")
                    .font(DS.TextRole.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mediaTypeLabel). Choose a pack to add it to.")
    }

    private var mediaThumb: some View {
        RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .frame(width: 64, height: 64)
            .overlay {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: mediaSymbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous))
            .accessibilityHidden(true)
    }

    private func packRow(_ pack: StickerPack) -> some View {
        let isSelected = selectedPackID == pack.id
        let compatible = isCompatible(pack)

        return Button {
            selectedPackID = pack.id
        } label: {
            HStack(spacing: DS.Space.md) {
                packThumb(pack)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(pack.name)
                        .font(DS.TextRole.cardTitle)
                        .lineLimit(1)

                    Text(compatible ? packSummary(pack) : incompatibleReason(pack))
                        .font(DS.TextRole.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.ColorRole.accent)
                        .accessibilityHidden(true)
                } else if !compatible {
                    Image(systemName: "nosign")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: DS.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!compatible)
        .accessibilityLabel("\(pack.name), \(compatible ? packSummary(pack) : incompatibleReason(pack))")
        .accessibilityHint(compatible ? "Selects this pack" : "This pack holds the other kind of media")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func packThumb(_ pack: StickerPack) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .frame(width: 48, height: 48)
            .overlay {
                if let data = pack.traySourcePreview, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.xs)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(DS.TextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
    }

    // MARK: - Selection helpers

    private func packSummary(_ pack: StickerPack) -> String {
        let count = pack.stickers.count
        let countText = count == 1 ? "1 sticker" : "\(count) stickers"
        return "\(countText) · \(pack.kind?.label ?? "Empty")"
    }

    private func selectFirstPack() {
        guard selectedPackID == nil else { return }
        if let pack = store.packs.first(where: isCompatible) {
            selectedPackID = pack.id
        }
    }

    // MARK: - Loading

    @MainActor
    private func loadPreview() async {
        switch source {
        case .image, .gif:
            previewImage = StickerSourceStore.image(for: source)
        case .video:
            previewImage = try? await FrameExtractor.thumbnail(
                fromVideoAt: StickerSourceStore.url(for: source),
                at: 0
            )
        }
    }

    // MARK: - Actions

    @MainActor
    private func createPack() {
        let pack = store.createPack()
        selectedPackID = pack.id
    }

    @MainActor
    private func performAdd() {
        guard let packID = selectedPackID,
              let pack = store.pack(with: packID),
              isCompatible(pack),
              !isBusy else { return }

        switch source {
        case .image:
            editorTask = .photo
        case .video:
            editorTask = .video
        case .gif:
            editorTask = .gif
        }
    }

    @ViewBuilder
    private func editor(for task: EditorTask) -> some View {
        switch task {
        case .photo:
            StickerEditorView(source: source) { sticker in
                addFromEditor(sticker)
            }
        case .video:
            VideoTrimView(source: source) { sticker in
                addFromEditor(sticker)
            }
        case .gif:
            GIFTrimView(source: source) { sticker in
                addFromEditor(sticker)
            }
        }
    }

    @MainActor
    private func addFromEditor(_ sticker: StickerItem) {
        guard let packID = selectedPackID,
              let pack = store.pack(with: packID),
              isCompatible(pack) else { return }
        do {
            try store.add(sticker, to: packID)
            didAdd = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Dismiss the whole sheet only after the editor has fully closed.
    private func editorDismissed() {
        guard didAdd else { return }
        didAdd = false
        onDone()
    }
}

// MARK: - Previews

#Preview("Light") {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
}

#Preview("Dark") {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
    .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
    .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
    .frame(width: 430, height: 932)
}
