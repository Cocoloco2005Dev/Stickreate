import SwiftUI
import UIKit
import Observation
import VisionKit

/// Dedicated subject-lift step built on VisionKit.
///
/// VisionKit detects **every** subject in the photo. The user picks one by
/// tapping it on the image (`interaction.subject(at:)`), tapping its numbered
/// chip, or press-and-holding it (Photos-like). The chosen subject's
/// background-removed cut-out is rendered in the preview box, and a
/// Cut-out / Original switch shows what is being cut from. Confirming hands the
/// cut-out to the editor, which adopts it as its working image directly.
@MainActor
struct SubjectLiftView: View {
    /// The (pristine) working image to analyze.
    let image: UIImage
    /// Called with the background-removed cut-out when the user confirms.
    let onLift: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = SubjectLiftModel()
    @State private var showsOriginal = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                SubjectLiftCanvas(image: image, model: model)

                if model.isAnalyzing {
                    analyzingOverlay
                } else if model.subjects.isEmpty {
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
            // Picking a subject always returns to the cut-out view.
            .onChange(of: model.selectedIndex) { _, _ in showsOriginal = false }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - Bottom control

    private var bottomBar: some View {
        VStack(spacing: DS.Space.md) {
            instruction
                .font(DS.TextRole.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.subjects.count > 1 {
                subjectStrip
            }

            HStack(alignment: .center, spacing: DS.Space.lg) {
                previewBox

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Picker("Preview", selection: $showsOriginal) {
                        Text("Cut-out").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Preview mode")
                    .accessibilityHint("Switches the preview between the lifted cut-out and the original photo")

                    Button("Use Subject") { confirmLifted() }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity, minHeight: DS.minTapTarget)
                        .disabled(model.previewImage == nil)
                        .accessibilityHint("Uses the previewed subject in the editor")
                }
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.xs)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

    private var instruction: Text {
        if model.subjects.count > 1 {
            Text("Tap a subject to preview it, then Use Subject.")
        } else {
            Text("Tap the subject to preview it, then Use Subject.")
        }
    }

    // MARK: - Subject list

    /// Numbered chips, one per detected subject (left-to-right), so every subject
    /// is selectable by a reliable tap — no dragging required.
    private var subjectStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(Array(model.subjects.enumerated()), id: \.offset) { index, _ in
                    subjectChip(index)
                }
            }
            .padding(.horizontal, DS.Space.xs)
        }
        .accessibilityLabel("Detected subjects")
    }

    private func subjectChip(_ index: Int) -> some View {
        let selected = model.selectedIndex == index
        return Button {
            model.select(index)
        } label: {
            Text("\(index + 1)")
                .font(DS.TextRole.supporting.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: DS.minTapTarget, height: DS.minTapTarget)
                .background(
                    Circle().fill(
                        selected ? DS.ColorRole.accent : Color(uiColor: .secondarySystemFill)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Subject \(index + 1)")
        .accessibilityHint("Previews this subject")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Preview box (shows the cropped result, not an icon)

    private var previewBox: some View {
        ZStack {
            if showsOriginal {
                Color(uiColor: .tertiarySystemBackground)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let preview = model.previewImage {
                LiftCheckerboard()
                Image(uiImage: preview)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(DS.Space.sm)
            } else if model.isPreviewLoading {
                LiftCheckerboard()
                ProgressView()
                    .tint(.white)
            } else {
                Color(uiColor: .secondarySystemFill)
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "person.crop.rectangle")
                        .font(.title2)
                    Text("Tap a subject")
                        .font(DS.TextRole.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewAccessibilityLabel)
        .accessibilityHint("The subject you'll lift into the editor")
    }

    private var previewAccessibilityLabel: String {
        if showsOriginal { return "Original image" }
        if model.previewImage != nil { return "Selected subject preview" }
        if model.isPreviewLoading { return "Preparing subject preview" }
        return "No subject selected"
    }

    // MARK: - Overlays

    private var analyzingOverlay: some View {
        VStack(spacing: DS.Space.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Finding subjects…")
                .font(DS.TextRole.supporting.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finding subjects")
    }

    /// No dead-end: when VisionKit finds nothing, steer back to the manual tools.
    private var emptyOverlay: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "person.crop.rectangle.badge.xmark")
                .font(.largeTitle)
            Text("No subjects found")
                .font(DS.TextRole.cardTitle)
            Text("VisionKit couldn't find a subject to lift. Go back and refine with Restore, Erase, Rectangle, Lasso or Crop.")
                .font(DS.TextRole.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to tools") { dismiss() }
                .buttonStyle(.glass)
                .frame(minHeight: DS.minTapTarget)
        }
        .foregroundStyle(.white)
        .padding(DS.Space.xxl)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .padding(.horizontal, DS.Space.xxl)
    }

    // MARK: - Actions

    private func confirmLifted() {
        guard let lifted = model.previewImage else { return }
        onLift(lifted)
        dismiss()
    }
}

/// Holds the VisionKit interaction and the per-subject lift state the SwiftUI
/// chrome reads. One subject is selected at a time; its single-subject cut-out is
/// generated once per selection.
@MainActor
@Observable
final class SubjectLiftModel {
    /// Every subject VisionKit found, ordered left-to-right.
    var subjects: [ImageAnalysisInteraction.Subject] = []
    /// Index into `subjects` of the current selection, if any.
    var selectedIndex: Int?
    /// The cut-out for the selected subject, shown in the preview box.
    var previewImage: UIImage?
    var isPreviewLoading = false
    var isAnalyzing = true
    var errorMessage: String?

    /// The interaction installed on the image view. Not observed.
    @ObservationIgnored var interaction: ImageAnalysisInteraction?
    /// Token guarding against a stale preview publishing after a fast switch.
    @ObservationIgnored private var generation = 0

    var selectedSubject: ImageAnalysisInteraction.Subject? {
        guard let selectedIndex, subjects.indices.contains(selectedIndex) else { return nil }
        return subjects[selectedIndex]
    }

    /// Orders the detected subjects and selects the first so a preview is ready
    /// immediately. Keeps the current selection when it is still valid.
    func setSubjects(_ set: Set<ImageAnalysisInteraction.Subject>) {
        // `Subject.bounds` is horizontal in any coordinate space, so sorting by
        // `minX` gives a stable left-to-right order without needing to interpret
        // the origin.
        subjects = set.sorted { $0.bounds.minX < $1.bounds.minX }
        guard !subjects.isEmpty else {
            selectedIndex = nil
            previewImage = nil
            return
        }
        let keepCurrent = selectedIndex.map { subjects.indices.contains($0) } ?? false
        if !keepCurrent { select(0) }
    }

    /// Selects a subject by index and previews its cut-out.
    func select(_ index: Int) {
        guard subjects.indices.contains(index) else { return }
        let changed = selectedIndex != index
        selectedIndex = index
        if changed || previewImage == nil {
            generatePreview()
        }
    }

    /// Selects a subject instance reported by a tap or a press-and-hold highlight.
    func selectSubject(_ subject: ImageAnalysisInteraction.Subject) {
        guard let index = subjects.firstIndex(of: subject) else { return }
        select(index)
    }

    func selectHighlighted(_ highlighted: Set<ImageAnalysisInteraction.Subject>) {
        guard let subject = highlighted.first else { return }
        selectSubject(subject)
    }

    /// Renders the cut-out for the selected subject only (one single-subject set
    /// per call, as VisionKit expects). A newer selection supersedes an in-flight
    /// one, so a stale image never lands.
    func generatePreview() {
        guard let interaction, let subject = selectedSubject else {
            previewImage = nil
            return
        }
        generation &+= 1
        let token = generation
        isPreviewLoading = true
        Task { @MainActor in
            defer { if token == generation { isPreviewLoading = false } }
            do {
                let image = try await interaction.image(for: Set([subject]))
                guard token == generation else { return }
                previewImage = image
            } catch {
                guard token == generation else { return }
                previewImage = nil
                errorMessage = "Couldn't lift that subject. Try again."
            }
        }
    }
}

/// Thin bridge: a `UIImageView` with the VisionKit subject interaction, plus a
/// tap recognizer that maps a tap to the subject under it.
private struct SubjectLiftCanvas: UIViewRepresentable {
    let image: UIImage
    let model: SubjectLiftModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isAccessibilityElement = true
        container.accessibilityLabel = "Photo with detected subjects"
        container.accessibilityHint = "Use the subject buttons below to preview one"

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

        // Tap-to-select: coexist with VisionKit's own (press-and-hold) gestures.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        imageView.addGestureRecognizer(tap)

        context.coordinator.analyze(image: image, interaction: interaction)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let model: SubjectLiftModel
        private var task: Task<Void, Never>?

        init(model: SubjectLiftModel) {
            self.model = model
        }

        /// A tap selects the subject under the finger, if any.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let interaction = model.interaction,
                  let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let model = self.model
            Task { @MainActor in
                if let subject = await interaction.subject(at: point) {
                    model.selectSubject(subject)
                }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func analyze(image: UIImage, interaction: ImageAnalysisInteraction) {
            task?.cancel()
            let model = self.model
            task = Task { @MainActor [weak model] in
                guard let model else { return }

                do {
                    let analyzer = ImageAnalyzer()
                    let configuration = ImageAnalyzer.Configuration([])
                    let analysis = try await analyzer.analyze(image, configuration: configuration)
                    guard !Task.isCancelled else { return }
                    interaction.analysis = analysis
                } catch {
                    model.isAnalyzing = false
                    return
                }

                // Subject lifting runs as its own pass a few seconds after the
                // initial analysis, so `subjects` may start empty.
                var found: Set<ImageAnalysisInteraction.Subject> = []
                for _ in 0..<24 {
                    if Task.isCancelled { return }
                    let current = await interaction.subjects
                    if !current.isEmpty {
                        found = current
                        break
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                guard !Task.isCancelled else { return }
                if found.isEmpty { found = await interaction.subjects }
                model.setSubjects(found)
                model.isAnalyzing = false

                // Press-and-hold: VisionKit highlights the subject under the
                // finger; select it so its cut-out previews automatically.
                // Bounded so the task always ends even without dismantling.
                var lastHighlighted: Set<ImageAnalysisInteraction.Subject> = []
                for _ in 0..<300 {
                    if Task.isCancelled { return }
                    let highlighted = interaction.highlightedSubjects
                    if highlighted.isEmpty {
                        lastHighlighted = []
                    } else if highlighted != lastHighlighted {
                        lastHighlighted = highlighted
                        model.selectHighlighted(highlighted)
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

// MARK: - Previews

private func previewLiftImage() -> UIImage {
    UIImage(systemName: "photo") ?? UIImage()
}

#Preview("Light") {
    SubjectLiftView(image: previewLiftImage()) { _ in }
}

#Preview("Dark") {
    SubjectLiftView(image: previewLiftImage()) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    SubjectLiftView(image: previewLiftImage()) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    SubjectLiftView(image: previewLiftImage()) { _ in }
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    SubjectLiftView(image: previewLiftImage()) { _ in }
        .frame(width: 430, height: 932)
}
