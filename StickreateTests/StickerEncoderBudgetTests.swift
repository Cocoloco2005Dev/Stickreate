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
}
