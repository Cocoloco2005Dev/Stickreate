import SwiftUI
import UIKit
import Observation
import VisionKit

/// Dedicated subject-lift step, built on VisionKit so press-and-hold behaves
/// exactly like Photos.
///
/// A `UIImageView` hosts an `ImageAnalysisInteraction`; VisionKit draws its own
/// highlight and lift while the finger is down. "Use Subject" hands the
/// background-removed cutout back to the editor, which seeds its editable mask
/// from the cutout's alpha so Restore/Erase/Rectangle/Lasso/Crop still refine it.
@MainActor
struct SubjectLiftView: View {
    /// The working image to analyze. Same pixels the editor edits.
    let image: UIImage
    /// Called with the background-removed cut-out when the user confirms.
    let onLift: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = SubjectLiftModel()

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

    // MARK: - Chrome

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Text("Press and hold a subject to lift it")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                liftSelected()
            } label: {
                Text("Use Subject")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.subjectCount == 0 || model.isLifting)
            .accessibilityHint("Lifts the highlighted subject into the editor")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

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

    // MARK: - Lift

    private func liftSelected() {
        guard !model.isLifting else { return }
        model.isLifting = true
        Task {
            defer { model.isLifting = false }
            do {
                if let cutout = try await model.lift() {
                    onLift(cutout)
                    dismiss()
                } else {
                    model.errorMessage = "Press and hold a subject, then tap Use Subject."
                }
            } catch {
                model.errorMessage = "Couldn't lift that subject. Try again."
            }
        }
    }
}

/// Holds the VisionKit interaction and the analysis state the SwiftUI chrome
/// reads. The representable owns the views; this class only exposes results.
@MainActor
@Observable
final class SubjectLiftModel {
    var subjectCount = 0
    var isAnalyzing = true
    var isLifting = false
    var errorMessage: String?

    /// The interaction installed on the image view. Not observed: analyzed
    /// results are mirrored into the observed properties below.
    @ObservationIgnored var interaction: ImageAnalysisInteraction?

    /// Returns the background-removed image for the highlighted subject, or the
    /// single subject when only one exists. `nil` when nothing is available.
    func lift() async throws -> UIImage? {
        guard let interaction else { return nil }
        let chosen = interaction.highlightedSubjects.isEmpty
            ? interaction.subjects
            : interaction.highlightedSubjects
        guard !chosen.isEmpty else { return nil }
        return try await interaction.image(for: chosen)
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

    @MainActor
    final class Coordinator {
        private var pollTask: Task<Void, Never>?

        func analyze(
            image: UIImage,
            interaction: ImageAnalysisInteraction,
            model: SubjectLiftModel
        ) {
            pollTask?.cancel()
            pollTask = Task { [weak model] in
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
                // initial analysis, so `subjects` may start empty. Poll until it
                // resolves or we time out (~12s).
                for _ in 0..<24 {
                    if Task.isCancelled { return }
                    let count = interaction.subjects.count
                    if count > 0 {
                        model.subjectCount = count
                        model.isAnalyzing = false
                        return
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                model.subjectCount = interaction.subjects.count
                model.isAnalyzing = false
            }
        }
    }
}

/// Converts a background-removed cut-out's alpha channel into the single-channel
/// keep mask `MaskEditor` seeds from.
///
/// `MaskCompositor.seed` draws the mask through a vertically flipped transform,
/// so this mirrors that same transform when reading alpha: whatever Core Graphics
/// does when drawing into a bitmap context, the flip cancels out and the seeded
/// mask lands upright. Alpha 255 = keep, 0 = remove.
enum SubjectCutoutMask {
    static func mask(fromAlphaOf cutout: UIImage) -> CGImage? {
        let source = cutout.cgImage
        guard let cgImage = source ?? cutout.upNormalized()?.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height)
        let created: Bool = bytes.withUnsafeMutableBytes { buffer in
            // Alpha-only context: drawing the cut-out leaves the source alpha.
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: nil,
                      bitmapInfo: CGImageAlphaInfo.only.rawValue
                  ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }

        for index in bytes.indices {
            bytes[index] = bytes[index] >= 128 ? 255 : 0
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
