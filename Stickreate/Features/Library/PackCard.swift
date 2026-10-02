import SwiftUI
import UIKit

/// Content-layer card for a sticker pack. Deliberately opaque — it sits inside
/// the grid and must not compete with the Liquid Glass navigation layer.
struct PackCard: View {
    let pack: StickerPack

    private var thumbnail: UIImage? {
        guard let data = pack.traySourcePreview else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview

            Text(pack.name)
                .font(.headline)
                .lineLimit(1)

            Text(stickerCount)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

    private var stickerCount: String {
        pack.stickers.count == 1 ? "1 sticker" : "\(pack.stickers.count) stickers"
    }
}

#Preview {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
}
