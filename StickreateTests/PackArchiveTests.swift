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

    // MARK: - Round-trip: order, emojis, single-kind

    func testRoundTripPreservesStickerOrder() throws {
        let bytes: [UInt8] = [10, 20, 30, 40]
        let pack = StickerPack(name: "Order", stickers: bytes.map { sticker($0) })

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        // Distinct payloads, so any reorder would show up in the byte sequence.
        XCTAssertEqual(imported.stickers.map(\.stickerData), pack.stickers.map(\.stickerData))
        XCTAssertEqual(Set(imported.stickers.map(\.stickerData)).count, bytes.count)
    }

    func testRoundTripPreservesEmojisPerSticker() throws {
        let pack = StickerPack(name: "Emoji", stickers: [
            StickerItem(kind: .static, emojis: ["😀", "🎉"], stickerData: Data([1]), previewData: preview(1)),
            StickerItem(kind: .static, emojis: ["🔥"], stickerData: Data([2]), previewData: preview(2)),
            StickerItem(kind: .static, emojis: [], stickerData: Data([3]), previewData: preview(3))
        ])

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.stickers.map(\.emojis), [["😀", "🎉"], ["🔥"], []])
    }

    func testRoundTripCapsEmojisAtThree() throws {
        let pack = StickerPack(name: "EmojiCap", stickers: [
            StickerItem(kind: .static, emojis: ["1", "2", "3", "4", "5"], stickerData: Data([1]), previewData: preview(1)),
            sticker(2),
            sticker(3)
        ])

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.stickers[0].emojis, ["1", "2", "3"])
    }

    func testRoundTripStaticPackStaysStatic() throws {
        let pack = StickerPack(name: "S", stickers: [sticker(1), sticker(2), sticker(3)])

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.kind, .static)
        XCTAssertTrue(imported.stickers.allSatisfy { $0.kind == .static })
        XCTAssertFalse(imported.isMixed)
    }

    func testRoundTripAnimatedPackStaysAnimated() throws {
        let pack = StickerPack(name: "A", stickers: (1...3).map { byte in
            StickerItem(kind: .animated, stickerData: Data([UInt8(byte)]), previewData: preview(UInt8(byte)))
        })

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.kind, .animated)
        XCTAssertTrue(imported.stickers.allSatisfy { $0.kind == .animated })
        XCTAssertFalse(imported.isMixed)
    }

    // MARK: - Rejection paths

    func testImportThrowsOnMalformedZIP() {
        // Starts with the ZIP magic ("PK") but is not a valid archive. Whether
        // ZIPFoundation refuses to open it or yields an empty archive, the importer
        // must surface `.invalid`, never a crash or a phantom pack.
        let garbage = Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0x00, 0x11, 0x22, 0x33])
        XCTAssertThrowsError(try PackArchive.importPack(from: garbage)) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .invalid)
        }
    }

    func testLegacyWrongFormatIsRejected() {
        let json = #"{"format":"other.pack","version":1,"name":"X","publisher":"Y","stickers":[]}"#
        XCTAssertThrowsError(try PackArchive.importPack(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .invalid)
        }
    }

    func testLegacyUnsupportedVersionIsRejected() {
        let json = #"{"format":"stickreate.pack","version":99,"name":"Future","publisher":"X","stickers":[]}"#
        XCTAssertThrowsError(try PackArchive.importPack(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .unsupportedVersion)
        }
    }

    func testZipImportRejectsOverCapArchive() throws {
        // 31 stickers: `exportData` doesn't validate, so the import-time cap check
        // is what must reject it.
        let pack = StickerPack(
            name: "TooMany",
            stickers: (0...Limits.maxStickers).map { sticker(UInt8($0)) }
        )
        let data = try PackArchive.exportData(pack)

        XCTAssertThrowsError(try PackArchive.importPack(from: data)) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .tooManyStickers)
        }
    }

    func testZipImportRejectsOversizedEntry() throws {
        // 1.5 MB: under the 20 MB total cap but over the 1 MB per-entry cap.
        let big = Data(repeating: 0x41, count: 1_500_000)
        let pack = StickerPack(name: "Big", stickers: [
            StickerItem(kind: .static, stickerData: big, previewData: preview(1))
        ])
        let data = try PackArchive.exportData(pack)

        XCTAssertThrowsError(try PackArchive.importPack(from: data)) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .payloadTooLarge)
        }
    }

    func testZipImportRejectsArchiveOverTotalCap() throws {
        // 22 × 1 MB entries: each is under the per-entry cap, but the declared
        // total is over the 20 MB cap, so the bomb guard must reject before
        // extracting anything.
        let oneMB = Data(repeating: 0x42, count: 1_000_000)
        let pack = StickerPack(name: "Bomb", stickers: (0..<22).map { index in
            StickerItem(kind: .static, stickerData: oneMB, previewData: preview(UInt8(index)))
        })
        let data = try PackArchive.exportData(pack)

        XCTAssertThrowsError(try PackArchive.importPack(from: data)) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .payloadTooLarge)
        }
    }
}
