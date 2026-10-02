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

    /// Extracts evenly-spaced frames from a video, capped at `maxFrames`.
    ///
    /// Only the first 10 s are sampled (WhatsApp's animation ceiling), and frame
    /// duration is the sampled span divided by the number of frames.
    static func frames(fromVideoAt url: URL, maxFrames: Int = 30) async throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw Failure.empty }

        let span = min(seconds, Limits.maxAnimationDuration)
        let count = max(1, maxFrames)
        let frameDuration = span / Double(count)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [Frame] = []
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * frameDuration, preferredTimescale: 600)
            let result = try? await generator.image(at: time)
            guard let cgImage = result?.image else { continue }
            frames.append(Frame(image: UIImage(cgImage: cgImage), duration: frameDuration))
        }

        guard !frames.isEmpty else { throw Failure.empty }
        return frames
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
            if let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) {
                let delay = max(frameDelay(source: source, index: index), Limits.minFrameDuration)
                frames.append(Frame(image: UIImage(cgImage: cgImage), duration: delay))
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
