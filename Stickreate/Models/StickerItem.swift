import Foundation

struct StickerItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: StickerKind
    var emojis: [String]
    /// WhatsApp-ready WebP bytes (static or animated).
    var stickerData: Data
    /// Square PNG used for on-screen previews.
    var previewData: Data
    /// Original media for re-editing; `nil` for stickers saved before sources
    /// existed (optional so older persisted packs still decode).
    var source: StickerSource?

    init(
        id: UUID = UUID(),
        kind: StickerKind,
        emojis: [String] = [],
        stickerData: Data,
        previewData: Data,
        source: StickerSource? = nil
    ) {
        self.id = id
        self.kind = kind
        self.emojis = emojis
        self.stickerData = stickerData
        self.previewData = previewData
        self.source = source
    }
}
