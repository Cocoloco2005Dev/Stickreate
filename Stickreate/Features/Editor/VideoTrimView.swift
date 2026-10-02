import SwiftUI
import UIKit
import PhotosUI

/// Trims a picked video and turns it into an animated sticker.
///
/// The clip is chosen with a two-handle range control (WhatsApp caps animations
/// at 10 s) and a frame-rate control shows the estimated frame count live. The
/// final encode runs through `StickerFactory.makeAnimatedSticker`, which drops
/// frames automatically if the file would exceed WhatsApp's 500 KB budget.
@MainActor
struct VideoTrimView: View {
    let item: PhotosPickerItem
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: VideoDraft?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var lowerBound: TimeInterval = 0
    @State private var upperBound: TimeInterval = 0
    @State private var fps: Double = 10

    @State private var thumbnails: [UIImage] = []

    @State private var isCreating = false
    @State private var errorMessage: String?

    private var clipLength: TimeInterval {
        max(0, upperBound - lowerBound)
    }

    private var estimatedFrames: Int {
        max(1, Int((fps * clipLength).rounded()))
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
                Button("Close") { dismiss() }
            }
        }
    }

    private func controls(for draft: VideoDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                thumbnailStrip

                TrimRangeSlider(
                    duration: draft.duration,
                    minSpan: min(0.2, draft.duration),
                    maxSpan: min(Limits.maxAnimationDuration, draft.duration),
                    lower: $lowerBound,
                    upper: $upperBound
                )

                rangeSummary(for: draft)
                fpsControl
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var thumbnailStrip: some View {
        if !thumbnails.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
        }
    }

    private func rangeSummary(for draft: VideoDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Trim", value: "\(seconds(lowerBound)) – \(seconds(upperBound)) s")
            LabeledContent("Clip length", value: "\(seconds(clipLength)) s")

            if draft.duration > Limits.maxAnimationDuration {
                Text("WhatsApp caps animated stickers at \(Int(Limits.maxAnimationDuration)) seconds, so the clip is limited to that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var fpsControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frame rate")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(fps)) fps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $fps, in: 3...20, step: 1) {
                Text("Frame rate")
            }
            .accessibilityLabel("Frame rate")
            .accessibilityValue(Text("\(Int(fps)) frames per second"))

            Text("≈ \(estimatedFrames) frames")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("WhatsApp caps animated stickers at 500 KB, so very high frame rates may be reduced automatically.")
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
        defer { isLoading = false }

        do {
            let loaded = try await StickerFactory.loadVideoDraft(from: item)
            guard loaded.duration > 0 else {
                loadErrorMessage = "This video has no duration."
                return
            }
            draft = loaded
            lowerBound = 0
            upperBound = min(loaded.duration, Limits.maxAnimationDuration)
            await loadThumbnails(for: loaded)
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadThumbnails(for draft: VideoDraft) async {
        let count = 8
        var images: [UIImage] = []
        for index in 0..<count {
            let position = draft.duration * (Double(index) + 0.5) / Double(count)
            if let image = try? await FrameExtractor.thumbnail(fromVideoAt: draft.url, at: position) {
                images.append(image)
            }
        }
        thumbnails = images
    }

    // MARK: - Create

    @MainActor
    private func create() {
        guard let draft, clipLength > 0 else { return }
        let range = lowerBound...upperBound
        isCreating = true

        Task {
            do {
                let sticker = try await StickerFactory.makeAnimatedSticker(
                    from: draft,
                    range: range,
                    fps: fps
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
            case .increment: upper = clampedUpper(upper + 0.5)
            case .decrement: upper = clampedUpper(upper - 0.5)
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
