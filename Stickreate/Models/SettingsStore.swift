import Observation
import Foundation

/// Where an export goes by default.
enum ExportMode: String, CaseIterable, Codable, Sendable {
    case whatsApp
    case file

    var label: String {
        switch self {
        case .whatsApp:
            "WhatsApp"
        case .file:
            "File"
        }
    }
}

/// App-wide preferences, persisted to `UserDefaults` under `stickreate.` keys.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Keys {
        static let defaultFPS = "stickreate.defaultFPS"
        static let confirmIntelligentCut = "stickreate.confirmIntelligentCut"
        static let keepOriginalSources = "stickreate.keepOriginalSources"
        static let hasSeenOnboarding = "stickreate.hasSeenOnboarding"
        static let exportMode = "stickreate.exportMode"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // Tracked backing storage; the public properties stay observable and persist.
    private var storedDefaultFPS: Int
    private var storedConfirmIntelligentCut: Bool
    private var storedKeepOriginalSources: Bool
    private var storedHasSeenOnboarding: Bool
    private var storedExportMode: ExportMode

    /// Frames per second for video stickers, clamped to `5...30`.
    var defaultFPS: Int {
        get { storedDefaultFPS }
        set {
            storedDefaultFPS = min(max(newValue, 5), 30)
            defaults.set(storedDefaultFPS, forKey: Keys.defaultFPS)
        }
    }

    /// Ask before running the automatic subject cut-out on photos.
    var confirmIntelligentCut: Bool {
        get { storedConfirmIntelligentCut }
        set {
            storedConfirmIntelligentCut = newValue
            defaults.set(newValue, forKey: Keys.confirmIntelligentCut)
        }
    }

    /// Keep the original media on disk so stickers stay re-editable.
    var keepOriginalSources: Bool {
        get { storedKeepOriginalSources }
        set {
            storedKeepOriginalSources = newValue
            defaults.set(newValue, forKey: Keys.keepOriginalSources)
        }
    }

    var hasSeenOnboarding: Bool {
        get { storedHasSeenOnboarding }
        set {
            storedHasSeenOnboarding = newValue
            defaults.set(newValue, forKey: Keys.hasSeenOnboarding)
        }
    }

    /// Default export destination.
    var exportMode: ExportMode {
        get { storedExportMode }
        set {
            storedExportMode = newValue
            defaults.set(newValue.rawValue, forKey: Keys.exportMode)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedDefaultFPS = min(max(defaults.object(forKey: Keys.defaultFPS) as? Int ?? 10, 5), 30)
        self.storedConfirmIntelligentCut = defaults.object(forKey: Keys.confirmIntelligentCut) as? Bool ?? true
        self.storedKeepOriginalSources = defaults.object(forKey: Keys.keepOriginalSources) as? Bool ?? true
        self.storedHasSeenOnboarding = defaults.object(forKey: Keys.hasSeenOnboarding) as? Bool ?? false
        self.storedExportMode = defaults.string(forKey: Keys.exportMode)
            .flatMap(ExportMode.init(rawValue:)) ?? .whatsApp
    }

    // MARK: - Storage

    /// Removes app temporary files. Never touches `Documents/Sources`, so
    /// stickers' editable originals are always preserved.
    /// - Returns: approximate bytes freed.
    @discardableResult
    func clearCache() -> Int {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var freed = 0
        for url in contents {
            freed += Self.byteSize(of: url)
            try? fileManager.removeItem(at: url)
        }
        return freed
    }

    /// Human-readable size of `Documents/Sources` plus `packs.json`.
    var storageSummary: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sources = documents.appendingPathComponent("Sources", isDirectory: true)
        let packs = documents.appendingPathComponent("packs.json", isDirectory: false)
        let total = Self.directorySize(sources) + (Self.fileSize(packs) ?? 0)
        return Self.format(total)
    }

    // MARK: - Sizing helpers

    private static func directorySize(_ url: URL) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total = 0
        for case let file as URL in enumerator {
            total += fileSize(file) ?? 0
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return nil }
        return values?.fileSize
    }

    /// Size of a file or (recursively) a directory, for cache reporting.
    private static func byteSize(of url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        return isDirectory.boolValue ? directorySize(url) : (fileSize(url) ?? 0)
    }

    private static func format(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
