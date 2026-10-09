import SwiftUI
import UIKit

/// The two explicit background options for an animated sticker.
enum StickerBackgroundChoice: Hashable {
    case original
    case aiCut
}

/// Lets the user choose between keeping the video's background or cutting the
/// subject out. Content layer — the swatches are opaque, never glass.
struct BackgroundChoiceView: View {
    let previewImage: UIImage?
    @Binding var choice: StickerBackgroundChoice

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            Spacer(minLength: 0)

            Text("Keep the background or lift the subject with Intelligent Cut.")
                .font(DS.TextRole.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Space.xxl)

            HStack(spacing: DS.Space.lg) {
                card(for: .original, title: "Original", subtitle: "Keeps the background")
                card(for: .aiCut, title: "Intelligent Cut", subtitle: "Apple Vision · on-device")
            }
            .padding(.horizontal, DS.Space.xl)

            Text("Intelligent Cut runs on this iPhone. Your photo never leaves the device.")
                .font(DS.TextRole.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Space.xxl)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(
        for option: StickerBackgroundChoice,
        title: String,
        subtitle: String
    ) -> some View {
        let isSelected = choice == option

        return Button {
            choice = option
        } label: {
            VStack(spacing: DS.Space.sm) {
                swatch(for: option)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DS.ColorRole.accent)
                                .padding(DS.Space.sm)
                                .accessibilityHidden(true)
                        }
                    }

                Text(title)
                    .font(DS.TextRole.cardTitle)

                Text(subtitle)
                    .font(DS.TextRole.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity)
            .background(
                DS.ColorRole.contentSurface,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? DS.ColorRole.accent : Color.clear,
                        lineWidth: 3
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Selects \(title)")
    }

    @ViewBuilder
    private func swatch(for option: StickerBackgroundChoice) -> some View {
        switch option {
        case .original:
            ZStack {
                Color(uiColor: .tertiarySystemBackground)
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

        case .aiCut:
            ZStack {
                CheckerboardSwatch()
                Image(systemName: "person.crop.rectangle")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(DS.ColorRole.accent)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Small checkerboard used behind the Intelligent Cut swatch. Content layer — never glass.
private struct CheckerboardSwatch: View {
    private let cell: CGFloat = 12

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

// MARK: - Previews

#Preview("Light") {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.original))
}

#Preview("Dark") {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.aiCut))
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.original))
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.original))
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.aiCut))
        .frame(width: 430, height: 932)
}
