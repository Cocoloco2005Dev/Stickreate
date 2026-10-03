import UIKit
import AVFoundation
import ImageIO

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

    /// Loads a video's duration without extracting any frames.
    static func videoDraft(from url: URL) async throws -> VideoDraft {
        let duration = try await loadDuration(of: url)
        return VideoDraft(url: url, duration: duration)
    }

    /// A single still at `time`, with the preferred track transform applied by
    /// `AVAssetImageGenerator`. Decoded off the main thread.
    static func thumbnail(fromVideoAt url: URL, at time: TimeInterval) async throws -> UIImage? {
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let generator = makeGenerator(for: url)
            guard let result = try? await generator.image(at: cmTime) else { return nil }
            return autoreleasepool { UIImage(cgImage: result.image) }
        }
        return await task.value
    }

    /// A generator configured to apply the preferred track transform (so frames
    /// are upright) and to decode no larger than the 512 px canvas.
    ///
    /// This is Apple's canonical path for stills from video; the custom
    /// `AVAssetReaderVideoCompositionOutput` approach was removed because it
    /// produced upside-down frames.
    private static func makeGenerator(for url: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameMaxDimension, height: frameMaxDimension)
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance
        return generator
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

    /// Extracts frames from a trimmed `range` using `AVAssetImageGenerator`
    /// (`appliesPreferredTrackTransform = true`), so frames are always upright.
    ///
    /// `fps <= 0` selects an automatic rate (targeting ~15 fps, lower for long
    /// spans) and the count is capped at `maxFrames`. The count is kept at a
    /// usable minimum of 8 frames whenever the span can afford it (8 × 8 ms),
    /// never below 2.
    ///
    /// Each frame lasts the actual sampling step `span / count`, so the summed
    /// animation duration always equals the trimmed span even when the frame
    /// count is capped. Durations never fall below `Limits.minFrameDuration`.
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
        // Keep a usable frame count (≥ 8) unless the span is too short to give
        // each frame the 8 ms floor; then the hard floor is 2.
        let usableFloor = span >= Limits.minFrameDuration * 8 ? 8 : 2
        let count = cap >= 2 ? min(cap, max(usableFloor, sampled)) : sampled
        let step = span / Double(count)
        let frameDuration = max(step, Limits.minFrameDuration)

        let times = (0..<count).map {
            CMTime(seconds: lower + step * Double($0), preferredTimescale: 600)
        }
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let task = Task.detached(priority: .userInitiated) {
            try await decodeFrames(
                url: url,
                times: times,
                frameDuration: frameDuration,
                onProgress: onProgress
            )
        }
        var frames = try await task.value

        // If a decode failed for trailing targets, repeat the last frame so the
        // summed duration still equals the span.
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

    /// Automatic frame rate: ~15 fps for short clips, lower for long ones so the
    /// count stays within `maxFrames`. Capped at 30.
    private static func automaticFPS(span: TimeInterval, maxFrames: Int) -> Double {
        guard span > 0 else { return 1 }
        return min(15, max(1, Double(max(1, maxFrames)) / span))
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

    /// Decodes `times` off the main thread with `AVAssetImageGenerator`
    /// (`appliesPreferredTrackTransform = true`, so frames are upright). Each
    /// decode runs in its own autorelease pool so frames never pile up.
    private static func decodeFrames(
        url: URL,
        times: [CMTime],
        frameDuration: TimeInterval,
        onProgress: ((Double) -> Void)?
    ) async throws -> [Frame] {
        let generator = makeGenerator(for: url)
        let total = Double(times.count)
        var frames: [Frame] = []
        frames.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            if let result = try? await generator.image(at: time) {
                let frame = autoreleasepool {
                    Frame(image: UIImage(cgImage: result.image), duration: frameDuration)
                }
                frames.append(frame)
            }
            reportProgress(onProgress, total > 0 ? Double(index + 1) / total : 1)
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
