import Observation
import Foundation

/// Owns the user's packs. In-memory for now; file persistence lands in a later phase.
@Observable
final class PackStore {
    var packs: [StickerPack] = []

    @discardableResult
    func createPack(named name: String = "Untitled Pack") -> StickerPack {
        let pack = StickerPack(name: name)
        packs.append(pack)
        return pack
    }

    func pack(with id: UUID) -> StickerPack? {
        packs.first { $0.id == id }
    }

    func add(_ item: StickerItem, to packID: UUID) throws {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        var pack = packs[index]

        if let kind = pack.kind, kind != item.kind {
            throw StickerPack.ValidationError.mixedKinds
        }
        guard pack.stickers.count < Limits.maxStickers else {
            throw StickerPack.ValidationError.tooMany(Limits.maxStickers)
        }

        pack.stickers.append(item)
        packs[index] = pack
    }

    func removeSticker(_ stickerID: UUID, from packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        packs[index].stickers.removeAll { $0.id == stickerID }
    }

    func removePack(_ packID: UUID) {
        packs.removeAll { $0.id == packID }
    }

    func rename(_ packID: UUID, to name: String) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        packs[index].name = name
    }
}
