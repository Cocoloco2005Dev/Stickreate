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

    var body: some View {
        NavigationStack {
            Group {
                if isBusy {
                    ProgressView("Preparing…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { onDone() }
                .disabled(isBusy)
                .tint(Color.accentColor)
        }

        if let pack = selectedPack {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add to \(pack.name)") {
                    performAdd()
                }
                .buttonStyle(.glassProminent)
                .disabled(isBusy)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            mediaRow
                .padding(.horizontal, 20)
                .padding(.top, 8)

            ContentUnavailableView {
                Label("No Packs Yet", systemImage: "square.grid.2x2")
            } description: {
                Text("Create a pack to add this \(mediaTypeLabel.lowercased()) to.")
            } actions: {
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
                .accessibilityLabel("Create a new pack")
            }
        }
    }

    private var mediaRow: some View {
        HStack(spacing: 14) {
            mediaThumb

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaTypeLabel)
                    .font(.headline)

                Text("Choose a pack to add it to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mediaTypeLabel). Choose a pack to add it to.")
    }

    private var mediaThumb: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private func packRow(_ pack: StickerPack) -> some View {
        let isSelected = selectedPackID == pack.id

        return Button {
            selectedPackID = pack.id
        } label: {
            HStack(spacing: 12) {
                packThumb(pack)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(packSummary(pack))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pack.name), \(packSummary(pack))")
        .accessibilityHint("Selects this pack")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func packThumb(_ pack: StickerPack) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 48, height: 48)
            .overlay {
                if let data = pack.traySourcePreview, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption)
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
        if let pack = store.packs.first {
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
        guard let packID = selectedPackID, !isBusy else { return }

        switch source {
        case .image:
            editorTask = .photo
        case .video:
            editorTask = .video
        case .gif:
            convertGIF(into: packID)
        }
    }

    @MainActor
    private func convertGIF(into packID: UUID) {
        isBusy = true
        Task {
            do {
                let sticker = try await StickerFactory.makeAnimatedSticker(fromGIFSource: source)
                try store.add(sticker, to: packID)
                isBusy = false
                onDone()
            } catch {
                isBusy = false
                errorMessage = error.localizedDescription
            }
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
        }
    }

    @MainActor
    private func addFromEditor(_ sticker: StickerItem) {
        guard let packID = selectedPackID else { return }
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

#Preview {
    ImportMediaSheet(
        source: .image(fileName: "preview.jpg"),
        store: PackStore(),
        onDone: {}
    )
}
