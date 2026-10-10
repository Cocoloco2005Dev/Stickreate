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

    /// Shared Core Image context for applying the single video mask to frames.
    private static let ciContext = CIContext()

    // MARK: - Encoding

    /// Encodes an already-prepared image into a static sticker (no background removal).
    static func encodeStatic(
        _ image: UIImage,
        source: StickerSource? = nil,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) throws -> StickerItem {
        // Static creation runs only the compression + saving stages, so it emits
        // composed overall fractions from the compression slice of the ONE bar
        // (there is no extraction/cut to spend those earlier weights on).
        let creationStarted = CFAbsoluteTimeGetCurrent()
        var progress = ProgressAccumulator()
        onStage?(.compressing(progress.update(0, in: .compression)))
        // Auto-fit a cut-out subject to fill the canvas; opaque photos and fully
        // transparent images pass through unchanged.
        let fitted = StickerEncoder.alphaFitted(image)
        guard let stickerData = StickerEncoder.staticSticker(from: fitted),
              let previewData = StickerEncoder.previewPNG(from: fitted, size: 512) else {
            throw Failure.failed("Couldn't encode this sticker.")
        }
        onStage?(.compressing(progress.update(1, in: .compression)))
        onStage?(.saving)
        let item = StickerItem(
            kind: .static,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
        onStage?(.done)
        Log.timing(
            .encode,
            "static creation total bytes=\(stickerData.count) preview=\(previewData.count)",
            ms: (CFAbsoluteTimeGetCurrent() - creationStarted) * 1000
        )
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
    /// (`nil` = full frame). Background removal is opt-in (off by default) and
    /// tracks motion with a Vision pass every `maskStride` frames.
    ///
    /// `onProgress` (0...1, main queue): frame extraction when
    /// `removeBackground == false`, otherwise the Vision pass + composite.
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
        // Extraction occupies the first 0 → ~0.30 slice of the ONE overall bar.
        // Its callbacks are delivered asynchronously, so once extraction returns we
        // drop any late tick and snap to the slice end — a stale `.extracting`
        // update must never arrive after cut/compress and pull the bar backwards.
        var extraction = ProgressAccumulator()
        var extracting = true
        onStage?(.extracting(extraction.update(0, in: .extraction)))
        let extracted = try await FrameExtractor.frames(
            fromVideoAt: draft.url,
            range: range,
            fps: fps,
            onProgress: { value in
                guard extracting else { return }
                onStage?(.extracting(extraction.update(value, in: .extraction)))
                if !removeBackground { onProgress?(value) }
            }
        )
        extracting = false
        onStage?(.extracting(extraction.update(1, in: .extraction)))
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

    /// Crops every frame to the union of their (padded) alpha bounds so a cut-out
    /// subject fills the canvas uniformly — one shared box, so the animation never
    /// jitters. No-ops unless the first frame reports transparency AND every frame
    /// shares one pixel size (mixed-size GIF frames are left untouched). The crop
    /// is applied in place so each source image is released as it is replaced.
    private static func alphaFittedFrames(_ frames: [Frame]) -> [Frame] {
        // Early-out on the common opaque path: one scan instead of one per frame.
        guard let first = frames.first?.image,
              StickerEncoder.alphaBounds(of: first) != nil else {
            return frames
        }
        let size = pixelSize(of: first)
        guard size.width > 0,
              frames.allSatisfy({ pixelSize(of: $0.image) == size }),
              let union = StickerEncoder.alphaUnion(of: frames.map(\.image)) else {
            return frames
        }
        let padded = StickerEncoder.paddedCropRect(union, margin: StickerEncoder.alphaMargin, in: first)
        var result = frames
        for index in result.indices {
            result[index] = Frame(
                image: crop(result[index].image, toPixel: padded),
                duration: result[index].duration
            )
        }
        return result
    }

    /// Pixel dimensions of an upright image, independent of its point `scale`.
    private static func pixelSize(of image: UIImage) -> CGSize {
        let oriented = image.upNormalized() ?? image
        guard let cgImage = oriented.cgImage else { return .zero }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    /// Crops `image` to a top-left pixel rect, clamped to the image bounds.
    private static func crop(_ image: UIImage, toPixel rect: CGRect) -> UIImage {
        let oriented = image.upNormalized() ?? image
        guard let cgImage = oriented.cgImage else { return image }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )
        let clamped = rect.intersection(bounds).integral
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = cgImage.cropping(to: clamped) else {
            return image
        }
        return UIImage(cgImage: cropped)
    }

    /// Rebuilds an animated sticker from a stored GIF source, untrimmed.
    static func makeAnimatedSticker(
        fromGIFSource source: StickerSource,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        try await makeAnimatedSticker(
            fromGIF: source,
            range: nil,
            cropRect: nil,
            removeBackground: false,
            onStage: onStage
        )
    }

    /// Builds an animated sticker from a stored GIF with user-chosen trim, crop
    /// and background — the editable counterpart of `fromGIFSource:`.
    ///
    /// Unlike video, GIF frames are already in memory after decoding, so the
    /// trim keeps only the frames whose on-screen interval overlaps `range`
    /// (using their real delays) and passes `targetDuration = range length` to
    /// the shared sink, making the trimmed length exact. `cropRect` is a
    /// normalized top-left rect applied to every frame, same convention as
    /// video. `removeBackground` reuses the shared Vision path.
    static func makeAnimatedSticker(
        fromGIF source: StickerSource,
        range: ClosedRange<TimeInterval>?,
        cropRect: CGRect?,
        removeBackground: Bool,
        onProgress: ((Double) -> Void)? = nil,
        onStage: ((StickerCreationStage) -> Void)? = nil
    ) async throws -> StickerItem {
        guard case .gif = source else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
            throw Failure.empty
        }
        // GIF decode is coarse (no per-frame callback): two ticks across the
        // extraction slice of the ONE overall bar.
        var extraction = ProgressAccumulator()
        onStage?(.extracting(extraction.update(0, in: .extraction)))
        let all = try FrameExtractor.frames(fromGIF: data, maxFrames: 80)
        onStage?(.extracting(extraction.update(1, in: .extraction)))

        let trimmed: [Frame]
        let targetDuration: TimeInterval?
        if let range {
            let selection = frameRange(for: range, durations: all.map(\.duration))
            let selected = Array(all[selection])
            if selected.isEmpty {
                // Degenerate range: encode the whole GIF at its own duration
                // rather than compressing it into a bogus (shorter) span.
                trimmed = all
                targetDuration = nil
            } else {
                trimmed = selected
                let lower = max(0, range.lowerBound)
                targetDuration = max(0, range.upperBound - lower)
            }
        } else {
            trimmed = all
            targetDuration = nil
        }

        let cropped = cropRect.map { rect in
            trimmed.map { Frame(image: crop($0.image, to: rect), duration: $0.duration) }
        } ?? trimmed

        return try await makeAnimated(
            from: cropped,
            removeBackground: removeBackground,
            source: source,
            targetDuration: targetDuration,
            onProgress: onProgress,
            onStage: onStage
        )
    }

    /// Half-open index range of the frames whose cumulative on-screen interval
    /// `[start, start + delay)` overlaps `range`. Frames are contiguous, so the
    /// result is contiguous too. Pure — durations only, no decoding — so the GIF
    /// trim rule is unit-testable in isolation.
    static func frameRange(
        for range: ClosedRange<TimeInterval>,
        durations: [TimeInterval]
    ) -> Range<Int> {
        guard !durations.isEmpty else { return 0..<0 }
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)

        // First frame whose end passes the lower edge.
        var start = durations.count
        var time = 0.0
        for (index, duration) in durations.enumerated() {
            if time + max(0, duration) > lower {
                start = index
                break
            }
            time += max(0, duration)
        }

        // First frame whose start reaches the upper edge (exclusive).
        var end = durations.count
        var startOfFrame = 0.0
        for (index, duration) in durations.enumerated() {
            if startOfFrame >= upper {
                end = index
                break
            }
            startOfFrame += max(0, duration)
        }

        start = min(max(0, start), durations.count)
        end = max(start, min(end, durations.count))
        return start < end ? start..<end : 0..<0
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

        let creationStarted = CFAbsoluteTimeGetCurrent()

        // ONE overall 0…1 accumulator across cut → compress (extraction already
        // reported its 0 → ~0.30 slice), so the bar never resets or decreases.
        var progress = ProgressAccumulator()

        // Only run Vision when explicitly asked. If the cutout fails entirely,
        // keep the original frames for all.
        let usable: [Frame]
        if removeBackground {
            let cutStarted = CFAbsoluteTimeGetCurrent()
            usable = await cutOut(frames, onProgress: { value in
                onStage?(.cutting(progress.update(value, in: .cut)))
                onProgress?(value)
            }) ?? frames
            let cutMs = (CFAbsoluteTimeGetCurrent() - cutStarted) * 1000
            Log.timing(.vision, "cut frames=\(frames.count)", ms: cutMs)
            #if DEBUG
            print(String(format: "[StickerFactory] vision %d frames in %.0fms", frames.count, cutMs))
            #endif
        } else {
            usable = frames
        }

        // One shared alpha-fit box for the whole clip: a cut-out subject fills
        // the canvas without per-frame scale jitter. No-op when opaque.
        let fitStarted = CFAbsoluteTimeGetCurrent()
        let encoded = alphaFittedFrames(usable)
        Log.timing(.vision, "alpha-fit frames=\(encoded.count)", ms: (CFAbsoluteTimeGetCurrent() - fitStarted) * 1000)

        // A cancelled creation must abort BEFORE the expensive encode, not just
        // discard its result. The caller treats a thrown CancellationError as a
        // silent cancel.
        try Task.checkCancellation()

        onStage?(.compressing(progress.update(0, in: .compression)))
        #if DEBUG
        let encodeStarted = CFAbsoluteTimeGetCurrent()
        #endif
        // Capture the preview source and count BEFORE encoding so `encoded` has no
        // use after the encode call. In an optimized build ARC can then release
        // the source frame set at that point, roughly halving the resident frame
        // memory during the encode ladder. (Fully freeing it also needs the
        // callers to stop holding their frames — tracked as a Phase 4b follow-up.)
        guard let firstImage = encoded.first?.image else { throw Failure.empty }
        let frameCount = encoded.count
        guard let stickerData = StickerEncoder.animatedSticker(
            from: encoded,
            targetDuration: targetDuration,
            // Compose the encoder's 0...1 fraction into the compression slice of
            // the ONE overall bar (~0.65 → ~0.95); 1.0 stays reserved for `.done`.
            onProgress: { fraction in
                onStage?(.compressing(progress.update(fraction, in: .compression)))
            }
        ),
        let previewData = StickerEncoder.previewPNG(from: firstImage, size: 512) else {
            throw Failure.failed("Couldn't encode this animated sticker.")
        }
        #if DEBUG
        let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStarted) * 1000
        print(String(format: "[StickerFactory] encode %d frames in %.0fms (%d bytes)", frameCount, encodeMs, stickerData.count))
        #endif
        // `.done` carries fraction 1.0 once the item (payload + preview) exists.
        onStage?(.saving)
        let item = StickerItem(
            kind: .animated,
            emojis: [],
            stickerData: stickerData,
            previewData: previewData,
            source: source
        )
        onStage?(.done)
        Log.timing(
            .encode,
            "animated creation total frames=\(frameCount) bytes=\(stickerData.count)",
            ms: (CFAbsoluteTimeGetCurrent() - creationStarted) * 1000
        )
        return item
    }

    /// Vision runs on every frame so the cut contour tracks motion exactly.
    /// ponytail: per-frame Vision is the accuracy-maximising default; the small
    /// 256 px mask input keeps it affordable. Raise N only if a device profile
    /// shows the per-frame pass dominating.
    private static let maskStride = 1

    /// Longest side of the image handed to Vision. The resulting mask is scaled
    /// back up by `composite`, which always runs at full frame resolution.
    /// ponytail: a 256 px input is ~4× cheaper to segment than 512 px; it softens
    /// mask edges. Drop the downscale if edge quality matters more than speed.
    private static let maskInputMaxDimension: CGFloat = 256

    /// Watchdog backstop for the per-frame cut-out. Scaled with the frame count
    /// (base + per-frame allowance) because every anchor runs its own Vision pass
    /// and is followed by the sequential composite. Cancellable, and capped so a
    /// true hang can never freeze the UI.
    private static let cutOutBaseTimeout: TimeInterval = 10
    private static let cutOutPerFrameTimeout: TimeInterval = 0.2

    private static func cutOutTimeout(forFrameCount count: Int) -> TimeInterval {
        cutOutBaseTimeout + cutOutPerFrameTimeout * Double(max(0, count))
    }

    /// Applies a subject mask to every frame so the cutout follows motion: one
    /// Vision pass per frame (per `maskStride`), with the nearest successful mask
    /// reused after a failed pass. Never throws and never surfaces an error: if
    /// Vision fails, finds no subject, times out, or the caller cancels, it
    /// returns nil and the caller keeps the original frames.
    ///
    /// `onProgress` maps the anchor Vision passes and the per-frame composite
    /// into `0...1`.
    private static func cutOut(_ frames: [Frame], onProgress: ((Double) -> Void)? = nil) async -> [Frame]? {
        guard !frames.isEmpty else { return nil }
        let timeout = cutOutTimeout(forFrameCount: frames.count)
        let work = CancellableCutout()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[Frame]?, Never>) in
                let gate = ResumeOnce(continuation)
                // Ignore progress once the race is decided, so a late/timed-out work
                // task can't push stale `.cutting` updates after the fallback.
                let progress: ((Double) -> Void)? = onProgress.map { forward in
                    { value in if gate.isPending { forward(value) } }
                }
                let task = Task.detached(priority: .userInitiated) { () -> [Frame]? in
                    await computeCutout(frames, onProgress: progress)
                }
                work.store(task)
                // Deliver the result if it finishes first; the watchdog resumes `nil`
                // (original frames) and cancels the work if it doesn't. `gate` makes
                // the race safe: the continuation is resumed exactly once.
                let watchdog = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    task.cancel()
                    gate.resume(nil)
                }
                Task {
                    gate.resume(await task.value)
                    watchdog.cancel()
                }
            }
        } onCancel: {
            // Forward the CALLER's cancellation to the detached cut so Intelligent
            // Cut stops promptly when the user taps Cancel.
            work.cancel()
        }
    }

    /// Computes a subject mask every `maskStride` frames and composites each
    /// frame through the nearest successful mask, so the contour tracks motion
    /// instead of freezing one frame's silhouette.
    ///
    /// Returns nil (no cut) when Vision finds a subject on fewer than two anchors
    /// (i.e. essentially every pass failed), or when the work is cancelled — the
    /// caller then keeps the original frames. A frame whose anchor pass failed
    /// reuses the previous mask only for a bounded run (see `maskAssignments`),
    /// so a vanished subject stops being painted instead of lingering as a ghost.
    private static func computeCutout(_ frames: [Frame], onProgress: ((Double) -> Void)?) async -> [Frame]? {
        guard !frames.isEmpty else { return nil }

        // Anchor indices: 0, maskStride, 2*maskStride, …
        var anchors: [Int] = []
        var anchorIndex = 0
        while anchorIndex < frames.count {
            anchors.append(anchorIndex)
            anchorIndex += maskStride
        }

        // Phase 1: one Vision pass per anchor. Progress covers the first half.
        var masksByAnchor: [Int: CGImage] = [:]
        var successfulAnchors: [Int] = []
        for (position, anchor) in anchors.enumerated() {
            if Task.isCancelled { return nil }
            onProgress?(0.5 * Double(position) / Double(anchors.count))
            let input = frames[anchor].image.scaled(toMaxDimension: maskInputMaxDimension)
            guard let extraction = try? await BackgroundRemover.extractSubject(from: input),
                  !extraction.instances.isEmpty else {
                continue
            }
            // Clean the mask before it is ever composited: zero the faint
            // near-transparent halo Vision leaves around the subject so it can't
            // count as content and inflate the shared alpha-fit box.
            masksByAnchor[anchor] = cleanedMask(extraction.mask) ?? extraction.mask
            successfulAnchors.append(anchor)
        }

        // No successful Vision pass at all: fall back to the untouched frames.
        // A single success still cuts its own frames; `maskAssignments` bounds how
        // far that mask is reused when later anchors fail, and does not smear it
        // backwards across a long leading gap.
        Log.info(
            .vision,
            "cut masks succeeded=\(successfulAnchors.count)/\(anchors.count) frames=\(frames.count)"
        )
        guard !successfulAnchors.isEmpty else { return nil }
        onProgress?(0.5)

        // Phase 2: composite each frame with its nearest successful mask.
        let assignment = maskAssignments(
            frameCount: frames.count,
            stride: maskStride,
            successfulAnchors: successfulAnchors
        )
        var result: [Frame] = []
        result.reserveCapacity(frames.count)
        let total = Double(frames.count)
        for (index, frame) in frames.enumerated() {
            if Task.isCancelled { return nil }
            // Per-frame autoreleasepool: the composite allocates transient Core
            // Image objects; this loop is now the long pole (up to ~240 frames).
            let composited = autoreleasepool { () -> Frame in
                if let anchor = assignment[index], let mask = masksByAnchor[anchor] {
                    return Frame(image: composite(frame.image, through: mask) ?? frame.image, duration: frame.duration)
                }
                // No mask (no anchor succeeded) — leave the frame uncut.
                return Frame(image: frame.image, duration: frame.duration)
            }
            result.append(composited)
            onProgress?(0.5 + 0.5 * Double(index + 1) / total)
        }
        return result
    }

    /// Max number of consecutive failed frames a stale mask may still be reused
    /// for. After this many failures the frame is left uncut, so a subject that
    /// vanished (a hand leaving the shot) stops being painted instead of showing
    /// a lingering ghost silhouette.
    static let maxMaskReuseAge = 3

    /// Assigns each frame the index of the computed mask it should use.
    ///
    /// Anchors are scheduled at `0, stride, 2*stride, …`. A frame in an anchor's
    /// bucket `[anchor, anchor + stride)` uses the most recent anchor at or
    /// before it that succeeded, so a failed anchor's frames reuse the previous
    /// mask (temporal smoothing). Reuse is bounded: once `maxMaskReuseAge`
    /// consecutive frames have failed, those frames are left uncut (`nil`) rather
    /// than showing a stale silhouette. A short leading gap (fewer than
    /// `maxMaskReuseAge` frames before the first success) back-fills that first
    /// mask, but a longer gap is left uncut — no stale mask smeared across it.
    /// Returns all-`nil` only when no anchor succeeded. Pure: no Vision, no
    /// images — unit-testable.
    static func maskAssignments(
        frameCount: Int,
        stride: Int,
        successfulAnchors: [Int]
    ) -> [Int?] {
        guard frameCount > 0, stride > 0 else {
            return Array(repeating: nil, count: max(0, frameCount))
        }
        let succeeded = Set(successfulAnchors)
        var result = [Int?](repeating: nil, count: frameCount)
        // Walk anchor buckets left→right. A successful anchor resets the run of
        // failed frames; a failed bucket reuses the last mask only while the run
        // is shorter than `maxMaskReuseAge`.
        var current: Int?
        var failedFrames = 0
        var anchor = 0
        while anchor < frameCount {
            let end = min(anchor + stride, frameCount)
            if succeeded.contains(anchor) {
                current = anchor
                failedFrames = 0
                for index in anchor..<end { result[index] = anchor }
            } else if let mask = current {
                for index in anchor..<end {
                    if failedFrames < maxMaskReuseAge { result[index] = mask }
                    failedFrames += 1
                }
            }
            anchor += stride
        }
        // Bounded leading back-fill: cover at most `maxMaskReuseAge - 1` frames
        // before the first success so a short gap doesn't flash, but a long
        // leading gap is left uncut.
        if let first = successfulAnchors.min() {
            var index = first - 1
            var distance = 1
            while index >= 0, distance < maxMaskReuseAge, result[index] == nil {
                result[index] = first
                index -= 1
                distance += 1
            }
        }
        return result
    }

    /// Mask value at or below which a pixel is treated as background. Vision's
    /// masks fade out over a soft band around the subject; those faint values
    /// would otherwise composite to near-transparent halo pixels that inflate the
    /// alpha-fit box.
    static let maskThreshold: UInt8 = 16

    /// Zeroes every pixel of a single-channel Vision mask below `threshold`, so
    /// the soft halo (and any faint speck) around the subject is removed before
    /// it is composited. Returns a new 8-bit grayscale `CGImage`, or `nil` if the
    /// mask can't be rendered. Pure pixel pass — unit-testable without Vision.
    static func cleanedMask(_ mask: CGImage, threshold: UInt8 = StickerFactory.maskThreshold) -> CGImage? {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for index in pixels.indices where pixels[index] < threshold {
            pixels[index] = 0
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
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

    /// Holds the detached cut-out task so the caller's cancellation can reach it.
    /// Cancellation requested before the task is stored is remembered and applied
    /// on `store`, closing the create/observe race.
    private final class CancellableCutout: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<[Frame]?, Never>?
        private var cancelled = false

        func store(_ task: Task<[Frame]?, Never>) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { self.task = task }
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
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

    // MARK: - Loading

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
