import Foundation

struct StickerPack: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var publisher: String
    var stickers: [StickerItem]
    /// Optional user folder/group; `nil` for packs saved before folders existed.
    var folder: String?

    init(
        id: UUID = UUID(),
        name: String,
        publisher: String = "Stickreate",
        stickers: [StickerItem] = [],
        folder: String? = nil
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.stickers = stickers
        self.folder = folder
    }

    /// The pack's kind is fixed by its first sticker.
    var kind: StickerKind? {
        stickers.first?.kind
    }

    /// True when the pack holds both static and animated stickers. WhatsApp can't
    /// import a mixed pack, so the exporter splits it by kind.
    var isMixed: Bool {
        Set(stickers.map(\.kind)).count > 1
    }

    var staticStickers: [StickerItem] {
        stickers.filter { $0.kind == .static }
    }

    var animatedStickers: [StickerItem] {
        stickers.filter { $0.kind == .animated }
    }

    /// The sticker shown in WhatsApp's tray picker.
    var traySourcePreview: Data? {
        stickers.first?.previewData
    }

    enum ValidationError: LocalizedError, Equatable {
        case tooFew(Int)
        case tooMany(Int)
        case mixedKinds

        var errorDescription: String? {
            switch self {
            case .tooFew(let minimum):
                "A pack needs at least \(minimum) stickers."
            case .tooMany(let maximum):
                "A pack can hold at most \(maximum) stickers."
            case .mixedKinds:
                "A pack can't mix static and animated stickers."
            }
        }
    }

    /// A pack may hold up to 30 stickers. It may mix static and animated
    /// stickers, but every non-empty kind group must still reach WhatsApp's
    /// minimum of 3 — the exporter then splits the pack by kind.
    func validate() throws {
        if stickers.count > Limits.maxStickers {
            throw ValidationError.tooMany(Limits.maxStickers)
        }
        if !staticStickers.isEmpty && staticStickers.count < Limits.minStickers {
            throw ValidationError.tooFew(Limits.minStickers)
        }
        if !animatedStickers.isEmpty && animatedStickers.count < Limits.minStickers {
            throw ValidationError.tooFew(Limits.minStickers)
        }
    }
}
