import SwiftUI
import UIKit
import Observation
import VisionKit

/// Dedicated subject-lift step, built on VisionKit so press-and-hold behaves
/// exactly like Photos.
///
/// A `UIImageView` hosts an `ImageAnalysisInteraction`; VisionKit draws its own
/// highlight and lift while the finger is down. As soon as a subject is lifted,
/// its background-removed cut-out appears as a draggable thumbnail. The user
/// drags it into a target box (or taps "Use Subject") to hand it to the editor,
/// which adopts the cut-out as its working image directly — no alpha-to-mask
/// conversion, so there is nothing to misalign.
@MainActor
struct SubjectLiftView: View {
    /// The working image to analyze.
    let image: UIImage
    /// Called with the background-removed cut-out when the user confirms.
    let onLift: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = SubjectLiftModel()

    // Drag-to-use state, all in the global coordinate space.
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var isOverTarget = false
    @State private var targetFrame: CGRect = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                SubjectLiftCanvas(image: image, model: model)

                if model.isAnalyzing {
                    analyzingOverlay
                } else if model.subjectCount == 0 {
                    emptyOverlay
                }
            }
            .navigationTitle("Lift Subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .alert("Couldn't lift subject", isPresented: errorBinding) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - Bottom control

    /// One fixed layout in every state: the lifted-subject slot, the drag target,
    /// and both buttons are always present (just disabled/hidden-content until a
    /// subject is lifted), so nothing pops or re-lays out mid-flow.
    private var bottomBar: some View {
        VStack(spacing: 12) {
            Text("Press and hold a subject, then drag it into the box")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                liftedSlot

                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)

                dropTarget
            }

            HStack(spacing: 12) {
                Button("Lift Different") { model.liftedImage = nil }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                    .disabled(model.liftedImage == nil)
                    .accessibilityHint("Clears this subject so you can lift another")

                Button("Use Subject") { confirmLifted() }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.liftedImage == nil)
                    .accessibilityHint("Uses this subject in the editor")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

    /// Always-present slot for the lifted subject, so the row never re-lays out.
    @ViewBuilder
    private var liftedSlot: some View {
        if let lifted = model.liftedImage {
            liftedThumbnail(lifted)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "person.crop.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )
                .accessibilityHidden(true)
        }
    }

    private func liftedThumbnail(_ lifted: UIImage) -> some View {
        Image(uiImage: lifted)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 84, height: 84)
            .background(LiftCheckerboard())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(isDragging ? 0.45 : 0.2),
                radius: isDragging ? 14 : 5,
                y: isDragging ? 8 : 3
            )
            .scaleEffect(isDragging ? 1.08 : 1)
            .offset(dragTranslation)
            .zIndex(isDragging ? 2 : 0)
            .gesture(dragToUse)
            .accessibilityLabel("Lifted subject")
            .accessibilityHint("Drag into the box, or use the Use Subject button")
    }

    private var dropTarget: some View {
        VStack(spacing: 6) {
            Image(systemName: isOverTarget ? "checkmark.circle.fill" : "arrow.down.to.line")
                .font(.title2)
            Text("Use this subject")
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(isOverTarget ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isOverTarget ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isOverTarget ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            targetFrame = frame
        }
        .accessibilityLabel("Use this subject target")
    }

    private var dragToUse: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                dragTranslation = value.translation
                isOverTarget = targetFrame.contains(value.location)
            }
            .onEnded { value in
                let dropped = targetFrame.contains(value.location)
                withAnimation(.snappy) {
                    isDragging = false
                    dragTranslation = .zero
                    isOverTarget = false
                }
                if dropped {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    confirmLifted()
                }
            }
    }

    // MARK: - Overlays

    private var analyzingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Finding subjects…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
    }

    /// No dead-end: when VisionKit finds nothing, steer back to the manual tools.
    private var emptyOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.rectangle.badge.xmark")
                .font(.system(size: 40))
            Text("No subjects found")
                .font(.headline)
            Text("VisionKit couldn't find a subject to lift. Go back and refine with Restore, Erase, Rectangle, Lasso or Crop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to tools") { dismiss() }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func confirmLifted() {
        guard let lifted = model.liftedImage else { return }
        onLift(lifted)
        dismiss()
    }
}

/// Holds the VisionKit interaction and the lift state the SwiftUI chrome reads.
@MainActor
@Observable
final class SubjectLiftModel {
    var subjectCount = 0
    var isAnalyzing = true
    var errorMessage: String?
    /// The background-removed subject awaiting confirmation, if any.
    var liftedImage: UIImage?

    /// The interaction installed on the image view. Not observed: results are
    /// mirrored into the observed properties above.
    @ObservationIgnored var interaction: ImageAnalysisInteraction?
    /// Guards against overlapping cut-out generations.
    @ObservationIgnored private var isGenerating = false

    /// Renders the background-removed image for `subjects` and stores it.
    func generate(for subjects: Set<ImageAnalysisInteraction.Subject>) async {
        guard let interaction, !isGenerating, !subjects.isEmpty else { return }
        isGenerating = true
        defer { isGenerating = false }
        do {
            liftedImage = try await interaction.image(for: subjects)
        } catch {
            if liftedImage == nil {
                errorMessage = "Couldn't lift that subject. Try again."
            }
        }
    }
}

/// Thin bridge: a `UIImageView` with the VisionKit subject interaction.
private struct SubjectLiftCanvas: UIViewRepresentable {
    let image: UIImage
    let model: SubjectLiftModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .imageSubject
        imageView.addInteraction(interaction)
        model.interaction = interaction

        context.coordinator.analyze(image: image, interaction: interaction, model: model)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        private var task: Task<Void, Never>?

        func analyze(
            image: UIImage,
            interaction: ImageAnalysisInteraction,
            model: SubjectLiftModel
        ) {
            task?.cancel()
            task = Task { @MainActor [weak model] in
                guard let model else { return }

                do {
                    let analyzer = ImageAnalyzer()
                    let configuration = ImageAnalyzer.Configuration([])
                    let analysis = try await analyzer.analyze(image, configuration: configuration)
                    guard !Task.isCancelled else { return }
                    interaction.analysis = analysis
                } catch {
                    model.subjectCount = 0
                    model.isAnalyzing = false
                    return
                }

                // Subject lifting runs as its own pass a few seconds after the
                // initial analysis, so `subjects` may start empty.
                for _ in 0..<24 {
                    if Task.isCancelled { return }
                    let current = await interaction.subjects
                    if !current.isEmpty { break }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                guard !Task.isCancelled else { return }
                let finalSubjects = await interaction.subjects
                model.subjectCount = finalSubjects.count
                model.isAnalyzing = false

                // Auto-materialize the cut-out when the user highlights a subject
                // (press-and-hold), so a draggable thumbnail appears like Photos.
                // Bounded so the task always ends even without dismantling.
                var lastHighlighted: Set<ImageAnalysisInteraction.Subject> = []
                for _ in 0..<300 {
                    if Task.isCancelled { return }
                    let highlighted = interaction.highlightedSubjects
                    if highlighted.isEmpty {
                        lastHighlighted = []
                    } else if highlighted != lastHighlighted {
                        lastHighlighted = highlighted
                        await model.generate(for: highlighted)
                    }
                    try? await Task.sleep(for: .seconds(0.4))
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}

/// Small checkerboard so a cut-out's transparency reads inside its thumbnail.
private struct LiftCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            let light = Color(uiColor: .systemGray5)
            let dark = Color(uiColor: .systemGray3)
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
