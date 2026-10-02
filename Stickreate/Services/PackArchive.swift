import Foundation

/// Shareable archive of a single pack. The format is a small JSON envelope so
/// packs can be AirDropped/shared as a `.stickreatepack` file and re-imported
/// with fresh ids (imported stickers are not re-editable).
enum PackArchive {
    enum Failure: LocalizedError {
        case invalid
        case unsupportedVersion
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalid:
                "This isn't a valid Stickreate pack."
            case .unsupportedVersion:
                "This pack was made with a newer version of Stickreate."
            case .failed(let message):
                message
            }
        }
    }

    private static let formatIdentifier = "stickreate.pack"
    private static let currentVersion = 1
    private static let fileExtension = "stickreatepack"

    // MARK: - Public API

    static func exportData(_ pack: StickerPack) throws -> Data {
        let archive = Archive(
            format: formatIdentifier,
            version: currentVersion,
            name: pack.name,
            publisher: pack.publisher,
            folder: pack.folder,
            stickers: pack.stickers.map { sticker in
                ArchivedSticker(
                    kind: sticker.kind,
                    emojis: sticker.emojis,
                    sticker: sticker.stickerData.base64EncodedString(),
                    preview: sticker.previewData.base64EncodedString()
                )
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(archive)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    static func importPack(from data: Data) throws -> StickerPack {
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch {
            throw Failure.invalid
        }

        guard archive.format == formatIdentifier else { throw Failure.invalid }
        guard archive.version >= 1, archive.version <= currentVersion else {
            throw Failure.unsupportedVersion
        }

        let stickers = try archive.stickers.map { archived -> StickerItem in
            guard let stickerData = Data(base64Encoded: archived.sticker),
                  let previewData = Data(base64Encoded: archived.preview) else {
                throw Failure.invalid
            }
            // Fresh ids; imported media has no local source file.
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

    /// Writes the archive to a temporary `.stickreatepack` file for sharing.
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

    // MARK: - Envelope

    private struct Archive: Codable {
        var format: String
        var version: Int
        var name: String
        var publisher: String
        var folder: String?
        var stickers: [ArchivedSticker]
    }

    private struct ArchivedSticker: Codable {
        var kind: StickerKind
        var emojis: [String]
        var sticker: String
        var preview: String
    }

    // MARK: - Helpers

    private static func normalizedFolder(_ folder: String?) -> String? {
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Keeps the file name to a safe, readable subset of the pack name.
    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ .")
        let filtered = String(name.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? "pack" : String(filtered.prefix(64))
    }
}
