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
        guard let index = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[index].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        if let source = packs[index].stickers[stickerIndex].source {
            StickerSourceStore.delete(source)
        }
        packs[index].stickers.remove(at: stickerIndex)
        save()
    }

    /// Replaces a sticker in place, keeping its order.
    ///
    /// Primary lookup is by id. Re-encoding an edited sticker (via
    /// `StickerFactory`) produces a fresh id, so when no id matches we fall back
    /// to the sticker's unique source file and keep the original stable id.
    func updateSticker(_ sticker: StickerItem, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }) else { return }
        let stickers = packs[packIndex].stickers

        if let index = stickers.firstIndex(where: { $0.id == sticker.id }) {
            packs[packIndex].stickers[index] = sticker
        } else if let source = sticker.source,
                  let index = stickers.firstIndex(where: { $0.source == source }) {
            let existing = stickers[index]
            packs[packIndex].stickers[index] = StickerItem(
                id: existing.id,
                kind: sticker.kind,
                emojis: sticker.emojis,
                stickerData: sticker.stickerData,
                previewData: sticker.previewData,
                source: sticker.source
            )
        } else {
            return
        }
        save()
    }

    /// Reorders stickers, e.g. from a SwiftUI `ForEach` `.onMove`.
    func moveStickers(in packID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        var stickers = packs[index].stickers

        let moving = fromOffsets.sorted().map { stickers[$0] }
        for offset in fromOffsets.sorted(by: >) {
            stickers.remove(at: offset)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let insertion = max(0, min(toOffset - removedBeforeDestination, stickers.count))
        stickers.insert(contentsOf: moving, at: insertion)

        packs[index].stickers = stickers
        save()
    }

    /// Moves a sticker to index 0 so it becomes the pack's tray/cover image.
    func setCover(_ stickerID: UUID, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.id == stickerID }),
              stickerIndex != 0 else { return }
        let sticker = packs[packIndex].stickers.remove(at: stickerIndex)
        packs[packIndex].stickers.insert(sticker, at: 0)
        save()
    }

    /// Duplicates a sticker next to the original with a new id. The source file
    /// is copied too, so deleting one copy can't remove the other's media.
    func duplicateSticker(_ stickerID: UUID, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.id == stickerID }),
              packs[packIndex].stickers.count < Limits.maxStickers else { return }

        let original = packs[packIndex].stickers[stickerIndex]
        let copiedSource = original.source.flatMap { StickerSourceStore.duplicate($0) }
        let copy = StickerItem(
            kind: original.kind,
            emojis: original.emojis,
            stickerData: original.stickerData,
            previewData: original.previewData,
            source: copiedSource
        )
        packs[packIndex].stickers.insert(copy, at: stickerIndex + 1)
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
