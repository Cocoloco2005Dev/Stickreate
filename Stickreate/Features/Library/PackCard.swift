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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            preview

            Text(pack.name)
                .font(DS.TextRole.cardTitle)
                .lineLimit(1)

            Text(countAndKind)
                .font(DS.TextRole.supporting)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let folder = pack.folder {
                Label(folder, systemImage: "folder")
                    .font(DS.TextRole.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this pack")
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(DS.Space.md)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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

// MARK: - Previews

#Preview("Light") {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
}

#Preview("Dark") {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 150)
        .padding()
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
        .frame(width: 430, height: 932)
}
