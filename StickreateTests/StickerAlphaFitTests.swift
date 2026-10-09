import XCTest
import UIKit
@testable import Stickreate

/// Unit tests for the pure alpha-bounds / padded-crop helpers that drive the
/// auto-fit of a cut-out subject. No Vision, just synthetic RGBA pixels.
final class StickerAlphaFitTests: XCTestCase {

    /// Transparent canvas with one opaque, pixel-aligned rectangle.
    private func imageWithOpaqueRect(
        _ rect: CGRect,
        size: CGSize = CGSize(width: 24, height: 24)
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.systemRed.cgColor)
            context.cgContext.fill(rect)
        }
    }

    private func opaqueImage(size: CGFloat = 8) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(bounds)
        }
    }

    private func transparentImage(size: CGFloat = 8) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: format
        ).image { _ in }
    }

    func testAlphaBoundsFindsOpaqueRectangle() {
        let rect = CGRect(x: 5, y: 4, width: 6, height: 7)
        XCTAssertEqual(StickerEncoder.alphaBounds(of: imageWithOpaqueRect(rect)), rect)
    }

    /// A fully opaque image has no transparency to fit.
    func testAlphaBoundsNilForOpaqueImage() {
        XCTAssertNil(StickerEncoder.alphaBounds(of: opaqueImage()))
    }

    /// A fully transparent image has no subject.
    func testAlphaBoundsNilForTransparentImage() {
        XCTAssertNil(StickerEncoder.alphaBounds(of: transparentImage()))
    }

    func testPaddedCropRectExpandsAndClampsToImageBounds() {
        let image = imageWithOpaqueRect(CGRect(x: 5, y: 4, width: 6, height: 7))
        XCTAssertEqual(
            StickerEncoder.paddedCropRect(
                CGRect(x: 5, y: 4, width: 6, height: 7),
                margin: 2,
                in: image
            ),
            CGRect(x: 3, y: 2, width: 10, height: 11)
        )
        // A margin larger than the canvas is clamped to the whole image.
        XCTAssertEqual(
            StickerEncoder.paddedCropRect(
                CGRect(x: 0, y: 0, width: 4, height: 4),
                margin: 99,
                in: image
            ),
            CGRect(x: 0, y: 0, width: 24, height: 24)
        )
    }

    func testAlphaFittedCropsTransparentBorder() {
        let image = imageWithOpaqueRect(
            CGRect(x: 24, y: 20, width: 10, height: 12),
            size: CGSize(width: 64, height: 64)
        )
        let fitted = StickerEncoder.alphaFitted(image)
        // Bounds (24,20,10,12) padded by the 8 px margin → (16,12,26,28).
        XCTAssertEqual(fitted.size.width, 26)
        XCTAssertEqual(fitted.size.height, 28)
    }

    /// Opaque photos must pass through untouched (same instance, no redraw).
    func testAlphaFittedLeavesOpaqueImageUnchanged() {
        let image = opaqueImage()
        XCTAssertTrue(StickerEncoder.alphaFitted(image) === image)
    }
}
