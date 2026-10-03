import SwiftUI
import UIKit

/// Content-layer card for a sticker pack. Deliberately opaque — it sits inside
/// the grid and must not compete with the Liquid Glass navigation layer.
struct PackCard: View {
    let pack: StickerPack

    private var thumbnail: UIImage? {
        guard let data = pack.traySourcePreview,
              let image = UIImage(data: data) else { return nil }
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview

            Text(pack.name)
                .font(.headline)
                .lineLimit(1)

            Text(countAndKind)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let folder = pack.folder {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var countAndKind: String {
        let count = pack.stickers.count
        let countText = count == 1 ? "1 sticker" : "\(count) stickers"
        return "\(countText) · \(kindText)"
    }

    private var kindText: String {
        if pack.isMixed { return "Mixed" }
        return pack.kind?.label ?? "Empty"
    }
}

#Preview {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
}
