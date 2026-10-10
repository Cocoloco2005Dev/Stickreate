import UIKit

/// Imports a finished pack into WhatsApp.
///
/// Mechanism (official): write the pack JSON to `UIPasteboard.general` under the
/// type `net.whatsapp.third-party.sticker-pack`, then open `whatsapp://stickerPack`.
/// Source: https://github.com/WhatsApp/stickers (iOS).
@MainActor
enum WhatsAppExporter {
    enum Failure: LocalizedError {
        case notInstalled
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "WhatsApp isn't installed on this iPhone."
            case .invalid(let message):
                message
            }
        }
    }

    /// Pasteboard type WhatsApp reads third-party packs from.
    private static let pasteboardType = "net.whatsapp.third-party.sticker-pack"

    static var isWhatsAppInstalled: Bool {
        guard let url = URL(string: "whatsapp://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Validates a single-kind pack and exports it.
    ///
    /// Mixed packs can't be imported by WhatsApp in one go; callers should export
    /// `pack.staticStickers` and `pack.animatedStickers` separately through
    /// `export(stickers:kind:name:publisher:identifier:)`.
    ///
    /// The identifier is derived from the pack's stable `id` (never a fresh UUID
    /// per call) and `name`/`publisher` come straight from the pack, so
    /// re-exporting the same pack reuses the same identifier and updates the
    /// existing WhatsApp pack instead of creating a new one. WhatsApp has a known
    /// bug where it can still show a duplicate entry even when the identifier is
    /// unchanged.
    static func export(_ pack: StickerPack) throws {
        try pack.validate()
        Log.info(
            .export,
            "validation passed stickers=\(pack.stickers.count) mixed=\(pack.isMixed)"
        )
        guard !pack.isMixed else {
            throw Failure.invalid("This pack mixes static and animated stickers. Export each kind separately.")
        }
        guard let kind = pack.kind else {
            throw Failure.invalid("This pack has no stickers.")
        }
        try export(
            stickers: pack.stickers,
            kind: kind,
            name: pack.name,
            publisher: pack.publisher,
            identifier: pack.id.uuidString
        )
    }

    /// Builds and imports a single-kind WhatsApp pack from `stickers`.
    ///
    /// `identifier` is sanitized to WhatsApp's accepted charset and
    /// `animated_sticker_pack` is set only for `kind == .animated`. The tray icon
    /// comes from the first sticker's `previewData`. Callers must pass a stable
    /// `identifier` for a given pack (and a distinct suffix per kind for a split
    /// mixed pack) so re-exports update the existing pack.
    static func export(
        stickers: [StickerItem],
        kind: StickerKind,
        name: String,
        publisher: String,
        identifier: String
    ) throws {
        guard let first = stickers.first else {
            throw Failure.invalid("This pack has no stickers.")
        }
        guard let preview = UIImage(data: first.previewData) else {
            throw Failure.invalid("This pack's preview image is missing.")
        }
        guard let trayPNG = StickerEncoder.trayIcon(from: preview) else {
            throw Failure.invalid("Couldn't build this pack's tray icon.")
        }
        Log.info(
            .export,
            "export kind=\(kind) stickers=\(stickers.count) tray=\(trayPNG.count)B"
        )

        let isAnimated = kind == .animated
        let stickerJSON: [[String: Any]] = stickers.map { sticker in
            [
                "image_data": sticker.stickerData.base64EncodedString(),
                "emojis": Array(sticker.emojis.prefix(Limits.maxEmojisPerSticker)),
                // WhatsApp caps accessibility text at 125 (static) / 255 (animated).
                "accessibility_text": String(name.prefix(isAnimated ? 255 : 125))
            ]
        }

        var payload: [String: Any] = [
            "identifier": sanitized(identifier, max: 128),
            "name": String(name.prefix(128)),
            "publisher": String(publisher.prefix(128)),
            "tray_image": trayPNG.base64EncodedString(),
            "stickers": stickerJSON
        ]
        if isAnimated {
            payload["animated_sticker_pack"] = true
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.invalid("Couldn't build the pack data.")
        }
        Log.info(.export, "payload bytes=\(data.count)")

        // Deliberately NOT gated on `canOpenURL("whatsapp://")`: inside
        // LiveContainer that query returns false even though opening the scheme
        // passes through to the real installed WhatsApp. Attempting the open is
        // the source of truth; if WhatsApp is missing, nothing happens.
        //
        // Error 1000 is an undocumented catch-all caused by a pasteboard/open
        // race ("error, then it works"). Kill its causes: write the pasteboard
        // exactly once (no separate clear that races WhatsApp's read), serialize
        // exports so only one open is ever in flight, give WhatsApp a
        // size-adaptive beat to read, then retry the write+open once if the open
        // reports failure.
        openTask?.cancel()
        openTask = Task { @MainActor in
            await runOpenSequence(payload: data)
        }
    }

    /// In-flight write+open sequence. Replaced on each export so a second export
    /// cancels the previous one instead of firing a second `open`.
    private static var openTask: Task<Void, Never>?

    /// Writes the pasteboard and opens WhatsApp after an adaptive delay, retrying
    /// the whole write+open once if the open completion reports failure.
    private static func runOpenSequence(payload: Data, isRetry: Bool = false) async {
        writePasteboard(payload)
        let delay = openDelay(forByteCount: payload.count)
        Log.info(.export, "open scheduled delay=\(delay)s retry=\(isRetry)")
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let url = URL(string: "whatsapp://stickerPack") else { return }

        let opened = await open(url)
        Log.info(.export, "open result success=\(opened) retry=\(isRetry)")
        if !opened, !isRetry, !Task.isCancelled {
            await runOpenSequence(payload: payload, isRetry: true)
        }
    }

    /// Single pasteboard transaction: one write, `.localOnly` so it never syncs,
    /// and a 120 s expiration so a late WhatsApp read doesn't hit an expired entry.
    private static func writePasteboard(_ payload: Data) {
        UIPasteboard.general.setItems(
            [[pasteboardType: payload]],
            options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 120)]
        )
        Log.info(.export, "pasteboard write done bytes=\(payload.count)")
    }

    /// Size-adaptive pre-open delay, bounded to 0.4–1.2 s: small packs open
    /// sooner, multi-MB packs get longer for WhatsApp to read the pasteboard.
    private static func openDelay(forByteCount bytes: Int) -> TimeInterval {
        let scaled = 0.4 + Double(bytes) / 4_000_000 * 0.8
        return min(max(scaled, 0.4), 1.2)
    }

    /// Opens WhatsApp's sticker importer and reports whether the system accepted it.
    private static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Identifier charset WhatsApp accepts: a-z A-Z 0-9 _ - . and space, ≤ 128.
    private static func sanitized(_ value: String, max: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .")
        return String(value.filter { allowed.contains($0) }.prefix(max))
    }
}
