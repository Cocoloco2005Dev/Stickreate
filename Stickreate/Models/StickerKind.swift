import Foundation

/// A WhatsApp sticker pack holds either static or animated stickers — never both.
enum StickerKind: String, Codable, Hashable, Sendable {
    case `static`
    case animated

    var label: String {
        switch self {
        case .static: "Static"
        case .animated: "Animated"
        }
    }
}
