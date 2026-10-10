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

    /// The shared union ignores a frame whose box is a wild area outlier (a stray
    /// speck or halo blob) so it can't inflate the crop and shrink the subject.
    func testAlphaUnionIgnoresAreaOutlierFrame() {
        let size = CGSize(width: 100, height: 100)
        let subject = CGRect(x: 40, y: 40, width: 20, height: 20)
        let frames = [
            imageWithOpaqueRect(subject, size: size),
            imageWithOpaqueRect(subject, size: size),
            imageWithOpaqueRect(subject, size: size),
            // Outlier: a huge blob covering most of the frame (area ≫ median),
            // but with a transparent border so `alphaBounds` still reports it.
            imageWithOpaqueRect(CGRect(x: 0, y: 0, width: 90, height: 90), size: size)
        ]
        XCTAssertEqual(StickerEncoder.alphaUnion(of: frames), subject)
    }

    /// Similar-sized frames are all unioned (a subject that moves or grows a
    /// little is never discarded).
    func testAlphaUnionKeepsSimilarFrames() {
        let size = CGSize(width: 100, height: 100)
        let a = CGRect(x: 10, y: 10, width: 20, height: 20)
        let b = CGRect(x: 60, y: 60, width: 20, height: 20)
        let frames = [
            imageWithOpaqueRect(a, size: size),
            imageWithOpaqueRect(a, size: size),
            imageWithOpaqueRect(a, size: size),
            imageWithOpaqueRect(b, size: size)
        ]
        XCTAssertEqual(StickerEncoder.alphaUnion(of: frames), a.union(b))
    }

    /// A grayscale CGImage with the given single-channel values (row-major).
    private func grayImage(_ values: [UInt8], width: Int) -> CGImage {
        let height = values.count / width
        let provider = CGDataProvider(data: Data(values) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Reads a single-channel CGImage back into raw bytes.
    private func grayBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// `cleanedMask` zeroes the faint halo and keeps the opaque subject.
    func testCleanedMaskZeroesFaintHalo() {
        let source = grayImage([0, 10, 15, 16, 200, 255], width: 6)
        guard let cleaned = StickerFactory.cleanedMask(source) else {
            return XCTFail("cleanedMask should render")
        }
        XCTAssertEqual(grayBytes(cleaned), [0, 0, 0, 16, 200, 255])
    }

    /// A mask that can't be smaller than its threshold is returned all-zero.
    func testCleanedMaskAllFaintBecomesZero() {
        let source = grayImage([1, 2, 3, 15], width: 4)
        guard let cleaned = StickerFactory.cleanedMask(source) else {
            return XCTFail("cleanedMask should render")
        }
        XCTAssertEqual(grayBytes(cleaned), [0, 0, 0, 0])
    }
}
