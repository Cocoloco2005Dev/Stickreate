import XCTest
@testable import Stickreate

final class SettingsStoreTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
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
}
