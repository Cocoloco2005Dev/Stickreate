import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Shared drag-and-drop support for turning an externally dragged photo or video
/// into a sticker. `stickerDrop` accepts the drag, imports the media through
/// `StickerSourceStore` (so it lands in `Documents/Sources` exactly like the
/// picker/Files paths), highlights the target with `StickerDropOverlay`, and
/// hands the imported sources back to the caller.
///
/// All three drop contexts (library root, pack editor, add sheet) reuse this and
/// only differ in what they do with the returned sources.
extension View {
    /// Makes this view accept a dragged image/video and report the imported
    /// sources. `onError` gets a user-facing message when nothing could be read.
    func stickerDrop(
        onDrop: @escaping ([StickerSource]) -> Void,
        onError: @escaping (String) -> Void,
        isEnabled: Bool = true
    ) -> some View {
        modifier(StickerDropModifier(isEnabled: isEnabled, onDrop: onDrop, onError: onError))
    }
}

/// Transient highlight shown while a compatible item is over the drop target.
/// Content is intentionally opaque, the accent border marks the actionable area,
/// and Reduce Transparency is honored by the material automatically.
struct StickerDropOverlay: View {
    /// The kind currently over the target, when it can be told from the drag.
    let kind: StickerKind?

    private var title: String {
        switch kind {
        case .static: "Add photo"
        case .animated: "Add video"
        case nil: "Add photo or video"
        }
    }

    private var symbol: String {
        switch kind {
        case .static: "photo"
        case .animated: "film"
        case nil: "photo.on.rectangle.angled"
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(
                    DS.ColorRole.accent,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(DS.Space.md)

            VStack(spacing: DS.Space.sm) {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(DS.ColorRole.accent)

                Text(title)
                    .font(DS.TextRole.cardTitle)
                    .foregroundStyle(.primary)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop target. \(title).")
    }
}

// MARK: - Modifier

private struct StickerDropModifier: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([StickerSource]) -> Void
    let onError: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var hoverKind: StickerKind?

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    StickerDropOverlay(kind: hoverKind)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.quick, value: isTargeted)
            .onDrop(
                of: [.image, .movie, .gif, .fileURL],
                delegate: StickerDropDelegate(
                    isEnabled: isEnabled,
                    isTargeted: $isTargeted,
                    hoverKind: $hoverKind,
                    onDrop: onDrop,
                    onError: onError
                )
            )
    }
}

// MARK: - Delegate

private struct StickerDropDelegate: DropDelegate {
    let isEnabled: Bool
    let isTargeted: Binding<Bool>
    let hoverKind: Binding<StickerKind?>
    let onDrop: ([StickerSource]) -> Void
    let onError: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled else { return }
        hoverKind.wrappedValue = kind(of: info)
        isTargeted.wrappedValue = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isEnabled else { return nil }
        hoverKind.wrappedValue = kind(of: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hoverKind.wrappedValue = nil
        isTargeted.wrappedValue = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        isTargeted.wrappedValue = false
        hoverKind.wrappedValue = nil

        let providers = info.itemProviders(for: [.image, .movie, .gif, .fileURL])
        guard !providers.isEmpty else {
            Task { @MainActor in onError("That item isn't a photo or video.") }
            return false
        }

        Task { @MainActor in
            var sources: [StickerSource] = []
            for provider in providers {
                if let source = await StickerDropLoader.load(provider) {
                    sources.append(source)
                }
            }
            if sources.isEmpty {
                onError("That item couldn't be read as a photo or video.")
            } else {
                onDrop(sources)
            }
        }
        return true
    }

    /// Best-effort label for the highlight; a movie wins over a still.
    private func kind(of info: DropInfo) -> StickerKind? {
        if info.hasItemsConforming(to: [.movie]) { return .animated }
        if info.hasItemsConforming(to: [.image]) { return .static }
        return nil
    }
}

// MARK: - Loading

/// Turns one dragged item provider into a stored `StickerSource`, reusing the
/// same import path as the picker/Files. Returns `nil` when the item can't be
/// read as media, so a bad drag never crashes — it just reports an error.
enum StickerDropLoader {
    static func load(_ provider: NSItemProvider) async -> StickerSource? {
        // Movie first: a movie also conforms to generic file types.
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let source = await importFile(provider, type: .movie) {
            return source
        }

        // GIF before image so animation is preserved instead of flattened.
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier),
           let source = await importFile(provider, type: .gif) {
            return source
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let source = await importFile(provider, type: .image) { return source }
            // Cut-outs dragged from Photos have no file, only raw data.
            if let data = await loadData(provider, type: .image) {
                return try? await StickerSourceStore.importData(data)
            }
        }

        // A provider that only vends a generic file URL.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, type: .fileURL) {
            return try? await StickerSourceStore.importFile(at: url)
        }

        return nil
    }

    private static func importFile(_ provider: NSItemProvider, type: UTType) async -> StickerSource? {
        guard let url = await loadURL(provider, type: type) else { return nil }
        return try? await StickerSourceStore.importFile(at: url)
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                // File-backed drags hand over an NSURL; data-backed drags don't.
                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
