import Foundation

/// In-app, privacy-safe diagnostics ring buffer.
///
/// Keeps the last `capacity` structured lines produced through `Log` so a user
/// can copy/share them from Settings — a support feature that is available in
/// Release (it is not the DEBUG self-test). Deliberately in-memory only: no file
/// I/O, no network. Messages are the same already-sanitized strings sent to
/// `os.Logger` (frame counts, byte sizes, durations, categories) and never carry
/// image bytes, credentials, or user-identifying data.
///
/// Thread-safe: every access is guarded by a single lock, so appends from
/// background encode/extract work can't race the Settings UI.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    struct Entry {
        let timestamp: Date
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    /// Only touched while `lock` is held (`DateFormatter` is not thread-safe).
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    /// Appends one entry, dropping the oldest when the buffer is full.
    func append(category: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(timestamp: Date(), category: category, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Number of buffered entries.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Clears the buffer.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
    }

    /// Ordered text export. Newest-last (chronological) by default; pass
    /// `newestFirst: true` for reverse order. A labeled header names the order
    /// and the entry count. Suitable for `UIPasteboard` / a share sheet.
    func text(newestFirst: Bool = false) -> String {
        lock.lock()
        defer { lock.unlock() }
        let ordered = newestFirst ? Array(entries.reversed()) : entries
        let order = newestFirst ? "newest first" : "oldest first"
        var lines = ["Stickreate debug log — \(entries.count) entries (\(order))"]
        for entry in ordered {
            lines.append("[\(formatter.string(from: entry.timestamp))] [\(entry.category)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}
