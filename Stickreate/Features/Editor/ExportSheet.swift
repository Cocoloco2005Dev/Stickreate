import SwiftUI
import UIKit

/// Confirms and exports a finished pack. WhatsApp mode hands it to WhatsApp (a
/// mixed pack exports its static and animated subsets separately); file mode
/// shares a `.stickreatepack`.
struct ExportSheet: View {
    let pack: StickerPack

    @Environment(\.dismiss) private var dismiss

    @State private var settings = SettingsStore.shared
    @State private var exportedKinds: Set<StickerKind> = []
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?
    @State private var detent: PresentationDetent = .large

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @MainActor private var isWhatsAppInstalled: Bool { WhatsAppExporter.isWhatsAppInstalled }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    preview
                    header
                    actions
                }
                .padding(24)
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
        if pack.isMixed {
            return "\(pack.staticStickers.count) static · \(pack.animatedStickers.count) animated"
        }
        let count = pack.stickers.count
        let kind = pack.kind?.label.lowercased() ?? "sticker"
        return "\(count) \(kind) \(count == 1 ? "sticker" : "stickers") · ready to add"
    }

    // MARK: - Actions

    @MainActor
    @ViewBuilder
    private var actions: some View {
        if settings.exportMode == .file {
            fileActions
        } else if pack.isMixed {
            mixedActions
        } else {
            singleAction
        }
    }

    @MainActor
    private var fileActions: some View {
        VStack(spacing: 12) {
            Button {
                shareFile()
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
    private func shareFile() {
        do {
            let url = try PackArchive.writeTemporaryFile(pack)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private var singleAction: some View {
        VStack(spacing: 12) {
            if exportedKinds.contains(pack.kind ?? .static) {
                addedLabel("Added to WhatsApp")
            } else {
                Button {
                    export(stickers: pack.stickers, kind: pack.kind ?? .static)
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

    @MainActor
    private var mixedActions: some View {
        VStack(spacing: 12) {
            Text("This pack has photos and videos. WhatsApp needs them as two separate packs.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            exportButton(kind: .static, stickers: pack.staticStickers)
            exportButton(kind: .animated, stickers: pack.animatedStickers)
            whatsAppFootnote
        }
    }

    @MainActor
    private func exportButton(kind: StickerKind, stickers: [StickerItem]) -> some View {
        let count = stickers.count
        let isShort = count < Limits.minStickers
        let isExported = exportedKinds.contains(kind)

        return VStack(spacing: 6) {
            if isExported {
                addedLabel("Added \(kind.label.lowercased()) pack")
            } else {
                Button {
                    export(stickers: stickers, kind: kind)
                } label: {
                    Label("Add \(kind.label.lowercased()) pack (\(count))", systemImage: symbol(for: kind))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .tint(.green)
                .disabled(isShort)
                .accessibilityHint(
                    isShort
                        ? "Needs at least \(Limits.minStickers) stickers"
                        : "Adds this pack to WhatsApp"
                )
            }

            if isShort {
                Text("\(kind.label) needs at least \(Limits.minStickers) stickers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func symbol(for kind: StickerKind) -> String {
        kind == .animated ? "play.rectangle" : "photo"
    }

    @MainActor
    private func export(stickers: [StickerItem], kind: StickerKind) {
        do {
            try WhatsAppExporter.export(
                stickers: stickers,
                kind: kind,
                name: pack.name,
                publisher: pack.publisher,
                identifier: identifier(for: kind)
            )
            withAnimation { _ = exportedKinds.insert(kind) }

            // Single-kind packs are done; mixed packs stay open so the other
            // subset can be added too.
            if !pack.isMixed {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    dismiss()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Distinct identifier per subset so WhatsApp doesn't merge them.
    private func identifier(for kind: StickerKind) -> String {
        pack.isMixed ? "\(pack.id.uuidString)-\(kind.rawValue)" : pack.id.uuidString
    }
}

#Preview {
    let stickers = (0..<6).map { _ in
        StickerItem(kind: .static, stickerData: Data(), previewData: Data())
    }
    return ExportSheet(pack: StickerPack(name: "Cats", stickers: stickers))
}
