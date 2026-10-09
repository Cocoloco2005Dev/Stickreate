#if DEBUG
import Foundation

/// Result of one DEBUG self-test run.
///
/// Codable so it can be written to `Documents/selftest-report.json` and shared.
/// The entire file is `#if DEBUG`, so no report type — and no JSON writer —
/// exists in a Release/App Store build.
struct SelfTestReport: Codable, Sendable, Identifiable {
    var id: Date { startedAt }

    /// One check's outcome.
    struct Check: Codable, Sendable, Identifiable, Hashable {
        var id: String { name }
        let name: String
        let passed: Bool
        let durationMS: Double
        let detail: String
    }

    let startedAt: Date
    let checks: [Check]
    let totalDurationMS: Double
    /// Convenience totals (also stored so they appear in the JSON).
    let passed: Int
    let failed: Int
    /// Single summary line, e.g. `[Stickreate SelfTest] PASS 6/6 checks in 412ms`.
    let summary: String

    init(startedAt: Date = Date(), checks: [Check], totalDurationMS: Double) {
        self.startedAt = startedAt
        self.checks = checks
        self.totalDurationMS = totalDurationMS

        let passedCount = checks.filter(\.passed).count
        self.passed = passedCount
        self.failed = checks.count - passedCount

        let failedNames = checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")
        let status = failedNames.isEmpty ? "PASS" : "FAIL"
        self.summary = "[Stickreate SelfTest] \(status) \(passedCount)/\(checks.count) checks in "
            + "\(Int(totalDurationMS.rounded()))ms"
            + (failedNames.isEmpty ? "" : " — failed: \(failedNames)")
    }

    // MARK: - Persistence

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest-report.json", isDirectory: false)
    }

    static var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Writes the report to Documents. Returns the URL on success.
    @discardableResult
    func persist() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(self)
            try data.write(to: SelfTestReport.fileURL, options: .atomic)
            return SelfTestReport.fileURL
        } catch {
            Log.selfTest.error("failed to write report: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func loadLast() -> SelfTestReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(SelfTestReport.self, from: data)
    }
}
#endif
