import SwiftUI
import UIKit
import SDWebImage
import SDWebImageWebPCoder

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPlaying = true
    /// The corner transport is hidden by default; tapping the sticker shows it,
    /// it fades out ~2 s later, and it stays visible while paused.
    @State private var controlsVisible = false
    @State private var hideTask: Task<Void, Never>?

    private var staticImage: UIImage? {
        UIImage(data: item.previewData)
    }

    private var hasActions: Bool {
        onEdit != nil || onEmojis != nil || onSetCover != nil || onDuplicate != nil || onDelete != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.lg) {
                preview
                details
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.sm)
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
            .onAppear {
                if item.kind == .animated { revealControls() }
            }
            .onDisappear { hideTask?.cancel() }
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
                    AnimatedStickerView(
                        data: item.stickerData,
                        fallback: staticImage,
                        isPlaying: $isPlaying
                    )
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
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if showPlayPause {
                    playPauseButton
                        .padding(DS.Space.md)
                        .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .onTapGesture { toggleControls() }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.kind == .animated ? "Animated sticker preview" : "Sticker preview")
        }
    }

    /// Small corner transport — control layer → glass, kept out of the sticker's
    /// center so the preview stays readable.
    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.body.weight(.bold))
                .frame(width: DS.minTapTarget, height: DS.minTapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Stops or restarts the animated preview")
    }

    /// Animated stickers show the transport while it's revealed or while paused.
    private var showPlayPause: Bool {
        item.kind == .animated && (controlsVisible || !isPlaying)
    }

    // MARK: - Transport visibility

    private func revealControls() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            controlsVisible = true
        }
        scheduleAutoHide()
    }

    /// Fades the transport out after ~2 s — but never while paused.
    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                controlsVisible = false
            }
        }
    }

    private func toggleControls() {
        guard item.kind == .animated else { return }
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        } else {
            revealControls()
        }
    }

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            scheduleAutoHide()
        } else {
            // Paused → keep the transport visible.
            hideTask?.cancel()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
    }

    private var details: some View {
        VStack(spacing: DS.Space.xs) {
            Text(item.kind == .animated ? "Animated sticker" : "Sticker")
                .font(DS.TextRole.cardTitle)

            if isCover {
                Label("Cover", systemImage: "star.fill")
                    .font(DS.TextRole.caption.weight(.semibold))
                    .foregroundStyle(DS.ColorRole.accent)
            }

            if !item.emojis.isEmpty {
                Text(item.emojis.joined(separator: " "))
                    .font(.title3)
                    .accessibilityLabel("Emojis \(item.emojis.joined(separator: " "))")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: DS.Space.sm) {
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
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
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

/// Plays an animated WebP with SDWebImage's animated image view. The image is
/// decoded explicitly through `SDImageWebPCoder` (libwebp), which composites
/// delta/dispose frames correctly — the ImageIO WebP coder (`SDImageAWebPCoder`)
/// and `SDAnimatedImage(data:)` can silently yield a still, leaving a frozen
/// preview. Falls back to a still only if decoding truly fails.
private struct AnimatedStickerView: UIViewRepresentable {
    let data: Data
    let fallback: UIImage?
    @Binding var isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SDAnimatedImageView {
        let view = PlaybackAnimatedImageView(frame: .zero)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.autoPlayAnimatedImage = false   // playback is driven by `isPlaying`
        view.resetFrameIndexWhenStopped = true
        context.coordinator.data = data
        view.image = SDImageWebPCoder.shared.decodedImage(with: data, options: nil) ?? fallback
        context.coordinator.apply(isPlaying: isPlaying, to: view)
        return view
    }

    func updateUIView(_ uiView: SDAnimatedImageView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            uiView.image = SDImageWebPCoder.shared.decodedImage(with: data, options: nil) ?? fallback
        }
        context.coordinator.apply(isPlaying: isPlaying, to: uiView)
    }

    final class Coordinator {
        var data: Data?

        /// One place that maps the SwiftUI toggle onto the animated view, so
        /// `makeUIView` and `updateUIView` can't disagree — previously
        /// `makeUIView` always started the animation, which is why pausing
        /// appeared to do nothing.
        func apply(isPlaying: Bool, to view: SDAnimatedImageView) {
            (view as? PlaybackAnimatedImageView)?.wantsPlayback = isPlaying
            view.playbackRate = isPlaying ? 1 : 0
            if isPlaying {
                view.startAnimating()
            } else {
                view.stopAnimating()
            }
        }
    }
}

/// Starts/stops its display link with the desired playback state, so the
/// animation reliably begins on screen and honors pause.
private final class PlaybackAnimatedImageView: SDAnimatedImageView {
    var wantsPlayback = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if wantsPlayback {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

// MARK: - Previews

private func previewStickerItem() -> StickerItem {
    StickerItem(kind: .static, emojis: ["😺"], stickerData: Data(), previewData: Data())
}

private func previewAnimatedStickerItem() -> StickerItem {
    StickerItem(kind: .animated, emojis: ["😺"], stickerData: Data(), previewData: Data())
}

#Preview("Animated transport") {
    StickerPreviewSheet(item: previewAnimatedStickerItem())
}

#Preview("Light") {
    StickerPreviewSheet(item: previewStickerItem())
}

#Preview("Dark") {
    StickerPreviewSheet(item: previewStickerItem())
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    StickerPreviewSheet(item: previewStickerItem())
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    StickerPreviewSheet(item: previewStickerItem())
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    StickerPreviewSheet(item: previewStickerItem())
        .frame(width: 430, height: 932)
}

