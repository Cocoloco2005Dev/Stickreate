import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// Trims a video source and turns it into an animated sticker.
///
/// A real AVKit preview shows the clip; dragging a trim handle pauses and seeks
/// the player frame-accurately while a crisp still at the playhead is fetched
/// with `FrameExtractor`. The final encode keeps the source so the sticker stays
/// re-editable.
@MainActor
struct VideoTrimView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: VideoDraft?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var lowerBound: TimeInterval = 0
    @State private var upperBound: TimeInterval = 0
    @State private var fps: Int = 10

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playheadImage: UIImage?
    @State private var scrubTask: Task<Void, Never>?

    @State private var isCreating = false
    @State private var errorMessage: String?

    private static let fpsOptions = [5, 10, 15, 20, 24, 30]

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
                .navigationTitle("Trim Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isCreating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .buttonStyle(.glassProminent)
                            .disabled(draft == nil || isCreating || clipLength <= 0)
                    }
                }
        }
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let draft {
            if isCreating {
                ProgressView("Creating sticker…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                controls(for: draft)
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

    private func controls(for draft: VideoDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                previewCard

                TrimRangeSlider(
                    duration: draft.duration,
                    minSpan: min(0.2, draft.duration),
                    maxSpan: min(Limits.maxAnimationDuration, draft.duration),
                    lower: $lowerBound,
                    upper: $upperBound,
                    onScrub: { time in scrub(to: time) }
                )

                rangeSummary(for: draft)
                fpsControl
            }
            .padding(20)
        }
    }

    private var previewCard: some View {
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
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(isPlaying ? "Pause preview" : "Play preview")
        }
    }

    private func rangeSummary(for draft: VideoDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Trim", value: "\(seconds(lowerBound)) – \(seconds(upperBound)) s")
            LabeledContent("Clip length", value: "\(seconds(clipLength)) s")

            if draft.duration > Limits.maxAnimationDuration {
                Text("WhatsApp caps animated stickers at \(Int(Limits.maxAnimationDuration)) s, so the clip is limited to that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var fpsControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Frame rate")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(fps) fps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Picker("Frame rate", selection: $fps) {
                ForEach(Self.fpsOptions, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Frame rate")
            .accessibilityValue(Text("\(fps) frames per second"))

            Text("≈ \(estimatedFrames) frames")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("More frames per second looks smoother — like a good GIF — but WhatsApp caps animated stickers at 500 KB and \(Int(Limits.maxAnimationDuration)) s, so it compresses and may reduce frames automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    // MARK: - Create

    @MainActor
    private func create() {
        guard let draft, clipLength > 0 else { return }
        let range = lowerBound...upperBound
        isCreating = true
        player?.pause()
        isPlaying = false

        Task {
            do {
                let sticker = try await StickerFactory.makeAnimatedSticker(
                    from: draft,
                    range: range,
                    fps: Double(fps),
                    source: source
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
}

/// Two-handle range control over a duration. Content layer — never glass.
private struct TrimRangeSlider: View {
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

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let lowerX = x(for: lower, width: width)
            let upperX = x(for: upper, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemFill))
                    .frame(height: 6)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, upperX - lowerX), height: 6)
                    .offset(x: lowerX)

                handle.position(x: lowerX, y: proxy.size.height / 2)
                handle.position(x: upperX, y: proxy.size.height / 2)
            }
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
                        case .lower: lower = clampedLower(proposed)
                        case .upper: upper = clampedUpper(proposed)
                        case nil: break
                        }

                        if let handle = activeHandle {
                            onScrub(handle == .lower ? lower : upper)
                        }
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Trim range")
        .accessibilityValue(Text("\(seconds(lower)) to \(seconds(upper)) seconds"))
        .accessibilityHint("Drag the handles to choose the clip")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                upper = clampedUpper(upper + 0.5)
                onScrub(upper)
            case .decrement:
                upper = clampedUpper(upper - 0.5)
                onScrub(upper)
            @unknown default: break
            }
        }
    }

    private var handle: some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
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
