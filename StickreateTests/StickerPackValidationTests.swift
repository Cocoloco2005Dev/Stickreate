import XCTest
@testable import Stickreate

final class StickerPackValidationTests: XCTestCase {

    private func stickers(_ kind: StickerKind, count: Int) -> [StickerItem] {
        (0..<count).map { index in
            StickerItem(
                kind: kind,
                stickerData: Data([UInt8(index % 256)]),
                previewData: Data([UInt8((index + 1) % 256)])
            )
        }
    }

    func testThreeSingleKindStickersPass() {
        let pack = StickerPack(name: "P", stickers: stickers(.static, count: 3))
        XCTAssertNoThrow(try pack.validate())
    }

    func testMoreThanThirtyStickersThrowsTooMany() {
        let pack = StickerPack(name: "P", stickers: stickers(.static, count: 31))
        XCTAssertThrowsError(try pack.validate()) { error in
            XCTAssertEqual(error as? StickerPack.ValidationError, .tooMany(Limits.maxStickers))
        }
    }

    func testMixedPackWithUndersizedGroupThrowsTooFew() {
        let pack = StickerPack(
            name: "P",
            stickers: stickers(.static, count: 3) + stickers(.animated, count: 2)
        )
        XCTAssertThrowsError(try pack.validate()) { error in
            XCTAssertEqual(error as? StickerPack.ValidationError, .tooFew(Limits.minStickers))
        }
    }

    func testEmptyPackPassesValidation() {
        XCTAssertNoThrow(try StickerPack(name: "P").validate())
    }
}
