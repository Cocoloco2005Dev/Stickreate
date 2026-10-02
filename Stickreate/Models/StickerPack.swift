import Foundation

struct StickerPack: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var publisher: String
    var stickers: [StickerItem]

    init(
        id: UUID = UUID(),
        name: String,
        publisher: String = "Stickreate",
        stickers: [StickerItem] = []
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.stickers = stickers
    }

    /// The pack's kind is fixed by its first sticker.
    var kind: StickerKind? {
        stickers.first?.kind
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

    func validate() throws {
        if stickers.count < Limits.minStickers {
            throw ValidationError.tooFew(Limits.minStickers)
        }
        if stickers.count > Limits.maxStickers {
            throw ValidationError.tooMany(Limits.maxStickers)
        }
        if Set(stickers.map(\.kind)).count > 1 {
            throw ValidationError.mixedKinds
        }
    }
}
