import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// Trims a video source, then asks whether to keep or cut the background.
///
/// The trim screen is a dark editor: a full-bleed preview plus a bottom filmstrip
/// of real frames with a white selection window. "Next" moves to an explicit
/// background choice; "Apply" creates the sticker, keeping the source so it stays
/// re-editable.
@MainActor
struct VideoTrimView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable {
        case trim
        case background
    }

    @State private var step: Step = .trim

    @State private var draft: VideoDraft?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var lowerBound: TimeInterval = 0
    @State private var upperBound: TimeInterval = 0
    @State private var fps: Int = min(max(SettingsStore.shared.defaultFPS, 5), 30)

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playheadImage: UIImage?
    @State private var scrubTask: Task<Void, Never>?

    @State private var filmstrip: [UIImage] = []

    @State private var backgroundChoice: StickerBackgroundChoice = .original

    @State private var isCreating = false
    @State private var stage: StickerCreationStage?
    @State private var errorMessage: String?

    private static let standardFPSOptions = [5, 10, 15, 20, 24, 30]

    /// Includes the initial default fps even when it isn't a standard option,
    /// so the segmented control always has a selected value.
    private var fpsOptions: [Int] {
        let base = Self.standardFPSOptions
        return base.contains(fps) ? base : (base + [fps]).sorted()
    }

    private var sourceURL: URL { StickerSourceStore.url(for: source) }

    private var clipLength: TimeInterval {
        max(0, upperBound - lowerBound)
    }

    private var estimatedFrames: Int {
        max(1, Int((Double(fps) * clipLength).rounded()))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(step == .trim ? "Trim" : "Background")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { player?.pause() }
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
            }
            .disabled(isCreating)
            .accessibilityLabel(step == .background ? "Back to trim" : "Back")
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(step == .trim ? "Next" : "Apply") {
                if step == .trim {
                    step = .background
                } else {
                    apply()
                }
            }
            .tint(.blue)
            .disabled(draft == nil || isCreating || (step == .trim && clipLength <= 0))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let draft {
            ZStack {
                switch step {
                case .trim:
                    trimScreen(for: draft)

                case .background:
                    BackgroundChoiceView(previewImage: playheadImage, choice: $backgroundChoice)
                        .background(Color(uiColor: .systemBackground))
                }

                if isCreating {
                    creatingOverlay
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

    private func trimScreen(for draft: VideoDraft) -> some View {
        VStack(spacing: 0) {
            previewArea
            bottomPanel(for: draft)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var previewArea: some View {
        ZStack {
            Color.black

            if isPlaying {
                VideoPlayer(player: player)
            } else if let playheadImage {
                Image(uiImage: playheadImage)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { togglePlayback() }
        .accessibilityElement()
        .accessibilityLabel("Video preview")
        .accessibilityHint("Double tap to play or pause")
    }

    private func bottomPanel(for draft: VideoDraft) -> some View {
        VStack(spacing: 14) {
            fpsControl

            FilmstripView(
                thumbnails: filmstrip,
                duration: draft.duration,
                minSpan: min(0.2, draft.duration),
                maxSpan: min(Limits.maxAnimationDuration, draft.duration),
                lower: $lowerBound,
                upper: $upperBound,
                onScrub: { time in scrub(to: time) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private var fpsControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Frame rate")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(fps) fps · ≈ \(estimatedFrames) frames")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Picker("Frame rate", selection: $fps) {
                ForEach(fpsOptions, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Frame rate")
            .accessibilityValue(Text("\(fps) frames per second"))

            Text("WhatsApp caps animated stickers at 500 KB and \(Int(Limits.maxAnimationDuration)) s, so the app compresses and may reduce frames.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var creatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                stageIndicator

                Text(stageLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(
                Color.black.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stageLabel)
    }

    @ViewBuilder
    private var stageIndicator: some View {
        if let fraction = stage?.fraction {
            // Determinate stages only; `.compressing` is indeterminate.
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.circular)
                .tint(.white)
        } else {
            ProgressView()
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

            let player = AVPlayer(url: sourceURL)
            player.actionAtItemEnd = .pause
            self.player = player

            isLoading = false
            scrub(to: lowerBound)
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

    /// Streams filmstrip frames in the background; the UI never waits on them.
    private func loadFilmstrip(for draft: VideoDraft) {
        let url = sourceURL
        let duration = draft.duration
        let count = 16

        Task {
            var frames: [UIImage] = []
            for index in 0..<count {
                let time = duration * (Double(index) + 0.5) / Double(count)
                guard let image = try? await FrameExtractor.thumbnail(fromVideoAt: url, at: time) else {
                    continue
                }
                frames.append(image)
                filmstrip = frames
            }
        }
    }

    // MARK: - Preview / playhead

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
        loadPlayheadImage(at: time)
    }

    private func loadPlayheadImage(at time: TimeInterval) {
        scrubTask?.cancel()
        let url = sourceURL
        scrubTask = Task {
            let image = try? await FrameExtractor.thumbnail(fromVideoAt: url, at: time)
            guard !Task.isCancelled else { return }
            playheadImage = image
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            loadPlayheadImage(at: CMTimeGetSeconds(player.currentTime()))
        } else {
            player.seek(
                to: CMTime(seconds: lowerBound, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            player.play()
            isPlaying = true
        }
    }

    // MARK: - Actions

    private func goBack() {
        if step == .background {
            step = .trim
        } else {
            dismiss()
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
                    fps: Double(fps),
                    removeBackground: removeBackground,
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
}

/// Continuous strip of real frames with a white selection window and two thick
/// vertical handles. Content layer — never glass.
private struct FilmstripView: View {
    let thumbnails: [UIImage]
    let duration: TimeInterval
    let minSpan: TimeInterval
    let maxSpan: TimeInterval
    @Binding var lower: TimeInterval
    @Binding var upper: TimeInterval
    let onScrub: (TimeInterval) -> Void

    @State private var activeHandle: Handle?

    private enum Handle {
        case lower
        case upper
    }

    private let stripHeight: CGFloat = 64

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
            }
            .frame(width: width, height: stripHeight)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle == nil {
                            let toLower = abs(value.startLocation.x - lowerX)
                            let toUpper = abs(value.startLocation.x - upperX)
                            activeHandle = toLower <= toUpper ? .lower : .upper
                        }
                        let proposed = time(for: value.location.x, width: width)
                        switch activeHandle {
                        case .lower:
                            lower = clampedLower(proposed)
                        case .upper:
                            upper = clampedUpper(proposed)
                        case nil:
                            break
                        }
                        if let handle = activeHandle {
                            onScrub(handle == .lower ? lower : upper)
                        }
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
        .frame(height: stripHeight)
        .accessibilityElement()
        .accessibilityLabel("Trim range")
        .accessibilityValue(Text("\(seconds(lower)) to \(seconds(upper)) seconds"))
        .accessibilityHint("Drag the white handles to choose the clip")
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
