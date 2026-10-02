import UIKit
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Editable subject mask behind the manual sticker editor.
///
/// Holds the upright base image plus a mutable 8-bit grayscale keep/remove mask.
/// State is main-actor isolated; strokes mutate the mask synchronously and the
/// composited preview is rebuilt off the main actor, then published on it.
@MainActor
@Observable
final class MaskEditor {
    /// Upright original image.
    let base: UIImage
    /// `base` composited through the current mask.
    private(set) var preview: UIImage

    /// Brush radius as a fraction of the shorter side (clamped 0.02...0.3).
    var brushRadius: CGFloat = 0.08

    var canUndo: Bool { !undoStack.isEmpty }

    private let pixelWidth: Int
    private let pixelHeight: Int
    private var maskData: [UInt8]
    private let seededMask: [UInt8]
    private var undoStack: [[UInt8]] = []

    /// Guards against out-of-order preview publishes during fast strokes.
    private var previewGeneration = 0
    private var lastPreviewRefresh: CFTimeInterval = 0

    // ponytail: bounded by count and total bytes; switch to region-diff snapshots
    // if editing very large photos becomes common.
    private let maxUndoCount = 20
    private let maxUndoBytes = 96 * 1024 * 1024

    /// - Parameter mask: Vision's subject mask; `nil` starts with everything kept.
    init(base: UIImage, mask: CGImage?) {
        self.base = base
        let cgImage = base.cgImage
        let width = max(1, cgImage?.width ?? Int((base.size.width * base.scale).rounded()))
        let height = max(1, cgImage?.height ?? Int((base.size.height * base.scale).rounded()))
        self.pixelWidth = width
        self.pixelHeight = height

        let seeded = mask.map { MaskCompositor.seed(bytesFrom: $0, width: width, height: height) }
            ?? [UInt8](repeating: 255, count: width * height)
        self.seededMask = seeded
        self.maskData = seeded
        self.preview = base

        refreshPreview()
    }

    // MARK: - Editing

    /// Snapshots the mask so the following stroke can be undone as one step.
    func beginStroke() {
        pushUndo()
    }

    /// Paints along a segment whose points are normalized 0...1 over `base`.
    /// `restoring == true` paints keep (white); `false` paints remove (black).
    func stroke(from: CGPoint, to: CGPoint, restoring: Bool) {
        let fraction = min(max(brushRadius, 0.02), 0.3)
        let radius = fraction * CGFloat(min(pixelWidth, pixelHeight))
        let value: UInt8 = restoring ? 255 : 0

        let start = CGPoint(x: from.x * CGFloat(pixelWidth), y: from.y * CGFloat(pixelHeight))
        let end = CGPoint(x: to.x * CGFloat(pixelWidth), y: to.y * CGFloat(pixelHeight))
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let spacing = max(1, radius * 0.5)
        let steps = max(1, Int((distance / spacing).rounded(.up)))

        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            paint(at: CGPoint(x: start.x + dx * t, y: start.y + dy * t), radius: radius, value: value)
        }

        // Live feedback while dragging, throttled to ~30 fps.
        refreshPreviewThrottled()
    }

    /// Rebuilds the preview from the finished stroke.
    func endStroke() {
        refreshPreview()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        maskData = previous
        refreshPreview()
    }

    /// Restores the mask seeded at init time.
    func reset() {
        maskData = seededMask
        undoStack.removeAll()
        refreshPreview()
    }

    /// Composites `base` through the mask and crops to a normalized rect
    /// (`nil` = full frame). The rect uses the top-left origin convention.
    func render(croppedTo cropRect: CGRect?) -> UIImage? {
        guard let image = MaskCompositor.composite(
            base: base,
            maskBytes: maskData,
            width: pixelWidth,
            height: pixelHeight
        ) else { return nil }

        guard let cropRect, let cgImage = image.cgImage else { return image }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let rect = CGRect(
            x: cropRect.origin.x * width,
            y: cropRect.origin.y * height,
            width: cropRect.width * width,
            height: cropRect.height * height
        ).intersection(bounds)

        guard !rect.isEmpty, let cropped = cgImage.cropping(to: rect.integral) else { return image }
        return UIImage(cgImage: cropped)
    }

    // MARK: - Painting

    private func paint(at center: CGPoint, radius: CGFloat, value: UInt8) {
        guard radius > 0 else { return }
        let minX = max(0, Int(center.x - radius))
        let maxX = min(pixelWidth - 1, Int(center.x + radius))
        let minY = max(0, Int(center.y - radius))
        let maxY = min(pixelHeight - 1, Int(center.y + radius))
        guard minX <= maxX, minY <= maxY else { return }

        let radiusSquared = radius * radius
        for y in minY...maxY {
            let dy = CGFloat(y) + 0.5 - center.y
            let row = y * pixelWidth
            for x in minX...maxX {
                let dx = CGFloat(x) + 0.5 - center.x
                if dx * dx + dy * dy <= radiusSquared {
                    maskData[row + x] = value
                }
            }
        }
    }

    private func pushUndo() {
        undoStack.append(maskData)
        while undoStack.count > maxUndoCount
            || undoStack.reduce(0, { $0 + $1.count }) > maxUndoBytes {
            undoStack.removeFirst()
        }
    }

    /// Refreshes the preview at most ~30 times per second during a stroke.
    private func refreshPreviewThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastPreviewRefresh >= 1.0 / 30.0 else { return }
        lastPreviewRefresh = now
        refreshPreview()
    }

    /// Rebuilds the composited preview off the main actor, then publishes it.
    /// Stale results from a superseded stroke are dropped.
    private func refreshPreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        let bytes = maskData
        let base = self.base
        let width = pixelWidth
        let height = pixelHeight
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = MaskCompositor.composite(base: base, maskBytes: bytes, width: width, height: height)
            guard let image else { return }
            await MainActor.run {
                guard let self, self.previewGeneration == generation else { return }
                self.preview = image
            }
        }
    }
}

/// Nonisolated pixel helpers so compositing can run off the main thread.
private enum MaskCompositor {
    static let context = CIContext()

    /// Renders `mask` into a top-left row-major grayscale buffer of `width`×`height`.
    static func seed(bytesFrom mask: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }

            // Flip so buffer row 0 is the top row, matching `maskData`.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// `base` where the mask is white, transparent where it is black.
    static func composite(base: UIImage, maskBytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let baseImage = CIImage(image: base),
              let maskImage = maskCGImage(bytes: maskBytes, width: width, height: height) else {
            return nil
        }

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: baseImage.extent)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = baseImage
        filter.backgroundImage = clear
        filter.maskImage = CIImage(cgImage: maskImage)

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: baseImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func maskCGImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count >= width * height,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
