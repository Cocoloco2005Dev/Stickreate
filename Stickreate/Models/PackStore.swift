import Observation
import Foundation

/// Owns the user's packs and persists them to disk in the app's Documents folder.
@Observable
final class PackStore {
    var packs: [StickerPack] = []

    private let fileURL: URL = {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("packs.json", isDirectory: false)
    }()

    init() {
        load()
    }

    // MARK: - Mutations

    @discardableResult
    func createPack(named name: String = "Untitled Pack") -> StickerPack {
        let pack = StickerPack(name: name)
        packs.append(pack)
        save()
        return pack
    }

    func pack(with id: UUID) -> StickerPack? {
        packs.first { $0.id == id }
    }

    func add(_ item: StickerItem, to packID: UUID) throws {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        var pack = packs[index]

        // Mixed kinds are allowed; the exporter splits them on export.
        guard pack.stickers.count < Limits.maxStickers else {
            throw StickerPack.ValidationError.tooMany(Limits.maxStickers)
        }

        pack.stickers.append(item)
        packs[index] = pack
        save()
    }

    func removeSticker(_ stickerID: UUID, from packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        packs[index].stickers.removeAll { $0.id == stickerID }
        save()
    }

    func removePack(_ packID: UUID) {
        packs.removeAll { $0.id == packID }
        save()
    }

    func rename(_ packID: UUID, to name: String) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        packs[index].name = name
        save()
    }

    func setEmojis(_ emojis: [String], for stickerID: UUID, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        packs[packIndex].stickers[stickerIndex].emojis = Array(emojis.prefix(Limits.maxEmojisPerSticker))
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        packs = (try? JSONDecoder().decode([StickerPack].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(packs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
