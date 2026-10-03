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

    /// Budget for animated stickers. WhatsApp enforces ~500 KB, so keep headroom.
    private static let animatedByteBudget = 450 * 1024

    /// Short quality ladder for animated WebP. The first pass over this ladder
    /// runs with libwebp's fast defaults; only the single best (smallest)
    /// candidate is re-encoded with the slow settings.
    private static let animatedQualities: [Double] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

    /// libwebp method/pass. Method 4 is the encoder default (fast); the slow
    /// method/pass pair buys size at a large CPU cost, so it runs at most once.
    private static let fastMethod = 4
    private static let fastPass = 1
    private static let escalatedMethod = 6
    private static let escalatedPass = 10

    /// Animated sticker from frames. Compresses hard on the full frame set first;
    /// only if that can't fit the 450 KB budget does it drop frames (keeping ≥ 2).
    ///
    /// The canvas stays exactly 512×512 (a WhatsApp requirement — dimensions are
    /// never reduced). Requires at least two frames; one frame is not a valid
    /// animated payload.
    static func animatedSticker(from frames: [Frame], loopCount: Int = 0) -> Data? {
        guard frames.count >= 2 else { return nil }
        let prepared = prepare(frames)
        guard prepared.count >= 2 else { return nil }

        let loop = UInt(max(0, loopCount))

        // Compress harder before dropping any frames.
        if let data = encodeAnimated(prepared, loopCount: loop) {
            return data
        }

        // Quality alone wasn't enough: drop frames, never below two.
        var attempted = Set<Int>([prepared.count])
        for candidate in frameLadder(prepared) {
            guard candidate.count >= 2, attempted.insert(candidate.count).inserted else { continue }
            if let data = encodeAnimated(candidate, loopCount: loop) {
                return data
            }
        }
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

    /// Encodes `frames` as animated WebP.
    ///
    /// Fast path first: walks the quality ladder with libwebp's fast method/pass
    /// (method 4, 1 pass) and returns the first result within budget. Only if no
    /// rung fits does it re-encode the single smallest candidate once with the
    /// slow settings (method 6, 10 passes). Each attempt runs in its own
    /// autorelease pool so peak memory stays flat.
    private static func encodeAnimated(_ frames: [Frame], loopCount: UInt) -> Data? {
        let sdFrames = frames.map { SDImageFrame(image: $0.image, duration: $0.duration) }

        var smallest: Data?
        var smallestQuality: Double?

        for quality in animatedQualities {
            let data = encodeAnimated(
                sdFrames,
                loopCount: loopCount,
                quality: quality,
                method: fastMethod,
                pass: fastPass
            )
            guard let data else { continue }
            if data.count <= animatedByteBudget {
                return data
            }
            if smallest == nil || data.count < smallest!.count {
                smallest = data
                smallestQuality = quality
            }
        }

        // Nothing fit at fast settings: one last, slow attempt on the smallest
        // candidate only (never re-encode every rung at method 6).
        guard let quality = smallestQuality else { return nil }
        let data = encodeAnimated(
            sdFrames,
            loopCount: loopCount,
            quality: quality,
            method: escalatedMethod,
            pass: escalatedPass
        )
        if let data, data.count <= animatedByteBudget {
            return data
        }
        return nil
    }

    /// Runs one animated encode attempt in its own autorelease pool and logs its
    /// duration under `#if DEBUG`. Bytes/duration only — never frame content.
    private static func encodeAnimated(
        _ frames: [SDImageFrame],
        loopCount: UInt,
        quality: Double,
        method: Int,
        pass: Int
    ) -> Data? {
        let options: [SDImageCoderOption: Any] = [
            .encodeCompressionQuality: quality,
            .encodeWebPMethod: method,
            .encodeWebPPass: pass,
            .encodeWebPThreadLevel: 1,
            .encodeWebPAlphaQuality: 60
        ]
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif
        let data = autoreleasepool { () -> Data? in
            SDImageWebPCoder.shared.encodedData(
                with: frames,
                loopCount: loopCount,
                format: .webP,
                options: options
            )
        }
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print(String(
            format: "[StickerEncoder] animated q=%.2f method=%d pass=%d %.0fms -> %d bytes",
            quality, method, pass, ms, data?.count ?? 0
        ))
        #endif
        return data
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

    /// Progressively fewer frames: every 2nd, then 12, 9, 6 — never the full set
    /// (the caller tries that first) and never below two.
    private static func frameLadder(_ frames: [Frame]) -> [[Frame]] {
        var counts = Set<Int>()
        if frames.count > 2 { counts.insert(frames.count / 2) }
        [12, 9, 6].forEach { counts.insert($0) }
        let valid = counts.filter { $0 >= 2 && $0 < frames.count }.sorted(by: >)
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
