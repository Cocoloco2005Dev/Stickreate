import SwiftUI
import PhotosUI

/// Sheet for picking photos, videos, or Live Photos and turning them into
/// stickers. Presented as a sheet with its own navigation bar.
struct AddStickerSheet: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var selection: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private var pack: StickerPack? { store.pack(with: packID) }

    private var remaining: Int {
        max(0, Limits.maxStickers - (pack?.stickers.count ?? 0))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Stickers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isProcessing)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            Task { await add() }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(selection.isEmpty || isProcessing || remaining == 0)
                    }
                }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isProcessing {
            ProgressView("Creating stickers…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if remaining == 0 {
            ContentUnavailableView {
                Label("Pack Is Full", systemImage: "checkmark.circle")
            } description: {
                Text("A pack can hold at most \(Limits.maxStickers) stickers.")
            }
        } else {
            VStack(spacing: 24) {
                picker

                Text("You can add up to \(remaining) more \(remaining == 1 ? "sticker" : "stickers").")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(24)
        }
    }

    private var picker: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: remaining,
            matching: .any(of: [.images, .videos, .livePhotos])
        ) {
            Label(
                selection.isEmpty ? "Choose Photos" : "\(selection.count) selected",
                systemImage: "photo.on.rectangle.angled"
            )
        }
        .buttonStyle(.glass)
    }

    @MainActor
    private func add() async {
        guard !selection.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }

        for item in selection {
            do {
                let sticker = try await StickerFactory.makeSticker(from: item)
                try store.add(sticker, to: packID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        selection = []
        dismiss()
    }
}

#Preview {
    let store = PackStore()
    let pack = store.createPack(named: "Cats")
    return AddStickerSheet(store: store, packID: pack.id)
}
