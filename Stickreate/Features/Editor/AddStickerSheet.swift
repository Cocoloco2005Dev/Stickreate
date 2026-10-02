import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Sheet for picking photos, videos, or Live Photos and turning them into
/// stickers. Still photos open `StickerEditorView` so the user can crop and
/// clean up the background; videos and GIFs run through the automatic pipeline.
@MainActor
struct AddStickerSheet: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var selection: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var editing: EditTask?
    @State private var pendingContinuation: CheckedContinuation<UIImage?, Never>?
    @State private var editedImage: UIImage?

    private var pack: StickerPack? { store.pack(with: packID) }

    private var remaining: Int {
        max(0, Limits.maxStickers - (pack?.stickers.count ?? 0))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Stickers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isProcessing)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            Task { await add() }
                        }
                        .disabled(selection.isEmpty || isProcessing || remaining == 0)
                    }
                }
        }
        .sheet(item: $editing, onDismiss: editingDismissed) { task in
            StickerEditorView(item: task.item) { image in
                editedImage = image
            }
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if remaining == 0 {
            ContentUnavailableView {
                Label("Pack Is Full", systemImage: "checkmark.circle")
            } description: {
                Text("A pack can hold at most \(Limits.maxStickers) stickers.")
            }
        } else if isProcessing {
            ProgressView("Creating stickers…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 20) {
                chooser
                helper

                if !selection.isEmpty {
                    previewRow
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var chooser: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: remaining,
            matching: .any(of: [.images, .videos, .livePhotos])
        ) {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 36, weight: .regular))
                Text("Choose Photos or Videos")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
        .buttonStyle(.glassProminent)
        .accessibilityLabel("Choose photos or videos")
    }

    private var helper: some View {
        Text("Pick up to \(remaining) \(remaining == 1 ? "item" : "items"). Photos open an editor to crop and clean up; videos and GIFs convert automatically.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selection.count == 1 ? "1 item selected" : "\(selection.count) items selected")
                .font(.subheadline.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(selection.enumerated()), id: \.offset) { _, item in
                        SelectionThumbnail(item: item)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Processing

    @MainActor
    private func add() async {
        guard !selection.isEmpty else { return }

        let animatedCount = selection.filter(isAnimated).count
        let stillCount = selection.count - animatedCount

        // Enforce WhatsApp's no-mixing rule before anything is written.
        if animatedCount > 0 && stillCount > 0 {
            errorMessage = StickerPack.ValidationError.mixedKinds.localizedDescription
            return
        }
        let selectionKind: StickerKind = animatedCount > 0 ? .animated : .static
        if let existing = pack?.kind, existing != selectionKind {
            errorMessage = StickerPack.ValidationError.mixedKinds.localizedDescription
            return
        }
        if selection.count > remaining {
            errorMessage = StickerPack.ValidationError.tooMany(Limits.maxStickers).localizedDescription
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        for item in selection {
            do {
                if isAnimated(item) {
                    let sticker = try await StickerFactory.makeSticker(from: item)
                    try store.add(sticker, to: packID)
                } else {
                    // Stills are hand-edited; a cancelled editor skips that item.
                    guard let image = await edit(item) else { continue }
                    let sticker = try StickerFactory.encodeStatic(image)
                    try store.add(sticker, to: packID)
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        selection = []
        dismiss()
    }

    private func isAnimated(_ item: PhotosPickerItem) -> Bool {
        let types = item.supportedContentTypes
        return types.contains { $0.conforms(to: .movie) }
            || types.contains { $0.conforms(to: .gif) }
    }

    /// Presents the editor for one still and suspends until it closes.
    @MainActor
    private func edit(_ item: PhotosPickerItem) async -> UIImage? {
        await withCheckedContinuation { continuation in
            editedImage = nil
            pendingContinuation = continuation
            editing = EditTask(item: item)
        }
    }

    /// Runs once the editor sheet is fully gone, so the next one presents cleanly.
    private func editingDismissed() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        let result = editedImage
        editedImage = nil
        continuation.resume(returning: result)
    }

    private struct EditTask: Identifiable {
        let id = UUID()
        let item: PhotosPickerItem
    }
}

/// Small opaque preview of a picked item. Content layer — never glass.
private struct SelectionThumbnail: View {
    let item: PhotosPickerItem

    @State private var image: UIImage?
    @State private var didLoad = false

    private var isAnimated: Bool {
        let types = item.supportedContentTypes
        return types.contains { $0.conforms(to: .movie) }
            || types.contains { $0.conforms(to: .gif) }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 76, height: 76)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: isAnimated ? "film" : "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if isAnimated {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isAnimated ? "Video or GIF selected" : "Photo selected")
            .task {
                guard !didLoad, !isAnimated else { return }
                didLoad = true
                image = await Self.loadThumbnail(item)
            }
    }

    private static func loadThumbnail(_ item: PhotosPickerItem) async -> UIImage? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return nil }
        return image
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return AddStickerSheet(store: store, packID: pack.id)
}
