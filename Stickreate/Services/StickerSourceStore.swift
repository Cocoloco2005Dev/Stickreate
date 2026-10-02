import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

/// On-disk store for the original media behind a sticker, so stickers can be
/// re-opened in the editor. Files live in `Documents/Sources/<uuid>.<ext>`.
enum StickerSourceStore {
    enum Failure: LocalizedError {
        case unsupported
        case empty
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "This file type isn't supported."
            case .empty:
                "Nothing was selected."
            case .failed(let message):
                message
            }
        }
    }

    /// Imports a picked item into app storage and returns its source reference.
    static func importPicked(_ item: PhotosPickerItem) async throws -> StickerSource {
        let types = item.supportedContentTypes

        if types.contains(where: { $0.conforms(to: .movie) }) {
            let temporary = try await movieURL(from: item)
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(temporary.pathExtension.isEmpty ? "mov" : temporary.pathExtension)
            try moveOrCopy(from: temporary, to: destination)
            return .video(fileName: destination.lastPathComponent)
        }

        if types.contains(where: { $0.conforms(to: .gif) }) {
            let data = try await imageData(from: item)
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("gif")
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw Failure.failed(error.localizedDescription)
            }
            return .gif(fileName: destination.lastPathComponent)
        }

        if types.contains(where: { $0.conforms(to: .image) }) {
            let data = try await imageData(from: item)
            guard let image = UIImage(data: data) else { throw Failure.empty }
            return try saveImage(image, id: UUID())
        }

        throw Failure.unsupported
    }

    /// Saves an upright still image as a source file.
    static func saveImage(_ image: UIImage, id: UUID) throws -> StickerSource {
        let upright = image.upNormalized() ?? image
        guard let data = upright.jpegData(compressionQuality: 0.95) else {
            throw Failure.failed("Couldn't save this image.")
        }
        let destination = directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("jpg")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        return .image(fileName: destination.lastPathComponent)
    }

    static func url(for source: StickerSource) -> URL {
        directory.appendingPathComponent(source.fileName, isDirectory: false)
    }

    /// Loads the source for display; GIFs return their first frame, videos `nil`.
    static func image(for source: StickerSource) -> UIImage? {
        switch source {
        case .image:
            guard let data = try? Data(contentsOf: url(for: source)) else { return nil }
            return UIImage(data: data)
        case .gif:
            guard let data = try? Data(contentsOf: url(for: source)),
                  let cgSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else { return nil }
            return UIImage(cgImage: cgImage)
        case .video:
            return nil
        }
    }

    static func delete(_ source: StickerSource) {
        try? FileManager.default.removeItem(at: url(for: source))
    }

    /// Copies a source file to a fresh name so two stickers don't share one file.
    /// Returns `nil` if the copy fails.
    static func duplicate(_ source: StickerSource) -> StickerSource? {
        let original = url(for: source)
        guard FileManager.default.fileExists(atPath: original.path) else { return nil }

        let name = UUID().uuidString + "." + original.pathExtension
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: original, to: destination)
        } catch {
            return nil
        }

        switch source {
        case .image: return .image(fileName: name)
        case .video: return .video(fileName: name)
        case .gif: return .gif(fileName: name)
        }
    }

    // MARK: - Storage

    private static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func moveOrCopy(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw Failure.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Loading

    private static func imageData(from item: PhotosPickerItem) async throws -> Data {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw Failure.empty
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    private static func movieURL(from item: PhotosPickerItem) async throws -> URL {
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                throw Failure.empty
            }
            return movie.url
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}

/// Copies a picked movie into a temporary file so it can be read by AVFoundation.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
