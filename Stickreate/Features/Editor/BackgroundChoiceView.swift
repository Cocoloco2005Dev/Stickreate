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
        VStack(spacing: 20) {
            Text("Keep the background or lift the subject with Intelligent Cut.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 16) {
                card(for: .original, title: "Original", subtitle: "Keeps the background")
                card(for: .aiCut, title: "Intelligent Cut", subtitle: "Apple Vision · on-device")
            }
            .padding(.horizontal, 20)

            Text("Intelligent Cut runs on this iPhone. Your photo never leaves the device.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.top, 20)
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
            VStack(spacing: 10) {
                swatch(for: option)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 3
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                }
            }

        case .aiCut:
            ZStack {
                CheckerboardSwatch()
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
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

#Preview {
    BackgroundChoiceView(previewImage: nil, choice: .constant(.original))
}
