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
        maxFrames: Int = 240,
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
    /// `fps <= 0` selects an automatic rate targeting ~24 fps, capped by
    /// `maxFrames`. The count is never allowed to collapse: a span of at least
    /// 1 s keeps ≥ 24 frames, shorter spans keep ≥ 8 (and ≥ 2 for a tiny span),
    /// so a video never loses its motion.
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
        maxFrames: Int = 240,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> [Frame] {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        let span = upper - lower
        guard span > 0 else { throw Failure.empty }

        let cap = max(1, maxFrames)
        let requestedFPS = fps > 0 ? min(max(fps, 1), 30) : automaticFPS(span: span, maxFrames: cap)
        let sampled = max(1, min(cap, Int((span * requestedFPS).rounded())))
        // Never collapse to a handful of frames: ≥ 24 for a span of ~1 s or
        // more, ≥ 8 for shorter spans, and the hard floor of 2 only for a span
        // too short to give every frame the 8 ms minimum.
        let usableFloor: Int
        if span >= 1 {
            usableFloor = 24
        } else if span >= Limits.minFrameDuration * 8 {
            usableFloor = 8
        } else {
            usableFloor = 2
        }
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

    /// Automatic frame rate: targets ~24 fps, lowered only when `maxFrames`
    /// can't fit that many frames across the span. Capped at 30.
    private static func automaticFPS(span: TimeInterval, maxFrames: Int) -> Double {
        guard span > 0 else { return 1 }
        return min(24, max(1, Double(max(1, maxFrames)) / span))
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
        // A kept frame represents `step` source frames; sum their delays so
        // downsampling preserves the animation length instead of playing fast.
        // The pure helper keeps this rule unit-testable without a real GIF.
        let keptDelays = downsampledDelays(
            baseDelays: (0..<total).map { frameDelay(source: source, index: $0) },
            step: step
        )
        var frames: [Frame] = []
        var index = 0
        var kept = 0
        while index < total {
            let frame = autoreleasepool { () -> Frame? in
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
                let delay = max(keptDelays[kept], Limits.minFrameDuration)
                let image = UIImage(cgImage: cgImage).scaled(toMaxDimension: frameMaxDimension)
                return Frame(image: image, duration: delay)
            }
            if let frame {
                frames.append(frame)
            }
            index += step
            kept += 1
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

    /// Sums the delays of the source frames each kept (downsampled) frame
    /// represents. Kept frame `k` covers source indices
    /// `k*step ..< min((k+1)*step, baseDelays.count)`; the final group is short
    /// when the count isn't a multiple of `step`. Pure (no GIF decoding), so the
    /// duration-preservation rule is unit-testable on its own. `step <= 1` is the
    /// identity.
    static func downsampledDelays(baseDelays: [TimeInterval], step: Int) -> [TimeInterval] {
        guard step > 1, !baseDelays.isEmpty else { return baseDelays }
        var result: [TimeInterval] = []
        result.reserveCapacity((baseDelays.count + step - 1) / step)
        var index = 0
        while index < baseDelays.count {
            let end = min(index + step, baseDelays.count)
            result.append(baseDelays[index..<end].reduce(0, +))
            index += step
        }
        return result
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
