import Foundation

struct StickerItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: StickerKind
    var emojis: [String]

    init(id: UUID = UUID(), kind: StickerKind, emojis: [String] = []) {
        self.id = id
        self.kind = kind
        self.emojis = emojis
    }
}
