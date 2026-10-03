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
}
