import SwiftUI
import UIKit

/// Confirms and exports a finished pack. WhatsApp mode adds the pack's single
/// kind; packs can't mix photos and videos, so a mixed pack is blocked with an
/// explanation. File mode shares a `.stickreatepack`.
///
/// Reads the pack live from the store by id, so it never shows a stale snapshot.
struct ExportSheet: View {
    let store: PackStore
    let packID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var settings = SettingsStore.shared
    @State private var isExported = false
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?
    @State private var detent: PresentationDetent = .large

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var pack: StickerPack? { store.pack(with: packID) }

    @MainActor private var isWhatsAppInstalled: Bool { WhatsAppExporter.isWhatsAppInstalled }

    var body: some View {
        NavigationStack {
            Group {
                if let pack {
                    ScrollView {
                        VStack(spacing: 24) {
                            preview(pack)
                            header(pack)
                            actions(pack)
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle(settings.exportMode == .file ? "Export Pack" : "Add to WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(url: item.url) {
                shareItem = nil
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
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

    private func preview(_ pack: StickerPack) -> some View {
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

    private func header(_ pack: StickerPack) -> some View {
        VStack(spacing: 4) {
            Text(pack.name)
                .font(.headline)
                .lineLimit(1)

            Text(statusLine(pack))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func statusLine(_ pack: StickerPack) -> String {
        let count = pack.stickers.count
        let kind = pack.kind?.label.lowercased() ?? "sticker"
        return "\(count) \(kind) \(count == 1 ? "sticker" : "stickers") · ready to add"
    }

    // MARK: - Actions

    @MainActor
    @ViewBuilder
    private func actions(_ pack: StickerPack) -> some View {
        if settings.exportMode == .file {
            fileActions(pack)
        } else if pack.isMixed {
            mixedNotice
        } else {
            singleAction(pack)
        }
    }

    @MainActor
    private func fileActions(_ pack: StickerPack) -> some View {
        VStack(spacing: 12) {
            Button {
                shareFile(pack)
            } label: {
                Label("Share Pack File", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)

            Text("Shares a .stickreatepack. Anyone with Stickreate can import it later.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @MainActor
    private func shareFile(_ pack: StickerPack) {
        do {
            let url = try PackArchive.writeTemporaryFile(pack)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private var mixedNotice: some View {
        VStack(spacing: 12) {
            Label("This pack mixes photos and videos", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))

            Text("WhatsApp imports one kind per pack. Remove the stickers that don't belong, or share it as a file instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func singleAction(_ pack: StickerPack) -> some View {
        VStack(spacing: 12) {
            if isExported {
                addedLabel("Added to WhatsApp")
            } else {
                Button {
                    export(pack)
                } label: {
                    Label("Add to WhatsApp", systemImage: "plus.message")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(pack.stickers.isEmpty)
            }

            whatsAppFootnote
        }
    }

    private func addedLabel(_ title: String) -> some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(title)
    }

    @MainActor
    @ViewBuilder
    private var whatsAppFootnote: some View {
        if !isWhatsAppInstalled {
            Text("If WhatsApp doesn't open, open it once and try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @MainActor
    private func export(_ pack: StickerPack) {
        do {
            try WhatsAppExporter.export(
                stickers: pack.stickers,
                kind: pack.kind ?? .static,
                name: pack.name,
                publisher: pack.publisher,
                identifier: pack.id.uuidString
            )
            withAnimation { isExported = true }

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
    let store = PackStore()
    let stickers = (0..<6).map { _ in
        StickerItem(kind: .static, stickerData: Data(), previewData: Data())
    }
    let pack = StickerPack(name: "Cats", stickers: stickers)
    store.importPack(pack)
    return ExportSheet(store: store, packID: pack.id)
}
