import SwiftUI
import UIKit
import Combine

/// Edits a stored GIF: duration trim, spatial crop, then an explicit
/// Original / Intelligent Cut choice — the GIF counterpart of `VideoTrimView`.
///
/// AVFoundation can't decode a GIF, so there is no `AVPlayer`. The preview
/// cycles the frames already extracted by `FrameExtractor` on a timer, and
/// respects Reduce Motion by resting on the first frame of the selection.
@MainActor
struct GIFTrimView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Hashable {
        case trim
        case crop
        case background
    }

    @State private var step: Step = .trim

    @State private var frames: [Frame]?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var lowerBound: TimeInterval = 0
    @State private var upperBound: TimeInterval = 0

    /// Normalized (0...1) top-left crop rect. Defaults to the full frame.
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Display aspect (width / height) of the GIF, for the crop overlay.
    @State private var frameAspect: CGFloat?

    @State private var filmstrip: [UIImage] = []

    /// Index into `frames` of the frame currently shown. Playback and scrubbing
    /// both move this; the playhead is derived from it (delay-aware).
    @State private var previewIndex = 0
    @State private var isPlaying = false
    @State private var tickAccumulator: TimeInterval = 0

    @State private var backgroundChoice: StickerBackgroundChoice = .original

    @State private var isCreating = false
    @State private var stage: StickerCreationStage?
    @State private var errorMessage: String?
    @State private var successPulse = 0
    @State private var creationTask: Task<Void, Never>?

    /// Fixed UI tick; the delay-aware accumulator advances the frame index, so
    /// frames are shown for their real GIF delays rather than the tick length.
    private let previewTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let tick: TimeInterval = 1.0 / 30.0

    private var duration: TimeInterval {
        frames?.reduce(0) { $0 + max($1.duration, 0) } ?? 0
    }

    private var clipLength: TimeInterval { max(0, upperBound - lowerBound) }

    /// Full-list index range of the frames inside the current selection.
    private var selectedRange: Range<Int> {
        guard let frames, !frames.isEmpty else { return 0..<0 }
        return StickerFactory.frameRange(
            for: lowerBound...upperBound,
            durations: frames.map(\.duration)
        )
    }

    private var currentImage: UIImage? {
        guard let frames, !frames.isEmpty else { return nil }
        return frames[min(max(previewIndex, 0), frames.count - 1)].image
    }

    /// Cumulative start time of `previewIndex`, for the filmstrip marker.
    private var playhead: TimeInterval {
        guard let frames else { return 0 }
        let index = min(max(previewIndex, 0), frames.count)
        return frames[..<index].reduce(0) { $0 + max($1.duration, 0) }
    }

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
        .onChange(of: lowerBound) { _, _ in handleSelectionChange() }
        .onChange(of: upperBound) { _, _ in handleSelectionChange() }
        .onReceive(previewTimer) { _ in tickPlayback() }
        .creationProgressOverlay(isCreating, stage: stage, onCancel: cancelCreation)
        .haptic(.success, trigger: successPulse)
        .announceOnChange(of: stage.announcementPhase) { $0 }
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
        BackActionItem(label: backLabel, isDisabled: isCreating) { goBack() }
        PrimaryActionItem(
            title: step == .background ? "Apply" : "Next",
            isDisabled: frames == nil || isCreating || (step == .trim && clipLength <= 0)
        ) {
            advance()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if frames != nil {
            ZStack(alignment: .top) {
                switch step {
                case .trim:
                    trimScreen

                case .crop:
                    cropScreen

                case .background:
                    BackgroundChoiceView(previewImage: currentImage, choice: $backgroundChoice)
                        .background(Color(uiColor: .systemBackground))
                }
            }
        } else if isLoading {
            LoadingState(title: "Loading GIF…")
        } else {
            EmptyState(
                symbol: "exclamationmark.triangle",
                title: "Couldn't Open This GIF",
                message: loadErrorMessage ?? "Try choosing a different GIF."
            ) {
                Button("Try Again") { retry() }
                    .buttonStyle(.glassProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
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

    /// GIFs can't be played by AVKit, so the extracted frames are cycled in a
    /// plain `Image`; `tickPlayback` owns the delay-aware advance.
    private var previewArea: some View {
        ZStack {
            Color.black

            if let image = currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func transportRow(showPlay: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            if showPlay {
                playPauseButton
            }

            Text("\(timeString(playhead)) / \(timeString(duration))")
                .font(DS.TextRole.supporting.monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(timeString(playhead)) of \(timeString(duration))")

            Spacer(minLength: 0)
        }
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(DS.TextRole.supporting.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: DS.minTapTarget, height: DS.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: DS.Space.md) {
            transportRow(showPlay: true)
            selectionReadout
            filmstripView

            Text("WhatsApp caps animated stickers at 500 KB and \(Int(Limits.maxAnimationDuration)) s, so the app compresses automatically.")
                .font(DS.TextRole.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
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

                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
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
        VStack(spacing: DS.Space.md) {
            transportRow(showPlay: true)

            HStack(spacing: DS.Space.md) {
                Text("Drag to frame the crop. It applies to every frame.")
                    .font(DS.TextRole.caption)
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
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
        .background(Color.black)
    }

    /// Where the aspect-fit frame is drawn inside the crop canvas.
    private func mediaFrame(in canvas: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let aspect = max(frameAspect ?? 1, 0.01)

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
        HStack(spacing: DS.Space.sm) {
            Text("\(seconds(lowerBound))–\(seconds(upperBound)) s")
                .font(DS.TextRole.supporting.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)

            Text("· \(seconds(clipLength)) s")
                .font(DS.TextRole.supporting.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true

        do {
            guard case .gif = source else { throw StickerFactory.Failure.unsupported }
            guard let data = try? Data(contentsOf: StickerSourceStore.url(for: source)) else {
                throw StickerFactory.Failure.empty
            }
            let extracted = try FrameExtractor.frames(fromGIF: data, maxFrames: 30)
            frames = extracted
            buildFilmstrip(extracted)
            frameAspect = extracted.first.map { $0.image.size.width / max($0.image.size.height, 1) }

            let total = extracted.reduce(0) { $0 + max($1.duration, 0) }
            lowerBound = 0
            upperBound = min(total, Limits.maxAnimationDuration)
            previewIndex = 0
            tickAccumulator = 0

            isLoading = false
            // Reduce Motion rests on the first frame instead of animating.
            isPlaying = !reduceMotion
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

    private func buildFilmstrip(_ frames: [Frame]) {
        let count = 16
        guard !frames.isEmpty else { return }
        if frames.count <= count {
            filmstrip = frames.map(\.image)
        } else {
            filmstrip = (0..<count).map { index in
                let sampleIndex = Int(Double(index) * Double(frames.count) / Double(count))
                return frames[min(sampleIndex, frames.count - 1)].image
            }
        }
    }

    // MARK: - Playback / scrubbing

    /// Advances the shown frame by real GIF delays. Wraps within the selection so
    /// the preview never runs outside the trimmed range.
    private func tickPlayback() {
        guard isPlaying, let frames, !frames.isEmpty else { return }
        let range = selectedRange
        guard range.lowerBound < range.upperBound else { return }

        if previewIndex < range.lowerBound || previewIndex >= range.upperBound {
            previewIndex = range.lowerBound
            tickAccumulator = 0
        }

        tickAccumulator += tick
        var steps = 0
        while steps < 120 {
            let frameDuration = max(frames[previewIndex].duration, Limits.minFrameDuration)
            if tickAccumulator < frameDuration { break }
            tickAccumulator -= frameDuration
            previewIndex += 1
            steps += 1
            if previewIndex >= range.upperBound {
                previewIndex = range.lowerBound
                break
            }
        }
    }

    /// The selection moved while the preview was running; keep the shown frame
    /// inside the new window.
    private func handleSelectionChange() {
        let range = selectedRange
        guard range.lowerBound < range.upperBound else { return }
        if previewIndex < range.lowerBound || previewIndex >= range.upperBound {
            previewIndex = range.lowerBound
            tickAccumulator = 0
        }
    }

    private func scrub(to time: TimeInterval) {
        isPlaying = false
        previewIndex = frameIndex(at: min(max(time, 0), duration))
        tickAccumulator = 0
    }

    private func togglePlayback() {
        guard let frames, !frames.isEmpty else { return }
        isPlaying.toggle()
        if isPlaying {
            let range = selectedRange
            if previewIndex < range.lowerBound || previewIndex >= range.upperBound {
                previewIndex = range.lowerBound
            }
            tickAccumulator = 0
        }
    }

    /// Frame index whose cumulative interval contains `time`.
    private func frameIndex(at time: TimeInterval) -> Int {
        guard let frames, !frames.isEmpty else { return 0 }
        var elapsed = 0.0
        for (index, frame) in frames.enumerated() {
            elapsed += max(frame.duration, 0)
            if time < elapsed { return index }
        }
        return frames.count - 1
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
            step = .background
        case .background:
            apply()
        }
    }

    @MainActor
    private func apply() {
        guard frames != nil, clipLength > 0 else { return }
        let range = lowerBound...upperBound
        let removeBackground = backgroundChoice == .aiCut
        isCreating = true
        stage = .loading
        isPlaying = false

        creationTask = Task {
            do {
                let sticker = try await StickerFactory.makeAnimatedSticker(
                    fromGIF: source,
                    range: range,
                    cropRect: hasCrop ? cropRect : nil,
                    removeBackground: removeBackground,
                    onStage: { newStage in
                        // Stage callbacks can arrive off the main actor.
                        Task { @MainActor in
                            stage = newStage
                        }
                    }
                )
                if Task.isCancelled { return }
                isCreating = false
                stage = nil
                successPulse += 1
                onDone(sticker)
                dismiss()
            } catch {
                if Task.isCancelled { return }
                isCreating = false
                stage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancels the running encode and resumes the preview.
    private func cancelCreation() {
        creationTask?.cancel()
        creationTask = nil
        isCreating = false
        stage = nil
        isPlaying = !reduceMotion
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

// MARK: - Previews

private func previewGIFSource() -> StickerSource {
    .gif(fileName: "preview.gif")
}

#Preview("Light") {
    GIFTrimView(source: previewGIFSource()) { _ in }
}

#Preview("Dark") {
    GIFTrimView(source: previewGIFSource()) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    GIFTrimView(source: previewGIFSource()) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    GIFTrimView(source: previewGIFSource()) { _ in }
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    GIFTrimView(source: previewGIFSource()) { _ in }
        .frame(width: 430, height: 932)
}
