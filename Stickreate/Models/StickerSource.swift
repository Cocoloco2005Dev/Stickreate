import Foundation

/// Reference to the original picked media kept in app storage so a sticker can
/// be re-opened and edited again. `fileName` is relative to
/// `Documents/Sources/`.
enum StickerSource: Codable, Hashable, Sendable {
    case image(fileName: String)
    case video(fileName: String)
    case gif(fileName: String)

    var fileName: String {
        switch self {
        case .image(let fileName), .video(let fileName), .gif(let fileName):
            fileName
        }
    }
}
