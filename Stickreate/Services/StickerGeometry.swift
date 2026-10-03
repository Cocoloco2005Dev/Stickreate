import UIKit

/// Pure, testable mapping between the editor canvas and normalized image
/// coordinates (top-left origin, 0...1). No view state.
enum StickerGeometry {
    /// Aspect-fit frame of the image inside the canvas, scaled by `zoom` and
    /// offset by `pan` (canvas points).
    static func imageFrame(canvas: CGSize, imageSize: CGSize, zoom: CGFloat, pan: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let width = imageSize.width * fit * zoom
        let height = imageSize.height * fit * zoom
        let centerX = canvas.width / 2 + pan.width
        let centerY = canvas.height / 2 + pan.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// Clamps a pan to the slack between the (zoomed) image and the canvas, so
    /// the image never leaves empty space on the edges.
    static func clampedPan(_ value: CGSize, canvas: CGSize, imageSize: CGSize, zoom: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return value }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let maxX = max(0, (imageSize.width * fit * zoom - canvas.width) / 2)
        let maxY = max(0, (imageSize.height * fit * zoom - canvas.height) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    /// Touch → normalized 0...1 image coordinates, clamped to the image edges.
    static func normalized(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let x = (location.x - frame.minX) / frame.width
        let y = (location.y - frame.minY) / frame.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Normalized 0...1 image coordinates → canvas point.
    static func canvasPoint(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
    }
}
