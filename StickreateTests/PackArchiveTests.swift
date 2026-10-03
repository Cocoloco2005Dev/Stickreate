import XCTest
import UIKit
@testable import Stickreate

final class PackArchiveTests: XCTestCase {

    private func preview(_ byte: UInt8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side: CGFloat = 8
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            context.cgContext.setFillColor(UIColor(white: CGFloat(byte) / 255, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    private func sticker(_ byte: UInt8) -> StickerItem {
        StickerItem(
            kind: .static,
            emojis: ["😀", "🎉"],
            stickerData: Data([byte, byte &+ 1, 0x52, 0x49, 0x46, 0x46]),
            previewData: preview(byte)
        )
    }

    func testExportedDataIsAZip() throws {
        let pack = StickerPack(name: "Test Pack", stickers: [sticker(1), sticker(2), sticker(3)])
        let data = try PackArchive.exportData(pack)
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
    }

    func testExportImportRoundTripsPackAndStickerBytes() throws {
        let pack = StickerPack(
            name: "Test Pack",
            publisher: "Unit Tests",
            stickers: [sticker(1), sticker(2), sticker(3)],
            folder: "Favorites"
        )

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.name, "Test Pack")
        XCTAssertEqual(imported.publisher, "Unit Tests")
        XCTAssertNil(imported.folder) // the ZIP manifest carries no folder
        XCTAssertEqual(imported.stickers.count, 3)
        XCTAssertEqual(imported.kind, .static)
        XCTAssertEqual(imported.stickers.map(\.emojis), [["😀", "🎉"], ["😀", "🎉"], ["😀", "🎉"]])
        XCTAssertEqual(imported.stickers.map(\.stickerData), pack.stickers.map(\.stickerData))
        XCTAssertTrue(imported.stickers.allSatisfy { !$0.previewData.isEmpty })
    }

    func testImportedStickersAreNotReEditable() throws {
        let pack = StickerPack(name: "Test Pack", stickers: [sticker(1), sticker(2), sticker(3)])
        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))
        XCTAssertTrue(imported.stickers.allSatisfy { $0.source == nil })
    }

    func testImportThrowsOnMalformedData() {
        XCTAssertThrowsError(try PackArchive.importPack(from: Data("not json".utf8)))
    }

    func testLegacyJSONStillImports() throws {
        let legacy = """
        {"format":"stickreate.pack","version":1,"name":"Legacy","publisher":"Old",
         "stickers":[{"kind":"static","emojis":["😀"],
         "sticker":"\(Data([1, 2, 3]).base64EncodedString())",
         "preview":"\(preview(9).base64EncodedString())"}]}
        """
        let pack = try PackArchive.importPack(from: Data(legacy.utf8))
        XCTAssertEqual(pack.name, "Legacy")
        XCTAssertEqual(pack.publisher, "Old")
        XCTAssertEqual(pack.stickers.count, 1)
        XCTAssertEqual(pack.stickers[0].stickerData, Data([1, 2, 3]))
    }
}
