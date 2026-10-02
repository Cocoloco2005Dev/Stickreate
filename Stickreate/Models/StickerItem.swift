import Foundation

struct StickerItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: StickerKind
    var emojis: [String]
    /// WhatsApp-ready WebP bytes (static or animated).
    var stickerData: Data
    /// Square PNG used for on-screen previews.
    var previewData: Data

    init(
        id: UUID = UUID(),
        kind: StickerKind,
        emojis: [String] = [],
        stickerData: Data,
        previewData: Data
    ) {
        self.id = id
        self.kind = kind
        self.emojis = emojis
        self.stickerData = stickerData
        self.previewData = previewData
    }
}
