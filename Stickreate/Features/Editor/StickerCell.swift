import SwiftUI
import UIKit

/// A numbered slot in the pack editor grid. Content layer — opaque, never glass.
/// A `nil` item renders a dashed "add" placeholder instead.
struct StickerCell<MenuContent: View>: View {
    let item: StickerItem?
    let index: Int
    let isCover: Bool
    let onAdd: (() -> Void)?
    let onTap: (() -> Void)?
    let menu: MenuContent

    init(
        item: StickerItem?,
        index: Int,
        isCover: Bool,
        onAdd: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.item = item
        self.index = index
        self.isCover = isCover
        self.onAdd = onAdd
        self.onTap = onTap
        self.menu = menu()
    }

    var body: some View {
        if let item {
            filledTile(item)
                .contextMenu { menu }
        } else {
            placeholderTile
        }
    }

    // MARK: - Filled tile

    private func filledTile(_ item: StickerItem) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay { preview(for: item) }
            .overlay(alignment: .topLeading) { numberBadge }
            .overlay(alignment: .topTrailing) { trailingBadges(for: item) }
            .overlay(alignment: .bottomLeading) { emojiBadge(for: item) }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { onTap?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: item))
            .accessibilityHint("Opens a large preview")
            .accessibilityAddTraits([.isImage, .isButton])
    }

    @ViewBuilder
    private func preview(for item: StickerItem) -> some View {
        if let image = UIImage(data: item.previewData) {
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

    private var numberBadge: some View {
        Text("\(index + 1)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: Circle())
            .padding(6)
            .accessibilityHidden(true)
    }

    private func trailingBadges(for item: StickerItem) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isCover {
                Label("Cover", systemImage: "star.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
            }

            if item.kind == .animated {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .padding(6)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func emojiBadge(for item: StickerItem) -> some View {
        if !item.emojis.isEmpty {
            Text(item.emojis.prefix(Limits.maxEmojisPerSticker).joined())
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(uiColor: .systemBackground).opacity(0.9), in: Capsule())
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Placeholder tile

    private var placeholderTile: some View {
        Button {
            onAdd?()
        } label: {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.35))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                }
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add sticker")
    }

    private func accessibilityLabel(for item: StickerItem) -> String {
        var parts = ["Sticker \(index + 1)", item.kind == .animated ? "animated" : "static"]
        if isCover { parts.append("cover") }
        if !item.emojis.isEmpty {
            parts.append("emojis \(item.emojis.joined(separator: " "))")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let item = StickerItem(
        kind: .animated,
        emojis: ["😺"],
        stickerData: Data(),
        previewData: Data()
    )
    return HStack {
        StickerCell(item: item, index: 0, isCover: true) {
            Button("Edit") {}
        }
        StickerCell(item: nil, index: 1, isCover: false, onAdd: {}) {
            EmptyView()
        }
    }
    .frame(width: 240)
    .padding()
}
