import Observation
import Foundation

/// Owns the user's packs and persists them to disk in the app's Documents folder.
@Observable
final class PackStore {
    /// One store shared by RootView and the library so they present the same data.
    static let shared = PackStore()

    var packs: [StickerPack] = []

    /// User-facing message for the most recent persistence problem, if any.
    /// Set when a load had to recover/quarantine or a save failed; RootView
    /// observes it and presents it in an alert.
    var persistenceError: String?

    /// Set when `load()` had to quarantine a corrupt file. Suppresses the orphan
    /// sweep, since `packs` may then be a partial or recovered view of the library.
    private var recoveredFromCorruptFile = false

    private let directory: URL

    private var fileURL: URL {
        directory.appendingPathComponent("packs.json", isDirectory: false)
    }

    private var backupURL: URL {
        directory.appendingPathComponent("packs.json.bak", isDirectory: false)
    }

    /// `directory` is injectable so tests can point the store at a temp folder;
    /// production uses the app's Documents directory.
    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
        load()
        reconcileSources()
    }

    /// Clears the current persistence message, e.g. after the alert is dismissed.
    func clearPersistenceError() {
        persistenceError = nil
    }

    // MARK: - Mutations

    @discardableResult
    func createPack(named name: String = "Untitled Pack") -> StickerPack {
        let pack = StickerPack(name: name)
        packs.append(pack)
        persist()
        return pack
    }

    /// Validates and inserts an imported pack, then persists it.
    ///
    /// Imported packs may hold fewer than WhatsApp's minimum of 3, so the
    /// minimum isn't enforced here — but a pack must be non-empty, within
    /// `Limits.maxStickers`, and single-kind. Rejected packs aren't stored and
    /// are surfaced through `persistenceError`.
    @discardableResult
    func importPack(_ pack: StickerPack) -> Bool {
        guard !pack.stickers.isEmpty,
              pack.stickers.count <= Limits.maxStickers,
              !pack.isMixed else {
            persistenceError = "This pack couldn't be imported: it's empty, too large, or mixes sticker types."
            return false
        }
        packs.append(pack)
        persist()
        return true
    }

    func pack(with id: UUID) -> StickerPack? {
        packs.first { $0.id == id }
    }

    func add(_ item: StickerItem, to packID: UUID) throws {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        var pack = packs[index]

        // Packs are single-kind: adding the other kind would mix them.
        if let existing = pack.stickers.first, existing.kind != item.kind {
            throw StickerPack.ValidationError.mixedKinds
        }
        guard pack.stickers.count < Limits.maxStickers else {
            throw StickerPack.ValidationError.tooMany(Limits.maxStickers)
        }

        pack.stickers.append(item)
        packs[index] = pack
        persist()
    }

    func removeSticker(_ stickerID: UUID, from packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[index].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        if let source = packs[index].stickers[stickerIndex].source {
            StickerSourceStore.delete(source)
        }
        packs[index].stickers.remove(at: stickerIndex)
        persist()
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
        persist()
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
        persist()
    }

    /// Moves a sticker to index 0 so it becomes the pack's tray/cover image.
    func setCover(_ stickerID: UUID, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.id == stickerID }),
              stickerIndex != 0 else { return }
        let sticker = packs[packIndex].stickers.remove(at: stickerIndex)
        packs[packIndex].stickers.insert(sticker, at: 0)
        persist()
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
        persist()
    }

    func removePack(_ packID: UUID) {
        if let pack = packs.first(where: { $0.id == packID }) {
            for sticker in pack.stickers {
                if let source = sticker.source {
                    StickerSourceStore.delete(source)
                }
            }
        }
        packs.removeAll { $0.id == packID }
        persist()
    }

    func rename(_ packID: UUID, to name: String) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        packs[index].name = name
        persist()
    }

    /// Assigns (or clears) a pack's folder. Blank strings clear the folder.
    func setFolder(_ folder: String?, for packID: UUID) {
        guard let index = packs.firstIndex(where: { $0.id == packID }) else { return }
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        packs[index].folder = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist()
    }

    /// All distinct, non-empty folders, sorted for display.
    var folders: [String] {
        Set(packs.compactMap { $0.folder }).sorted()
    }

    func setEmojis(_ emojis: [String], for stickerID: UUID, in packID: UUID) {
        guard let packIndex = packs.firstIndex(where: { $0.id == packID }),
              let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.id == stickerID }) else { return }
        packs[packIndex].stickers[stickerIndex].emojis = Array(emojis.prefix(Limits.maxEmojisPerSticker))
        persist()
    }

    // MARK: - Persistence

    private func load() {
        // Missing packs.json is the normal first-launch case: start empty, no error.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StickerPack].self, from: data) else {
            // Present but unreadable or undecodable: quarantine and recover.
            recoverFromCorruptFile()
            return
        }

        packs = decoded
    }

    /// Keeps the bad bytes in a quarantine copy, then either restores the last
    /// good backup or starts empty with a message. The original is never deleted.
    private func recoverFromCorruptFile() {
        recoveredFromCorruptFile = true
        let quarantineURL = directory.appendingPathComponent(quarantineFileName(), isDirectory: false)
        try? FileManager.default.copyItem(at: fileURL, to: quarantineURL)

        if let backupData = try? Data(contentsOf: backupURL),
           let decoded = try? JSONDecoder().decode([StickerPack].self, from: backupData) {
            packs = decoded
            persistenceError = "Your library had to be restored from a backup."
        } else {
            packs = []
            persistenceError = "Your library couldn't be read. A copy was kept as \(quarantineURL.lastPathComponent)."
        }
    }

    /// Filename-safe ISO timestamp, e.g. `packs.corrupt-2026-10-09T12-34-56Z.json`.
    private func quarantineFileName() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "packs.corrupt-\(timestamp).json"
    }

    /// Deletes files in `Sources/` that no pack's `sticker.source` references.
    ///
    /// Conservative: only regular files directly inside `Sources/` are removed
    /// (directories are left alone), and the sweep is skipped when `load()` hit
    /// a problem — otherwise an empty/partial `packs` would make live sources
    /// look orphaned and wipe them.
    func reconcileSources() {
        guard !recoveredFromCorruptFile, persistenceError == nil else { return }

        let fileManager = FileManager.default
        let sourcesURL = directory.appendingPathComponent("Sources", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }

        let referenced = Set(packs.flatMap { $0.stickers.compactMap { $0.source?.fileName } })
        for file in files where !referenced.contains(file.lastPathComponent) {
            let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    /// Single funnel for writes. Mutators stay non-throwing; failures surface
    /// through `persistenceError` instead of silently resetting the library.
    private func persist() {
        let data: Data
        do {
            data = try JSONEncoder().encode(packs)
        } catch {
            persistenceError = "Your library couldn't be saved."
            return
        }

        // Roll the previous file to the backup with a cheap move (no read/decode).
        // A corrupt packs.json is handled at load via quarantine, so it needn't
        // be re-validated here.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.moveItem(at: fileURL, to: backupURL)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Not enough storage — your last change wasn't saved."
        }
    }
}
