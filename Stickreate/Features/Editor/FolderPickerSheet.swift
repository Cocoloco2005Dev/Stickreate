import SwiftUI

/// Assigns a pack to a folder. Type a name or pick an existing one; Save is the
/// single prominent action.
struct FolderPickerSheet: View {
    let currentFolder: String?
    let folders: [String]
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String

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
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use folder \(folder)")
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmed)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    FolderPickerSheet(currentFolder: "Cats", folders: ["Cats", "Dogs"]) { _ in }
}
