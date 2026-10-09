import SwiftUI

/// Assigns a pack to a folder. Type a name or pick an existing one; Save is the
/// single prominent action.
struct FolderPickerSheet: View {
    let currentFolder: String?
    let folders: [String]
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var savePulse = 0

    init(currentFolder: String?, folders: [String], onSave: @escaping (String?) -> Void) {
        self.currentFolder = currentFolder
        self.folders = folders
        self.onSave = onSave
        _text = State(initialValue: currentFolder ?? "")
    }

    private var trimmed: String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder name") {
                    TextField("Folder", text: $text)
                        .textInputAutocapitalization(.words)
                }

                if !folders.isEmpty {
                    Section("Existing folders") {
                        ForEach(folders, id: \.self) { folder in
                            Button {
                                text = folder
                            } label: {
                                HStack {
                                    Text(folder)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if text == folder {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(DS.ColorRole.accent)
                                    }
                                }
                                .frame(minHeight: DS.minTapTarget, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use folder \(folder)")
                            .accessibilityAddTraits(text == folder ? .isSelected : [])
                        }
                    }
                }

                if currentFolder != nil {
                    Section {
                        Button("Remove from Folder", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelActionItem { dismiss() }
                PrimaryActionItem(title: "Save") {
                    savePulse += 1
                    onSave(trimmed)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .haptic(.success, trigger: savePulse)
    }
}

// MARK: - Previews

#Preview("Light") {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
}

#Preview("Dark") {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
        .frame(width: 430, height: 932)
}
