import SwiftUI
import UIKit
import SDWebImage

/// Large, near-full-screen preview of one sticker with its actions. Animated
/// stickers play their WebP; static stickers show their PNG preview.
struct StickerPreviewSheet: View {
    let item: StickerItem
    let isCover: Bool
    let canDuplicate: Bool
    let onEdit: () -> Void
    let onEmojis: () -> Void
    let onSetCover: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var staticImage: UIImage? {
        UIImage(data: item.previewData)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                preview
                details
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close preview")
                }
            }
            .safeAreaInset(edge: .bottom) {
                actions
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            CheckerboardBackground()

            if item.kind == .animated {
                AnimatedStickerView(data: item.stickerData, fallback: staticImage)
            } else if let staticImage {
                Image(uiImage: staticImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if item.kind == .animated {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(12)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.kind == .animated ? "Animated sticker preview" : "Sticker preview")
    }

    private var details: some View {
        VStack(spacing: 6) {
            Text(item.kind == .animated ? "Animated sticker" : "Sticker")
                .font(.headline)

            if isCover {
                Label("Cover", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if !item.emojis.isEmpty {
                Text(item.emojis.joined(separator: " "))
                    .font(.title3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton(
                "Edit",
                symbol: "pencil",
                enabled: item.source != nil,
                action: onEdit
            )
            actionButton(
                "Emojis",
                symbol: "face.smiling",
                enabled: true,
                action: onEmojis
            )
            actionButton(
                "Set as Cover",
                symbol: "star",
                enabled: !isCover,
                action: onSetCover
            )
            actionButton(
                "Duplicate",
                symbol: "plus.square.on.square",
                enabled: canDuplicate,
                action: onDuplicate
            )
            actionButton(
                "Delete",
                symbol: "trash",
                enabled: true,
                destructive: true,
                action: onDelete
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil) {
            action()
            dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .tint(destructive ? .red : nil)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

/// Opaque checkerboard so transparency in the sticker is visible.
/// Content layer — never glass.
private struct CheckerboardBackground: View {
    private let cell: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let light = Color(uiColor: .systemBackground)
            let dark = Color(uiColor: .systemGray5)
            let columns = max(1, Int(ceil(size.width / cell)))
            let rows = max(1, Int(ceil(size.height / cell)))

            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    let color = (row + column).isMultiple(of: 2) ? light : dark
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

/// Plays an animated WebP. Falls back to a still if the animation can't be
/// decoded. Content layer — never glass.
private struct AnimatedStickerView: UIViewRepresentable {
    let data: Data
    let fallback: UIImage?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SDAnimatedImageView {
        let view = SDAnimatedImageView(frame: .zero)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        // Only build the image when the bytes actually change, so re-rendering
        // the sheet never restarts the animation.
        context.coordinator.data = data
        view.image = SDAnimatedImage(data: data) ?? fallback
        return view
    }

    func updateUIView(_ uiView: SDAnimatedImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        uiView.image = SDAnimatedImage(data: data) ?? fallback
    }

    final class Coordinator {
        var data: Data?
    }
}
