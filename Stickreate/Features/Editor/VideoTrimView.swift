import SwiftUI
import UIKit
import AVFoundation

/// Edits a video source: duration trim, spatial crop, then an explicit
/// Original / Intelligent Cut choice. The screens are dark editors with a
/// full-bleed preview and a bottom filmstrip. Frame rate is automatic.
@MainActor
struct VideoTrimView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable {
        case trim
        case crop
        case background
    }

    @State private var step: Step = .trim

    @State private var draft: VideoDraft?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var lowerBound: TimeInterval = 0
    @State private var upperBound: TimeInterval = 0
    @State private var playhead: TimeInterval = 0
    /// Normalized (0...1) top-left crop rect. Defaults to the full frame.
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Display aspect (width / height) of the video, for the crop overlay.
    @State private var videoAspect: CGFloat?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var playheadImage: UIImage?
    @State private var thumbTask: Task<Void, Never>?

    @State private var filmstrip: [UIImage] = []

    @State private var backgroundChoice: StickerBackgroundChoice = .original

    @State private var isCreating = false
    @State private var stage: StickerCreationStage?
    @State private var errorMessage: String?

    private var sourceURL: URL { StickerSourceStore.url(for: source) }

    private var duration: TimeInterval { draft?.duration ?? 0 }

    private var clipLength: TimeInterval { max(0, upperBound - lowerBound) }

    private var stepTitle: String {
        switch step {
        case .trim: "Trim"
        case .crop: "Crop"
        case .background: "Background"
        }
    }

    private var backLabel: String {
        switch step {
        case .trim: "Close"
        case .crop: "Back to trim"
        case .background: "Back to crop"
        }
    }

    private var hasCrop: Bool {
        !(cropRect.minX <= 0.001
            && cropRect.minY <= 0.001
            && cropRect.width >= 0.999
            && cropRect.height >= 0.999)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(stepTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { teardownPlayer() }
        .alert(
            "Couldn't create sticker",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .tint(.white)
            .disabled(isCreating)
            .accessibilityLabel(backLabel)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(step == .background ? "Apply" : "Next") {
                advance()
            }
            .fontWeight(.semibold)
            .tint(.blue)
            .disabled(draft == nil || isCreating || (step == .trim && clipLength <= 0))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if draft != nil {
            ZStack(alignment: .top) {
                switch step {
                case .trim:
                    trimScreen

                case .crop:
                    cropScreen

                case .background:
                    BackgroundChoiceView(previewImage: playheadImage, choice: $backgroundChoice)
                        .background(Color(uiColor: .systemBackground))
                }

                if isCreating {
                    progressBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        } else if isLoading {
            ProgressView("Loading video…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Couldn't Open This Video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadErrorMessage ?? "Try choosing a different video.")
            } actions: {
                Button("Try Again") { retry() }
                Button("Close") { dismiss() }
            }
        }
    }

    private var trimScreen: some View {
        VStack(spacing: 0) {
            previewArea
            bottomPanel
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black

            if let player {
                PlayerLayerView(player: player)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { playButton }
        .accessibilityElement(children: .contain)
    }

    private var playButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(.black.opacity(0.4), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Plays the video preview")
    }

    /// Playback scrubber under the preview: shows and sets the current position.
    private func scrubberRow(showPlay: Bool) -> some View {
        HStack(spacing: 12) {
            if showPlay {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }

            Text(timeString(playhead))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .leading)

            Slider(value: scrubBinding, in: 0...max(duration, 0.01))
                .tint(.white)
                .accessibilityLabel("Playback position")
                .accessibilityValue(Text("\(timeString(playhead)) of \(timeString(duration))"))

            Text(timeString(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { min(max(playhead, 0), max(duration, 0.01)) },
            set: { value in
                if isPlaying {
                    player?.pause()
                    isPlaying = false
                }
                playhead = value
                player?.seek(
                    to: CMTime(seconds: value, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        )
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            scrubberRow(showPlay: false)
            selectionReadout
            filmstripView

            Text("WhatsApp caps animated stickers at 500 KB and \(Int(Limits.maxAnimationDuration)) s, so the app compresses automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private var filmstripView: some View {
        FilmstripView(
            thumbnails: filmstrip,
            duration: duration,
            playhead: playhead,
            minSpan: min(0.2, duration),
            maxSpan: min(Limits.maxAnimationDuration, duration),
            lower: $lowerBound,
            upper: $upperBound,
            onScrub: { time in scrub(to: time) }
        )
    }

    // MARK: - Crop screen

    private var cropScreen: some View {
        VStack(spacing: 0) {
            cropCanvas
            cropControls
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var cropCanvas: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            let frame = mediaFrame(in: canvas)

            ZStack {
                Color.black

                if let player {
                    PlayerLayerView(player: player)
                } else {
                    ProgressView()
                        .tint(.white)
                }

                if frame.width > 0 {
                    CropOverlay(cropRect: $cropRect, frameRect: frame)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
        }
    }

    private var cropControls: some View {
        VStack(spacing: 12) {
            scrubberRow(showPlay: true)

            HStack(spacing: 12) {
                Text("Drag to frame the crop. It applies to every frame.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Reset") {
                    resetCrop()
                }
                .buttonStyle(.glass)
                .disabled(!hasCrop)
                .accessibilityLabel("Reset crop")
            }

            filmstripView
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    /// Where the letterboxed video is drawn inside the crop canvas.
    private func mediaFrame(in canvas: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let aspect = max(videoAspect ?? 1, 0.01)

        let mediaWidth: CGFloat
        let mediaHeight: CGFloat
        if canvas.width / canvas.height > aspect {
            mediaHeight = canvas.height
            mediaWidth = mediaHeight * aspect
        } else {
            mediaWidth = canvas.width
            mediaHeight = mediaWidth / aspect
        }

        return CGRect(
            x: (canvas.width - mediaWidth) / 2,
            y: (canvas.height - mediaHeight) / 2,
            width: mediaWidth,
            height: mediaHeight
        )
    }

    private func resetCrop() {
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private var selectionReadout: some View {
        HStack(spacing: 6) {
            Text("\(seconds(lowerBound))–\(seconds(upperBound)) s")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)

            Text("· \(seconds(clipLength)) s")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Progress banner (top, inline — never covers the caption below)

    private var progressBanner: some View {
        HStack(spacing: 12) {
            stageIndicator

            Text(stageLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.8), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stageLabel)
    }

    @ViewBuilder
    private var stageIndicator: some View {
        if let fraction = stage?.fraction {
            // Determinate stages only; `.compressing` is indeterminate.
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
    }

    private var stageLabel: String {
        stage?.label ?? "Preparing…"
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true

        do {
            let loaded = try await StickerFactory.loadVideoDraft(from: source)
            guard loaded.duration > 0 else {
                isLoading = false
                loadErrorMessage = "This video has no duration."
                return
            }
            draft = loaded
            lowerBound = 0
            upperBound = min(loaded.duration, Limits.maxAnimationDuration)
            playhead = lowerBound
            if let size = await videoDisplaySize() {
                videoAspect = size.width / max(size.height, 1)
            }

            let player = AVPlayer(url: sourceURL)
            player.actionAtItemEnd = .pause
            self.player = player

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { time in
                playhead = CMTimeGetSeconds(time)
            }

            isLoading = false
            _ = await player.seek(
                to: CMTime(seconds: lowerBound, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            loadFilmstrip(for: loaded)
        } catch {
            isLoading = false
            loadErrorMessage = error.localizedDescription
        }
    }

    private func retry() {
        didLoad = false
        loadErrorMessage = nil
        isLoading = true
        Task { await load() }
    }

    private func teardownPlayer() {
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        thumbTask?.cancel()
        thumbTask = nil
    }

    /// Streams filmstrip frames in the background; the UI never waits on them.
    private func loadFilmstrip(for draft: VideoDraft) {
        let url = sourceURL
        let total = draft.duration
        let count = 16

        Task {
            var frames: [UIImage] = []
            for index in 0..<count {
                let time = total * (Double(index) + 0.5) / Double(count)
                guard let image = try? await FrameExtractor.thumbnail(fromVideoAt: url, at: time) else {
                    continue
                }
                frames.append(image)
                filmstrip = frames
                // Fallback aspect for the crop overlay if the track load failed.
                if videoAspect == nil {
                    videoAspect = image.size.width / max(image.size.height, 1)
                }
            }
        }
    }

    /// Display size of the video, accounting for the preferred transform.
    private func videoDisplaySize() async -> CGSize? {
        let asset = AVURLAsset(url: sourceURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return nil
        }
        let transformed = natural.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    // MARK: - Playback / scrubbing

    private func scrub(to time: TimeInterval) {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        playhead = time
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= upperBound - 0.05 || playhead < lowerBound - 0.05 {
                player.seek(
                    to: CMTime(seconds: lowerBound, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            player.play()
            isPlaying = true
        }
    }

    /// Loads a still for the background screen's "Original" swatch.
    private func prepareBackgroundPreview() {
        let url = sourceURL
        let time = min(max(playhead, lowerBound), upperBound)
        thumbTask?.cancel()
        thumbTask = Task {
            let image = try? await FrameExtractor.thumbnail(fromVideoAt: url, at: time)
            guard !Task.isCancelled else { return }
            playheadImage = image
        }
    }

    // MARK: - Actions

    private func goBack() {
        switch step {
        case .trim:
            dismiss()
        case .crop:
            step = .trim
        case .background:
            step = .crop
        }
    }

    private func advance() {
        switch step {
        case .trim:
            step = .crop
        case .crop:
            prepareBackgroundPreview()
            step = .background
        case .background:
            apply()
        }
    }

    @MainActor
    private func apply() {
        guard let draft, clipLength > 0 else { return }
        let range = lowerBound...upperBound
        let removeBackground = backgroundChoice == .aiCut
        isCreating = true
        stage = .loading
        player?.pause()
        isPlaying = false

        Task {
            do {
                let sticker = try await StickerFactory.makeAnimatedSticker(
                    from: draft,
                    range: range,
                    fps: 0,                     // automatic frame rate
                    removeBackground: removeBackground,
                    cropRect: hasCrop ? cropRect : nil,
                    source: source,
                    onStage: { newStage in
                        // Stage callbacks can arrive off the main actor.
                        Task { @MainActor in
                            stage = newStage
                        }
                    }
                )
                isCreating = false
                onDone(sticker)
                dismiss()
            } catch {
                isCreating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bare `AVPlayerLayer` so the preview has no built-in controls — the screen
/// draws its own play button. Content layer, never glass.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // `layerClass` guarantees the backing layer is an `AVPlayerLayer`.
            layer as! AVPlayerLayer
        }
    }
}

/// Draggable, resizable crop rectangle drawn over the letterboxed video.
/// Dimmed outside, white border, large corner handles. Content layer.
private struct CropOverlay: View {
    /// Normalized (0...1) top-left crop rect.
    @Binding var cropRect: CGRect
    /// Where the video is drawn, in the parent's coordinate space.
    let frameRect: CGRect

    @State private var isDragging = false
    @State private var activeHandle: Handle?
    @State private var initialRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private enum Handle: Hashable {
        case move
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let minSize: CGFloat = 0.1
    private let grab: CGFloat = 28

    var body: some View {
        let rect = canvasRect()
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        ZStack {
            // Dim the video outside the crop window.
            Path { path in
                path.addRect(frameRect)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            ForEach(corners, id: \.self) { point in
                // Visible 36 pt, 56 pt touch target via `grab` below.
                Circle()
                    .fill(Color.white)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                    .shadow(radius: 1)
                    .position(point)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(rect: rect))
        .accessibilityElement()
        .accessibilityLabel("Crop area")
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint("Drag to move, or the corners to resize")
    }

    private func dragGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    initialRect = cropRect
                    activeHandle = handle(at: value.startLocation, rect: rect)
                }
                guard let handle = activeHandle else { return }
                cropRect = updatedRect(
                    handle: handle,
                    dx: value.translation.width / max(frameRect.width, 1),
                    dy: value.translation.height / max(frameRect.height, 1)
                )
            }
            .onEnded { _ in
                isDragging = false
                activeHandle = nil
            }
    }

    private func handle(at point: CGPoint, rect: CGRect) -> Handle? {
        if near(point, CGPoint(x: rect.minX, y: rect.minY)) { return .topLeft }
        if near(point, CGPoint(x: rect.maxX, y: rect.minY)) { return .topRight }
        if near(point, CGPoint(x: rect.minX, y: rect.maxY)) { return .bottomLeft }
        if near(point, CGPoint(x: rect.maxX, y: rect.maxY)) { return .bottomRight }
        return rect.contains(point) ? .move : nil
    }

    private func near(_ point: CGPoint, _ corner: CGPoint) -> Bool {
        let dx = point.x - corner.x
        let dy = point.y - corner.y
        return (dx * dx + dy * dy).squareRoot() <= grab
    }

    private func updatedRect(handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch handle {
        case .move:
            let x = min(max(0, initialRect.minX + dx), 1 - initialRect.width)
            let y = min(max(0, initialRect.minY + dy), 1 - initialRect.height)
            return CGRect(x: x, y: y, width: initialRect.width, height: initialRect.height)

        case .topLeft:
            let x = min(max(0, initialRect.minX + dx), initialRect.maxX - minSize)
            let y = min(max(0, initialRect.minY + dy), initialRect.maxY - minSize)
            return CGRect(x: x, y: y, width: initialRect.maxX - x, height: initialRect.maxY - y)

        case .topRight:
            let maxX = max(min(1, initialRect.maxX + dx), initialRect.minX + minSize)
            let y = min(max(0, initialRect.minY + dy), initialRect.maxY - minSize)
            return CGRect(x: initialRect.minX, y: y, width: maxX - initialRect.minX, height: initialRect.maxY - y)

        case .bottomLeft:
            let x = min(max(0, initialRect.minX + dx), initialRect.maxX - minSize)
            let maxY = max(min(1, initialRect.maxY + dy), initialRect.minY + minSize)
            return CGRect(x: x, y: initialRect.minY, width: initialRect.maxX - x, height: maxY - initialRect.minY)

        case .bottomRight:
            let maxX = max(min(1, initialRect.maxX + dx), initialRect.minX + minSize)
            let maxY = max(min(1, initialRect.maxY + dy), initialRect.minY + minSize)
            return CGRect(x: initialRect.minX, y: initialRect.minY, width: maxX - initialRect.minX, height: maxY - initialRect.minY)
        }
    }

    private func canvasRect() -> CGRect {
        CGRect(
            x: frameRect.minX + cropRect.minX * frameRect.width,
            y: frameRect.minY + cropRect.minY * frameRect.height,
            width: cropRect.width * frameRect.width,
            height: cropRect.height * frameRect.height
        )
    }

    private var accessibilityValue: String {
        let width = Int((cropRect.width * 100).rounded())
        let height = Int((cropRect.height * 100).rounded())
        return "\(width) percent wide, \(height) percent tall"
    }
}

/// Continuous strip of real frames with a white selection window. Dragging the
/// centre moves the window; dragging an edge resizes it. Content layer.
private struct FilmstripView: View {
    let thumbnails: [UIImage]
    let duration: TimeInterval
    let playhead: TimeInterval
    let minSpan: TimeInterval
    let maxSpan: TimeInterval
    @Binding var lower: TimeInterval
    @Binding var upper: TimeInterval
    let onScrub: (TimeInterval) -> Void

    @State private var activeHandle: Handle?
    @State private var initialLower: TimeInterval = 0
    @State private var initialUpper: TimeInterval = 0
    @State private var moveStartTime: TimeInterval = 0

    private enum Handle {
        case lower
        case upper
        case move
    }

    private let stripHeight: CGFloat = 64
    private let maxGrab: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let lowerX = x(for: lower, width: width)
            let upperX = x(for: upper, width: width)

            ZStack(alignment: .leading) {
                frames
                    .frame(width: width, height: stripHeight)
                    .clipped()

                // Frames outside the range stay visible but dimmed.
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: width, height: stripHeight))
                    path.addRoundedRect(
                        in: CGRect(
                            x: lowerX,
                            y: 0,
                            width: max(0, upperX - lowerX),
                            height: stripHeight
                        ),
                        cornerSize: CGSize(width: 8, height: 8)
                    )
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: max(0, upperX - lowerX), height: stripHeight)
                    .offset(x: lowerX)
                    .allowsHitTesting(false)

                handleBar.position(x: lowerX, y: stripHeight / 2)
                handleBar.position(x: upperX, y: stripHeight / 2)

                // Playhead at the current playback position.
                playheadMark
                    .position(
                        x: x(for: min(max(playhead, 0), duration), width: width),
                        y: stripHeight / 2
                    )
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: stripHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle == nil {
                            begin(
                                at: value.startLocation.x,
                                lowerX: lowerX,
                                upperX: upperX,
                                width: width
                            )
                        }
                        let proposed = time(for: value.location.x, width: width)
                        switch activeHandle {
                        case .lower:
                            lower = clampedLower(proposed)
                            onScrub(lower)
                        case .upper:
                            upper = clampedUpper(proposed)
                            onScrub(upper)
                        case .move:
                            let span = initialUpper - initialLower
                            let delta = proposed - moveStartTime
                            let newLower = min(max(0, initialLower + delta), max(0, duration - span))
                            lower = newLower
                            upper = newLower + span
                            onScrub(lower)
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
        .frame(height: stripHeight)
        .accessibilityElement()
        .accessibilityLabel("Trim range")
        .accessibilityValue(Text("\(seconds(lower)) to \(seconds(upper)) seconds"))
        .accessibilityHint("Drag the selection to move it, or its edges to resize")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                upper = clampedUpper(upper + 0.5)
                onScrub(upper)
            case .decrement:
                upper = clampedUpper(upper - 0.5)
                onScrub(upper)
            @unknown default:
                break
            }
        }
    }

    private func begin(at startX: CGFloat, lowerX: CGFloat, upperX: CGFloat, width: CGFloat) {
        initialLower = lower
        initialUpper = upper
        let startTime = time(for: startX, width: width)
        moveStartTime = startTime

        // Edges take a proportional slice so the middle stays draggable even
        // when the selection window is narrow.
        let windowWidth = upperX - lowerX
        let edgeGrab = min(maxGrab, windowWidth * 0.35)

        let nearLower = abs(startX - lowerX) <= edgeGrab
        let nearUpper = abs(startX - upperX) <= edgeGrab

        if nearLower {
            activeHandle = .lower
        } else if nearUpper {
            activeHandle = .upper
        } else if startTime > lower && startTime < upper {
            activeHandle = .move
        } else {
            activeHandle = abs(startX - lowerX) <= abs(startX - upperX) ? .lower : .upper
        }
    }

    @ViewBuilder
    private var frames: some View {
        if thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { _ in
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemFill))
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: stripHeight)
                        .clipped()
                }
            }
        }
    }

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .frame(width: 10, height: stripHeight)
            .shadow(radius: 2)
            .accessibilityHidden(true)
    }

    private var playheadMark: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)

            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
        }
        .frame(height: stripHeight)
        .shadow(radius: 1)
        .accessibilityHidden(true)
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(0, Double(x / width) * duration), duration)
    }

    private func clampedLower(_ proposed: TimeInterval) -> TimeInterval {
        let maxLower = max(0, upper - minSpan)
        let minLower = max(0, upper - maxSpan)
        return min(max(proposed, minLower), maxLower)
    }

    private func clampedUpper(_ proposed: TimeInterval) -> TimeInterval {
        let minUpper = min(duration, lower + minSpan)
        let maxUpper = min(duration, lower + maxSpan)
        return min(max(proposed, minUpper), maxUpper)
    }

    private func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
