import SwiftUI
import UIKit

/// Confirms and hands a finished pack to WhatsApp. Exactly one prominent action:
/// "Add to WhatsApp", tinted green because green means WhatsApp here.
struct ExportSheet: View {
    let pack: StickerPack

    @Environment(\.dismiss) private var dismiss

    @State private var exported = false
    @State private var errorMessage: String?

    @MainActor private var isWhatsAppInstalled: Bool { WhatsAppExporter.isWhatsAppInstalled }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                preview
                header
                Spacer(minLength: 0)
                actions
            }
            .padding(24)
            .navigationTitle("Add to WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .alert(
            "Couldn't add pack",
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

    private var preview: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(pack.stickers.prefix(6)) { item in
                stickerThumbnail(item)
            }
        }
        .accessibilityHidden(true)
    }

    private func stickerThumbnail(_ item: StickerItem) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = UIImage(data: item.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(pack.name)
                .font(.headline)
                .lineLimit(1)

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var statusLine: String {
        let count = pack.stickers.count
        let kind = pack.kind?.label.lowercased() ?? "sticker"
        return "\(count) \(kind) \(count == 1 ? "sticker" : "stickers") · ready to add"
    }

    @MainActor
    @ViewBuilder
    private var actions: some View {
        if exported {
            Label("Added to WhatsApp", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityLabel("Added to WhatsApp")
        } else {
            VStack(spacing: 12) {
                Button {
                    export()
                } label: {
                    Label("Add to WhatsApp", systemImage: "plus.message")
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(!isWhatsAppInstalled)

                if !isWhatsAppInstalled {
                    Text("WhatsApp isn't installed. Install it, then come back to add this pack.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @MainActor
    private func export() {
        do {
            try WhatsAppExporter.export(pack)
            withAnimation { exported = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    let stickers = (0..<6).map { _ in
        StickerItem(kind: .static, stickerData: Data(), previewData: Data())
    }
    return ExportSheet(pack: StickerPack(name: "Cats", stickers: stickers))
}
