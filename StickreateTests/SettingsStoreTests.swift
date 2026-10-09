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
        XCTAssertEqual(store.defaultFPS, 10)
        XCTAssertTrue(store.confirmIntelligentCut)
        XCTAssertTrue(store.keepOriginalSources)
        XCTAssertFalse(store.hasSeenOnboarding)
        XCTAssertEqual(store.exportMode, .whatsApp)
    }

    func testDefaultFPSClampsToRange() {
        let store = SettingsStore(defaults: freshDefaults())
        store.defaultFPS = 99
        XCTAssertEqual(store.defaultFPS, 30)
        store.defaultFPS = 1
        XCTAssertEqual(store.defaultFPS, 5)
    }

    func testValuesPersistAcrossInstances() {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.defaultFPS = 24
        first.confirmIntelligentCut = false
        first.keepOriginalSources = false
        first.hasSeenOnboarding = true
        first.exportMode = .file

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.defaultFPS, 24)
        XCTAssertFalse(second.confirmIntelligentCut)
        XCTAssertFalse(second.keepOriginalSources)
        XCTAssertTrue(second.hasSeenOnboarding)
        XCTAssertEqual(second.exportMode, .file)
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
