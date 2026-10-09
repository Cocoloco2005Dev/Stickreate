import XCTest
import UIKit
@testable import Stickreate

final class StickerGeometryTests: XCTestCase {

    private let accuracy: CGFloat = 0.0001

    func testLetterboxingCentersLandscapeImageWithEqualVerticalMargins() {
        let canvas = CGSize(width: 300, height: 300)
        let image = CGSize(width: 200, height: 100) // 2:1 landscape

        let frame = StickerGeometry.imageFrame(canvas: canvas, imageSize: image, zoom: 1, pan: .zero)

        XCTAssertEqual(frame.width, 300, accuracy: accuracy)
        XCTAssertEqual(frame.height, 150, accuracy: accuracy)
        XCTAssertEqual(frame.minX, 0, accuracy: accuracy)
        XCTAssertEqual(frame.midX, canvas.width / 2, accuracy: accuracy)
        XCTAssertEqual(frame.midY, canvas.height / 2, accuracy: accuracy)
        XCTAssertEqual(frame.minY, canvas.height - frame.maxY, accuracy: accuracy)
    }

    func testImageFrameReturnsZeroForDegenerateSizes() {
        XCTAssertEqual(
            StickerGeometry.imageFrame(canvas: .zero, imageSize: CGSize(width: 10, height: 10), zoom: 1, pan: .zero),
            .zero
        )
        XCTAssertEqual(
            StickerGeometry.imageFrame(canvas: CGSize(width: 100, height: 100), imageSize: .zero, zoom: 1, pan: .zero),
            .zero
        )
    }

    func testNormalizedMapsFrameCornersAndCenter() {
        let frame = CGRect(x: 20, y: 30, width: 200, height: 100)

        let topLeft = StickerGeometry.normalized(CGPoint(x: frame.minX, y: frame.minY), in: frame)
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 0, accuracy: accuracy)

        let bottomRight = StickerGeometry.normalized(CGPoint(x: frame.maxX, y: frame.maxY), in: frame)
        XCTAssertEqual(bottomRight.x, 1, accuracy: accuracy)
        XCTAssertEqual(bottomRight.y, 1, accuracy: accuracy)

        let center = StickerGeometry.normalized(CGPoint(x: frame.midX, y: frame.midY), in: frame)
        XCTAssertEqual(center.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(center.y, 0.5, accuracy: accuracy)
    }

    func testNormalizedClampsOutsideFrame() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)

        let outsideTopLeft = StickerGeometry.normalized(CGPoint(x: -500, y: -500), in: frame)
        XCTAssertEqual(outsideTopLeft, .zero)

        let outsideBottomRight = StickerGeometry.normalized(CGPoint(x: 9999, y: 9999), in: frame)
        XCTAssertEqual(outsideBottomRight.x, 1, accuracy: accuracy)
        XCTAssertEqual(outsideBottomRight.y, 1, accuracy: accuracy)
    }

    func testCanvasPointInvertsNormalized() {
        let frame = CGRect(x: 20, y: 30, width: 200, height: 100)
        let point = StickerGeometry.canvasPoint(CGPoint(x: 0.25, y: 0.75), in: frame)
        XCTAssertEqual(point.x, 70, accuracy: accuracy)
        XCTAssertEqual(point.y, 105, accuracy: accuracy)
    }

    func testClampedPanIsZeroWhenImageSmallerThanCanvas() {
        let canvas = CGSize(width: 300, height: 300)
        let image = CGSize(width: 200, height: 100)
        let clamped = StickerGeometry.clampedPan(
            CGSize(width: 500, height: -500),
            canvas: canvas,
            imageSize: image,
            zoom: 1
        )
        XCTAssertEqual(clamped, .zero)
    }

    func testClampedPanBoundsWhenZoomedIn() {
        let canvas = CGSize(width: 300, height: 300)
        let image = CGSize(width: 200, height: 100)
        // zoom 2 → fitted 600×300, so maxX = 150 and maxY = 0.
        let over = StickerGeometry.clampedPan(
            CGSize(width: 1000, height: 500),
            canvas: canvas,
            imageSize: image,
            zoom: 2
        )
        XCTAssertEqual(over.width, 150, accuracy: accuracy)
        XCTAssertEqual(over.height, 0, accuracy: accuracy)

        let under = StickerGeometry.clampedPan(
            CGSize(width: -1000, height: -500),
            canvas: canvas,
            imageSize: image,
            zoom: 2
        )
        XCTAssertEqual(under.width, -150, accuracy: accuracy)
        XCTAssertEqual(under.height, 0, accuracy: accuracy)
    }

    // MARK: - Edge cases: degenerate sizes, extreme zoom/pan, letterbox corners

    func testImageFrameShiftsCenterByPan() {
        let canvas = CGSize(width: 300, height: 300)
        let image = CGSize(width: 200, height: 100)
        let frame = StickerGeometry.imageFrame(
            canvas: canvas,
            imageSize: image,
            zoom: 1,
            pan: CGSize(width: 10, height: -20)
        )
        XCTAssertEqual(frame.width, 300, accuracy: accuracy)
        XCTAssertEqual(frame.height, 150, accuracy: accuracy)
        XCTAssertEqual(frame.midX, 160, accuracy: accuracy)
        XCTAssertEqual(frame.midY, 130, accuracy: accuracy)
    }

    func testImageFrameFitsTallImageByHeight() {
        let canvas = CGSize(width: 400, height: 200)
        let image = CGSize(width: 100, height: 400) // 1:4 portrait
        let frame = StickerGeometry.imageFrame(canvas: canvas, imageSize: image, zoom: 1, pan: .zero)
        XCTAssertEqual(frame.width, 50, accuracy: accuracy)
        XCTAssertEqual(frame.height, 200, accuracy: accuracy)
        XCTAssertEqual(frame.midX, 200, accuracy: accuracy)
        XCTAssertEqual(frame.midY, 100, accuracy: accuracy)
    }

    func testImageFrameZeroZoomIsEmptyButCentered() {
        let frame = StickerGeometry.imageFrame(
            canvas: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 10, height: 10),
            zoom: 0,
            pan: .zero
        )
        XCTAssertEqual(frame.width, 0, accuracy: accuracy)
        XCTAssertEqual(frame.height, 0, accuracy: accuracy)
        XCTAssertEqual(frame.midX, 50, accuracy: accuracy)
        XCTAssertEqual(frame.midY, 50, accuracy: accuracy)
    }

    func testImageFrameExtremeZoomGrowsAroundCenter() {
        let frame = StickerGeometry.imageFrame(
            canvas: CGSize(width: 300, height: 300),
            imageSize: CGSize(width: 200, height: 100),
            zoom: 1000,
            pan: .zero
        )
        XCTAssertEqual(frame.width, 300_000, accuracy: 0.5)
        XCTAssertEqual(frame.height, 150_000, accuracy: 0.5)
        XCTAssertEqual(frame.midX, 150, accuracy: accuracy)
        XCTAssertEqual(frame.midY, 150, accuracy: accuracy)
    }

    func testNormalizedReturnsZeroForDegenerateFrames() {
        XCTAssertEqual(StickerGeometry.normalized(CGPoint(x: 50, y: 50), in: .zero), .zero)
        XCTAssertEqual(
            StickerGeometry.normalized(
                CGPoint(x: 50, y: 50),
                in: CGRect(x: 10, y: 10, width: 0, height: 100)
            ),
            .zero
        )
    }

    /// A point produced from normalized coordinates must invert exactly, even on
    /// a letterboxed/zoomed/panned frame.
    func testCanvasPointInvertsNormalizedOnTransformedFrame() {
        let frame = StickerGeometry.imageFrame(
            canvas: CGSize(width: 300, height: 300),
            imageSize: CGSize(width: 200, height: 100),
            zoom: 1,
            pan: CGSize(width: 12, height: -8)
        )
        for xi in 0...5 {
            for yi in 0...5 {
                let x = CGFloat(xi) / 5
                let y = CGFloat(yi) / 5
                let point = StickerGeometry.canvasPoint(CGPoint(x: x, y: y), in: frame)
                let back = StickerGeometry.normalized(point, in: frame)
                XCTAssertEqual(back.x, x, accuracy: accuracy)
                XCTAssertEqual(back.y, y, accuracy: accuracy)
            }
        }
    }

    /// Landscape image in a square canvas: the top/bottom canvas corners fall in
    /// the letterbox and clamp to the image edges, while the centre maps to 0.5.
    func testNormalizedClampsCanvasLetterboxCorners() {
        let canvas = CGSize(width: 300, height: 300)
        let image = CGSize(width: 200, height: 100)
        let frame = StickerGeometry.imageFrame(canvas: canvas, imageSize: image, zoom: 1, pan: .zero)

        let topLeft = StickerGeometry.normalized(CGPoint(x: 0, y: 0), in: frame)
        XCTAssertEqual(topLeft.x, 0, accuracy: accuracy)
        XCTAssertEqual(topLeft.y, 0, accuracy: accuracy) // clamped from -0.5

        let bottomRight = StickerGeometry.normalized(CGPoint(x: 300, y: 300), in: frame)
        XCTAssertEqual(bottomRight.x, 1, accuracy: accuracy)
        XCTAssertEqual(bottomRight.y, 1, accuracy: accuracy) // clamped from 1.5

        let center = StickerGeometry.normalized(CGPoint(x: 150, y: 150), in: frame)
        XCTAssertEqual(center.x, 0.5, accuracy: accuracy)
        XCTAssertEqual(center.y, 0.5, accuracy: accuracy)
    }

    func testClampedPanUsesSlackOnBothAxesWhenZoomedPastCanvas() {
        let clamped = StickerGeometry.clampedPan(
            CGSize(width: 9999, height: -9999),
            canvas: CGSize(width: 300, height: 300),
            imageSize: CGSize(width: 300, height: 300),
            zoom: 3 // 900×900, slack 300 per axis
        )
        XCTAssertEqual(clamped.width, 300, accuracy: accuracy)
        XCTAssertEqual(clamped.height, -300, accuracy: accuracy)
    }

    func testClampedPanIsZeroAtZeroZoom() {
        let clamped = StickerGeometry.clampedPan(
            CGSize(width: 50, height: 50),
            canvas: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 100, height: 100),
            zoom: 0
        )
        XCTAssertEqual(clamped, .zero)
    }

    func testClampedPanReturnsInputUnchangedForDegenerateInputs() {
        let value = CGSize(width: 33, height: -7)
        XCTAssertEqual(
            StickerGeometry.clampedPan(value, canvas: .zero, imageSize: CGSize(width: 10, height: 10), zoom: 1),
            value
        )
        XCTAssertEqual(
            StickerGeometry.clampedPan(value, canvas: CGSize(width: 100, height: 100), imageSize: .zero, zoom: 1),
            value
        )
    }
}
