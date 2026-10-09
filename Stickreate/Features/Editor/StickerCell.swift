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
        RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            .fill(DS.ColorRole.contentSurface)
            .aspectRatio(1, contentMode: .fit)
            .overlay { preview(for: item) }
            .overlay(alignment: .topLeading) { numberBadge }
            .overlay(alignment: .topTrailing) { trailingBadges(for: item) }
            .overlay(alignment: .bottomLeading) { emojiBadge(for: item) }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
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
                .padding(DS.Space.sm)
        } else {
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var numberBadge: some View {
        Text("\(index + 1)")
            .font(DS.TextRole.badge)
            .foregroundStyle(.white)
            .padding(5)
            .background(DS.ColorRole.mediaScrim, in: Circle())
            .padding(DS.Space.sm)
            .accessibilityHidden(true)
    }

    private func trailingBadges(for item: StickerItem) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.xs) {
            if isCover {
                Label("Cover", systemImage: "star.fill")
                    .font(DS.TextRole.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(DS.ColorRole.accent, in: Capsule())
            }

            if item.kind == .animated {
                Image(systemName: "play.fill")
                    .font(DS.TextRole.badge)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(DS.ColorRole.mediaScrim, in: Circle())
            }
        }
        .padding(DS.Space.sm)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func emojiBadge(for item: StickerItem) -> some View {
        if !item.emojis.isEmpty {
            Text(item.emojis.prefix(Limits.maxEmojisPerSticker).joined())
                .font(DS.TextRole.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DS.ColorRole.contentSurfaceRaised.opacity(0.9), in: Capsule())
                .padding(DS.Space.sm)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Placeholder tile

    private var placeholderTile: some View {
        Button {
            onAdd?()
        } label: {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .fill(DS.ColorRole.contentSurface.opacity(0.35))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .strokeBorder(
                            DS.ColorRole.accent.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                }
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DS.ColorRole.accent)
                }
                .frame(minWidth: DS.minTapTarget, minHeight: DS.minTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add sticker")
        .accessibilityHint("Adds a new sticker to this pack")
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

// MARK: - Previews

private func previewAnimatedItem() -> StickerItem {
    StickerItem(kind: .animated, emojis: ["😺"], stickerData: Data(), previewData: Data())
}

#Preview("Light") {
    HStack {
        StickerCell(item: previewAnimatedItem(), index: 0, isCover: true) { Button("Edit") {} }
        StickerCell(item: nil, index: 1, isCover: false, onAdd: {}) { EmptyView() }
    }
    .frame(width: 240)
    .padding()
}

#Preview("Dark") {
    HStack {
        StickerCell(item: previewAnimatedItem(), index: 0, isCover: true) { Button("Edit") {} }
        StickerCell(item: nil, index: 1, isCover: false, onAdd: {}) { EmptyView() }
    }
    .frame(width: 240)
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    HStack {
        StickerCell(item: previewAnimatedItem(), index: 0, isCover: true) { Button("Edit") {} }
        StickerCell(item: nil, index: 1, isCover: false, onAdd: {}) { EmptyView() }
    }
    .frame(width: 240)
    .padding()
    .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    StickerCell(item: previewAnimatedItem(), index: 0, isCover: true) { Button("Edit") {} }
        .frame(width: 160)
        .padding()
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    StickerCell(item: previewAnimatedItem(), index: 0, isCover: true) { Button("Edit") {} }
        .frame(width: 200)
        .padding()
        .frame(width: 430, height: 932)
}
