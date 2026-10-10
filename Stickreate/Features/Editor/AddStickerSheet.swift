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
    @State private var commitIndex = 0
    @State private var commitTotal = 0
    @State private var creationTask: Task<Void, Never>?
    @State private var notice: Notice?
    @State private var successPulse = 0
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

    /// One channel for non-blocking messages. Errors and "some items were
    /// skipped" read differently, so they get distinct titles.
    private enum Notice: Identifiable, Equatable {
        case error(String)
        case skipped(String)
        case full(String)

        var id: String {
            switch self {
            case .error(let message): "error-\(message)"
            case .skipped(let message): "skipped-\(message)"
            case .full(let message): "full-\(message)"
            }
        }

        var title: String {
            switch self {
            case .error: "Something went wrong"
            case .skipped: "Only one kind per pack"
            case .full: "Pack is full"
            }
        }

        var message: String {
            switch self {
            case .error(let message), .skipped(let message), .full(let message): message
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .stickerDrop { sources in
                    enqueueDropped(sources)
                } onError: { message in
                    presentError(message)
                }
                .navigationTitle("Add Stickers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    CancelActionItem(isDisabled: isProcessing) { dismiss() }
                    // No Add action until there is something in the queue.
                    if !queue.isEmpty {
                        PrimaryActionItem(
                            title: "Add \(queue.count)",
                            isDisabled: isProcessing || isImporting || remaining == 0
                        ) {
                            startCommit()
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
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
        .creationProgressOverlay(
            isProcessing,
            stage: currentStage,
            title: "Adding stickers",
            detail: commitDetail,
            onCancel: cancelCommit
        )
        .haptic(.success, trigger: successPulse)
        .haptic(.error, trigger: notice)
        .announceOnChange(of: currentStage.announcementPhase) { $0 }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if remaining == 0 {
            EmptyState(
                symbol: "checkmark.circle",
                title: "Pack Is Full",
                message: "A pack can hold at most \(Limits.maxStickers) stickers."
            ) {
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
            }
        } else if isImporting {
            LoadingState(title: "Importing…")
        } else if queue.isEmpty && !isProcessing {
            pickerState
        } else {
            queueState
        }
    }

    private var pickerState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                packSummary
                actionsRow
                existingStickersSection
                howToSection
            }
            .padding(DS.Space.xl)
        }
    }

    // MARK: - Picker helpers

    private var packSummary: some View {
        HStack(spacing: DS.Space.md) {
            packCover

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(pack?.name ?? "This pack")
                    .font(DS.TextRole.cardTitle)
                    .lineLimit(1)

                Text("\(pack?.stickers.count ?? 0) of \(Limits.maxStickers) · \(packKindLabel)")
                    .font(DS.TextRole.supporting)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var packCover: some View {
        RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .frame(width: 56, height: 56)
            .overlay {
                if let image = packCoverImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.xs)
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
        HStack(spacing: DS.Space.md) {
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
        VStack(spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(DS.TextRole.supporting.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var existingStickersSection: some View {
        let stickers = pack?.stickers ?? []
        if !stickers.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Already in this pack")
                    .font(DS.TextRole.supporting.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(stickers.prefix(12)) { item in
                            ExistingStickerThumb(item: item)
                        }
                    }
                    .padding(.vertical, DS.Space.xxs)
                }
            }
        }
    }

    private var howToSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("How it works")
                .font(DS.TextRole.supporting.weight(.semibold))
                .foregroundStyle(.secondary)

            howToStep(1, howToPickText)
            howToStep(2, "Edit or trim each item")
            howToStep(3, "Tap Add to save them to the pack")
        }
    }

    private func howToStep(_ number: Int, _ title: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text("\(number)")
                .font(DS.TextRole.badge)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(DS.ColorRole.accent, in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(DS.TextRole.supporting)

            Spacer(minLength: 0)
        }
    }

    private var queueState: some View {
        VStack(spacing: 0) {
            queueHeader

            List {
                ForEach(queue) { item in
                    queueRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        // Swipe-to-remove, mirroring the xmark button. No actions
                        // are offered while creating, which disables the swipe.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isProcessing {
                                Button(role: .destructive) {
                                    remove(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
        }
    }

    /// "Item N of M" line shown inside the shared creation-progress card.
    private var commitDetail: String? {
        guard commitTotal > 0 else { return nil }
        return "Item \(max(1, commitIndex)) of \(commitTotal)"
    }

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("\(queue.count) \(queue.count == 1 ? "item" : "items") to add")
                    .font(DS.TextRole.supporting.weight(.semibold))

                Text("Tap an item to open its editor. Anything you leave unedited is added with defaults.")
                    .font(DS.TextRole.caption)
                    .foregroundStyle(.secondary)
            }

            if !isProcessing {
                HStack(spacing: DS.Space.md) {
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
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }

    private var cameraIconButton: some View {
        Button {
            requestCamera()
        } label: {
            Image(systemName: "camera")
                .frame(width: DS.minTapTarget, height: DS.minTapTarget)
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

                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(typeLabel(for: item.source))
                            .font(DS.TextRole.supporting.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("Tap to edit")
                            .font(DS.TextRole.caption)
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
        case .image, .video, .gif: true
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
            GIFTrimView(source: item.source) { sticker in
                update(item.id, with: sticker)
            }
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
            presentError(error.localizedDescription)
        }
    }

    @MainActor
    private func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        var skipped = 0
        for url in urls {
            guard queue.count < remaining else { break }
            do {
                let source = try await StickerSourceStore.importFile(at: url)
                guard kindMatchesTarget(stickerKind(for: source)) else {
                    skipped += 1
                    continue
                }
                queue.append(QueueItem(source: source))
            } catch {
                presentError(error.localizedDescription)
            }
        }
        reportSkipped(skipped)
    }

    /// Files a dropped item (or items) into the queue, applying the same
    /// single-kind filtering as the picker/Files paths. Anything that can't be
    /// queued (pack full, or the wrong kind) is deleted so its already-copied
    /// source doesn't linger orphaned, and the user is told why.
    @MainActor
    private func enqueueDropped(_ sources: [StickerSource]) {
        guard !sources.isEmpty else { return }

        var added = 0
        var skipped = 0
        var overflow = 0
        for source in sources {
            guard queue.count < remaining else {
                overflow += 1
                StickerSourceStore.delete(source)
                continue
            }
            guard kindMatchesTarget(stickerKind(for: source)) else {
                skipped += 1
                StickerSourceStore.delete(source)
                continue
            }
            queue.append(QueueItem(source: source))
            added += 1
        }

        if overflow > 0 {
            if added == 0 {
                notice = .full("Pack is full — nothing was added.")
            } else {
                let noun = overflow == 1 ? "item" : "items"
                notice = .full("Pack is full — \(overflow) \(noun) \(overflow == 1 ? "wasn't" : "weren't") added.")
            }
        } else {
            reportSkipped(skipped)
        }
    }

    @MainActor
    private func importSources(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }

        var skipped = 0
        for item in items {
            guard queue.count < remaining else { break }
            do {
                let source = try await StickerSourceStore.importPicked(item)
                guard kindMatchesTarget(stickerKind(for: source)) else {
                    skipped += 1
                    continue
                }
                queue.append(QueueItem(source: source))
            } catch {
                presentError(error.localizedDescription)
            }
        }

        pickerSelection = []
        reportSkipped(skipped)
    }

    /// The kind a multi-selection should keep: the pack's kind if it already has
    /// one, else the first queued item's kind (the first sticker fixes the pack).
    private var effectiveKind: StickerKind? {
        packKind ?? queue.first.map { stickerKind(for: $0.source) }
    }

    /// True when `kind` can join the current selection. The first item is always
    /// accepted and fixes the target kind for the rest of the batch.
    private func kindMatchesTarget(_ kind: StickerKind) -> Bool {
        guard let target = effectiveKind else { return true }
        return target == kind
    }

    private func presentError(_ message: String) {
        notice = .error(message)
    }

    /// Clear, single message when a mixed multi-selection was trimmed to one kind.
    private func reportSkipped(_ count: Int) {
        guard count > 0 else { return }
        let noun = count == 1 ? "item" : "items"
        switch effectiveKind {
        case .static:
            notice = .skipped("Added the photos. Skipped \(count) \(noun) that weren't photos — a pack holds one kind.")
        case .animated:
            notice = .skipped("Added the videos. Skipped \(count) \(noun) that weren't videos — a pack holds one kind.")
        case nil:
            notice = .skipped("Skipped \(count) \(noun) — a pack holds one kind.")
        }
    }

    // MARK: - Commit

    /// Starts the commit in a cancellable task so the progress card's Cancel can
    /// stop it.
    private func startCommit() {
        creationTask = Task { await commit() }
    }

    /// Cancels an in-flight commit. The queue is untouched past the current item,
    /// so everything not yet added (and its edits) survives for a retry.
    private func cancelCommit() {
        creationTask?.cancel()
        creationTask = nil
        isProcessing = false
        currentStage = nil
        committingID = nil
    }

    @MainActor
    private func commit() async {
        guard !queue.isEmpty else { return }

        if queue.count > remaining {
            presentError(StickerPack.ValidationError.tooMany(Limits.maxStickers).localizedDescription)
            return
        }

        isProcessing = true
        commitTotal = queue.count
        commitIndex = 0
        defer {
            isProcessing = false
            currentStage = nil
            committingID = nil
            commitIndex = 0
            commitTotal = 0
        }

        // Iterate a snapshot and drop each item only after it is added, so a
        // failure (or a cancel) keeps the remaining queue and their edits intact.
        for item in queue {
            if Task.isCancelled { return }
            do {
                commitIndex += 1
                committingID = item.id
                currentStage = .loading
                var sticker = try await resolvedSticker(for: item)
                if Task.isCancelled { return }
                // Respect the user's "Keep original sources" preference: when
                // off, don't persist the original media (the sticker then isn't
                // re-editable). The source is written earlier while editing, so
                // it must be dropped here at the single commit choke point.
                if !SettingsStore.shared.shouldPersistOriginalSources, let source = sticker.source {
                    StickerSourceStore.delete(source)
                    sticker.source = nil
                }
                guard isCompatible(sticker.kind) else {
                    presentError(incompatibleMessage)
                    return
                }
                try store.add(sticker, to: packID)
                queue.removeAll { $0.id == item.id }
            } catch {
                if Task.isCancelled { return }
                presentError(error.localizedDescription)
                return
            }
        }

        if Task.isCancelled { return }
        successPulse += 1
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
            return try await StickerFactory.makeAnimatedSticker(
                fromGIFSource: item.source,
                onStage: stageHandler(for: item)
            )
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
                        presentError("Camera access is off. Turn it on in Settings to take a photo.")
                    }
                }
            }
        default:
            presentError("Camera access is off. Turn it on in Settings to take a photo.")
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
                    presentError(incompatibleMessage)
                    return
                }
                queue.append(QueueItem(source: source))
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }
}

/// Compact preview of a sticker already in the pack. Content layer — never glass.
private struct ExistingStickerThumb: View {
    let item: StickerItem

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .frame(width: 56, height: 56)
            .overlay {
                if let image = UIImage(data: item.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.xs)
                } else {
                    Image(systemName: "photo")
                        .font(DS.TextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .animated {
                    Image(systemName: "play.fill")
                        .font(DS.TextRole.badge)
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(DS.ColorRole.mediaScrim, in: Circle())
                        .padding(DS.Space.xs)
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
        RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .frame(width: 56, height: 56)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: isEdited ? .fit : .fill)
                        .padding(isEdited ? DS.Space.xs : 0)
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous))
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

// MARK: - Previews

private func addSheetPreviewStore() -> (PackStore, UUID) {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return (store, pack.id)
}

#Preview("Light") {
    let (store, id) = addSheetPreviewStore()
    AddStickerSheet(store: store, packID: id)
}

#Preview("Dark") {
    let (store, id) = addSheetPreviewStore()
    AddStickerSheet(store: store, packID: id)
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    let (store, id) = addSheetPreviewStore()
    AddStickerSheet(store: store, packID: id)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    let (store, id) = addSheetPreviewStore()
    AddStickerSheet(store: store, packID: id)
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    let (store, id) = addSheetPreviewStore()
    AddStickerSheet(store: store, packID: id)
        .frame(width: 430, height: 932)
}

