import XCTest
@testable import Stickreate

final class PackStorePersistenceTests: XCTestCase {

    private let fm = FileManager.default

    private func makeTempDirectory() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("PackStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packsURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("packs.json")
    }

    private func backupURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("packs.json.bak")
    }

    private func quarantineFiles(in directory: URL) -> [URL] {
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix("packs.corrupt-") }
    }

    // MARK: - load()

    func testMissingFileStartsEmptyWithoutError() throws {
        let directory = try makeTempDirectory()
        let store = PackStore(directory: directory)

        XCTAssertTrue(store.packs.isEmpty)
        XCTAssertNil(store.persistenceError)
    }

    func testCorruptFileWithBackupRecoversFromBackup() throws {
        let directory = try makeTempDirectory()
        let backup = StickerPack(name: "Backup Pack")
        try JSONEncoder().encode([backup]).write(to: backupURL(directory), options: .atomic)
        try Data("not valid json".utf8).write(to: packsURL(directory), options: .atomic)

        let store = PackStore(directory: directory)

        XCTAssertEqual(store.packs.count, 1)
        XCTAssertEqual(store.packs.first?.name, "Backup Pack")
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(quarantineFiles(in: directory).count, 1)
    }

    func testCorruptFileWithoutBackupQuarantinesAndReports() throws {
        let directory = try makeTempDirectory()
        try Data("garbage".utf8).write(to: packsURL(directory), options: .atomic)

        let store = PackStore(directory: directory)

        XCTAssertTrue(store.packs.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(quarantineFiles(in: directory).count, 1)
        // The bad bytes are preserved, never deleted or overwritten.
        XCTAssertEqual(try Data(contentsOf: packsURL(directory)), Data("garbage".utf8))
    }

    // MARK: - persist()

    func testSaveCreatesBackupOfPreviousGoodFile() throws {
        let directory = try makeTempDirectory()
        let store = PackStore(directory: directory)

        store.createPack(named: "One")
        XCTAssertFalse(fm.fileExists(atPath: backupURL(directory).path))

        store.createPack(named: "Two")
        XCTAssertTrue(fm.fileExists(atPath: backupURL(directory).path))

        let backedUp = try JSONDecoder().decode(
            [StickerPack].self,
            from: Data(contentsOf: backupURL(directory))
        )
        XCTAssertEqual(backedUp.count, 1)
        XCTAssertEqual(backedUp.first?.name, "One")
        XCTAssertNil(store.persistenceError)

        // A further save refreshes the backup with the previous good file.
        store.createPack(named: "Three")
        let refreshed = try JSONDecoder().decode(
            [StickerPack].self,
            from: Data(contentsOf: backupURL(directory))
        )
        XCTAssertEqual(refreshed.map(\.name), ["One", "Two"])
    }

    // MARK: - removePack()

    func testRemovePackDeletesStickerSources() throws {
        let directory = try makeTempDirectory()

        // Source files live under StickerSourceStore's own (sandbox) directory.
        let source = StickerSource.image(fileName: "test-\(UUID().uuidString).jpg")
        let sourceURL = StickerSourceStore.url(for: source)
        try fm.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: sourceURL, options: .atomic)
        defer { try? fm.removeItem(at: sourceURL) }
        XCTAssertTrue(fm.fileExists(atPath: sourceURL.path))

        let pack = StickerPack(name: "Doomed", stickers: [
            StickerItem(
                kind: .static,
                stickerData: Data([0x00]),
                previewData: Data([0x00]),
                source: source
            )
        ])
        let store = PackStore(directory: directory)
        store.importPack(pack)

        store.removePack(pack.id)

        XCTAssertFalse(fm.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(store.packs.isEmpty)
    }
}
