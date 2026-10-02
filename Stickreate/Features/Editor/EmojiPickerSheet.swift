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

    private let paletteColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    private var canAddCustom: Bool {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && selected.count < Limits.maxEmojisPerSticker
            && !selected.contains(trimmed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selectedSection
                    paletteSection
                    customSection
                }
                .padding(20)
            }
            .navigationTitle("Emojis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selected)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    // MARK: - Sections

    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected \(selected.count) of \(Limits.maxEmojisPerSticker)")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(selected, id: \.self) { emoji in
                    Button {
                        remove(emoji)
                    } label: {
                        Text(emoji)
                            .font(.largeTitle)
                            .frame(width: 44, height: 44)
                            .background(
                                Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(emoji)")
                }

                if selected.isEmpty {
                    Text("No emojis yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Common")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: paletteColumns, spacing: 8) {
                ForEach(Self.palette, id: \.self) { emoji in
                    let isSelected = selected.contains(emoji)
                    Button {
                        toggle(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.25)
                                    : Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Remove \(emoji)" : "Add \(emoji)")
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type your own")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
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

#Preview {
    EmojiPickerSheet(initialEmojis: ["😺", "🔥"]) { _ in }
}
