import UIKit
import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

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

    /// Shared Core Image context for compositing video frames through the mask.
    private static let ciContext = CIContext()

    /// Turns a picked photo, video, or GIF into a ready-to-use sticker.
    ///
    /// Video and GIF stickers also persist their original media so they can be
    /// re-opened in the editor. `onStage` reports real creation phases.
    static func makeSticker(
        from item: PhotosPickerItem,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        onStage?(.loading)
        let types = item.supportedContentTypes

        if types.contains(where: { $0.conforms(to: .movie) }) {
            let source = try await StickerSourceStore.importPicked(item)
            guard case .video = source else { throw Failure.unsupported }
            let frames = try await FrameExtractor.frames(
                fromVideoAt: StickerSourceStore.url(for: source),
                maxFrames: 30,
                onProgress: { onStage?(.extracting($0)) }
            )
            return try await makeAnimated(
                from: frames,
                removeBackground: false,
                source: source,
                onStage: onStage
            )
        }

        if types.contains(where: { $0.conforms(to: .gif) }) {
            let source = try await StickerSourceStore.importPicked(item)
            guard case .gif = source else { throw Failure.unsupported }
            guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
                throw Failure.empty
            }
            onStage?(.extracting(0))
            let frames = try FrameExtractor.frames(fromGIF: data, maxFrames: 30)
            onStage?(.extracting(1))
            return try await makeAnimated(
                from: frames,
                removeBackground: false,
                source: source,
                onStage: onStage
            )
        }

        if types.contains(where: { $0.conforms(to: .image) }) {
            let data = try await imageData(from: item)
            guard let image = UIImage(data: data) else {
                throw Failure.empty
            }
            return try await makeStatic(from: image, onStage: onStage)
        }

        throw Failure.unsupported
    }

    // MARK: - Paths

    private static func makeStatic(
        from image: UIImage,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        // Background removal is best-effort: any failure falls back to the
        // original image so sticker creation never blocks.
        onStage?(.cutting(0))
        let subject = (try? await BackgroundRemover.removeBackground(
            from: image,
            progress: { onStage?(.cutting($0)) }
        )) ?? image
        onStage?(.cutting(1))
        return try encodeStatic(subject, onStage: onStage)
    }

    /// Loads a picked image as an upright `UIImage` without touching the pixels.
    static func loadUprightImage(from item: PhotosPickerItem) async throws -> UIImage {
        let data = try await imageData(from: item)
        guard let image = UIImage(data: data) else { throw Failure.empty }
        return image.upNormalized() ?? image
    }

    /// Encodes an already-prepared image into a static sticker (no background removal).
    static func encodeStatic(
        _ image: UIImage,
        source: StickerSource? = nil,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) throws -> StickerItem {
        onStage?(.compressing(0))
        guard let stickerData = StickerEncoder.staticSticker(from: image),
              let previewData = StickerEncoder.previewPNG(from: image, size: 512) else {
            throw Failure.failed("Couldn't encode this sticker.")
        }
        onStage?(.compressing(1.0))
        onStage?(.saving)
        let item = StickerItem(
            kind: .static,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
        onStage?(.done)
        return item
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

    /// Builds an animated sticker from a trimmed video range.
    ///
    /// `fps <= 0` lets the extractor choose a sane automatic rate. `cropRect`
    /// is a normalized top-left rect applied to every frame before encoding
    /// (`nil` = full frame). Background removal is opt-in (off by default):
    /// per-frame Vision is slow and memory-hungry, and video stickers rarely
    /// need it.
    ///
    /// `onProgress` (0...1, main queue): frame extraction when
    /// `removeBackground == false`, otherwise per-frame Vision across the clip.
    /// `onStage` reports real phases and `nil`-free completion (`.done` last).
    static func makeAnimatedSticker(
        from draft: VideoDraft,
        range: ClosedRange<TimeInterval>,
        fps: Double = 0,
        removeBackground: Bool = false,
        cropRect: CGRect? = nil,
        source: StickerSource? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        onStage?(.extracting(0))
        let extracted = try await FrameExtractor.frames(
            fromVideoAt: draft.url,
            range: range,
            fps: fps,
            onProgress: { value in
                onStage?(.extracting(value))
                if !removeBackground { onProgress?(value) }
            }
        )
        let frames = cropRect.map { rect in
            extracted.map { Frame(image: crop($0.image, to: rect), duration: $0.duration) }
        } ?? extracted
        // Pass the trimmed span so the encoder can make the integer-millisecond
        // frame durations sum to exactly the requested length.
        let span = max(0, range.upperBound - range.lowerBound)
        return try await makeAnimated(
            from: frames,
            removeBackground: removeBackground,
            source: source,
            targetDuration: span,
            onProgress: removeBackground ? onProgress : nil,
            onStage: onStage
        )
    }

    /// Crops a normalized (top-left) rect out of `image`, preserving duration.
    private static func crop(_ image: UIImage, to rect: CGRect) -> UIImage {
        let oriented = image.upNormalized() ?? image
        guard let cgImage = oriented.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let clamped = CGRect(
            x: rect.minX * width,
            y: rect.minY * height,
            width: rect.width * width,
            height: rect.height * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clamped.isEmpty, let cropped = cgImage.cropping(to: clamped.integral) else {
            return image
        }
        return UIImage(cgImage: cropped)
    }

    /// Rebuilds an animated sticker from a stored GIF source.
    static func makeAnimatedSticker(
        fromGIFSource source: StickerSource,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        guard case .gif = source else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
            throw Failure.empty
        }
        onStage?(.extracting(0))
        let frames = try FrameExtractor.frames(fromGIF: data, maxFrames: 30)
        onStage?(.extracting(1))
        return try await makeAnimated(
            from: frames,
            removeBackground: false,
            source: source,
            onStage: onStage
        )
    }

    private static func makeAnimated(
        from frames: [Frame],
        removeBackground: Bool,
        source: StickerSource?,
        targetDuration: TimeInterval? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        guard !frames.isEmpty else { throw Failure.empty }

        // Only run Vision when explicitly asked. If the first frame can't be
        // cut, keep the original frames for all.
        let usable: [Frame]
        if removeBackground {
            #if DEBUG
            let visionStarted = CFAbsoluteTimeGetCurrent()
            #endif
            usable = await cutOut(frames, onProgress: { value in
                onStage?(.cutting(value))
                onProgress?(value)
            }) ?? frames
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - visionStarted) * 1000
            print(String(format: "[StickerFactory] vision %d frames in %.0fms", frames.count, ms))
            #endif
        } else {
            usable = frames
        }

        onStage?(.compressing(0))
        #if DEBUG
        let encodeStarted = CFAbsoluteTimeGetCurrent()
        #endif
        guard let stickerData = StickerEncoder.animatedSticker(
            from: usable,
            targetDuration: targetDuration,
            onProgress: { fraction in onStage?(.compressing(fraction)) }
        ),
        let previewData = StickerEncoder.previewPNG(from: usable[0].image, size: 512) else {
            throw Failure.failed("Couldn't encode this animated sticker.")
        }
        #if DEBUG
        let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStarted) * 1000
        print(String(format: "[StickerFactory] encode %d frames in %.0fms (%d bytes)", usable.count, encodeMs, stickerData.count))
        #endif
        onStage?(.compressing(1.0))
        onStage?(.saving)
        let item = StickerItem(
            kind: .animated,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
        onStage?(.done)
        return item
    }

    /// Hard ceiling for the single-mask cut-out. If Vision or the per-frame
    /// compositing doesn't finish in time, the original frames are used so the
    /// UI can never sit on a frozen still.
    private static let cutOutTimeout: TimeInterval = 8

    /// Applies a single Vision subject mask to every frame, so the animated
    /// cutout can't flicker. The mask is computed once from the middle frame and
    /// composited onto each frame sequentially (bounded work, always completes).
    /// A watchdog aborts to the ORIGINAL frames if the whole step runs over
    /// `cutOutTimeout`.
    ///
    /// `onProgress` is the Vision pass + per-frame compositing mapped into `0...1`.
    private static func cutOut(_ frames: [Frame], onProgress: ((Double) -> Void)? = nil) async -> [Frame]? {
        guard !frames.isEmpty else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Frame]?, Never>) in
            let gate = ResumeOnce(continuation)
            // Ignore progress once the race is decided, so a late/timed-out work
            // task can't push stale `.cutting` updates after the fallback.
            let progress: ((Double) -> Void)? = onProgress.map { forward in
                { value in if gate.isPending { forward(value) } }
            }
            let work = Task.detached(priority: .userInitiated) { () -> [Frame]? in
                await computeCutout(frames, onProgress: progress)
            }
            // Deliver the result if it finishes first; the watchdog resumes `nil`
            // (original frames) and cancels the work if it doesn't. `gate` makes
            // the race safe: the continuation is resumed exactly once.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(cutOutTimeout * 1_000_000_000))
                work.cancel()
                gate.resume(nil)
            }
            Task {
                gate.resume(await work.value)
                watchdog.cancel()
            }
        }
    }

    /// The actual single-mask work: one Vision pass, then composite every frame
    /// through that mask in order. Returns nil on failure or cancellation so the
    /// caller falls back to the original frames.
    private static func computeCutout(_ frames: [Frame], onProgress: ((Double) -> Void)?) async -> [Frame]? {
        guard !frames.isEmpty else { return nil }
        let representative = frames[frames.count / 2]

        onProgress?(0)
        guard let extraction = try? await BackgroundRemover.extractSubject(
            from: representative.image,
            progress: { onProgress?($0) }
        ) else {
            onProgress?(1)
            return nil
        }
        if Task.isCancelled { return nil }
        guard !extraction.instances.isEmpty else {
            // No detected subject means a blank mask; use the original frames.
            onProgress?(1)
            return nil
        }

        let mask = extraction.mask
        var result: [Frame] = []
        result.reserveCapacity(frames.count)
        let total = Double(frames.count)
        for (index, frame) in frames.enumerated() {
            if Task.isCancelled { return nil }
            let image = composite(frame.image, through: mask) ?? frame.image
            result.append(Frame(image: image, duration: frame.duration))
            onProgress?(Double(index + 1) / total)
        }
        return result
    }

    /// Resumes a continuation at most once, so the work task and the watchdog can
    /// race without a double-resume crash.
    private final class ResumeOnce {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[Frame]?, Never>?

        init(_ continuation: CheckedContinuation<[Frame]?, Never>) {
            self.continuation = continuation
        }

        /// True until the continuation has been resumed.
        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func resume(_ value: [Frame]?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Composites `image` through a single-channel grayscale `mask` (white =
    /// keep) onto a transparent background. The mask is scaled to the image
    /// extent if their pixel sizes differ.
    private static func composite(_ image: UIImage, through mask: CGImage) -> UIImage? {
        guard let base = CIImage(image: image) else { return nil }
        var maskImage = CIImage(cgImage: mask)
        if maskImage.extent.width > 0, maskImage.extent.height > 0,
           maskImage.extent.size != base.extent.size {
            maskImage = maskImage.transformed(by: CGAffineTransform(
                scaleX: base.extent.width / maskImage.extent.width,
                y: base.extent.height / maskImage.extent.height
            ))
        }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: base.extent)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = base
        filter.backgroundImage = clear
        filter.maskImage = maskImage
        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: base.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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
