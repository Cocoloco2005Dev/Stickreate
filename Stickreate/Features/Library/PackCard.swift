import SwiftUI

/// Content-layer card. Intentionally not glass — it sits inside the grid and
/// must not compete with the navigation layer.
struct PackCard: View {
    let pack: StickerPack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }

            Text(pack.name)
                .font(.headline)
                .lineLimit(1)

            Text("\(pack.stickers.count) stickers")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PackCard(pack: StickerPack(name: "Cats"))
        .frame(width: 180)
        .padding()
}
