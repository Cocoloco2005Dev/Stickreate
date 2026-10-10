import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pack library. Content layer — cards stay opaque and Liquid Glass lives in the
/// navigation bar plus the single primary action of the empty state.
struct LibraryView: View {
    /// Shared with `RootView` so incoming media and the library see one store.
    @State private var store = PackStore.shared
    @State private var settings = SettingsStore.shared
    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var folderFilter: FolderFilter = .all
    @State private var showingImporter = false
    @State private var importedMedia: ImportedMedia?
    /// Sources waiting for the destination-pack sheet, so a multi-item drop is
    /// offered one at a time instead of silently dropping the extras.
    @State private var mediaQueue: [StickerSource] = []
    /// Total sticker count when the current import sheet was presented, used to
    /// tell whether the sheet actually added the media.
    @State private var presentedStickerBaseline = 0
    @State private var isImportingMedia = false
    @State private var showingImportedBanner = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeAlert: ActiveAlert?
    @State private var renameName = ""
    @State private var folderTarget: StickerPack?
    @State private var exportTarget: StickerPack?
    @State private var shareItem: ShareItem?

    @State private var successPulse = 0
    @State private var errorPulse = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Space.lg)]

    /// Wrapper so `.sheet(item:)` can present a media source chosen from Files.
    private struct ImportedMedia: Identifiable {
        let id = UUID()
        let source: StickerSource
    }

    /// One alert channel so manage actions and errors never fight, and always
    /// anchor to the screen.
    private enum ActiveAlert {
        case importFailed(String)
        case error(String)
        case rename(StickerPack)
        case deletePack(StickerPack)
    }

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private enum FolderFilter: Hashable {
        case all
        case noFolder
        case folder(String)
    }

    private struct FolderGroup: Identifiable {
        let title: String
        let packs: [StickerPack]
        var id: String { title }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if !settings.hasSeenOnboarding {
                    onboardingCard
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.top, DS.Space.sm)
                        .padding(.bottom, DS.Space.xs)
                }

                if showingImportedBanner {
                    StatusBanner(title: "Pack imported")
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.top, DS.Space.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                mainContent
            }
            .animation(reduceMotion ? nil : DS.Motion.standard, value: showingImportedBanner)
            .stickerDrop { sources in
                enqueueMedia(sources)
            } onError: { message in
                presentError(message, as: .importFailed)
            }
            .navigationTitle("Sticker Packs")
            .navigationDestination(for: UUID.self) { id in
                PackEditorView(store: store, packID: id)
            }
            .searchable(text: $searchText, prompt: "Search packs")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.image, .movie, .gif, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .sheet(item: $importedMedia, onDismiss: mediaSheetDismissed) { media in
                ImportMediaSheet(source: media.source, store: store) {
                    importedMedia = nil
                }
            }
            .sheet(item: $folderTarget) { pack in
                FolderPickerSheet(currentFolder: pack.folder, folders: store.folders) { folder in
                    store.setFolder(folder, for: pack.id)
                }
            }
            .sheet(item: $exportTarget) { pack in
                ExportSheet(store: store, packID: pack.id)
            }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url) { shareItem = nil }
            }
            .alert(alertTitle, isPresented: alertIsPresented) {
                alertActions
            } message: {
                alertMessage
            }
            .haptic(.success, trigger: successPulse)
            .haptic(.error, trigger: errorPulse)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if isImportingMedia {
            LoadingState(title: "Importing…")
        } else if store.packs.isEmpty {
            emptyState
        } else if filteredPacks.isEmpty {
            noResultsState
        } else {
            grid
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Label("Welcome to Stickreate", systemImage: "sparkles")
                    .font(DS.TextRole.cardTitle)

                Spacer(minLength: DS.Space.sm)

                Button("Got it") {
                    settings.hasSeenOnboarding = true
                }
                .font(DS.TextRole.supporting.weight(.semibold))
                .accessibilityLabel("Dismiss the welcome card")
            }

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                onboardingStep(1, "Create a pack")
                onboardingStep(2, "Add and edit stickers")
                onboardingStep(3, "Add to WhatsApp")
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DS.ColorRole.contentSurface,
            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func onboardingStep(_ number: Int, _ title: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text("\(number)")
                .font(DS.TextRole.badge)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(DS.ColorRole.accent, in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(DS.TextRole.supporting)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Two clear actions: filter the grid, and add. The imports live under
        // Add so the bar never shows three near-identical icons.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Folder", selection: $folderFilter) {
                    Text("All Folders").tag(FolderFilter.all)
                    Text("No Folder").tag(FolderFilter.noFolder)
                    ForEach(store.folders, id: \.self) { folder in
                        Text(folder).tag(FolderFilter.folder(folder))
                    }
                }
            } label: {
                Label("Filter by folder", systemImage: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filter by folder")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New Pack", systemImage: "plus") {
                    createPack()
                }

                Divider()

                // One entry: accepts photos, videos, GIFs, and `.stickreatepack`
                // files, and routes to the right import below.
                Button("Import…", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityLabel("Add packs or media")
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        EmptyState(
            symbol: "square.grid.2x2",
            title: "No Sticker Packs",
            message: "Packs group your stickers for WhatsApp. Create one, add photos or videos, then export."
        ) {
            Button("New Pack", systemImage: "plus") {
                createPack()
            }
            .buttonStyle(.glassProminent)

            Button("Import…", systemImage: "square.and.arrow.down") {
                showingImporter = true
            }
        }
    }

    @ViewBuilder
    private var noResultsState: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if folderFilter == .all {
            EmptyState(
                symbol: "folder",
                title: "No Packs Here",
                message: "Create a pack to get started."
            )
        } else {
            EmptyState(
                symbol: "folder",
                title: "No Packs Here",
                message: "No packs match this folder filter."
            ) {
                Button("Show All Packs") {
                    folderFilter = .all
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                librarySummary

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        HStack(spacing: DS.Space.sm) {
                            Text(group.title)
                                .font(DS.TextRole.section)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            Text("\(group.packs.count)")
                                .font(DS.TextRole.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(group.title), \(group.packs.count) packs")

                        LazyVGrid(columns: columns, spacing: DS.Space.lg) {
                            ForEach(group.packs) { pack in
                                NavigationLink(value: pack.id) {
                                    PackCard(pack: pack)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    packMenu(for: pack)
                                }
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.lg)
        }
    }

    /// Compact library totals, so the top of the grid carries real counts
    /// instead of starting straight into the folder sections.
    private var librarySummary: some View {
        let packCount = store.packs.count
        let stickerCount = store.packs.reduce(0) { $0 + $1.stickers.count }
        return HStack(spacing: DS.Space.xs) {
            Text("\(packCount) \(packCount == 1 ? "pack" : "packs")")
            Text("·")
            Text("\(stickerCount) \(stickerCount == 1 ? "sticker" : "stickers")")
            Spacer(minLength: 0)
        }
        .font(DS.TextRole.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(packCount) packs, \(stickerCount) stickers")
    }

    private var filteredPacks: [StickerPack] {
        var result = store.packs

        switch folderFilter {
        case .all:
            break
        case .noFolder:
            result = result.filter { $0.folder == nil }
        case .folder(let name):
            result = result.filter { $0.folder == name }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        return result
    }

    private var groups: [FolderGroup] {
        let grouped = Dictionary(grouping: filteredPacks) { $0.folder ?? "" }
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return orderedKeys.map { key in
            FolderGroup(title: key.isEmpty ? "No Folder" : key, packs: grouped[key] ?? [])
        }
    }

    // MARK: - Manage from the library

    @ViewBuilder
    private func packMenu(for pack: StickerPack) -> some View {
        Button("Rename…", systemImage: "pencil") {
            renameName = pack.name
            activeAlert = .rename(pack)
        }

        Button("Folder…", systemImage: "folder") {
            folderTarget = pack
        }

        // Primary: WhatsApp sticker import (opens WhatsApp's pack preview).
        // Secondary: a `.stickreatepack` data file for backup/transfer.
        Button("Add to WhatsApp…", systemImage: "plus.message") {
            exportTarget = pack
        }
        .disabled(!canExport(pack))
        .accessibilityHint(canExport(pack) ? "Opens the WhatsApp sticker import" : exportReason(pack))

        if !canExport(pack) {
            Button(exportReason(pack), systemImage: "info.circle") {}
                .disabled(true)
        }

        Button("Export Pack File…", systemImage: "square.and.arrow.up") {
            exportFile(pack)
        }

        Divider()

        Button("Delete…", systemImage: "trash", role: .destructive) {
            activeAlert = .deletePack(pack)
        }
    }

    private func canExport(_ pack: StickerPack) -> Bool {
        // Mixed packs have no single kind WhatsApp can import.
        !pack.isMixed && pack.stickers.count >= Limits.minStickers
    }

    /// Why the WhatsApp import is unavailable, shown in the pack menu.
    private func exportReason(_ pack: StickerPack) -> String {
        if pack.isMixed {
            return "This pack mixes photos and videos."
        }
        let needed = max(0, Limits.minStickers - pack.stickers.count)
        return needed == 1 ? "Add 1 more sticker." : "Add \(needed) more stickers."
    }

    /// Writes a `.stickreatepack` and opens the share sheet. This is the data
    /// backup/transfer path; the WhatsApp import is the primary action.
    private func exportFile(_ pack: StickerPack) {
        Task { @MainActor in
            do {
                // ZIP build + disk write off the main actor.
                let url = try await Task.detached(priority: .userInitiated) {
                    try PackArchive.writeTemporaryFile(pack)
                }.value
                shareItem = ShareItem(url: url)
            } catch {
                presentError(error.localizedDescription, as: .general)
            }
        }
    }

    // MARK: - Alert

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { activeAlert = nil } }
        )
    }

    private var alertTitle: String {
        switch activeAlert {
        case .importFailed: "Import failed"
        case .error: "Something went wrong"
        case .rename: "Rename Pack"
        case .deletePack: "Delete this pack?"
        case nil: ""
        }
    }

    @ViewBuilder
    private var alertActions: some View {
        switch activeAlert {
        case .importFailed, .error:
            Button("OK", role: .cancel) {}
        case .rename:
            TextField("Pack name", text: $renameName)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) {}
        case .deletePack(let pack):
            Button("Delete Pack", role: .destructive) {
                store.removePack(pack.id)
            }
            Button("Cancel", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var alertMessage: some View {
        switch activeAlert {
        case .importFailed(let message), .error(let message):
            Text(message)
        case .rename:
            Text("Give this pack a name.")
        case .deletePack:
            Text("This removes the pack and all its stickers. You can't undo this.")
        case nil:
            EmptyView()
        }
    }

    private func saveRename() {
        guard case .rename(let pack) = activeAlert else { return }
        let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.rename(pack.id, to: trimmed)
    }

    /// Single funnel for error alerts so the error haptic always fires with it.
    private func presentError(_ message: String, as kind: ErrorChannel) {
        switch kind {
        case .importFailed: activeAlert = .importFailed(message)
        case .general: activeAlert = .error(message)
        }
        errorPulse += 1
    }

    private enum ErrorChannel {
        case importFailed
        case general
    }

    // MARK: - Actions

    private func createPack() {
        let pack = store.createPack()
        path.append(pack.id)
    }

    /// Single import entry: a `.stickreatepack` file restores a pack; any other
    /// pick (photo, video, GIF) is imported as media and offered a destination
    /// pack through `ImportMediaSheet`.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            if ext == PackArchive.fileExtension || ext == "stickreatepack" {
                importPackFile(url)
            } else {
                Task { await importMediaFile(url) }
            }
        case .failure(let error):
            presentError(error.localizedDescription, as: .importFailed)
        }
    }

    private func importPackFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                // Whole-archive read + unzip off the main actor; only the UI
                // state update re-enters it.
                let pack = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url)
                    return try PackArchive.importPack(from: data)
                }.value
                if store.importPack(pack) {
                    settings.refreshStorageSummary()
                    showImportedBanner()
                } else {
                    presentError(
                        "This pack couldn't be imported: it's empty, too large, or mixes sticker types.",
                        as: .importFailed
                    )
                }
            } catch {
                presentError(error.localizedDescription, as: .importFailed)
            }
        }
    }

    /// Files import path: reliable when the OS share/open-in doesn't route into the
    /// app (e.g. LiveContainer). Imports the file, then offers the destination
    /// picker via `ImportMediaSheet`.
    @MainActor
    private func importMediaFile(_ url: URL) async {
        isImportingMedia = true
        defer { isImportingMedia = false }

        do {
            let source = try await StickerSourceStore.importFile(at: url)
            enqueueMedia([source])
        } catch {
            presentError(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                as: .importFailed
            )
        }
    }

    /// A drop (or File) imports one or more sources, then offers each a
    /// destination pack through `ImportMediaSheet`, one at a time.
    private func enqueueMedia(_ sources: [StickerSource]) {
        mediaQueue.append(contentsOf: sources)
        advanceMediaQueue()
    }

    /// Presents the next queued source if no import sheet is already showing.
    private func advanceMediaQueue() {
        guard importedMedia == nil, let next = mediaQueue.first else { return }
        presentedStickerBaseline = stickerCount
        importedMedia = ImportedMedia(source: next)
    }

    /// Drops the source whose sheet just closed. If no sticker was added, the
    /// imported (already-copied) source is deleted rather than left orphaned,
    /// then the next queued source is offered.
    private func mediaSheetDismissed() {
        if let dismissed = mediaQueue.first, stickerCount == presentedStickerBaseline {
            StickerSourceStore.delete(dismissed)
        }
        if !mediaQueue.isEmpty { mediaQueue.removeFirst() }
        advanceMediaQueue()
    }

    /// Total stickers across every pack; a delta tells whether an import added one.
    private var stickerCount: Int {
        store.packs.reduce(0) { $0 + $1.stickers.count }
    }

    /// Transient, non-blocking confirmation that a pack file landed.
    private func showImportedBanner() {
        successPulse += 1
        showingImportedBanner = true
        Task {
            try? await Task.sleep(for: DS.Motion.confirmationHold)
            showingImportedBanner = false
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    LibraryView()
}

#Preview("Dark") {
    LibraryView()
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    LibraryView()
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    LibraryView()
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    LibraryView()
        .frame(width: 430, height: 932)
}

