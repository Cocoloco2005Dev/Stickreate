import SwiftUI
import UIKit
import PhotosUI
import AVFoundation

/// Adds stickers to a pack. Picked photos, videos, and GIFs land in a queue;
/// tapping a row opens its editor, and "Add N" commits everything. Items left
/// unedited are created with sensible defaults.
@MainActor
struct AddStickerSheet: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var queue: [QueueItem] = []

    @State private var isImporting = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var editingItem: QueueItem?

    @State private var showingCamera = false
    @State private var capturedImage: UIImage?

    private var pack: StickerPack? { store.pack(with: packID) }

    private var remaining: Int {
        max(0, Limits.maxStickers - (pack?.stickers.count ?? 0))
    }

    private var available: Int {
        max(0, remaining - queue.count)
    }

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private struct QueueItem: Identifiable {
        let id = UUID()
        let source: StickerSource
        var sticker: StickerItem?

        /// GIFs convert automatically, and edited items carry their sticker.
        var needsEdit: Bool {
            if case .gif = source { return false }
            return sticker == nil
        }
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
                        Button(addButtonTitle) {
                            Task { await commit() }
                        }
                        .disabled(queue.isEmpty || isProcessing || isImporting || remaining == 0)
                    }
                }
        }
        .sheet(item: $editingItem) { item in
            editor(for: item)
        }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: processCapturedImage) {
            CameraPicker(
                onCapture: { image in
                    capturedImage = image
                    showingCamera = false
                },
                onCancel: {
                    showingCamera = false
                }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickerSelection) { _, newItems in
            importPicked(newItems)
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

    private var addButtonTitle: String {
        queue.isEmpty ? "Add" : "Add \(queue.count)"
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
        } else if isImporting {
            ProgressView("Importing…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isProcessing {
            ProgressView("Adding…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if queue.isEmpty {
            pickerState
        } else {
            queueState
        }
    }

    private var pickerState: some View {
        VStack(spacing: 20) {
            PhotosPicker(
                selection: $pickerSelection,
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

            if isCameraAvailable {
                cameraButton
            }

            Text("Pick up to \(remaining) \(remaining == 1 ? "item" : "items"). Photos open an editor; videos open a trim screen; GIFs convert automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var queueState: some View {
        VStack(spacing: 0) {
            queueHeader

            List {
                ForEach(queue) { item in
                    queueRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            Text("\(queue.count) \(queue.count == 1 ? "item" : "items")")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            if available > 0 {
                PhotosPicker(
                    selection: $pickerSelection,
                    maxSelectionCount: available,
                    matching: .any(of: [.images, .videos, .livePhotos])
                ) {
                    Label("Add more", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Add more photos or videos")
            }

            if isCameraAvailable {
                cameraIconButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cameraButton: some View {
        Button {
            requestCamera()
        } label: {
            Label("Take Photo", systemImage: "camera")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Take a photo")
    }

    private var cameraIconButton: some View {
        Button {
            requestCamera()
        } label: {
            Image(systemName: "camera")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Take a photo")
    }

    // MARK: - Queue row

    private func queueRow(_ item: QueueItem) -> some View {
        HStack(spacing: 12) {
            Button {
                openEditor(item)
            } label: {
                HStack(spacing: 12) {
                    QueueThumbnail(source: item.source)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(typeLabel(for: item.source))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(item.needsEdit ? "Needs edit" : "Ready")
                            .font(.caption)
                            .foregroundStyle(item.needsEdit ? Color.secondary : Color.green)
                    }

                    Spacer(minLength: 0)

                    if isEditable(item.source) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(typeLabel(for: item.source)), \(item.needsEdit ? "needs edit" : "ready")")

            Button {
                remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(typeLabel(for: item.source).lowercased())")
        }
    }

    private func typeLabel(for source: StickerSource) -> String {
        switch source {
        case .image: "Photo"
        case .video: "Video"
        case .gif: "GIF"
        }
    }

    private func isEditable(_ source: StickerSource) -> Bool {
        switch source {
        case .image, .video: true
        case .gif: false
        }
    }

    // MARK: - Editing

    @ViewBuilder
    private func editor(for item: QueueItem) -> some View {
        switch item.source {
        case .image:
            StickerEditorView(source: item.source) { sticker in
                update(item.id, with: sticker)
            }
        case .video:
            VideoTrimView(source: item.source) { sticker in
                update(item.id, with: sticker)
            }
        case .gif:
            EmptyView()
        }
    }

    private func openEditor(_ item: QueueItem) {
        guard isEditable(item.source) else { return }
        editingItem = item
    }

    private func update(_ id: UUID, with sticker: StickerItem) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].sticker = sticker
    }

    private func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    // MARK: - Importing

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { await importSources(items) }
    }

    @MainActor
    private func importSources(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }

        for item in items {
            guard queue.count < remaining else { break }
            do {
                let source = try await StickerSourceStore.importPicked(item)
                queue.append(QueueItem(source: source))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        pickerSelection = []
    }

    // MARK: - Commit

    @MainActor
    private func commit() async {
        guard !queue.isEmpty else { return }

        if queue.count > remaining {
            errorMessage = StickerPack.ValidationError.tooMany(Limits.maxStickers).localizedDescription
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        for item in queue {
            do {
                let sticker = try await resolvedSticker(for: item)
                try store.add(sticker, to: packID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        queue = []
        dismiss()
    }

    private func resolvedSticker(for item: QueueItem) async throws -> StickerItem {
        if let sticker = item.sticker { return sticker }
        return try await defaultSticker(for: item.source)
    }

    /// Items the user never edited: photos keep their background; videos use the
    /// first 10 s at 10 fps; GIFs rebuild from their stored source.
    private func defaultSticker(for source: StickerSource) async throws -> StickerItem {
        switch source {
        case .image:
            guard let image = StickerSourceStore.image(for: source) else {
                throw StickerFactory.Failure.empty
            }
            return try StickerFactory.encodeStatic(image, source: source)

        case .video:
            let draft = try await StickerFactory.loadVideoDraft(from: source)
            guard draft.duration > 0 else { throw StickerFactory.Failure.empty }
            let upper = min(draft.duration, Limits.maxAnimationDuration)
            return try await StickerFactory.makeAnimatedSticker(
                from: draft,
                range: 0...upper,
                fps: 10,
                removeBackground: false,
                source: source
            )

        case .gif:
            return try await StickerFactory.makeAnimatedSticker(fromGIFSource: source)
        }
    }

    // MARK: - Camera

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showingCamera = true
                    } else {
                        errorMessage = "Camera access is off. Turn it on in Settings to take a photo."
                    }
                }
            }
        default:
            errorMessage = "Camera access is off. Turn it on in Settings to take a photo."
        }
    }

    @MainActor
    private func processCapturedImage() {
        guard let image = capturedImage else { return }
        capturedImage = nil

        Task {
            isImporting = true
            defer { isImporting = false }

            do {
                let upright = image.upNormalized() ?? image
                let source = try StickerSourceStore.saveImage(upright, id: UUID())
                queue.append(QueueItem(source: source))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Small opaque thumbnail for a queued source. Content layer — never glass.
private struct QueueThumbnail: View {
    let source: StickerSource

    @State private var image: UIImage?

    private var symbol: String {
        switch source {
        case .image: "photo"
        case .video: "film"
        case .gif: "photo.stack"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 56, height: 56)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task {
                image = await Self.load(source)
            }
            .accessibilityHidden(true)
    }

    private static func load(_ source: StickerSource) async -> UIImage? {
        switch source {
        case .image, .gif:
            return StickerSourceStore.image(for: source)
        case .video:
            return try? await FrameExtractor.thumbnail(
                fromVideoAt: StickerSourceStore.url(for: source),
                at: 0
            )
        }
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return AddStickerSheet(store: store, packID: pack.id)
}
