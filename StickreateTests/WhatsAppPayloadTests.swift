import XCTest
import UIKit
@testable import Stickreate

/// WhatsApp export tests.
///
/// `WhatsAppExporter`'s payload builder is not a pure function: it is
/// `@MainActor`, is `private`, and the same function writes the pasteboard and
/// opens `whatsapp://`. So these tests cover the closest hermetic seams:
///
/// - the validation that runs before any pasteboard side effect, and
/// - the sibling single-pack manifest (`PackArchive.exportData`) that carries the
///   same WhatsApp contract (sticker count/order, tray, kind flag, ≤3 emojis).
///
/// Not covered (needs an app-source seam): asserting the exact JSON written to
/// `UIPasteboard` under `net.whatsapp.third-party.sticker-pack` (`tray_image`,
/// `stickers[].image_data`, `animated_sticker_pack`).
@MainActor
final class WhatsAppPayloadTests: XCTestCase {

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

    private func item(
        kind: StickerKind = .static,
        emojis: [String] = [],
        byte: UInt8
    ) -> StickerItem {
        StickerItem(
            kind: kind,
            emojis: emojis,
            stickerData: Data([byte]),
            previewData: preview(byte)
        )
    }

    // MARK: - Validation seam (throws before touching the pasteboard)

    func testExportRejectsMixedPack() {
        let pack = StickerPack(name: "Mixed", stickers: [
            item(byte: 1), item(byte: 2), item(byte: 3),
            item(kind: .animated, byte: 4), item(kind: .animated, byte: 5), item(kind: .animated, byte: 6)
        ])
        XCTAssertThrowsError(try WhatsAppExporter.export(pack)) { error in
            XCTAssertEqual(error as? StickerPack.ValidationError, .mixedKinds)
        }
    }

    func testExportRejectsPackBelowMinimum() {
        let pack = StickerPack(name: "Small", stickers: [item(byte: 1), item(byte: 2)])
        XCTAssertThrowsError(try WhatsAppExporter.export(pack)) { error in
            XCTAssertEqual(error as? StickerPack.ValidationError, .tooFew(Limits.minStickers))
        }
    }

    func testExportRejectsPackOverCap() {
        let pack = StickerPack(
            name: "Big",
            stickers: (0...Limits.maxStickers).map { item(byte: UInt8($0)) }
        )
        XCTAssertThrowsError(try WhatsAppExporter.export(pack)) { error in
            XCTAssertEqual(error as? StickerPack.ValidationError, .tooMany(Limits.maxStickers))
        }
    }

    func testExportRejectsEmptyPack() {
        XCTAssertThrowsError(try WhatsAppExporter.export(StickerPack(name: "Empty"))) { error in
            XCTAssertTrue(error is WhatsAppExporter.Failure)
        }
    }

    /// A pack whose first preview can't be decoded must be rejected while building
    /// the tray, before any pasteboard/open side effect.
    func testExportRejectsMissingPreviewBeforeBuildingPayload() {
        let bad = StickerItem(kind: .static, stickerData: Data([1]), previewData: Data([0x00]))
        XCTAssertThrowsError(
            try WhatsAppExporter.export(
                stickers: [bad, item(byte: 2), item(byte: 3)],
                kind: .static,
                name: "N",
                publisher: "P",
                identifier: "test-identifier"
            )
        ) { error in
            XCTAssertTrue(error is WhatsAppExporter.Failure)
        }
    }

    // MARK: - Single-pack payload contract (closest inspectorable builder)

    func testSingleKindPayloadKeepsCountOrderTrayAndEmojiCap() throws {
        let pack = StickerPack(name: "Payload", publisher: "T", stickers: [
            item(emojis: ["1", "2", "3", "4"], byte: 11),
            item(emojis: ["x"], byte: 22),
            item(byte: 33)
        ])

        let imported = try PackArchive.importPack(from: try PackArchive.exportData(pack))

        XCTAssertEqual(imported.stickers.count, 3)
        XCTAssertEqual(imported.stickers.map(\.stickerData), [Data([11]), Data([22]), Data([33])])
        XCTAssertTrue(imported.stickers.allSatisfy { !$0.previewData.isEmpty }, "tray/preview must be present")
        XCTAssertEqual(imported.kind, .static)
        XCTAssertEqual(imported.stickers[0].emojis, ["1", "2", "3"], "emojis must be capped at 3")
    }
}
