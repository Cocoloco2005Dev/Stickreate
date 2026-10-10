import OSLog

/// Structured, privacy-safe logging for the perf-critical pipeline stages.
///
/// One subsystem, one category per stage, so Console / `log stream` can filter
/// (`subsystem == "com.cocol.stickreate" AND category == "encode"`). Numeric
/// counts/durations are logged `.public`; anything that could identify media
/// stays `.private` (the default for interpolated values).
///
/// This helper is intentionally *not* `#if DEBUG`-gated: os.Logger is a
/// production-grade, privacy-safe observability tool (see audit P2-20), and it
/// carries no self-test code. The DEBUG-only self-test is what gets stripped.
///
/// The `info`/`timing`/`error` helpers below ALSO append the same sanitized line
/// to `DebugLog.shared`, so the user can copy/share an in-app diagnostics log
/// from Settings (available in Release).
enum Log {
    static let subsystem = "com.cocol.stickreate"

    /// WebP encoding (static + animated): sizes, frame counts, elapsed time.
    static let encode = Logger(subsystem: subsystem, category: "encode")
    /// Frame extraction from video/GIF.
    static let extraction = Logger(subsystem: subsystem, category: "extraction")
    /// Vision subject cut-out.
    static let vision = Logger(subsystem: subsystem, category: "vision")
    /// WhatsApp pack export.
    static let export = Logger(subsystem: subsystem, category: "export")
    /// Pack archive import/export.
    static let archive = Logger(subsystem: subsystem, category: "archive")
    /// Anything that doesn't fit a stage above.
    static let general = Logger(subsystem: subsystem, category: "general")

    #if DEBUG
    /// DEBUG self-test summary line. Gated so no `selfTest` category (or the
    /// string "selfTest") is emitted in a Release/App Store build.
    static let selfTest = Logger(subsystem: subsystem, category: "selfTest")
    #endif

    /// A stage category: selects the matching `os.Logger` and names the line in
    /// the in-app `DebugLog`.
    enum Category: String {
        case encode
        case extraction
        case vision
        case export
        case archive
        case general

        fileprivate var logger: Logger {
            switch self {
            case .encode: Log.encode
            case .extraction: Log.extraction
            case .vision: Log.vision
            case .export: Log.export
            case .archive: Log.archive
            case .general: Log.general
            }
        }
    }

    /// Logs a message to Console AND the in-app `DebugLog`.
    static func info(_ category: Category, _ message: String) {
        category.logger.info("\(message, privacy: .public)")
        DebugLog.shared.append(category: category.rawValue, message: message)
    }

    /// Logs an error to Console AND the in-app `DebugLog`.
    static func error(_ category: Category, _ message: String) {
        category.logger.error("\(message, privacy: .public)")
        DebugLog.shared.append(category: category.rawValue, message: message)
    }

    /// Records a duration in **milliseconds** (Console + `DebugLog`).
    static func timing(_ category: Category, _ label: String, ms: Double) {
        let rounded = (ms * 10).rounded() / 10
        let message = "\(label) \(rounded)ms"
        category.logger.debug("\(message, privacy: .public)")
        DebugLog.shared.append(category: category.rawValue, message: message)
    }
}
