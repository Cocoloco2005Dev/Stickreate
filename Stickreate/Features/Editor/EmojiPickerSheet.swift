import SwiftUI
import UIKit

/// Picks up to `Limits.maxEmojisPerSticker` emojis for one sticker. Save is the
/// single prominent action; the palette is content layer.
@MainActor
struct EmojiPickerSheet: View {
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selected: [String]
    @State private var custom = ""
    @State private var savePulse = 0

    init(initialEmojis: [String], onSave: @escaping ([String]) -> Void) {
        self.onSave = onSave
        _selected = State(initialValue: Array(initialEmojis.prefix(Limits.maxEmojisPerSticker)))
    }

    private static let palette: [String] = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "😍", "😘",
        "😎", "🤩", "🥳", "😜", "🤔", "😴", "😭", "😡",
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "💯",
        "👍", "👎", "👏", "🙌", "🙏", "💪", "🤝", "✌️",
        "🔥", "✨", "⭐️", "🎉", "🎊", "💧", "☀️", "🌈",
        "🐶", "🐱", "🦊", "🐻", "🐼", "🐨", "🦁", "🐯"
    ]

    private let paletteColumns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: 6)

    private var canAddCustom: Bool {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && selected.count < Limits.maxEmojisPerSticker
            && !selected.contains(trimmed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    selectedSection
                    paletteSection
                    customSection
                }
                .padding(DS.Space.xl)
            }
            .navigationTitle("Emojis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePulse += 1
                        onSave(selected)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .haptic(.success, trigger: savePulse)
    }

    // MARK: - Sections

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Selected \(selected.count) of \(Limits.maxEmojisPerSticker)")
                .font(DS.TextRole.supporting.weight(.semibold))

            HStack(spacing: DS.Space.sm) {
                ForEach(selected, id: \.self) { emoji in
                    Button {
                        remove(emoji)
                    } label: {
                        Text(emoji)
                            .font(.largeTitle)
                            .frame(width: DS.minTapTarget, height: DS.minTapTarget)
                            .background(
                                DS.ColorRole.contentSurface,
                                in: RoundedRectangle(cornerRadius: DS.Radius.thumb, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(emoji)")
                }

                if selected.isEmpty {
                    Text("No emojis yet")
                        .font(DS.TextRole.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.minTapTarget)
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Common")
                .font(DS.TextRole.supporting.weight(.semibold))

            LazyVGrid(columns: paletteColumns, spacing: DS.Space.sm) {
                ForEach(Self.palette, id: \.self) { emoji in
                    let isSelected = selected.contains(emoji)
                    Button {
                        toggle(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: DS.minTapTarget)
                            .background(
                                isSelected
                                    ? DS.ColorRole.accent.opacity(0.25)
                                    : DS.ColorRole.contentSurface,
                                in: RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Remove \(emoji)" : "Add \(emoji)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Type your own")
                .font(DS.TextRole.supporting.weight(.semibold))

            HStack(spacing: DS.Space.md) {
                TextField("Emoji", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCustom() }

                Button("Add") { addCustom() }
                    .buttonStyle(.glass)
                    .disabled(!canAddCustom)
            }
        }
    }

    // MARK: - Selection

    private func toggle(_ emoji: String) {
        if let index = selected.firstIndex(of: emoji) {
            selected.remove(at: index)
        } else if selected.count < Limits.maxEmojisPerSticker {
            selected.append(emoji)
        }
    }

    private func remove(_ emoji: String) {
        selected.removeAll { $0 == emoji }
    }

    private func addCustom() {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              selected.count < Limits.maxEmojisPerSticker,
              !selected.contains(trimmed) else { return }
        selected.append(trimmed)
        custom = ""
    }
}

// MARK: - Previews

#Preview("Light") {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
}

#Preview("Dark") {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
        .frame(width: 430, height: 932)
}
