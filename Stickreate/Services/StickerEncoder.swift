import UIKit
import SDWebImage
import SDWebImageWebPCoder

/// Encodes artwork into WhatsApp-compliant WebP.
///
/// Budgets (WhatsApp, iOS): static ≤ 100 KB, animated ≤ 500 KB,
/// frames ≥ 8 ms, total animation ≤ 10 s, canvas exactly 512×512.
enum StickerEncoder {
    // MARK: - Static

    /// 512×512 static sticker. Must shrink quality until it fits 100 KB.
    static func staticSticker(from image: UIImage) -> Data? {
        guard let canvas = aspectFit(image, in: canvasSize) else { return nil }
        return encode(canvas, maxBytes: Limits.maxStaticBytes)
    }

    // MARK: - Animated

    /// Target budget for animated stickers. WhatsApp enforces a 500 KB hard cap;
    /// aim just under it so we can keep as many frames as possible.
    private static let animatedByteBudget = 480 * 1024

    /// Quality ladder (libwebp 0...100), walked top-down before ANY frames are
    /// dropped. The native animated encoder exploits inter-frame redundancy, so
    /// lowering quality is cheaper (and keeps more motion) than dropping frames.
    private static let animatedQualities: [Float] = [90, 80, 70, 60, 50, 40, 30, 25]

    /// libwebp animated method. Method 4 is the fast default; the native encoder
    /// already exploits inter-frame redundancy, so an expensive method is not
    /// worth the CPU here.
    private static let animatedMethod = 4

    /// Fallback per-frame settings (SDWebImageWebPCoder), used only if the
    /// native C encoder returns nil so we never regress to no sticker.
    private static let fallbackMethod = 4
    private static let fallbackPass = 1

    /// Animated sticker from frames, using libwebp's native `WebPAnimEncoder`
    /// (inter-frame compression) via `WebPAnimationEncoder`.
    ///
    /// Quality first: the full frame set is walked down the whole quality ladder
    /// before ANY frames are dropped. Only if the lowest quality still exceeds
    /// the budget are frames dropped — gently, keeping ~75% then ~50%, never
    /// below `minFramesAfterDrop` (or half the set, whichever is larger). Falls
    /// back to the per-frame static encoder only when the C encoder itself fails.
    ///
    /// The canvas stays exactly 512×512 (a WhatsApp requirement — dimensions are
    /// never reduced). Requires at least two frames; one frame is not a valid
    /// animated payload.
    ///
    /// When `targetDuration` is provided, frame durations are distributed as
    /// whole milliseconds that sum to `targetDuration`. `onProgress` reports a
    /// monotonic `0...1` fraction across frames and attempts, ending at 1.0.
    static func animatedSticker(
        from frames: [Frame],
        loopCount: Int = 0,
        targetDuration: TimeInterval? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) -> Data? {
        guard frames.count >= 2 else { return nil }
        let prepared = prepare(frames)
        guard prepared.count >= 2 else { return nil }

        let loop = max(0, loopCount)

        // Full frame set first, then gently fewer frames (never below 2).
        var candidates: [[Frame]] = [prepared]
        candidates.append(contentsOf: frameLadder(prepared))

        // Worst-case progress schedule: every candidate at every quality. Each
        // attempt reports its per-frame fraction; the bar is clamped below 1.0
        // and jumps to exactly 1.0 only once a payload is actually returned.
        let plannedAttempts = max(1, candidates.count * animatedQualities.count)
        var attempt = 0
        func report(_ frameFraction: Double) {
            let progress = (Double(attempt) + frameFraction) / Double(plannedAttempts)
            onProgress?(min(0.999, progress))
        }

        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif

        for candidate in candidates {
            let durations = targetMilliseconds(candidate, targetDuration: targetDuration)
            let images = candidate.map(\.image)
            for quality in animatedQualities {
                let options = WebPAnimationEncoder.Options(
                    quality: quality,
                    method: animatedMethod,
                    keyframeInterval: 10,
                    loopCount: loop,
                    minimizeSize: true
                )
                let data = WebPAnimationEncoder.encode(
                    frames: images,
                    durationsMs: durations,
                    options: options,
                    onProgress: report
                ) ?? encodeAnimatedFallback(
                    images: images,
                    durationsMs: durations,
                    loopCount: loop,
                    quality: Double(quality) / 100.0
                )
                attempt += 1
                // 480 KB target is below the 500 KB hard cap, so this also
                // guarantees WhatsApp compliance.
                if let data, data.count <= animatedByteBudget {
                    #if DEBUG
                    let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                    print(String(
                        format: "[StickerEncoder] animated %d frames q=%d %.0fms -> %d bytes",
                        images.count, Int(quality), ms, data.count
                    ))
                    #endif
                    onProgress?(1.0)
                    return data
                }
            }
        }

        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[StickerEncoder] animated failed after \(Int(ms.rounded()))ms (kept ≥ \(minFramesAfterDrop) frames)")
        #endif
        onProgress?(1.0)
        return nil
    }

    // MARK: - Tray & preview

    /// 96×96 PNG tray icon, ≤ 50 KB.
    static func trayIcon(from image: UIImage) -> Data? {
        let side = CGFloat(Limits.traySize)
        guard let canvas = aspectFit(image, in: CGSize(width: side, height: side)),
              let data = canvas.pngData() else { return nil }
        return data.count <= Limits.maxTrayBytes ? data : nil
    }

    /// Square PNG preview for the app UI.
    static func previewPNG(from image: UIImage, size: CGFloat) -> Data? {
        guard size > 0,
              let canvas = aspectFit(image, in: CGSize(width: size, height: size)) else { return nil }
        return canvas.pngData()
    }

    // MARK: - Encoding

    /// Tries `.encodeCompressionQuality` from 1.0 down to 0.3 in 0.05 steps,
    /// returning the first WebP that fits `maxBytes`.
    private static func encode(_ image: UIImage, maxBytes: Int) -> Data? {
        for step in 0...14 {
            let quality = 1.0 - Double(step) * 0.05
            let data = autoreleasepool { () -> Data? in
                SDImageWebPCoder.shared.encodedData(
                    with: image,
                    format: .webP,
                    options: [.encodeCompressionQuality: quality]
                )
            }
            if let data, data.count <= maxBytes {
                return data
            }
        }
        return nil
    }

    /// Fallback used only when the native C animated encoder returns nil.
    ///
    /// Reuses the previous per-frame static WebP path (no inter-frame
    /// compression) so a libwebp failure degrades in size/speed but never in
    /// correctness. Runs in its own autorelease pool. Durations carry the
    /// sub-microsecond epsilon SDWebImageWebPCoder needs for exact
    /// `int(duration * 1000)` truncation.
    private static func encodeAnimatedFallback(
        images: [UIImage],
        durationsMs: [Int],
        loopCount: Int,
        quality: Double
    ) -> Data? {
        let sdFrames = zip(images, durationsMs).map { image, ms in
            SDImageFrame(image: image, duration: Double(ms) / 1000.0 + 1e-9)
        }
        let options: [SDImageCoderOption: Any] = [
            .encodeCompressionQuality: quality,
            .encodeWebPMethod: fallbackMethod,
            .encodeWebPPass: fallbackPass,
            .encodeWebPThreadLevel: 1,
            .encodeWebPAlphaQuality: 60
        ]
        return autoreleasepool { () -> Data? in
            SDImageWebPCoder.shared.encodedData(
                with: sdFrames,
                loopCount: UInt(max(0, loopCount)),
                format: .webP,
                options: options
            )
        }
    }

    // MARK: - Frame preparation

    /// Draws every frame on the 512×512 canvas, clamps durations to the 8 ms
    /// floor and scales the whole animation down to the 10 s ceiling.
    private static func prepare(_ frames: [Frame]) -> [Frame] {
        var prepared = frames.compactMap { frame -> Frame? in
            autoreleasepool { () -> Frame? in
                guard let canvas = aspectFit(frame.image, in: canvasSize) else { return nil }
                return Frame(image: canvas, duration: max(frame.duration, Limits.minFrameDuration))
            }
        }

        let total = prepared.reduce(0) { $0 + $1.duration }
        guard total > Limits.maxAnimationDuration else { return prepared }

        // Proportionally scale durations to fit 10 s.
        let scale = Limits.maxAnimationDuration / total
        prepared = prepared.map { Frame(image: $0.image, duration: $0.duration * scale) }

        // If scaling pushed a frame below the 8 ms floor, drop the shortest ones.
        if prepared.contains(where: { $0.duration < Limits.minFrameDuration }) {
            prepared = prepared.filter { $0.duration >= Limits.minFrameDuration }
        }
        return prepared
    }

    /// Frame durations as whole milliseconds. With a `targetDuration` the
    /// millisecond values sum exactly to it (never below the 8 ms floor); without
    /// one, each duration is truncated to milliseconds and clamped to the floor.
    private static func targetMilliseconds(_ frames: [Frame], targetDuration: TimeInterval?) -> [Int] {
        let floorMs = Int((Limits.minFrameDuration * 1000).rounded())
        guard let targetDuration, !frames.isEmpty else {
            return frames.map { max(floorMs, Int($0.duration * 1000 + 1e-6)) }
        }

        let count = frames.count
        let floorTotal = count * floorMs
        let requestedMs = Int((min(max(targetDuration, 0), Limits.maxAnimationDuration) * 1000).rounded())
        let totalMs = max(requestedMs, floorTotal)
        guard totalMs > 0 else { return Array(repeating: floorMs, count: count) }

        let base = totalMs / count
        let remainder = totalMs % count
        let result = (0..<count).map { base + ($0 < remainder ? 1 : 0) }
        #if DEBUG
        assert(result.reduce(0, +) == totalMs, "Animated frame durations must sum to the target")
        #endif
        return result
    }

    /// Frame count the size-budget ladder must never drop below. Drops are
    /// gentle — keep ~75%, then ~50% — but never below this (or half the set,
    /// whichever is larger), so a video never loses its motion. The hard floor
    /// of 2 still applies upstream (a valid animation needs ≥ 2).
    private static let minFramesAfterDrop = 24

    /// Gentle frame-drop ladder: ~75%, then ~50%, then the floor. Empty when the
    /// set is already at or below the floor (then only the full set is used).
    private static func frameLadder(_ frames: [Frame]) -> [[Frame]] {
        let count = frames.count
        guard count > 2 else { return [] }
        let floor = min(count, max(minFramesAfterDrop, count / 2))
        var counts = Set<Int>()
        counts.insert(Int((Double(count) * 0.75).rounded()))
        counts.insert(max(floor, Int((Double(count) * 0.5).rounded())))
        counts.insert(floor)
        let valid = counts
            .filter { $0 >= max(2, floor) && $0 < count }
            .sorted(by: >)
        return valid.map { resample(frames, to: $0) }
    }

    /// Picks `count` evenly-spaced frames and spreads the total duration across
    /// them, preserving the overall animation length.
    private static func resample(_ frames: [Frame], to count: Int) -> [Frame] {
        guard count >= 1, frames.count > count else { return frames }
        let total = frames.reduce(0) { $0 + $1.duration }
        let step = Double(frames.count) / Double(count)
        let duration = total / Double(count)
        return (0..<count).map { index in
            let source = frames[min(frames.count - 1, Int(Double(index) * step))]
            return Frame(image: source.image, duration: duration)
        }
    }

    // MARK: - Drawing

    private static let canvasSize = CGSize(
        width: CGFloat(Limits.canvas),
        height: CGFloat(Limits.canvas)
    )

    /// Redraws `image` aspect-fit (contain), centred, on a transparent square
    /// canvas of exactly `size` pixels. No border, stroke or background.
    private static func aspectFit(_ image: UIImage, in size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let source = image.upNormalized() ?? image
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1 // pixel-exact canvas
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

extension UIImage {
    /// Returns a copy with `.up` orientation so downstream pixel work is upright.
    func upNormalized() -> UIImage? {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Returns a copy whose longest side is at most `maxDimension` pixels.
    /// Returns `self` when already small enough.
    func scaled(toMaxDimension maxDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard maxDimension > 0, longest > maxDimension else { return self }

        let ratio = maxDimension / longest
        let target = CGSize(
            width: max(1, (pixelWidth * ratio).rounded()),
            height: max(1, (pixelHeight * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
