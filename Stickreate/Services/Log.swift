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
enum Log {
    static let subsystem = "com.cocol.stickreate"

    /// WebP encoding (static + animated): sizes, frame counts, elapsed time.
    static let encode = Logger(subsystem: subsystem, category: "encode")
    /// Frame extraction from video/GIF.
    static let extraction = Logger(subsystem: subsystem, category: "extraction")
    /// Vision subject cut-out.
    static let vision = Logger(subsystem: subsystem, category: "vision")

    #if DEBUG
    /// DEBUG self-test summary line. Gated so no `selfTest` category (or the
    /// string "selfTest") is emitted in a Release/App Store build.
    static let selfTest = Logger(subsystem: subsystem, category: "selfTest")
    #endif
}
