import SwiftUI
import UIKit
import SDWebImage

/// Large, near-full-screen preview of one sticker. Animated stickers play their
/// WebP; static stickers show their PNG preview. The action callbacks are
/// optional: pass none for a read-only preview (e.g. from the export sheet).
struct StickerPreviewSheet: View {
    let item: StickerItem
    var isCover: Bool = false
    var canDuplicate: Bool = false
    var onEdit: (() -> Void)? = nil
    var onEmojis: (() -> Void)? = nil
    var onSetCover: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var staticImage: UIImage? {
        UIImage(data: item.previewData)
    }

    private var hasActions: Bool {
        onEdit != nil || onEmojis != nil || onSetCover != nil || onDuplicate != nil || onDelete != nil
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
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if hasActions {
            actions
        }
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { proxy in
            let side = max(1, min(proxy.size.width, proxy.size.height))

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
            .frame(width: side, height: side)
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
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.kind == .animated ? "Animated sticker preview" : "Sticker preview")
        }
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
            if let onEdit {
                actionButton(
                    "Edit",
                    symbol: "pencil",
                    enabled: item.source != nil,
                    action: onEdit
                )
            }

            if let onEmojis {
                actionButton(
                    "Emojis",
                    symbol: "face.smiling",
                    enabled: true,
                    action: onEmojis
                )
            }

            if let onSetCover {
                actionButton(
                    "Set as Cover",
                    symbol: "star",
                    enabled: !isCover,
                    action: onSetCover
                )
            }

            if let onDuplicate {
                actionButton(
                    "Duplicate",
                    symbol: "plus.square.on.square",
                    enabled: canDuplicate,
                    action: onDuplicate
                )
            }

            if let onDelete {
                actionButton(
                    "Delete",
                    symbol: "trash",
                    enabled: true,
                    destructive: true,
                    action: onDelete
                )
            }
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
        let view = AutoplayAnimatedImageView(frame: .zero)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.autoPlayAnimatedImage = true
        // Only build the image when the bytes actually change, so re-rendering
        // the sheet never restarts the animation.
        context.coordinator.data = data
        view.image = SDAnimatedImage(data: data) ?? fallback
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: SDAnimatedImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        uiView.image = SDAnimatedImage(data: data) ?? fallback
        uiView.startAnimating()
    }

    final class Coordinator {
        var data: Data?
    }
}

/// `SDAnimatedImageView` only starts its display link once it lands in a window;
/// when the image is set from a `UIViewRepresentable` before attachment it can
/// stay frozen. Nudge it to animate as soon as it is on screen.
private final class AutoplayAnimatedImageView: SDAnimatedImageView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        autoPlayAnimatedImage = true
        startAnimating()
    }
}
