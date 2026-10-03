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
    /// Upright original image, downscaled to the `maxDimension` cap.
    let base: UIImage
    /// `base` composited through the current mask.
    private(set) var preview: UIImage

    /// True when Vision supplied a subject mask at init.
    private(set) var hasSubject: Bool

    /// Brush radius as a fraction of the shorter side (clamped 0.02...0.3).
    var brushRadius: CGFloat = 0.08

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private let pixelWidth: Int
    private let pixelHeight: Int
    private var maskData: [UInt8]
    /// All-white mask (keep everything).
    private let whiteMask: [UInt8]
    /// Vision's subject mask, when one was supplied.
    private let subjectMask: [UInt8]?
    /// Whether the subject cut-out is currently in use.
    private var backgroundRemoved: Bool
    /// Vision's per-instance masks keyed by 1-based instance id, in editor pixels.
    private var instanceMasks: [Int: [UInt8]] = [:]
    /// Selected instance ids; empty means the whole image is kept.
    private(set) var selectedInstanceIDs: Set<Int> = []
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []

    /// Guards against out-of-order preview publishes during fast strokes.
    private var previewGeneration = 0
    private var lastPreviewRefresh: CFTimeInterval = 0

    // ponytail: bounded by count and total bytes; switch to region-diff snapshots
    // if editing very large photos becomes common.
    private let maxUndoCount = 20
    private let maxUndoBytes = 96 * 1024 * 1024

    /// - Parameters:
    ///   - mask: Vision's subject mask; `nil` starts with everything kept.
    ///   - maxDimension: longest side the base image is downscaled to so all
    ///     mask/composite work stays cheap.
    init(base: UIImage, mask: CGImage?, maxDimension: Int = 1024) {
        let scaledBase = base.scaled(toMaxDimension: CGFloat(maxDimension))
        self.base = scaledBase

        let cgImage = scaledBase.cgImage
        let width = max(1, cgImage?.width ?? Int((scaledBase.size.width * scaledBase.scale).rounded()))
        let height = max(1, cgImage?.height ?? Int((scaledBase.size.height * scaledBase.scale).rounded()))
        self.pixelWidth = width
        self.pixelHeight = height

        let white = [UInt8](repeating: 255, count: width * height)
        let subject = mask.map { MaskCompositor.seed(bytesFrom: $0, width: width, height: height) }
        self.whiteMask = white
        self.subjectMask = subject
        self.hasSubject = subject != nil
        self.backgroundRemoved = subject != nil
        self.maskData = subject ?? white
        self.preview = scaledBase

        refreshPreview()
    }

    /// Builds an editor seeded with Vision's per-instance masks. Starts with
    /// every instance selected (the combined subject mask).
    convenience init(
        base: UIImage,
        instances: [BackgroundRemover.SubjectInstance],
        maxDimension: Int = 1024
    ) {
        self.init(base: base, mask: MaskEditor.combinedMask(instances), maxDimension: maxDimension)
        for instance in instances {
            instanceMasks[instance.id] = MaskCompositor.seed(
                bytesFrom: instance.mask,
                width: pixelWidth,
                height: pixelHeight
            )
        }
        selectedInstanceIDs = Set(instances.map(\.id))
    }

    /// Union of the instance masks as one grayscale image (`nil` when empty).
    private static func combinedMask(_ instances: [BackgroundRemover.SubjectInstance]) -> CGImage? {
        guard !instances.isEmpty else { return nil }
        let width = instances.map { $0.mask.width }.max() ?? 0
        let height = instances.map { $0.mask.height }.max() ?? 0
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            context.setBlendMode(.lighten) // union = per-pixel max
            for instance in instances {
                context.draw(instance.mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return MaskCompositor.maskCGImage(bytes: bytes, width: width, height: height)
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
        redoStack.append(maskData)
        maskData = previous
        refreshPreview()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(maskData)
        maskData = next
        refreshPreview()
    }

    /// Fills a normalized top-left rect. `removing == true` paints black
    /// (remove); `false` paints white (keep).
    func selectRectangle(_ rect: CGRect, removing: Bool) {
        pushUndo()
        rasterize { context in
            context.setFillColor(gray: removing ? 0 : 1, alpha: 1)
            context.fill(CGRect(
                x: rect.minX * CGFloat(pixelWidth),
                y: (1 - rect.maxY) * CGFloat(pixelHeight),
                width: rect.width * CGFloat(pixelWidth),
                height: rect.height * CGFloat(pixelHeight)
            ))
        }
        refreshPreview()
    }

    /// Fills a normalized top-left polygon (at least three points). Same
    /// keep/remove semantics as `selectRectangle`.
    func selectLasso(_ points: [CGPoint], removing: Bool) {
        guard points.count >= 3 else { return }
        pushUndo()
        rasterize { context in
            context.setFillColor(gray: removing ? 0 : 1, alpha: 1)
            let path = CGMutablePath()
            for (index, point) in points.enumerated() {
                let mapped = CGPoint(
                    x: point.x * CGFloat(pixelWidth),
                    y: (1 - point.y) * CGFloat(pixelHeight)
                )
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.addLine(to: mapped)
                }
            }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        refreshPreview()
    }

    /// Rebuilds the keep mask as the union of the selected instances' masks.
    /// An empty selection keeps everything. Pushes an undo step and refreshes.
    func setInstances(_ ids: Set<Int>) {
        let valid = ids.filter { instanceMasks[$0] != nil }
        pushUndo()
        selectedInstanceIDs = valid
        if valid.isEmpty {
            maskData = whiteMask
            backgroundRemoved = false
        } else {
            var union = [UInt8](repeating: 0, count: whiteMask.count)
            for id in valid {
                guard let instance = instanceMasks[id] else { continue }
                for index in union.indices where instance[index] > union[index] {
                    union[index] = instance[index]
                }
            }
            maskData = union
            backgroundRemoved = true
        }
        refreshPreview()
    }

    /// The Vision instance whose mask contains `point` (normalized, top-left
    /// origin), or `nil` over the background. Ties go to the strongest coverage.
    func instanceID(at point: CGPoint) -> Int? {
        guard !instanceMasks.isEmpty, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let x = min(pixelWidth - 1, Int(min(max(point.x, 0), 1) * CGFloat(pixelWidth)))
        let y = min(pixelHeight - 1, Int(min(max(point.y, 0), 1) * CGFloat(pixelHeight)))
        let index = y * pixelWidth + x
        var best: (id: Int, value: UInt8)?
        for (id, mask) in instanceMasks where index < mask.count {
            let value = mask[index]
            if value > 0, best == nil || value > best!.value {
                best = (id, value)
            }
        }
        return best?.id
    }

    /// Switches between Vision's subject cut-out and keeping everything.
    /// Cheap: swaps which of the two mask snapshots is active.
    func setBackgroundRemoved(_ removed: Bool) {
        guard removed != backgroundRemoved else { return }
        if removed {
            guard let subjectMask else { return }
            backgroundRemoved = true
            maskData = subjectMask
        } else {
            backgroundRemoved = false
            maskData = whiteMask
        }
        redoStack.removeAll()
        refreshPreview()
    }

    /// Restores the mask seeded at init, keeping the current background mode.
    func reset() {
        maskData = backgroundRemoved ? (subjectMask ?? whiteMask) : whiteMask
        undoStack.removeAll()
        redoStack.removeAll()
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
        redoStack.removeAll()
    }

    /// Draws into the mask buffer through a flipped gray `CGContext` so
    /// normalized top-left coordinates line up with `maskData` (same Y-flip
    /// convention as `seed`).
    private func rasterize(_ draw: (CGContext) -> Void) {
        maskData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: pixelWidth,
                      height: pixelHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: pixelWidth,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: 1, y: -1)
            draw(context)
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
fileprivate enum MaskCompositor {
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

    fileprivate static func maskCGImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
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
