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
    /// Upright original image, downscaled to the `maxDimension` cap. Baked by
    /// `applyCrop(_:)`, which is why it is settable within the type.
    private(set) var base: UIImage
    /// The pristine photo this editor started from, preserved across crops and
    /// subject lifts. `restoreOriginal()` resets `base` to this.
    private(set) var originalBase: UIImage
    /// True while the working `base` is a lifted cut-out carried in from another
    /// editor (i.e. `originalBase` was supplied at init). Cleared by
    /// `restoreOriginal()` and preserved correctly across undo/redo.
    private(set) var isLifted: Bool
    /// `base` composited through the current mask.
    private(set) var preview: UIImage

    /// True when Vision supplied a subject mask at init.
    private(set) var hasSubject: Bool

    /// Brush radius as a fraction of the shorter side (clamped 0.02...0.3).
    var brushRadius: CGFloat = 0.08

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var pixelWidth: Int
    private var pixelHeight: Int
    private var maskData: [UInt8]
    /// All-white mask (keep everything), matching the current pixel size.
    private var whiteMask: [UInt8]
    /// Vision's subject mask, when one was supplied.
    private var subjectMask: [UInt8]?
    /// Whether the subject cut-out is currently in use.
    private var backgroundRemoved: Bool
    /// Vision's per-instance masks keyed by 1-based instance id, in editor pixels.
    private var instanceMasks: [Int: [UInt8]] = [:]
    /// Selected instance ids; empty means the whole image is kept.
    private(set) var selectedInstanceIDs: Set<Int> = []
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    /// Everything `applyCrop` can change, so `undo` can restore the pre-crop
    /// editor. The base image and instance-mask arrays are reference/COW-backed,
    /// so a snapshot is cheap.
    private struct Snapshot {
        let maskData: [UInt8]
        let base: UIImage
        let pixelWidth: Int
        let pixelHeight: Int
        let subjectMask: [UInt8]?
        let instanceMasks: [Int: [UInt8]]
        let selectedInstanceIDs: Set<Int>
        let backgroundRemoved: Bool
        let hasSubject: Bool
        let isLifted: Bool

        /// Total mask bytes held by this snapshot, for the undo memory cap.
        var byteCount: Int {
            maskData.count
                + (subjectMask?.count ?? 0)
                + instanceMasks.values.reduce(0) { $0 + $1.count }
        }
    }

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
    ///   - originalBase: the pristine photo to preserve for `restoreOriginal()`.
    ///     Defaults to this editor's own (scaled) base. Pass the previous
    ///     editor's `originalBase` when a subject lift replaces the working image.
    init(base: UIImage, mask: CGImage?, maxDimension: Int = 1024, originalBase: UIImage? = nil) {
        let scaledBase = base.scaled(toMaxDimension: CGFloat(maxDimension))
        self.base = scaledBase
        self.originalBase = originalBase ?? scaledBase
        self.isLifted = originalBase != nil

        let size = MaskEditor.pixelSize(of: scaledBase)
        self.pixelWidth = size.width
        self.pixelHeight = size.height

        let white = [UInt8](repeating: 255, count: size.width * size.height)
        let subject = mask.map { MaskCompositor.seed(bytesFrom: $0, width: size.width, height: size.height) }
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
        let cleaned = MaskCompositor.cleanMask(bytes, width: width, height: height)
        return MaskCompositor.maskCGImage(bytes: cleaned, width: width, height: height)
    }

    // MARK: - Introspection

    /// Pixel dimensions of `image`, matching the sizing rule used at init.
    static func pixelSize(of image: UIImage) -> (width: Int, height: Int) {
        let cgImage = image.cgImage
        let width = max(1, cgImage?.width ?? Int((image.size.width * image.scale).rounded()))
        let height = max(1, cgImage?.height ?? Int((image.size.height * image.scale).rounded()))
        return (width, height)
    }

    /// The current keep mask (top-left row-major) and its pixel size. Read-only
    /// seam for tests/diagnostics.
    var maskSnapshot: (bytes: [UInt8], width: Int, height: Int) {
        (maskData, pixelWidth, pixelHeight)
    }

    // MARK: - Editing

    // MARK: Coordinates
    //
    // The single Y convention for the whole editor: a normalized point uses a
    // TOP-LEFT origin (0,0 = top-left of `base`), and `maskData` is a top-left
    // row-major buffer (row 0 = top row). `pixelPoint(_:)` is the one place that
    // converts normalized -> pixel; `stroke`, `selectRectangle`, `selectLasso`
    // and `instanceID(at:)` all go through it so a point lands on the same pixel
    // in every tool. Do not hand-roll `1 - y` anywhere.

    /// Normalized top-left point (0...1) -> pixel coordinate in `maskData`.
    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1) * CGFloat(pixelWidth),
            y: min(max(point.y, 0), 1) * CGFloat(pixelHeight)
        )
    }

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

        let start = pixelPoint(from)
        let end = pixelPoint(to)
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
        redoStack.append(makeSnapshot())
        restore(previous)
        refreshPreview()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        restore(next)
        refreshPreview()
    }

    /// Fills a normalized top-left rect. `removing == true` paints black
    /// (remove); `false` paints white (keep). Uses the shared top-left
    /// coordinate convention, so it lands exactly where the brush would.
    func selectRectangle(_ rect: CGRect, removing: Bool) {
        let topLeft = pixelPoint(CGPoint(x: rect.minX, y: rect.minY))
        let bottomRight = pixelPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        let x0 = max(0, Int(topLeft.x.rounded(.down)))
        let y0 = max(0, Int(topLeft.y.rounded(.down)))
        let x1 = min(pixelWidth, Int(bottomRight.x.rounded(.up)))
        let y1 = min(pixelHeight, Int(bottomRight.y.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }

        pushUndo()
        let value: UInt8 = removing ? 0 : 255
        for y in y0..<y1 {
            let row = y * pixelWidth
            for x in x0..<x1 {
                maskData[row + x] = value
            }
        }
        refreshPreview()
    }

    /// Fills a normalized top-left polygon (at least three points). Same
    /// keep/remove semantics and coordinate convention as `selectRectangle`.
    func selectLasso(_ points: [CGPoint], removing: Bool) {
        guard points.count >= 3 else { return }
        let polygon = points.map(pixelPoint)
        let minX = max(0, Int((polygon.map(\.x).min() ?? 0).rounded(.down)))
        let maxX = min(pixelWidth - 1, Int((polygon.map(\.x).max() ?? 0).rounded(.up)))
        let minY = max(0, Int((polygon.map(\.y).min() ?? 0).rounded(.down)))
        let maxY = min(pixelHeight - 1, Int((polygon.map(\.y).max() ?? 0).rounded(.up)))
        guard maxX >= minX, maxY >= minY else { return }

        pushUndo()
        let value: UInt8 = removing ? 0 : 255
        for y in minY...maxY {
            let row = y * pixelWidth
            for x in minX...maxX {
                if pointInPolygon(polygon, x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5) {
                    maskData[row + x] = value
                }
            }
        }
        refreshPreview()
    }

    /// Even-odd point-in-polygon test in pixel space (top-left row-major).
    private func pointInPolygon(_ polygon: [CGPoint], x: CGFloat, y: CGFloat) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > y) != (b.y > y),
               x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
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
        let pixel = pixelPoint(point)
        let x = min(pixelWidth - 1, max(0, Int(pixel.x)))
        let y = min(pixelHeight - 1, max(0, Int(pixel.y)))
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

    /// Brings back the pristine original photo: resets the working image to
    /// `originalBase` (undoing any crop or subject lift) and clears the mask so
    /// the whole image shows. Undoable, so the previous state isn't lost.
    func restoreOriginal() {
        pushUndo()
        base = originalBase
        let size = MaskEditor.pixelSize(of: originalBase)
        pixelWidth = size.width
        pixelHeight = size.height
        whiteMask = [UInt8](repeating: 255, count: size.width * size.height)
        maskData = whiteMask
        backgroundRemoved = false
        selectedInstanceIDs = []
        isLifted = false
        // Masks seeded for a different base size no longer line up; drop them.
        if subjectMask?.count != whiteMask.count {
            subjectMask = nil
            hasSubject = false
        }
        if instanceMasks.contains(where: { $0.value.count != whiteMask.count }) {
            instanceMasks = [:]
        }
        redoStack.removeAll()
        refreshPreview()
    }

    /// Bakes a normalized top-left crop into `base`, the mask (and subject /
    /// instance masks), and the pixel dimensions, then keeps editing normally.
    /// Pushes an undo step, so `undo()` restores the full pre-crop state.
    ///
    /// The caller should clear its own pending crop rect afterwards; the editor
    /// holds no crop state of its own.
    func applyCrop(_ rect: CGRect) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let topLeft = pixelPoint(CGPoint(x: clamped.minX, y: clamped.minY))
        let bottomRight = pixelPoint(CGPoint(x: clamped.maxX, y: clamped.maxY))
        let x0 = max(0, Int(topLeft.x.rounded(.down)))
        let y0 = max(0, Int(topLeft.y.rounded(.down)))
        let x1 = min(pixelWidth, Int(bottomRight.x.rounded(.up)))
        let y1 = min(pixelHeight, Int(bottomRight.y.rounded(.up)))
        let newWidth = x1 - x0
        let newHeight = y1 - y0
        guard newWidth > 0, newHeight > 0,
              let croppedBase = MaskCompositor.crop(base, to: clamped) else { return }

        pushUndo()
        maskData = MaskCompositor.cropBytes(
            maskData, width: pixelWidth, height: pixelHeight,
            x: x0, y: y0, newWidth: newWidth, newHeight: newHeight
        )
        subjectMask = subjectMask.map {
            MaskCompositor.cropBytes(
                $0, width: pixelWidth, height: pixelHeight,
                x: x0, y: y0, newWidth: newWidth, newHeight: newHeight
            )
        }
        instanceMasks = instanceMasks.mapValues {
            MaskCompositor.cropBytes(
                $0, width: pixelWidth, height: pixelHeight,
                x: x0, y: y0, newWidth: newWidth, newHeight: newHeight
            )
        }
        base = croppedBase
        pixelWidth = newWidth
        pixelHeight = newHeight
        whiteMask = [UInt8](repeating: 255, count: newWidth * newHeight)
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

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            maskData: maskData,
            base: base,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            subjectMask: subjectMask,
            instanceMasks: instanceMasks,
            selectedInstanceIDs: selectedInstanceIDs,
            backgroundRemoved: backgroundRemoved,
            hasSubject: hasSubject,
            isLifted: isLifted
        )
    }

    private func restore(_ snapshot: Snapshot) {
        maskData = snapshot.maskData
        base = snapshot.base
        pixelWidth = snapshot.pixelWidth
        pixelHeight = snapshot.pixelHeight
        subjectMask = snapshot.subjectMask
        instanceMasks = snapshot.instanceMasks
        selectedInstanceIDs = snapshot.selectedInstanceIDs
        backgroundRemoved = snapshot.backgroundRemoved
        hasSubject = snapshot.hasSubject
        isLifted = snapshot.isLifted
        whiteMask = [UInt8](repeating: 255, count: snapshot.pixelWidth * snapshot.pixelHeight)
    }

    private func pushUndo() {
        undoStack.append(makeSnapshot())
        while undoStack.count > maxUndoCount
            || undoStack.reduce(0, { $0 + $1.byteCount }) > maxUndoBytes {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
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
        return cleanMask(bytes, width: width, height: height)
    }

    /// Turns Vision's soft mask into a hard, halo-free keep mask: threshold at
    /// 0.5, erode by 1 px to cut the soft fringe, then drop connected components
    /// smaller than `minArea` (specks). Deterministic and O(pixels). Input and
    /// output are top-left row-major buffers, same convention as `maskData`.
    ///
    /// Shared by the combined and per-instance seeds so every editable mask is
    /// cleaned the same way.
    static func cleanMask(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 1, height > 1, bytes.count >= width * height else {
            return bytes.map { $0 >= 128 ? 255 : 0 }
        }
        let count = width * height

        // 1) Hard threshold.
        var hard = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            hard[index] = bytes[index] >= 128 ? 255 : 0
        }

        // 2) Erode by 1 px: a keep pixel survives only if all four orthogonal
        //    neighbours are keep. Removes the 1 px soft fringe that reads as halo.
        var eroded = [UInt8](repeating: 0, count: count)
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let index = row + x
                if hard[index] == 255,
                   hard[index - 1] == 255, hard[index + 1] == 255,
                   hard[index - width] == 255, hard[index + width] == 255 {
                    eroded[index] = 255
                }
            }
        }

        // 3) Drop connected components smaller than `minArea` (tiny specks that
        //    survived the erosion). The component buffer is capped at `minArea`
        //    so a large blob never balloons memory. Small enough to keep legit
        //    small subjects (a 5×5 blob survives at 3×3 = 9 px).
        let minArea = 8
        var cleaned = eroded
        var visited = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        stack.reserveCapacity(minArea * 4)
        for start in 0..<count where eroded[start] == 255 && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            var component: [Int] = []
            var isSmall = true
            stack.append(start)
            visited[start] = true
            while let index = stack.popLast() {
                if isSmall {
                    component.append(index)
                    if component.count >= minArea {
                        isSmall = false
                        component.removeAll(keepingCapacity: true)
                    }
                }
                let x = index % width
                let y = index / width
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let neighbour = ny * width + nx
                        if eroded[neighbour] == 255 && !visited[neighbour] {
                            visited[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }
            if isSmall {
                for index in component { cleaned[index] = 0 }
            }
        }
        return cleaned
    }

    /// Crops a normalized top-left rect out of `image` (pixel-exact).
    static func crop(_ image: UIImage, to normalized: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let rect = CGRect(
            x: normalized.minX * width,
            y: normalized.minY * height,
            width: normalized.width * width,
            height: normalized.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// Crops a top-left row-major byte mask to `newWidth`×`newHeight` at `(x, y)`.
    static func cropBytes(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        newWidth: Int,
        newHeight: Int
    ) -> [UInt8] {
        guard newWidth > 0, newHeight > 0, x >= 0, y >= 0,
              x + newWidth <= width, y + newHeight <= height,
              bytes.count >= width * height else { return bytes }
        var out = [UInt8](repeating: 0, count: newWidth * newHeight)
        for row in 0..<newHeight {
            let source = (y + row) * width + x
            let destination = row * newWidth
            out.replaceSubrange(destination..<(destination + newWidth), with: bytes[source..<(source + newWidth)])
        }
        return out
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
