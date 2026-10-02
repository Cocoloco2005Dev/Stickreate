import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Sheet for picking photos, videos, or Live Photos and turning them into
/// stickers. Still photos open `StickerEditorView` to crop and clean up the
/// background; videos open `VideoTrimView`; GIFs run through the automatic
/// pipeline. Static and animated stickers may share one pack.
@MainActor
struct AddStickerSheet: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var selection: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var errorMessage: String?

    @State private var editing: EditTask?
    @State private var pendingContinuation: CheckedContinuation<Result<StickerItem, Error>?, Never>?
    @State private var pendingResult: Result<StickerItem, Error>?

    @State private var showingCamera = false
    @State private var capturedImage: UIImage?

    private var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

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
            editor(for: task)
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
        .onChange(of: selection) { _, newSelection in
            autoOpenEditorIfNeeded(newSelection)
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
    private func editor(for task: EditTask) -> some View {
        switch task.kind {
        case .still(let source):
            StickerEditorView(source: source) { image in
                pendingResult = Result { try StickerFactory.encodeStatic(image, source: source) }
            }
        case .video(let source):
            VideoTrimView(source: source) { sticker in
                pendingResult = .success(sticker)
            }
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

                if isCameraAvailable {
                    cameraButton
                }

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

    private var helper: some View {
        Text("Pick up to \(remaining) \(remaining == 1 ? "item" : "items"). Photos open an editor to crop and clean up; videos open a trim screen; GIFs convert automatically.")
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
                        SelectionThumbnail(item: item) {
                            remove(item)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remove(_ item: PhotosPickerItem) {
        selection.removeAll { $0 == item }
    }

    // MARK: - Processing

    @MainActor
    private func add() async {
        guard !selection.isEmpty else { return }

        if selection.count > remaining {
            errorMessage = StickerPack.ValidationError.tooMany(Limits.maxStickers).localizedDescription
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        for item in selection {
            do {
                let source = try await StickerSourceStore.importPicked(item)
                if await process(source: source) == false { return }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        selection = []
        dismiss()
    }

    /// Opens the right editor for a source and adds the result. Returns `false`
    /// only on a real error (a cancelled editor counts as handled).
    @MainActor
    private func process(source: StickerSource) async -> Bool {
        do {
            switch source {
            case .image:
                // Stills open the editor; a cancelled editor skips that item.
                guard let result = await edit(.still(source)) else { return true }
                try apply(result)
            case .video:
                // Videos open the trim screen; a cancelled trim skips that item.
                guard let result = await edit(.video(source)) else { return true }
                try apply(result)
            case .gif:
                let sticker = try await StickerFactory.makeAnimatedSticker(fromGIFSource: source)
                try store.add(sticker, to: packID)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func apply(_ result: Result<StickerItem, Error>) throws {
        switch result {
        case .success(let sticker):
            try store.add(sticker, to: packID)
        case .failure(let error):
            throw error
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
            isProcessing = true
            defer { isProcessing = false }

            do {
                let upright = image.upNormalized() ?? image
                let source = try StickerSourceStore.saveImage(upright, id: UUID())
                if await process(source: source) {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A lone pick opens its editor/trim right away so the step can't be missed.
    private func autoOpenEditorIfNeeded(_ items: [PhotosPickerItem]) {
        guard !isProcessing, editing == nil, remaining > 0, items.count == 1 else { return }

        Task {
            // Let the photo picker finish dismissing before presenting the editor.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !isProcessing, editing == nil, selection.count == 1 else { return }
            await add()
        }
    }

    /// Presents the matching editor and suspends until it closes.
    @MainActor
    private func edit(_ kind: EditTask.Kind) async -> Result<StickerItem, Error>? {
        await withCheckedContinuation { continuation in
            pendingResult = nil
            pendingContinuation = continuation
            editing = EditTask(kind: kind)
        }
    }

    /// Runs once the editor sheet is fully gone, so the next one presents cleanly.
    private func editingDismissed() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        let result = pendingResult
        pendingResult = nil
        continuation.resume(returning: result)
    }

    private struct EditTask: Identifiable {
        enum Kind {
            case still(StickerSource)
            case video(StickerSource)
        }

        let id = UUID()
        let kind: Kind
    }
}

/// Small opaque preview of a picked item with a remove control.
/// Content layer — never glass.
private struct SelectionThumbnail: View {
    let item: PhotosPickerItem
    let onRemove: () -> Void

    @State private var image: UIImage?
    @State private var didLoad = false

    private var isVideo: Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    private var isGIF: Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .gif) }
    }

    private var selectionLabel: String {
        if isVideo { return "Video selected" }
        if isGIF { return "GIF selected" }
        return "Photo selected"
    }

    private var removeLabel: String {
        if isVideo { return "Remove video" }
        if isGIF { return "Remove GIF" }
        return "Remove photo"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            preview
            removeButton
        }
        .frame(width: 76, height: 76)
        .task {
            guard !didLoad, !isVideo, !isGIF else { return }
            didLoad = true
            image = await Self.loadThumbnail(item)
        }
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: 76, height: 76)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: isVideo || isGIF ? "film" : "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if isVideo || isGIF {
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
            .accessibilityLabel(selectionLabel)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Color.clear
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.title3)
                        .padding(4)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(removeLabel)
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
