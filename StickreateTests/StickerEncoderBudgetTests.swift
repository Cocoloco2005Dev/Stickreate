import XCTest
import UIKit
@testable import Stickreate

final class StickerEncoderBudgetTests: XCTestCase {

    private func solidImage(_ color: UIColor, size: CGFloat = 512) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            color.setFill()
            context.fill(bounds)
        }
    }

    func testStaticSolidImageEncodesWithinBudget() {
        let data = StickerEncoder.staticSticker(from: solidImage(.systemRed))
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? .max, Limits.maxStaticBytes)
    }

    func testAnimatedSolidFramesEncodeWithinBudget() {
        let frames = [
            Frame(image: solidImage(.systemRed), duration: 0.1),
            Frame(image: solidImage(.systemGreen), duration: 0.1),
            Frame(image: solidImage(.systemBlue), duration: 0.1)
        ]
        let data = StickerEncoder.animatedSticker(from: frames)
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? .max, Limits.maxAnimatedBytes)
    }

    func testAnimatedStickerRejectsFewerThanTwoFrames() {
        XCTAssertNil(StickerEncoder.animatedSticker(from: []))
        XCTAssertNil(
            StickerEncoder.animatedSticker(from: [Frame(image: solidImage(.systemRed), duration: 0.1)])
        )
    }

    /// Forces the animated failure path with a zero byte budget and asserts the
    /// encoder never claims completion: no reported fraction may be 1.0.
    func testFailureNeverReportsOne() {
        let frames = [
            Frame(image: solidImage(.systemRed), duration: 0.1),
            Frame(image: solidImage(.systemGreen), duration: 0.1),
            Frame(image: solidImage(.systemBlue), duration: 0.1)
        ]
        var fractions: [Double] = []
        let data = StickerEncoder.animatedSticker(
            from: frames,
            byteBudget: 0,
            onProgress: { fractions.append($0) }
        )
        XCTAssertNil(data, "a zero budget must never fit a payload")
        XCTAssertFalse(fractions.isEmpty, "the failure path should still report in-flight progress")
        XCTAssertFalse(fractions.contains(1.0), "failure must never report 1.0; got \(fractions)")
        XCTAssertTrue(fractions.allSatisfy { $0 <= 0.999 })
    }

    /// A frame that is already a 512×512 `.up` canvas must be reused, not redrawn
    /// (the pass-through that keeps a single resident frame set).
    func testAlreadyCanvasFrameIsPassedThroughUnredrawn() {
        let image = solidImage(.systemRed, size: 512)
        let frames = [
            Frame(image: image, duration: 0.1),
            Frame(image: image, duration: 0.1)
        ]
        let prepared = StickerEncoder.preparedFramesForTesting(frames)
        XCTAssertEqual(prepared.count, frames.count)
        XCTAssertTrue(
            prepared[0].image === image,
            "an already-512×512 upright frame must be passed through, not redrawn"
        )
    }
}
