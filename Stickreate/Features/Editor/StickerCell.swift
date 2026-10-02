import SwiftUI
import UIKit

/// A single sticker in the editor grid. Content layer — opaque, never glass.
struct StickerCell: View {
    let item: StickerItem
    let store: PackStore
    let packID: UUID

    private var image: UIImage? {
        UIImage(data: item.previewData)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.kind == .animated {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !item.emojis.isEmpty {
                    Text(item.emojis.prefix(Limits.maxEmojisPerSticker).joined())
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .systemBackground).opacity(0.9), in: Capsule())
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.removeSticker(item.id, from: packID)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isImage)
    }

    private var accessibilityLabel: String {
        var parts = [item.kind == .animated ? "Animated sticker" : "Sticker"]
        if !item.emojis.isEmpty {
            parts.append("emojis \(item.emojis.joined(separator: " "))")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return StickerCell(
        item: StickerItem(kind: .animated, emojis: ["😺"], stickerData: Data(), previewData: Data()),
        store: store,
        packID: pack.id
    )
    .frame(width: 104, height: 104)
    .padding()
}
