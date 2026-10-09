import XCTest
import Foundation
@testable import Stickreate

final class SettingsStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    private func freshTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickreateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDefaults() {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(store.keepOriginalSources)
        XCTAssertFalse(store.hasSeenOnboarding)
    }

    /// The documented accessor must mirror the persisted toggle.
    func testShouldPersistOriginalSourcesMirrorsToggle() {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(store.shouldPersistOriginalSources)
        store.keepOriginalSources = false
        XCTAssertFalse(store.shouldPersistOriginalSources)
    }

    func testValuesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.keepOriginalSources = false
        first.hasSeenOnboarding = true

        let second = SettingsStore(defaults: defaults)
        XCTAssertFalse(second.keepOriginalSources)
        XCTAssertTrue(second.hasSeenOnboarding)
    }

    /// A file written moments ago may still be used by a share sheet or an
    /// in-flight export, so `clearCache` must leave it alone.
    func testClearCacheSkipsRecentFiles() throws {
        let store = SettingsStore(defaults: freshDefaults())
        let dir = try freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recent = dir.appendingPathComponent("recent.tmp")
        try Data(repeating: 0, count: 2048).write(to: recent)

        let freed = store.clearCache(in: dir)

        XCTAssertEqual(freed, 0, "a just-written temp file must be treated as in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    /// Old temp files are removed and only actually-freed bytes are reported.
    func testClearCacheRemovesOldFilesAndReportsFreedBytes() throws {
        let store = SettingsStore(defaults: freshDefaults())
        let dir = try freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = dir.appendingPathComponent("old.tmp")
        try Data(repeating: 0, count: 4096).write(to: old)
        // Backdate past the grace window so it is safe to remove.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: old.path
        )

        let freed = store.clearCache(in: dir)

        XCTAssertEqual(freed, 4096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
}
