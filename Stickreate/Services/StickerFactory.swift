import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Orchestrates: picked item → frames/image → background removal → encode → StickerItem.
enum StickerFactory {
    enum Failure: LocalizedError {
        case unsupported
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "This file type isn't supported."
            case .empty:
                "Nothing was selected."
            case .failed(let message):
                message
            }
        }
    }

    /// Turns a picked photo, video, or GIF into a ready-to-use sticker.
    ///
    /// Video and GIF stickers also persist their original media so they can be
    /// re-opened in the editor.
    static func makeSticker(from item: PhotosPickerItem) async throws -> StickerItem {
        let types = item.supportedContentTypes

        if types.contains(where: { $0.conforms(to: .movie) }) {
            let source = try await StickerSourceStore.importPicked(item)
            guard case .video = source else { throw Failure.unsupported }
            let frames = try await FrameExtractor.frames(
                fromVideoAt: StickerSourceStore.url(for: source),
                maxFrames: 30
            )
            return try await makeAnimated(from: frames, removeBackground: false, source: source)
        }

        if types.contains(where: { $0.conforms(to: .gif) }) {
            let source = try await StickerSourceStore.importPicked(item)
            guard case .gif = source else { throw Failure.unsupported }
            guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
                throw Failure.empty
            }
            let frames = try FrameExtractor.frames(fromGIF: data, maxFrames: 30)
            return try await makeAnimated(from: frames, removeBackground: false, source: source)
        }

        if types.contains(where: { $0.conforms(to: .image) }) {
            let data = try await imageData(from: item)
            guard let image = UIImage(data: data) else {
                throw Failure.empty
            }
            return try await makeStatic(from: image)
        }

        throw Failure.unsupported
    }

    // MARK: - Paths

    private static func makeStatic(from image: UIImage) async throws -> StickerItem {
        // Background removal is best-effort: any failure falls back to the
        // original image so sticker creation never blocks.
        let subject = (try? await BackgroundRemover.removeBackground(from: image)) ?? image
        return try encodeStatic(subject)
    }

    /// Loads a picked image as an upright `UIImage` without touching the pixels.
    static func loadUprightImage(from item: PhotosPickerItem) async throws -> UIImage {
        let data = try await imageData(from: item)
        guard let image = UIImage(data: data) else { throw Failure.empty }
        return image.upNormalized() ?? image
    }

    /// Encodes an already-prepared image into a static sticker (no background removal).
    static func encodeStatic(_ image: UIImage, source: StickerSource? = nil) throws -> StickerItem {
        guard let stickerData = StickerEncoder.staticSticker(from: image),
              let previewData = StickerEncoder.previewPNG(from: image, size: 512) else {
            throw Failure.failed("Couldn't encode this sticker.")
        }
        return StickerItem(
            kind: .static,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
    }

    /// Loads a picked movie into a temporary file and reports its duration.
    /// The temporary copy stays valid until the sticker is created.
    static func loadVideoDraft(from item: PhotosPickerItem) async throws -> VideoDraft {
        let url = try await movieURL(from: item)
        return try await FrameExtractor.videoDraft(from: url)
    }

    /// Loads a stored video source so it can be trimmed again.
    static func loadVideoDraft(from source: StickerSource) async throws -> VideoDraft {
        guard case .video = source else { throw Failure.unsupported }
        return try await FrameExtractor.videoDraft(from: StickerSourceStore.url(for: source))
    }

    /// Builds an animated sticker from a trimmed video range at the given fps.
    ///
    /// Background removal is opt-in (off by default): per-frame Vision is slow
    /// and memory-hungry, and video stickers rarely need it.
    static func makeAnimatedSticker(
        from draft: VideoDraft,
        range: ClosedRange<TimeInterval>,
        fps: Double,
        removeBackground: Bool = false,
        source: StickerSource? = nil
    ) async throws -> StickerItem {
        let frames = try await FrameExtractor.frames(fromVideoAt: draft.url, range: range, fps: fps)
        return try await makeAnimated(from: frames, removeBackground: removeBackground, source: source)
    }

    /// Rebuilds an animated sticker from a stored GIF source.
    static func makeAnimatedSticker(fromGIFSource source: StickerSource) async throws -> StickerItem {
        guard case .gif = source else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
            throw Failure.empty
        }
        let frames = try FrameExtractor.frames(fromGIF: data, maxFrames: 30)
        return try await makeAnimated(from: frames, removeBackground: false, source: source)
    }

    private static func makeAnimated(
        from frames: [Frame],
        removeBackground: Bool,
        source: StickerSource?
    ) async throws -> StickerItem {
        guard !frames.isEmpty else { throw Failure.empty }

        // Only run Vision when explicitly asked. If the first frame can't be
        // cut, keep the original frames for all.
        let usable: [Frame]
        if removeBackground {
            usable = await cutOut(frames) ?? frames
        } else {
            usable = frames
        }

        guard let stickerData = StickerEncoder.animatedSticker(from: usable),
              let previewData = StickerEncoder.previewPNG(from: usable[0].image, size: 512) else {
            throw Failure.failed("Couldn't encode this animated sticker.")
        }

        return StickerItem(
            kind: .animated,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
    }

    /// Background-removes every frame. Returns nil when the first frame fails,
    /// signalling the caller to use the original frames.
    private static func cutOut(_ frames: [Frame]) async -> [Frame]? {
        guard let first = frames.first else { return nil }
        guard let firstCut = try? await BackgroundRemover.removeBackground(from: first.image) else {
            return nil
        }

        var result = [Frame(image: firstCut, duration: first.duration)]
        for frame in frames.dropFirst() {
            let image = (try? await BackgroundRemover.removeBackground(from: frame.image)) ?? frame.image
            result.append(Frame(image: image, duration: frame.duration))
        }
        return result
    }

    // MARK: - Loading

    private static func imageData(from item: PhotosPickerItem) async throws -> Data {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw Failure.empty
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    private static func movieURL(from item: PhotosPickerItem) async throws -> URL {
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                throw Failure.empty
            }
            return movie.url
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}
