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

    /// Incompressible 512×512 RGB noise (deterministic), to exercise the low end
    /// of the quality/frame ladder.
    private func noiseImage(seed: UInt64, size: CGFloat = 512) -> UIImage {
        let width = Int(size)
        let height = Int(size)
        var rng = SplitMix64(seed: seed)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = UInt8(truncatingIfNeeded: rng.next())
            bytes[offset + 1] = UInt8(truncatingIfNeeded: rng.next())
            bytes[offset + 2] = UInt8(truncatingIfNeeded: rng.next())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return solidImage(.black, size: size)
        }
        return UIImage(cgImage: cgImage)
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testStaticSolidImageEncodesWithinBudget() {
        let data = StickerEncoder.staticSticker(from: solidImage(.systemRed))
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? .max, Limits.maxStaticBytes)
    }

    /// Worst-case static input: incompressible 512×512 noise. The static path has
    /// no frame-budget to drop, only the quality ladder (1.0 → 0.30), so unlike
    /// the animated path it may legitimately fail to reach the cap and return
    /// `nil`. The guaranteed invariant is that it never returns an over-budget
    /// payload.
    func testStaticImageNeverExceedsBudget() {
        let data = StickerEncoder.staticSticker(from: noiseImage(seed: 0xDEAD_BEEF))
        if let data {
            XCTAssertLessThanOrEqual(data.count, Limits.maxStaticBytes)
        }
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

    /// Motion-heavy input must still produce a valid sticker: the extended ladder
    /// (quality 25 + last-resort frame counts down to 2) is what rescues it. If it
    /// genuinely cannot fit, it must at least fail cleanly (no fake 100%).
    func testNoisyFrameSetStillEncodes() {
        let frames = (0..<10).map { index in
            Frame(image: noiseImage(seed: UInt64(index) + 1), duration: 0.1)
        }
        var fractions: [Double] = []
        let data = StickerEncoder.animatedSticker(
            from: frames,
            onProgress: { fractions.append($0) }
        )
        guard let data else {
            XCTAssertFalse(fractions.contains(1.0), "a failed noisy encode must never report 1.0")
            XCTFail("noisy frame set should fit after the extended ladder")
            return
        }
        XCTAssertLessThanOrEqual(data.count, Limits.maxAnimatedBytes)
        // Worst-case motion must fit the 480 KB target, not just the 500 KB cap
        // (the encoder returns the first candidate whose bytes fit this budget).
        XCTAssertLessThanOrEqual(data.count, 480 * 1024)
    }
}
