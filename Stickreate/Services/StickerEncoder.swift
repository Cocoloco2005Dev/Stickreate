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

    /// Animated sticker from frames. Must respect the 500 KB total budget by
    /// lowering quality and, if needed, dropping frames — then honour the
    /// 8 ms / 10 s limits.
    static func animatedSticker(from frames: [Frame], loopCount: Int = 0) -> Data? {
        let prepared = prepare(frames)
        guard !prepared.isEmpty else { return nil }

        let loop = UInt(max(0, loopCount))
        var attempted = Set<Int>()
        for candidate in frameLadder(prepared) {
            guard attempted.insert(candidate.count).inserted else { continue }
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
            if let data = SDImageWebPCoder.shared.encodedData(
                with: image,
                format: .webP,
                options: [.encodeCompressionQuality: quality]
            ), data.count <= maxBytes {
                return data
            }
        }
        return nil
    }

    /// Same quality ladder as `encode`, but for the animated WebP API. There is
    /// no total-size option, so the caller checks `data.count` against the budget.
    private static func encodeAnimated(_ frames: [Frame], loopCount: UInt) -> Data? {
        let sdFrames = frames.map { SDImageFrame(image: $0.image, duration: $0.duration) }
        for step in 0...14 {
            let quality = 1.0 - Double(step) * 0.05
            if let data = SDImageWebPCoder.shared.encodedData(
                with: sdFrames,
                loopCount: loopCount,
                format: .webP,
                options: [.encodeCompressionQuality: quality]
            ), data.count <= Limits.maxAnimatedBytes {
                return data
            }
        }
        return nil
    }

    // MARK: - Frame preparation

    /// Draws every frame on the 512×512 canvas, clamps durations to the 8 ms
    /// floor and scales the whole animation down to the 10 s ceiling.
    private static func prepare(_ frames: [Frame]) -> [Frame] {
        var prepared = frames.compactMap { frame -> Frame? in
            guard let canvas = aspectFit(frame.image, in: canvasSize) else { return nil }
            return Frame(image: canvas, duration: max(frame.duration, Limits.minFrameDuration))
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

    /// Full frames first, then progressively fewer (every 2nd, 12, 9, 6).
    private static func frameLadder(_ frames: [Frame]) -> [[Frame]] {
        var ladder: [[Frame]] = [frames]
        var counts = Set<Int>()
        if frames.count > 1 { counts.insert(frames.count / 2) }
        [12, 9, 6].forEach { counts.insert($0) }
        let valid = counts.filter { $0 >= 1 && $0 < frames.count }.sorted(by: >)
        ladder.append(contentsOf: valid.map { resample(frames, to: $0) })
        return ladder
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
}
