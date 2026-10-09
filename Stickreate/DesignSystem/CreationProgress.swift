import SwiftUI

/// Blocking creation-progress card shared by every screen that encodes a
/// sticker. It shows a **real** bar driven by the service's
/// `StickerCreationStage.fraction` (never a computed/fake percentage), the
/// stage's own label (which already carries the `%`), and a Cancel affordance so
/// the user is never stuck in a black box.
struct CreationProgressCard: View {
    let stage: StickerCreationStage?
    let onCancel: () -> Void
    var title: String = "Creating sticker"
    var detail: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stageLabel: String {
        guard let stage else { return "Preparing…" }
        if case .loading = stage { return "Preparing…" }
        return stage.label
    }

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.sm) {
                Text(title)
                    .font(DS.TextRole.cardTitle)

                Text(stageLabel)
                    .font(DS.TextRole.supporting)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : DS.Motion.quick, value: stageLabel)

                if let detail {
                    Text(detail)
                        .font(DS.TextRole.caption)
                        .foregroundStyle(.tertiary)
                }

                progressBar
                    .padding(.top, DS.Space.xxs)
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .buttonStyle(.glass)
                .frame(minWidth: 120, minHeight: DS.minTapTarget)
                .accessibilityHint("Stops creating this sticker")
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = stage?.fraction {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}

private struct CreationProgressOverlayModifier: ViewModifier {
    let isPresented: Bool
    let stage: StickerCreationStage?
    let title: String
    let detail: String?
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    CreationProgressCard(
                        stage: stage,
                        onCancel: onCancel,
                        title: title,
                        detail: detail
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: isPresented)
    }
}

extension View {
    /// Presents the shared creation-progress card (with Cancel) over the screen.
    func creationProgressOverlay(
        _ isPresented: Bool,
        stage: StickerCreationStage?,
        title: String = "Creating sticker",
        detail: String? = nil,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(
            CreationProgressOverlayModifier(
                isPresented: isPresented,
                stage: stage,
                title: title,
                detail: detail,
                onCancel: onCancel
            )
        )
    }
}

#Preview("Creation progress") {
    CreationProgressCard(stage: .compressing(0.42), onCancel: {}, detail: "Item 2 of 5")
        .padding()
}
