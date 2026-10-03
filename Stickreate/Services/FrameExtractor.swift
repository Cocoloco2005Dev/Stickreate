import UIKit
import AVFoundation
import ImageIO
import CoreImage
import CoreVideo

/// Turns videos and GIFs into sticker frames.
enum FrameExtractor {
    enum Failure: LocalizedError {
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                "No frames found in this file."
            case .failed(let message):
                message
            }
        }
    }

    // MARK: - Video

    /// Decode tolerance: exact seeks are far too slow for frame sampling.
    private static let frameTolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)

    /// Longest side of a decoded video/GIF frame. Matches the 512 px sticker
    /// canvas, so frames are never decoded larger than the encoder needs.
    private static let frameMaxDimension: CGFloat = CGFloat(Limits.canvas)

    /// Shared Core Image context for converting composed pixel buffers to images.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Loads a video's duration without extracting any frames.
    static func videoDraft(from url: URL) async throws -> VideoDraft {
        let duration = try await loadDuration(of: url)
        return VideoDraft(url: url, duration: duration)
    }

    /// A single still at `time`, with the preferred track transform applied.
    /// Decoded off the main thread; the decode runs in its own autorelease pool.
    static func thumbnail(fromVideoAt url: URL, at time: TimeInterval) async throws -> UIImage? {
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: frameMaxDimension, height: frameMaxDimension)
            generator.requestedTimeToleranceBefore = frameTolerance
            generator.requestedTimeToleranceAfter = frameTolerance
            return autoreleasepool {
                guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { return nil }
                return UIImage(cgImage: cgImage)
            }
        }
        return await task.value
    }

    /// Extracts evenly-spaced frames from the first 10 s of a video, capped at
    /// `maxFrames`. The frame rate is chosen automatically to fill the cap.
    /// `onProgress` is reported on the main queue.
    static func frames(
        fromVideoAt url: URL,
        maxFrames: Int = 30,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [Frame] {
        let duration = try await loadDuration(of: url)
        let span = min(duration, Limits.maxAnimationDuration)
        guard span > 0 else { throw Failure.empty }
        return try await frames(
            fromVideoAt: url,
            range: 0...span,
            fps: 0,
            maxFrames: maxFrames,
            onProgress: onProgress
        )
    }

    /// Extracts frames from a trimmed `range`.
    ///
    /// `fps <= 0` selects an automatic rate that fills `maxFrames` across the
    /// span (30 fps for short clips, lower for long ones). `fps` is otherwise
    /// clamped to 1...30.
    ///
    /// Each frame lasts the actual sampling step `span / count`, so the summed
    /// animation duration always equals the trimmed span even when the frame
    /// count is capped at `maxFrames`. Durations never fall below
    /// `Limits.minFrameDuration`, and at least two frames are emitted for any
    /// positive span so a valid animated payload is always possible.
    ///
    /// `onProgress` is reported on the main queue as each frame is decoded.
    static func frames(
        fromVideoAt url: URL,
        range: ClosedRange<TimeInterval>,
        fps: Double = 0,
        maxFrames: Int = 150,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [Frame] {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        let span = upper - lower
        guard span > 0 else { throw Failure.empty }

        let cap = max(1, maxFrames)
        let requestedFPS = fps > 0 ? min(max(fps, 1), 30) : automaticFPS(span: span, maxFrames: cap)
        let sampled = max(1, min(cap, Int((span * requestedFPS).rounded())))
        // Two frames minimum so the encoder always has a valid animation.
        let count = cap >= 2 ? max(2, sampled) : sampled
        let step = span / Double(count)
        let frameDuration = max(step, Limits.minFrameDuration)

        let times = (0..<count).map {
            CMTime(seconds: lower + step * Double($0), preferredTimescale: 600)
        }
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let task = Task.detached(priority: .userInitiated) {
            // Preferred: one sequential AVAssetReader pass through a video
            // composition (applies preferredTransform, so frames are upright).
            // Falls back to AVAssetImageGenerator if it can't be configured or
            // yields no frames — that path also applies the transform.
            if let sequential = try? await decodeFramesSequentially(
                url: url,
                times: times,
                frameDuration: frameDuration,
                onProgress: onProgress
            ), !sequential.isEmpty {
                return sequential
            }
            return try decodeFrames(
                url: url,
                times: times,
                frameDuration: frameDuration,
                onProgress: onProgress
            )
        }
        var frames = try await task.value

        // If a decoder dropped trailing targets (end-of-clip gap), repeat the
        // last frame so the summed duration still equals the span.
        if frames.count < count, let last = frames.last {
            while frames.count < count {
                frames.append(Frame(image: last.image, duration: frameDuration))
            }
        }
        #if DEBUG
        let total = frames.reduce(0) { $0 + $1.duration }
        let drift = abs(total - span)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print(String(
            format: "[FrameExtractor] %d frames @ %.1fms total %.3fs span %.3fs drift %.1fms in %.0fms",
            frames.count, frameDuration * 1000, total, span, drift * 1000, ms
        ))
        assert(drift < 0.05, "Frame durations must sum to the requested span")
        #endif
        return frames
    }

    /// Automatic frame rate that fills `maxFrames` across `span`, capped at 30.
    private static func automaticFPS(span: TimeInterval, maxFrames: Int) -> Double {
        guard span > 0 else { return 1 }
        return min(30, max(1, Double(max(1, maxFrames)) / span))
    }

    /// Decodes `times` in a single sequential pass, keeping output at or below
    /// the 512 px canvas. One pass, no random seeks.
    ///
    /// Orientation: the reader runs through an `AVAssetReaderVideoCompositionOutput`
    /// whose composition is built with `AVMutableVideoComposition(propertiesOf:)`.
    /// That composition carries a layer instruction per track that applies the
    /// track's `preferredTransform`, so rotated/mirrored sources come out upright.
    /// Decoding raw `AVAssetReaderTrackOutput` buffers and re-applying
    /// `preferredTransform` by hand is what previously produced upside-down
    /// frames. If the composition can't be configured this throws and the caller
    /// falls back to `AVAssetImageGenerator`, which also applies the transform.
    private static func decodeFramesSequentially(
        url: URL,
        times: [CMTime],
        frameDuration: TimeInterval,
        onProgress: ((Double) -> Void)?
    ) async throws -> [Frame] {
        guard let firstTime = times.first, let lastTime = times.last else {
            throw Failure.empty
        }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.failed("No video track.")
        }

        // `propertiesOf:` returns a composition whose instructions apply each
        // track's preferredTransform. If it has no render size or no
        // instructions the transform wouldn't be applied, so we refuse it and
        // let the caller fall back to AVAssetImageGenerator (which also applies
        // the transform). This is what keeps a wrong-orientation path from
        // shipping.
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        guard composition.renderSize.width > 0, composition.renderSize.height > 0,
              !composition.instructions.isEmpty else {
            throw Failure.failed("Couldn't configure a video composition.")
        }
        #if DEBUG
        print(String(
            format: "[FrameExtractor] composition render %.0fx%.0f, %d instructions",
            composition.renderSize.width, composition.renderSize.height,
            composition.instructions.count
        ))
        #endif

        // The composition's render size is already upright; scale it down to the
        // sticker canvas while preserving aspect ratio.
        let target = fittedSize(composition.renderSize, maxDimension: frameMaxDimension)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(target.width),
            kCVPixelBufferHeightKey as String: Int(target.height)
        ]

        let reader = try AVAssetReader(asset: asset)
        let end = CMTimeAdd(lastTime, CMTime(seconds: max(frameDuration, 1.0 / 30.0), preferredTimescale: 600))
        reader.timeRange = CMTimeRange(start: firstTime, end: end)

        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: settings)
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Failure.failed("Reader can't add the video composition output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.failed(reader.error?.localizedDescription ?? "Reader couldn't start.")
        }

        let total = Double(times.count)
        var frames: [Frame] = []
        var next = 0

        while next < times.count, reader.status == .reading,
              let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            // Skip samples before the next target, then reuse this one render for
            // every target that lands in this sample's interval.
            guard CMTimeCompare(times[next], pts) <= 0 else { continue }
            let rendered = CMSampleBufferGetImageBuffer(sample).flatMap { image(from: $0) }
            while next < times.count, CMTimeCompare(times[next], pts) <= 0 {
                if let rendered {
                    frames.append(Frame(image: rendered, duration: frameDuration))
                }
                next += 1
                reportProgress(onProgress, Double(next) / total)
            }
        }
        if reader.status == .reading { reader.cancelReading() }

        guard !frames.isEmpty else { throw Failure.empty }
        reportProgress(onProgress, 1)
        return frames
    }

    /// Renders a composed pixel buffer (already upright) to a `UIImage`.
    private static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Scales `size` down so its longest side is at most `maxDimension`,
    /// preserving aspect ratio.
    private static func fittedSize(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, maxDimension > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return size }
        let ratio = maxDimension / longest
        return CGSize(
            width: max(1, (size.width * ratio).rounded()),
            height: max(1, (size.height * ratio).rounded())
        )
    }

    /// Delivers progress on the main queue.
    private static func reportProgress(_ onProgress: ((Double) -> Void)?, _ value: Double) {
        guard let onProgress else { return }
        if Thread.isMainThread {
            onProgress(value)
        } else {
            DispatchQueue.main.async { onProgress(value) }
        }
    }

    /// Decodes `times` off the main thread. Each decode and conversion runs in
    /// its own autorelease pool so 4K sources never pile up frames in memory.
    private static func decodeFrames(
        url: URL,
        times: [CMTime],
        frameDuration: TimeInterval,
        onProgress: ((Double) -> Void)?
    ) throws -> [Frame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameMaxDimension, height: frameMaxDimension)
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance

        let total = Double(times.count)
        var frames: [Frame] = []
        for (index, time) in times.enumerated() {
            let frame: Frame? = autoreleasepool {
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                let decoded = UIImage(cgImage: cgImage)
                // The generator already caps at frameMaxDimension; only rescale if
                // it didn't (defensive guard, normally a no-op).
                let image = max(decoded.size.width, decoded.size.height) > frameMaxDimension
                    ? decoded.scaled(toMaxDimension: frameMaxDimension)
                    : decoded
                return Frame(image: image, duration: frameDuration)
            }
            if let frame { frames.append(frame) }

            if let onProgress, total > 0 {
                let value = Double(index + 1) / total
                if Thread.isMainThread {
                    onProgress(value)
                } else {
                    DispatchQueue.main.async { onProgress(value) }
                }
            }
        }

        guard !frames.isEmpty else { throw Failure.empty }
        return frames
    }

    /// Asset duration in seconds; `.empty` for a zero/indefinite duration.
    private static func loadDuration(of url: URL) async throws -> TimeInterval {
        do {
            let time = try await AVURLAsset(url: url).load(.duration)
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds > 0 else { throw Failure.empty }
            return seconds
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    /// Extracts frames (with their delays) from GIF data.
    static func frames(fromGIF data: Data, maxFrames: Int = 30) throws -> [Frame] {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.failed("Couldn't read this GIF.")
        }

        let total = CGImageSourceGetCount(source)
        guard total > 0 else { throw Failure.empty }

        let step = max(1, Int(ceil(Double(total) / Double(max(1, maxFrames)))))
        var frames: [Frame] = []
        var index = 0
        while index < total {
            let frame = autoreleasepool { () -> Frame? in
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
                let delay = max(frameDelay(source: source, index: index), Limits.minFrameDuration)
                let image = UIImage(cgImage: cgImage).scaled(toMaxDimension: frameMaxDimension)
                return Frame(image: image, duration: delay)
            }
            if let frame {
                frames.append(frame)
            }
            index += step
        }

        guard !frames.isEmpty else { throw Failure.empty }

        // A one-frame GIF isn't a valid animation; duplicate it.
        if frames.count == 1, let only = frames.first {
            frames.append(Frame(image: only.image, duration: only.duration))
        }
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print(String(format: "[FrameExtractor] gif %d frames in %.0fms", frames.count, ms))
        #endif
        return frames
    }

    /// Per-frame GIF delay, preferring the unclamped value. Defaults to 0.1 s.
    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
            return 0.1
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, unclamped > 0 {
            return unclamped
        }
        if let clamped = gif[kCGImagePropertyGIFDelayTime as String] as? Double, clamped > 0 {
            return clamped
        }
        return 0.1
    }
}
