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
    @State private var showingMediaImporter = false
    @State private var importedMedia: ImportedMedia?
    @State private var isImportingMedia = false

    @State private var activeAlert: ActiveAlert?
    @State private var renameName = ""
    @State private var folderTarget: StickerPack?
    @State private var exportTarget: StickerPack?
    @State private var shareItem: ShareItem?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

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
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }

                mainContent
            }
            .navigationTitle("Sticker Packs")
            .navigationDestination(for: UUID.self) { id in
                PackEditorView(store: store, packID: id)
            }
            .searchable(text: $searchText, prompt: "Search packs")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .fileImporter(
                isPresented: $showingMediaImporter,
                allowedContentTypes: [.image, .movie, .gif],
                allowsMultipleSelection: false
            ) { result in
                handleMediaImport(result)
            }
            .sheet(item: $importedMedia) { media in
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
                ExportSheet(pack: pack)
            }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url) { shareItem = nil }
            }
            .overlay {
                if isImportingMedia {
                    ProgressView("Importing…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .alert(alertTitle, isPresented: alertIsPresented) {
                alertActions
            } message: {
                alertMessage
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.packs.isEmpty {
            emptyState
        } else if filteredPacks.isEmpty {
            noResultsState
        } else {
            grid
        }
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Welcome to Stickreate", systemImage: "sparkles")
                    .font(.headline)

                Spacer(minLength: 8)

                Button("Got it") {
                    settings.hasSeenOnboarding = true
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("Dismiss the welcome card")
            }

            VStack(alignment: .leading, spacing: 8) {
                onboardingStep(1, "Create a pack")
                onboardingStep(2, "Add and edit stickers")
                onboardingStep(3, "Add to WhatsApp")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func onboardingStep(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
            Button {
                showingMediaImporter = true
            } label: {
                Label("Import from Files", systemImage: "folder.badge.plus")
            }
            .accessibilityLabel("Import photos or videos from Files")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingImporter = true
            } label: {
                Label("Import Pack", systemImage: "square.and.arrow.down")
            }
            .accessibilityLabel("Import sticker pack")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                createPack()
            } label: {
                Label("New Pack", systemImage: "plus")
            }
            .accessibilityLabel("New sticker pack")
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sticker Packs", systemImage: "square.grid.2x2")
        } description: {
            Text("Packs group your stickers for WhatsApp. Create one, add photos or videos, then export.")
        } actions: {
            Button("New Pack", systemImage: "plus") {
                createPack()
            }
            .buttonStyle(.glassProminent)

            Button("Import from Files", systemImage: "folder.badge.plus") {
                showingMediaImporter = true
            }

            Button("Import a Pack", systemImage: "square.and.arrow.down") {
                showingImporter = true
            }
        }
    }

    @ViewBuilder
    private var noResultsState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("No Packs Here", systemImage: "folder")
            } description: {
                Text("No packs match this folder filter.")
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: columns, spacing: 16) {
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
            .padding(16)
        }
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

        Button("Share Pack…", systemImage: "square.and.arrow.up") {
            share(pack)
        }

        Button(exportMenuTitle, systemImage: exportMenuSymbol) {
            exportTarget = pack
        }
        .disabled(!canExport(pack))

        Divider()

        Button("Delete…", systemImage: "trash", role: .destructive) {
            activeAlert = .deletePack(pack)
        }
    }

    private func canExport(_ pack: StickerPack) -> Bool {
        if pack.isMixed {
            return pack.staticStickers.count >= Limits.minStickers
                || pack.animatedStickers.count >= Limits.minStickers
        }
        return pack.stickers.count >= Limits.minStickers
    }

    private var exportMenuTitle: String {
        settings.exportMode == .file ? "Export Pack…" : "Add to WhatsApp…"
    }

    private var exportMenuSymbol: String {
        settings.exportMode == .file ? "square.and.arrow.up" : "plus.message"
    }

    private func share(_ pack: StickerPack) {
        do {
            let url = try PackArchive.writeTemporaryFile(pack)
            shareItem = ShareItem(url: url)
        } catch {
            activeAlert = .error(error.localizedDescription)
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

    // MARK: - Actions

    private func createPack() {
        let pack = store.createPack()
        path.append(pack.id)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let pack = try PackArchive.importPack(from: data)
                store.importPack(pack)
            } catch {
                activeAlert = .importFailed(error.localizedDescription)
            }

        case .failure(let error):
            activeAlert = .importFailed(error.localizedDescription)
        }
    }

    /// Files import path: reliable when the OS share/open-in doesn't route into the
    /// app (e.g. LiveContainer). Imports the file, then offers the destination
    /// picker via `ImportMediaSheet`.
    private func handleMediaImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importMediaFile(url) }
        case .failure(let error):
            activeAlert = .importFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func importMediaFile(_ url: URL) async {
        isImportingMedia = true
        defer { isImportingMedia = false }

        do {
            let source = try await StickerSourceStore.importFile(at: url)
            importedMedia = ImportedMedia(source: source)
        } catch {
            activeAlert = .importFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

#Preview {
    LibraryView()
}
