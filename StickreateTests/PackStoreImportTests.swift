import XCTest
import UIKit
@testable import Stickreate

final class PackStoreImportTests: XCTestCase {

    private let fm = FileManager.default

    private func makeTempDirectory() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("PackStoreImportTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real PNG so `PackArchive.exportData` can build a tray icon.
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

    private func sticker(kind: StickerKind = .static, source: StickerSource? = nil) -> StickerItem {
        StickerItem(
            kind: kind,
            stickerData: Data([0x01, 0x02, 0x03]),
            previewData: Data([0x00]),
            source: source
        )
    }

    // MARK: - PackStore.importPack validation

    func testImportRejectsTooManyStickers() throws {
        let store = PackStore(directory: try makeTempDirectory())
        let stickers = (0...Limits.maxStickers).map { _ in sticker() }
        let pack = StickerPack(name: "Too Many", stickers: stickers)

        XCTAssertFalse(store.importPack(pack))
        XCTAssertTrue(store.packs.isEmpty)
    }

    func testImportRejectsMixedKinds() throws {
        let store = PackStore(directory: try makeTempDirectory())
        let pack = StickerPack(name: "Mixed", stickers: [sticker(kind: .static), sticker(kind: .animated)])

        XCTAssertFalse(store.importPack(pack))
        XCTAssertTrue(store.packs.isEmpty)
    }

    func testImportAcceptsSmallNonEmptyPack() throws {
        let store = PackStore(directory: try makeTempDirectory())
        let pack = StickerPack(name: "Small", stickers: [sticker()])

        XCTAssertTrue(store.importPack(pack))
        XCTAssertEqual(store.packs.map(\.name), ["Small"])
    }

    // MARK: - PackArchive.importPack validation

    func testArchiveImportRejectsMixedKinds() throws {
        let json = """
        {"format":"stickreate.pack","version":1,"name":"Mixed","publisher":"T","stickers":[
         {"kind":"static","emojis":[],"sticker":"\(Data([1]).base64EncodedString())","preview":"\(preview(1).base64EncodedString())"},
         {"kind":"animated","emojis":[],"sticker":"\(Data([2]).base64EncodedString())","preview":"\(preview(2).base64EncodedString())"}]}
        """
        XCTAssertThrowsError(try PackArchive.importPack(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .mixedKinds)
        }
    }

    func testArchiveImportRejectsTooManyStickers() throws {
        let entries = (0...Limits.maxStickers).map { index in
            """
            {"kind":"static","emojis":[],"sticker":"\(Data([UInt8(index % 256)]).base64EncodedString())","preview":"\(Data([0x00]).base64EncodedString())"}
            """
        }.joined(separator: ",")
        let json = """
        {"format":"stickreate.pack","version":1,"name":"Big","publisher":"T","stickers":[\(entries)]}
        """
        XCTAssertThrowsError(try PackArchive.importPack(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .tooManyStickers)
        }
    }

    func testArchiveImportRejectsOversizedZIPEntry() throws {
        // One 1.5 MB sticker is under the 20 MB total cap but over the 1 MB
        // per-entry cap, so reading it must fail with `.payloadTooLarge`.
        let big = Data(repeating: 0x41, count: 1_500_000)
        let pack = StickerPack(name: "Big Entry", stickers: [
            StickerItem(kind: .static, stickerData: big, previewData: preview(1))
        ])
        let data = try PackArchive.exportData(pack)

        XCTAssertThrowsError(try PackArchive.importPack(from: data)) { error in
            XCTAssertEqual(error as? PackArchive.Failure, .payloadTooLarge)
        }
    }

    // MARK: - reconcileSources()

    func testReconcileSourcesDeletesOrphansAndKeepsReferenced() throws {
        let directory = try makeTempDirectory()
        let sourcesDir = directory.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let keptName = "kept-\(UUID().uuidString).jpg"
        let orphanName = "orphan-\(UUID().uuidString).jpg"
        let keptURL = sourcesDir.appendingPathComponent(keptName)
        let orphanURL = sourcesDir.appendingPathComponent(orphanName)
        try Data([0x01]).write(to: keptURL, options: .atomic)
        try Data([0x02]).write(to: orphanURL, options: .atomic)

        // A subdirectory must survive: only regular files are swept.
        let nestedDir = sourcesDir.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        // Seed a valid packs.json referencing only `keptName`, then init the
        // store so the launch sweep runs against the temp directory.
        let pack = StickerPack(name: "Keeps", stickers: [
            sticker(source: .image(fileName: keptName))
        ])
        try JSONEncoder().encode([pack]).write(to: directory.appendingPathComponent("packs.json"), options: .atomic)

        let store = PackStore(directory: directory)
        XCTAssertEqual(store.packs.count, 1)
        XCTAssertNil(store.persistenceError)

        XCTAssertTrue(fm.fileExists(atPath: keptURL.path))
        XCTAssertFalse(fm.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(fm.fileExists(atPath: nestedDir.path))
    }
}
