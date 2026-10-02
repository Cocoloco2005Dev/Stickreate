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

    /// Validates the pack, builds the tray icon, writes the pasteboard and opens WhatsApp.
    static func export(_ pack: StickerPack) throws {
        try pack.validate()

        guard let first = pack.stickers.first else {
            throw Failure.invalid("This pack has no stickers.")
        }
        guard let preview = UIImage(data: first.previewData) else {
            throw Failure.invalid("This pack's preview image is missing.")
        }
        guard let trayPNG = StickerEncoder.trayIcon(from: preview) else {
            throw Failure.invalid("Couldn't build this pack's tray icon.")
        }

        let isAnimated = pack.kind == .animated
        let stickers: [[String: Any]] = pack.stickers.map { sticker in
            [
                "image_data": sticker.stickerData.base64EncodedString(),
                "emojis": Array(sticker.emojis.prefix(Limits.maxEmojisPerSticker)),
                // WhatsApp caps accessibility text at 125 (static) / 255 (animated).
                "accessibility_text": String(pack.name.prefix(isAnimated ? 255 : 125))
            ]
        }

        var payload: [String: Any] = [
            "identifier": sanitized(pack.id.uuidString, max: 128),
            "name": String(pack.name.prefix(128)),
            "publisher": String(pack.publisher.prefix(128)),
            "tray_image": trayPNG.base64EncodedString(),
            "stickers": stickers
        ]
        if isAnimated {
            payload["animated_sticker_pack"] = true
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.invalid("Couldn't build the pack data.")
        }

        // Deliberately NOT gated on `canOpenURL("whatsapp://")`: inside
        // LiveContainer that query returns false even though opening the scheme
        // passes through to the real installed WhatsApp. Attempting the open is
        // the source of truth; if WhatsApp is missing, nothing happens.
        let pasteboardItem: [String: Any] = [pasteboardType: data]
        UIPasteboard.general.setItems(
            [pasteboardItem],
            options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 60)]
        )

        guard let url = URL(string: "whatsapp://stickerPack") else {
            throw Failure.invalid("Couldn't open WhatsApp.")
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Identifier charset WhatsApp accepts: a-z A-Z 0-9 _ - . and space, ≤ 128.
    private static func sanitized(_ value: String, max: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .")
        return String(value.filter { allowed.contains($0) }.prefix(max))
    }
}
