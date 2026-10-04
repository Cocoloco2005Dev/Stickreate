import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

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

    @State private var showingFileImporter = false
    @State private var isImporting = false
    @State private var isProcessing = false
    @State private var currentStage: StickerCreationStage?
    @State private var committingID: UUID?
    @State private var errorMessage: String?
    @State private var editingItem: QueueItem?
    @State private var previewSticker: StickerItem?

    @State private var showingCamera = false
    @State private var capturedImage: UIImage?

    private var pack: StickerPack? { store.pack(with: packID) }

    /// The pack's kind is fixed by its first sticker; `nil` while empty.
    private var packKind: StickerKind? { pack?.stickers.first?.kind }

    /// A source's kind: stills are static, GIFs and videos animated.
    private func stickerKind(for source: StickerSource) -> StickerKind {
        switch source {
        case .image: .static
        case .video, .gif: .animated
        }
    }

    /// An empty pack takes any kind (the first sticker sets it); a non-empty pack
    /// only takes its own kind, so a pack can never mix photos and videos.
    private func isCompatible(_ kind: StickerKind) -> Bool {
        guard let packKind else { return true }
        return packKind == kind
    }

    private var incompatibleMessage: String {
        switch packKind {
        case .animated: "This pack holds videos. Add a video or GIF, or start a new pack."
        case .static: "This pack holds photos. Add a photo, or start a new pack."
        case nil: "That media doesn't fit this pack."
        }
    }

    private var remaining: Int {
        max(0, Limits.maxStickers - (pack?.stickers.count ?? 0))
    }

    private var available: Int {
        max(0, remaining - queue.count)
    }

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// The photo picker only offers media that matches the pack's kind, so a static
    /// pack can't take a video and an animated pack can't take a still. Empty packs
    /// accept everything. GIFs are images, so they ride along only while the pack is
    /// empty (an animated pack prefers videos and live photos).
    private var pickerFilter: PHPickerFilter {
        guard let pack, let kind = pack.kind else {
            return .any(of: [.images, .videos, .livePhotos])
        }
        switch kind {
        case .static: return .images
        case .animated: return .any(of: [.videos, .livePhotos])
        }
    }

    /// Step 1 of "How it works", matching the picker's kind filter.
    private var howToPickText: String {
        guard let pack, let kind = pack.kind else { return "Pick photos, videos, or GIFs" }
        switch kind {
        case .static: return "Pick photos"
        case .animated: return "Pick videos"
        }
    }

    private struct QueueItem: Identifiable {
        let id = UUID()
        let source: StickerSource
        var sticker: StickerItem?
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
                            .tint(Color.accentColor)
                    }
                    // No Add action until there is something in the queue.
                    if !queue.isEmpty {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add \(queue.count)") {
                                Task { await commit() }
                            }
                            .disabled(isProcessing || isImporting || remaining == 0)
                        }
                    }
                }
        }
        .sheet(item: $editingItem) { item in
            editor(for: item)
        }
        .sheet(item: $previewSticker) { sticker in
            StickerPreviewSheet(item: sticker)
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .movie, .gif],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
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
        } else if isImporting {
            ProgressView("Importing…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if queue.isEmpty && !isProcessing {
            pickerState
        } else {
            queueState
        }
    }

    private var pickerState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                packSummary
                actionsRow
                existingStickersSection
                howToSection
            }
            .padding(20)
        }
    }

    // MARK: - Picker helpers

    private var packSummary: some View {
        HStack(spacing: 12) {
            packCover

            VStack(alignment: .leading, spacing: 2) {
                Text(pack?.name ?? "This pack")
                    .font(.headline)
                    .lineLimit(1)

                Text("\(pack?.stickers.count ?? 0) of \(Limits.maxStickers) · \(packKindLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var packCover: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 56, height: 56)
            .overlay {
                if let image = packCoverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
    }

    private var packCoverImage: UIImage? {
        guard let pack, let data = pack.traySourcePreview else { return nil }
        return UIImage(data: data)
    }

    private var packKindLabel: String {
        guard let pack, !pack.stickers.isEmpty else { return "Empty" }
        return pack.animatedStickers.count > pack.staticStickers.count ? "Animated" : "Static"
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(
                selection: $pickerSelection,
                maxSelectionCount: remaining,
                matching: pickerFilter
            ) {
                actionTile("Photos", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Choose from your photo library")

            Button {
                showingFileImporter = true
            } label: {
                actionTile("Files", systemImage: "folder")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Import from Files")

            if isCameraAvailable && isCompatible(.static) {
                Button {
                    requestCamera()
                } label: {
                    actionTile("Camera", systemImage: "camera")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Take a photo")
            }
        }
    }

    private func actionTile(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var existingStickersSection: some View {
        let stickers = pack?.stickers ?? []
        if !stickers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Already in this pack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stickers.prefix(12)) { item in
                            ExistingStickerThumb(item: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var howToSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            howToStep(1, howToPickText)
            howToStep(2, "Edit or trim each item")
            howToStep(3, "Tap Add to save them to the pack")
        }
    }

    private func howToStep(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 0)
        }
    }

    private var queueState: some View {
        VStack(spacing: 0) {
            queueHeader

            if isProcessing {
                commitBanner
            }

            List {
                ForEach(queue) { item in
                    queueRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
        }
    }

    /// Shows the current item's creation stage while the queue is committed.
    private var commitBanner: some View {
        HStack(spacing: 12) {
            if let fraction = currentStage?.fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(currentStage?.label ?? "Adding…")
                .font(.subheadline)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(currentStage?.label ?? "Adding")
    }

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(queue.count) \(queue.count == 1 ? "item" : "items") to add")
                    .font(.subheadline.weight(.semibold))

                Text("Tap an item to open its editor. Anything you leave unedited is added with defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isProcessing {
                HStack(spacing: 10) {
                    if available > 0 {
                        PhotosPicker(
                            selection: $pickerSelection,
                            maxSelectionCount: available,
                            matching: pickerFilter
                        ) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Add more photos or videos")

                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Add from Files", systemImage: "folder")
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Add media from Files")
                    }

                    if isCameraAvailable && isCompatible(.static) {
                        cameraIconButton
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                    // Once edited, the thumbnail shows the finished sticker.
                    QueueThumbnail(source: item.source, previewData: item.sticker?.previewData)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(typeLabel(for: item.source))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("Tap to edit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .accessibilityLabel("\(typeLabel(for: item.source)). Tap to edit")
            .accessibilityHint(isEditable(item.source) ? "Opens the editor" : "This item is added as-is")

            if let sticker = item.sticker {
                Button {
                    previewSticker = sticker
                } label: {
                    Image(systemName: "eye")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(typeLabel(for: item.source).lowercased())")
            }

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
        guard !isProcessing, isEditable(item.source) else { return }
        editingItem = item
    }

    private func update(_ id: UUID, with sticker: StickerItem) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].sticker = sticker
    }

    private func remove(_ item: QueueItem) {
        guard !isProcessing else { return }
        queue.removeAll { $0.id == item.id }
    }

    // MARK: - Importing

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { await importSources(items) }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await importFiles(urls) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        for url in urls {
            guard queue.count < remaining else { break }
            do {
                let source = try await StickerSourceStore.importFile(at: url)
                guard isCompatible(stickerKind(for: source)) else {
                    errorMessage = incompatibleMessage
                    continue
                }
                queue.append(QueueItem(source: source))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        defer {
            isProcessing = false
            currentStage = nil
            committingID = nil
        }

        // Iterate a snapshot and drop each item only after it is added, so a
        // failure keeps the remaining queue (and their edits) intact.
        for item in queue {
            do {
                committingID = item.id
                currentStage = .loading
                let sticker = try await resolvedSticker(for: item)
                guard isCompatible(sticker.kind) else {
                    errorMessage = incompatibleMessage
                    return
                }
                try store.add(sticker, to: packID)
                queue.removeAll { $0.id == item.id }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        dismiss()
    }

    private func resolvedSticker(for item: QueueItem) async throws -> StickerItem {
        if let sticker = item.sticker { return sticker }
        return try await defaultSticker(for: item)
    }

    /// Items the user never edited: photos keep their background; videos use the
    /// first 10 s at an automatic frame rate; GIFs rebuild from their source.
    private func defaultSticker(for item: QueueItem) async throws -> StickerItem {
        switch item.source {
        case .image:
            guard let image = StickerSourceStore.image(for: item.source) else {
                throw StickerFactory.Failure.empty
            }
            // `encodeStatic` is synchronous on the main actor, so assign directly.
            let id = item.id
            return try StickerFactory.encodeStatic(
                image,
                source: item.source,
                onStage: { newStage in
                    if committingID == id { currentStage = newStage }
                }
            )

        case .video:
            let onStage = stageHandler(for: item)
            let draft = try await StickerFactory.loadVideoDraft(from: item.source)
            guard draft.duration > 0 else { throw StickerFactory.Failure.empty }
            let upper = min(draft.duration, Limits.maxAnimationDuration)
            return try await StickerFactory.makeAnimatedSticker(
                from: draft,
                range: 0...upper,
                fps: 0,                     // automatic frame rate
                removeBackground: false,
                source: item.source,
                onStage: onStage
            )

        case .gif:
            return try await StickerFactory.makeAnimatedSticker(fromGIFSource: item.source)
        }
    }

    /// Stage callbacks can arrive off the main actor, so hop back before
    /// publishing. Stages from an item that is no longer committing are ignored.
    private func stageHandler(for item: QueueItem) -> (StickerCreationStage) -> Void {
        let id = item.id
        return { newStage in
            Task { @MainActor in
                guard committingID == id else { return }
                currentStage = newStage
            }
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
                guard isCompatible(.static) else {
                    errorMessage = incompatibleMessage
                    return
                }
                queue.append(QueueItem(source: source))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Compact preview of a sticker already in the pack. Content layer — never glass.
private struct ExistingStickerThumb: View {
    let item: StickerItem

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 56, height: 56)
            .overlay {
                if let image = UIImage(data: item.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .animated {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Small opaque thumbnail for a queued source. Shows the edited sticker's still
/// once the item has been processed. Content layer — never glass.
private struct QueueThumbnail: View {
    let source: StickerSource
    /// The edited sticker's still, if the item has already been processed.
    let previewData: Data?

    @State private var image: UIImage?
    @State private var isEdited = false

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
                        .aspectRatio(contentMode: isEdited ? .fit : .fill)
                        .padding(isEdited ? 4 : 0)
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: previewData) {
                if let previewData, let edited = UIImage(data: previewData) {
                    isEdited = true
                    image = edited
                } else {
                    isEdited = false
                    image = await Self.load(source)
                }
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
