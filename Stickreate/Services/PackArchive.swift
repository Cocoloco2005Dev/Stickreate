import Foundation
import UIKit
import ZIPFoundation

/// Shareable archive of a single pack.
///
/// The container is a ZIP so it is generic and interoperable: a WhatsApp
/// Android `contents.json` manifest plus the community `.wasticker` text files,
/// with WebP stickers and a PNG tray. Other sticker tools can read it and we can
/// read theirs. The legacy proprietary `.stickreatepack` JSON is still
/// importable for backward compatibility.
enum PackArchive {
    enum Failure: LocalizedError, Equatable {
        case invalid
        case unsupportedVersion
        case tooManyStickers
        case mixedKinds
        case payloadTooLarge
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalid:
                "This isn't a valid sticker pack file."
            case .unsupportedVersion:
                "This pack was made with a newer version of Stickreate."
            case .tooManyStickers:
                "This pack has too many stickers (WhatsApp allows up to \(Limits.maxStickers))."
            case .mixedKinds:
                "This pack mixes static and animated stickers, which WhatsApp can't import."
            case .payloadTooLarge:
                "This pack is too large to import."
            case .failed(let message):
                message
            }
        }
    }

    /// Interoperable ZIP extension. The legacy JSON format used `stickreatepack`.
    static let fileExtension = "wasticker"

    private static let legacyFormatIdentifier = "stickreate.pack"
    private static let legacyVersion = 1
    /// ZIP local-file-header magic: "PK".
    private static let zipMagic: [UInt8] = [0x50, 0x4B]

    /// Decompression caps that blunt ZIP-bomb imports: no single entry may
    /// expand past 1 MB, and no archive past 20 MB total.
    private static let maxEntryBytes = 1 * 1024 * 1024
    private static let maxTotalBytes = 20 * 1024 * 1024

    // MARK: - Public API

    /// Builds a `.wasticker` ZIP for `pack`.
    ///
    /// Entries: `contents.json` (WhatsApp Android single-pack manifest),
    /// `cover.png` (96×96 tray from the first sticker's preview), `1.webp`,
    /// `2.webp`, … (each sticker's bytes verbatim), `author.txt`, `title.txt`.
    static func exportData(_ pack: StickerPack) throws -> Data {
        guard let first = pack.stickers.first else { throw Failure.invalid }
        guard let preview = UIImage(data: first.previewData),
              let cover = StickerEncoder.trayIcon(from: preview) else {
            throw Failure.failed("Couldn't build this pack's tray icon.")
        }

        let isAnimated = pack.kind == .animated
        let manifest = makeManifest(pack, isAnimated: isAnimated)
        guard JSONSerialization.isValidJSONObject(manifest),
              let manifestData = try? JSONSerialization.data(
                  withJSONObject: manifest,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            throw Failure.failed("Couldn't build the pack manifest.")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            // Scope the archive so it is released (closing/flushing its backing
            // file) before we read the finished ZIP back off disk.
            do {
                let archive = try Archive(url: temporary, accessMode: .create)
                try add(archive, path: "contents.json", data: manifestData, compressed: true)
                try add(archive, path: "cover.png", data: cover, compressed: false)
                for (index, sticker) in pack.stickers.enumerated() {
                    try add(archive, path: "\(index + 1).webp", data: sticker.stickerData, compressed: false)
                }
                try add(archive, path: "author.txt", data: Data(pack.publisher.utf8), compressed: true)
                try add(archive, path: "title.txt", data: Data(pack.name.utf8), compressed: true)
            }
            return try Data(contentsOf: temporary)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    /// Imports a pack from either a ZIP (`.wasticker` / WhatsApp archive) or the
    /// legacy `.stickreatepack` JSON.
    static func importPack(from data: Data) throws -> StickerPack {
        guard !data.isEmpty else { throw Failure.invalid }
        let pack = data.starts(with: zipMagic)
            ? try importZIP(data)
            : try importLegacyJSON(data)
        try validate(pack)
        return pack
    }

    /// Rejects packs the app and WhatsApp can't hold: empty, over the sticker
    /// cap, or mixing static and animated stickers. The 3-sticker minimum is a
    /// WhatsApp export rule, not an import rule, so it isn't enforced here.
    private static func validate(_ pack: StickerPack) throws {
        if pack.stickers.isEmpty { throw Failure.invalid }
        if pack.stickers.count > Limits.maxStickers { throw Failure.tooManyStickers }
        if pack.isMixed { throw Failure.mixedKinds }
    }

    /// Writes the archive to a temporary `.wasticker` file for sharing.
    static func writeTemporaryFile(_ pack: StickerPack) throws -> URL {
        let data = try exportData(pack)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitizedFileName(pack.name))
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Export manifest

    private static func makeManifest(_ pack: StickerPack, isAnimated: Bool) -> [String: Any] {
        let accessibility = String(pack.name.prefix(isAnimated ? 255 : 125))
        let stickers: [[String: Any]] = pack.stickers.enumerated().map { index, sticker in
            [
                "image_file": "\(index + 1).webp",
                "emojis": Array(sticker.emojis.prefix(Limits.maxEmojisPerSticker)),
                "accessibility_text": accessibility
            ]
        }
        return [
            "android_play_store_link": "",
            "ios_app_store_link": "",
            "sticker_packs": [[
                "identifier": sanitizedIdentifier(pack.id.uuidString),
                "name": String(pack.name.prefix(128)),
                "publisher": String(pack.publisher.prefix(128)),
                "tray_image_file": "cover.png",
                "image_data_version": "1",
                "animated_sticker_pack": isAnimated,
                "stickers": stickers
            ]]
        ]
    }

    // MARK: - Import: ZIP

    private static func importZIP(_ data: Data) throws -> StickerPack {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw Failure.invalid
        }
        // Reject a declared-expansion ZIP bomb before extracting anything.
        let total = archive.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        guard total <= Int64(maxTotalBytes) else { throw Failure.payloadTooLarge }

        if let manifest = archive["contents.json"] {
            return try importManifest(try read(archive, manifest), archive: archive)
        }
        return try importCommunity(archive)
    }

    private static func importManifest(_ data: Data, archive: Archive) throws -> StickerPack {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let packs = root["sticker_packs"] as? [[String: Any]],
              let pack = packs.first else {
            throw Failure.invalid
        }
        let name = (pack["name"] as? String) ?? "Imported Pack"
        let publisher = (pack["publisher"] as? String) ?? "Unknown"
        let isAnimated = (pack["animated_sticker_pack"] as? Bool) ?? false
        let kind: StickerKind = isAnimated ? .animated : .static

        let tray = (pack["tray_image_file"] as? String)
            .flatMap { archive[$0] }
            .flatMap { try? read(archive, $0) }

        guard let entries = pack["stickers"] as? [[String: Any]], !entries.isEmpty else {
            throw Failure.invalid
        }
        guard entries.count <= Limits.maxStickers else { throw Failure.tooManyStickers }
        let stickers = try entries.map { entry -> StickerItem in
            guard let file = entry["image_file"] as? String,
                  let imageEntry = archive[file] else {
                throw Failure.invalid
            }
            let imageData = try read(archive, imageEntry)
            guard !imageData.isEmpty else { throw Failure.invalid }
            let emojis = (entry["emojis"] as? [String]) ?? []
            return StickerItem(
                kind: kind,
                emojis: Array(emojis.prefix(Limits.maxEmojisPerSticker)),
                stickerData: imageData,
                previewData: makePreview(imageData, fallback: tray),
                source: nil
            )
        }
        return StickerPack(name: name, publisher: publisher, stickers: stickers)
    }

    /// `.wasticker` community layout: `title.txt` / `author.txt` plus image
    /// files. The kind is inferred from whether the first WebP is animated.
    private static func importCommunity(_ archive: Archive) throws -> StickerPack {
        let name = string(in: archive, path: "title.txt") ?? "Imported Pack"
        let publisher = string(in: archive, path: "author.txt") ?? "Unknown"
        let tray = archive["cover.png"].flatMap { try? read(archive, $0) }
            ?? archive["cover.webp"].flatMap { try? read(archive, $0) }

        let metadata: Set<String> = ["contents.json", "title.txt", "author.txt", "cover.png", "cover.webp"]
        let images = archive
            .filter { entry in
                entry.type == .file
                    && !entry.path.hasPrefix("__MACOSX")
                    && !metadata.contains(entry.path.lowercased())
                    && isImagePath(entry.path)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !images.isEmpty else { throw Failure.invalid }
        guard images.count <= Limits.maxStickers else { throw Failure.tooManyStickers }

        let isAnimated = (try? read(archive, images[0])).map(isAnimatedWebP) ?? false
        let kind: StickerKind = isAnimated ? .animated : .static

        let stickers = try images.map { entry -> StickerItem in
            let imageData = try read(archive, entry)
            return StickerItem(
                kind: kind,
                emojis: [],
                stickerData: imageData,
                previewData: makePreview(imageData, fallback: tray),
                source: nil
            )
        }
        return StickerPack(name: name, publisher: publisher, stickers: stickers)
    }

    // MARK: - Import: legacy JSON

    private static func importLegacyJSON(_ data: Data) throws -> StickerPack {
        let archive: LegacyArchive
        do {
            archive = try JSONDecoder().decode(LegacyArchive.self, from: data)
        } catch {
            throw Failure.invalid
        }
        guard archive.format == legacyFormatIdentifier else { throw Failure.invalid }
        guard archive.version >= 1, archive.version <= legacyVersion else {
            throw Failure.unsupportedVersion
        }
        guard archive.stickers.count <= Limits.maxStickers else { throw Failure.tooManyStickers }

        let stickers = try archive.stickers.map { archived -> StickerItem in
            guard let stickerData = Data(base64Encoded: archived.sticker),
                  let previewData = Data(base64Encoded: archived.preview) else {
                throw Failure.invalid
            }
            return StickerItem(
                kind: archived.kind,
                emojis: Array(archived.emojis.prefix(Limits.maxEmojisPerSticker)),
                stickerData: stickerData,
                previewData: previewData,
                source: nil
            )
        }
        return StickerPack(
            name: archive.name,
            publisher: archive.publisher,
            stickers: stickers,
            folder: normalizedFolder(archive.folder)
        )
    }

    private struct LegacyArchive: Codable {
        var format: String
        var version: Int
        var name: String
        var publisher: String
        var folder: String?
        var stickers: [LegacySticker]
    }

    private struct LegacySticker: Codable {
        var kind: StickerKind
        var emojis: [String]
        var sticker: String
        var preview: String
    }

    // MARK: - ZIP helpers

    private static func add(_ archive: Archive, path: String, data: Data, compressed: Bool) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressed ? .deflate : .none,
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start < end else { return Data() }
                let lower = data.startIndex + start
                let upper = lower + (end - start)
                return Data(data[lower..<upper])
            }
        )
    }

    private static func read(_ archive: Archive, _ entry: Entry) throws -> Data {
        // Cap both the declared size and the bytes actually produced, so a
        // lying header can't slip a huge entry through.
        guard Int64(entry.uncompressedSize) <= Int64(maxEntryBytes) else { throw Failure.payloadTooLarge }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
            if data.count > maxEntryBytes { throw Failure.payloadTooLarge }
        })
        guard data.count <= maxEntryBytes else { throw Failure.payloadTooLarge }
        return data
    }

    private static func string(in archive: Archive, path: String) -> String? {
        guard let entry = archive[path], let data = try? read(archive, entry) else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// A square PNG preview for an imported sticker. Sticker bytes are WebP,
    /// which ImageIO decodes on iOS 14+; falls back to the pack tray (or the raw
    /// bytes) if decoding fails.
    private static func makePreview(_ stickerData: Data, fallback: Data?) -> Data {
        if let image = UIImage(data: stickerData),
           let png = StickerEncoder.previewPNG(from: image, size: CGFloat(Limits.canvas)) {
            return png
        }
        return fallback ?? stickerData
    }

    private static func isImagePath(_ path: String) -> Bool {
        ["webp", "png", "jpg", "jpeg", "gif"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A WebP is animated when it carries an `ANIM` chunk (RIFF/WEBP extended).
    private static func isAnimatedWebP(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        return data.prefix(32).range(of: Data("ANIM".utf8)) != nil
    }

    // MARK: - Helpers

    private static func normalizedFolder(_ folder: String?) -> String? {
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .")
        let filtered = String(value.filter { allowed.contains($0) })
        return filtered.isEmpty ? UUID().uuidString : String(filtered.prefix(128))
    }

    /// Keeps the file name to a safe, readable subset of the pack name.
    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ .")
        let filtered = String(name.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? "pack" : String(filtered.prefix(64))
    }
}
