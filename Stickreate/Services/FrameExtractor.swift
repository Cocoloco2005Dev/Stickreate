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

    /// Shared Core Image context for applying a track transform to reader output.
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

    /// Extracts evenly-spaced frames from a video, capped at `maxFrames`.
    ///
    /// Only the first 10 s are sampled (WhatsApp's animation ceiling). Frame
    /// rate is derived from `maxFrames` so the loop length matches the span.
    /// `onProgress` is reported on the main queue.
    static func frames(
        fromVideoAt url: URL,
        maxFrames: Int = 30,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [Frame] {
        let duration = try await loadDuration(of: url)
        let span = min(duration, Limits.maxAnimationDuration)
        guard span > 0 else { throw Failure.empty }
        let fps = min(30, max(1, Double(max(1, maxFrames)) / span))
        return try await frames(
            fromVideoAt: url,
            range: 0...span,
            fps: fps,
            maxFrames: maxFrames,
            onProgress: onProgress
        )
    }

    /// Extracts frames from a trimmed `range` at `fps` frames per second,
    /// never exceeding `maxFrames`. `fps` is clamped to 1...30 and each frame
    /// lasts `1/fps` (at least `Limits.minFrameDuration`).
    ///
    /// `onProgress` is reported on the main queue as each frame is decoded.
    static func frames(
        fromVideoAt url: URL,
        range: ClosedRange<TimeInterval>,
        fps: Double,
        maxFrames: Int = 150,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [Frame] {
        let clampedFPS = min(max(fps, 1), 30)
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        let span = upper - lower
        guard span > 0 else { throw Failure.empty }

        let cap = max(1, maxFrames)
        let count = max(1, min(cap, Int((span * clampedFPS).rounded())))
        let step = span / Double(count)
        let frameDuration = max(1 / clampedFPS, Limits.minFrameDuration)

        let times = (0..<count).map {
            CMTime(seconds: lower + step * Double($0), preferredTimescale: 600)
        }
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let task = Task.detached(priority: .userInitiated) {
            // Preferred: one sequential AVAssetReader pass decoding every sample
            // in order. Far cheaper than N independent AVAssetImageGenerator seeks
            // on long/high-resolution clips. Falls back if it can't be configured
            // or yields no frames.
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
        let frames = try await task.value
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print(String(format: "[FrameExtractor] video %d frames in %.0fms", frames.count, ms))
        #endif
        return frames
    }

    /// Decodes `times` in a single sequential pass with `AVAssetReader`, keeping
    /// output at or below the 512 px canvas. The track's `preferredTransform` is
    /// applied to each buffer. One pass, no random seeks.
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
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)

        // Never decode larger than the sticker canvas; aspect is preserved because
        // the requested size is the natural size scaled to fit.
        let target = fittedSize(naturalSize, maxDimension: frameMaxDimension)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(target.width),
            kCVPixelBufferHeightKey as String: Int(target.height)
        ]

        let reader = try AVAssetReader(asset: asset)
        let end = CMTimeAdd(lastTime, CMTime(seconds: max(frameDuration, 1.0 / 30.0), preferredTimescale: 600))
        reader.timeRange = CMTimeRange(start: firstTime, end: end)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Failure.failed("Reader can't add the video output.")
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
            let rendered = CMSampleBufferGetImageBuffer(sample).flatMap {
                image(from: $0, applying: transform)
            }
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

    /// Renders a decoded pixel buffer to an upright `UIImage`, applying the
    /// track transform when it isn't the identity.
    private static func image(from buffer: CVPixelBuffer, applying transform: CGAffineTransform) -> UIImage? {
        let base = CIImage(cvPixelBuffer: buffer)
        let oriented = transform.isIdentity ? base : base.transformed(by: transform)
        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
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
