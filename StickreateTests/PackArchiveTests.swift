import XCTest
@testable import Stickreate

final class PackArchiveTests: XCTestCase {

    private func sticker(_ byte: UInt8) -> StickerItem {
        StickerItem(
            kind: .static,
            emojis: ["😀", "🎉"],
            stickerData: Data([byte, byte &+ 1, 0x52, 0x49, 0x46, 0x46]),
            previewData: Data([0x89, 0x50, 0x4E, 0x47, byte])
        )
    }

    func testExportImportRoundTripsPackAndStickerBytes() throws {
        let pack = StickerPack(
            name: "Test Pack",
            publisher: "Unit Tests",
            stickers: [sticker(1), sticker(2), sticker(3)],
            folder: "Favorites"
        )

        let data = try PackArchive.exportData(pack)
        let imported = try PackArchive.importPack(from: data)

        XCTAssertEqual(imported.name, "Test Pack")
        XCTAssertEqual(imported.publisher, "Unit Tests")
        XCTAssertEqual(imported.folder, "Favorites")
        XCTAssertEqual(imported.stickers.count, 3)
        XCTAssertEqual(imported.kind, .static)
        XCTAssertEqual(imported.stickers.map(\.emojis), [["😀", "🎉"], ["😀", "🎉"], ["😀", "🎉"]])
        XCTAssertEqual(imported.stickers.map(\.stickerData), pack.stickers.map(\.stickerData))
        XCTAssertEqual(imported.stickers.map(\.previewData), pack.stickers.map(\.previewData))
    }

    func testImportedStickersAreNotReEditable() throws {
        let pack = StickerPack(name: "Test Pack", stickers: [sticker(1), sticker(2), sticker(3)])
        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))
        XCTAssertTrue(imported.stickers.allSatisfy { $0.source == nil })
    }

    func testImportThrowsOnMalformedData() {
        XCTAssertThrowsError(try PackArchive.importPack(from: Data("not json".utf8)))
    }
}
