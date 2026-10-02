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

    /// Longest side of a decoded video frame. Keeps 4K sources from allocating
    /// ~35 MB per frame while still exceeding the 512 pt sticker canvas.
    private static let frameMaxDimension: CGFloat = 512

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
            generator.maximumSize = CGSize(width: 1024, height: 1024)
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
    static func frames(fromVideoAt url: URL, maxFrames: Int = 30) async throws -> [Frame] {
        let duration = try await loadDuration(of: url)
        let span = min(duration, Limits.maxAnimationDuration)
        guard span > 0 else { throw Failure.empty }
        let fps = min(30, max(1, Double(max(1, maxFrames)) / span))
        return try await frames(fromVideoAt: url, range: 0...span, fps: fps, maxFrames: maxFrames)
    }

    /// Extracts frames from a trimmed `range` at `fps` frames per second,
    /// never exceeding `maxFrames`. `fps` is clamped to 1...30 and each frame
    /// lasts `1/fps` (at least `Limits.minFrameDuration`).
    static func frames(
        fromVideoAt url: URL,
        range: ClosedRange<TimeInterval>,
        fps: Double,
        maxFrames: Int = 150
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
        let task = Task.detached(priority: .userInitiated) {
            try decodeFrames(url: url, times: times, frameDuration: frameDuration)
        }
        return try await task.value
    }

    /// Decodes `times` off the main thread. Each decode and conversion runs in
    /// its own autorelease pool so 4K sources never pile up frames in memory.
    private static func decodeFrames(
        url: URL,
        times: [CMTime],
        frameDuration: TimeInterval
    ) throws -> [Frame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = frameTolerance
        generator.requestedTimeToleranceAfter = frameTolerance

        var frames: [Frame] = []
        for time in times {
            let frame: Frame? = autoreleasepool {
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                let image = UIImage(cgImage: cgImage).scaled(toMaxDimension: frameMaxDimension)
                return Frame(image: image, duration: frameDuration)
            }
            if let frame { frames.append(frame) }
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
