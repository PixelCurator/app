import SwiftUI
import Photos

// MARK: - Identifiable wrapper for PHAsset (sheet presentation)

/// Thin wrapper that makes `PHAsset` usable with `sheet(item:)`.
private struct IdentifiableAsset: Identifiable {
    let id: String       // PHAsset.localIdentifier
    let asset: PHAsset

    init(_ asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }
}

// MARK: - PhotoGridView

struct PhotoGridView: View {
    var onShowInbox: () -> Void = {}

    @Environment(PhotoController.self) private var library
    @Environment(AlbumManager.self) private var albums
    @Environment(\.embeddingIndexer) private var indexer
    @Environment(\.similaritySearch) private var search
    @Environment(\.activeVariant) private var activeVariant
    @Environment(\.entitlementProvider) private var entitlementProvider
    @Environment(\.switchVariant) private var switchVariant

    @Environment(\.sortingCoordinator) private var sortingCoordinator
    @Environment(\.decisionLog) private var decisionLog
    @Environment(\.isSwitchingVariant) private var isSwitchingVariant

    @State private var selectedAsset: PHAsset?
    @State private var assignAssetItem: IdentifiableAsset?
    @State private var similarAssetItem: IdentifiableAsset?
    @State private var toast: String?
    @State private var showVariantSettings = false
    @State private var showAppSettings = false
    @State private var unsortedCount: Int = 0

    /// Mirrors into `PhotoController.hideICloudPhotos` so the controller can
    /// produce a pre-filtered `visibleAssets` array. The macOS `Settings` scene
    /// reads the same `@AppStorage` key, so toggling it from Cmd-, or from the
    /// iOS sheet both end up flipping the controller's filter.
    @AppStorage("hideICloudPhotos") private var hideICloudPhotos: Bool = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if unsortedCount > 0 {
                    Button {
                        onShowInbox()
                    } label: {
                        HStack {
                            // Icon is interpolated INTO the Text (not a standalone
                            // Image) so it renders no separate accessibility image
                            // element above the grid — otherwise `app.images`
                            // queries would match it instead of a grid thumbnail.
                            Text("\(unsortedCount) photos to sort →")
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.thinMaterial)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox-cta")
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.visibleAssets, id: \.localIdentifier) { asset in
                        ThumbnailCell(asset: asset)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAsset = asset
                                assignAssetItem = IdentifiableAsset(asset)
                            }
                            .contextMenu {
                                Button {
                                    similarAssetItem = IdentifiableAsset(asset)
                                } label: {
                                    Label("Find Similar", systemImage: "sparkle.magnifyingglass")
                                }
                                .accessibilityIdentifier("context-find-similar")
                            }
                    }
                }
                .padding(2)
            }
            .navigationTitle("PixelCurator")
            .toolbar {
                if let indexer, indexer.isIndexing {
                    ToolbarItem(placement: .automatic) {
                        indexingProgressView(indexer: indexer)
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAppSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("toolbar-app-settings")
                }
                #endif
                ToolbarItem(placement: .automatic) {
                    Button {
                        showVariantSettings = true
                    } label: {
                        Label("Quality", systemImage: "cpu")
                    }
                    .accessibilityIdentifier("toolbar-variant-settings")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await decisionLog?.undo()
                            if let name = decisionLog?.lastUndoneAlbumName {
                                await showToast("Removed from \(name)")
                            } else if let error = decisionLog?.lastUndoError {
                                // Surface the failure — otherwise the user
                                // sees nothing and assumes Undo is broken.
                                await showToast(error)
                            }
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!(decisionLog?.canUndo ?? false))
                    .accessibilityIdentifier("toolbar-undo")
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(item: $assignAssetItem) { item in
                AssignSuggestionSheet(
                    asset: item.asset,
                    allAlbums: albums.albums,
                    sortingCoordinator: sortingCoordinator,
                    onAssign: { albumName in
                        selectedAsset = item.asset
                        assign(to: albumName)
                    }
                )
            }
            .sheet(isPresented: $showVariantSettings) {
                VariantSettingsView(
                    currentVariant: activeVariant,
                    entitlements: entitlementProvider,
                    onVariantChange: switchVariant
                )
            }
            #if os(iOS)
            .sheet(isPresented: $showAppSettings) {
                NavigationStack {
                    AppSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showAppSettings = false }
                            }
                        }
                }
            }
            #endif
            .onAppear {
                // Mirror the persisted toggle into the controller so its
                // `visibleAssets` derived value sees the current setting on
                // first render. The `.onChange` below handles subsequent flips.
                library.hideICloudPhotos = hideICloudPhotos
            }
            .onChange(of: hideICloudPhotos) { _, newValue in
                library.hideICloudPhotos = newValue
            }
            .sheet(item: $similarAssetItem) { item in
                if let search {
                    SimilarResultsView(queryAsset: item.asset)
                        .environment(search)
                        .environment(library)
                } else {
                    // Search engine still initialising — show a brief loading state.
                    ProgressView("Loading…")
                        .padding()
                }
            }
            .task(id: library.assets.count) {
                // Kick off background indexing once assets are loaded.
                // The indexer's skip-set makes re-runs idempotent — already-indexed
                // assets are skipped quickly without re-embedding.
                //
                // Gate on `isSwitchingVariant`: during a variant switch the
                // env-injected `indexer` is still the prior instance until
                // `bootIndexer` finishes, so calling `index(assets:)` here
                // would target the about-to-be-discarded indexer, race its
                // trailing `context.save()`, and confuse the new one.
                guard !isSwitchingVariant else { return }
                guard let indexer, !library.assets.isEmpty else { return }
                if !indexer.isIndexing {
                    await indexer.index(assets: library.assets)
                }
                unsortedCount = sortingCoordinator?.unsortedCount() ?? 0
            }
            .task(id: indexer?.isIndexing) {
                // Recompute the sortable count whenever indexing finishes.
                unsortedCount = sortingCoordinator?.unsortedCount() ?? 0
            }
        }
    }

    // MARK: - Indexing progress

    @ViewBuilder
    private func indexingProgressView(indexer: EmbeddingIndexer) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Indexing \(indexer.indexed)/\(indexer.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Album assignment

    private func assign(to albumName: String) {
        guard let asset = selectedAsset else { return }
        Task {
            let result = await albums.assignAndResolve(asset, toAlbumNamed: albumName)
            let ok: Bool
            switch result {
            case .added(let albumID):
                decisionLog?.record(
                    asset: asset,
                    albumName: albumName,
                    albumLocalIdentifier: albumID
                )
                // The photo is now in an album, so it leaves the sortable set —
                // refresh the inbox count/CTA, which otherwise stays stale until
                // the next indexing event.
                unsortedCount = sortingCoordinator?.unsortedCount() ?? 0
                ok = true
            case .alreadyMember:
                // No-op — do not record a phantom undo entry (S-1). Still refresh
                // the inbox count in case the cached state was stale.
                unsortedCount = sortingCoordinator?.unsortedCount() ?? 0
                ok = true
            case .failed:
                ok = false
            }
            await showToast(ok ? "Added to \(albumName)" : (albums.lastError ?? "Failed"))
        }
    }

    @MainActor
    private func showToast(_ message: String) async {
        withAnimation { toast = message }
        try? await Task.sleep(for: .seconds(2))
        withAnimation { toast = nil }
    }
}

// MARK: - Assign Suggestion Sheet

/// A sheet that shows ranked album suggestions (via AlbumSuggester k-NN) for a
/// tapped photo, plus the full album list as a fallback picker.
private struct AssignSuggestionSheet: View {
    let asset: PHAsset
    let allAlbums: [AlbumManager.Album]
    let sortingCoordinator: SortingCoordinator?
    let onAssign: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [AlbumSuggestion] = []

    var body: some View {
        NavigationStack {
            List {
                // --- Suggestions section ---
                if !suggestions.isEmpty {
                    Section("Top Suggestions") {
                        ForEach(suggestions.prefix(5)) { suggestion in
                            Button {
                                onAssign(suggestion.albumTitle)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.albumTitle)
                                            .foregroundStyle(.primary)
                                        Text("\(suggestion.supportingCount) matches")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(Int((suggestion.score * 100).rounded()))%")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Section {
                        Text("No suggestions yet — indexing may still be running")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // --- All albums section ---
                if !allAlbums.isEmpty {
                    Section("All Albums") {
                        ForEach(allAlbums) { album in
                            Button {
                                onAssign(album.title)
                                dismiss()
                            } label: {
                                Text(album.title)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add to album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityIdentifier("assign-suggestion-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                suggestions = sortingCoordinator?.suggestions(for: asset) ?? []
            }
        }
    }
}

// MARK: - Thumbnail Cell

/// Loads its thumbnail lazily when it scrolls on screen.
private struct ThumbnailCell: View {
    @Environment(PhotoController.self) private var library
    let asset: PHAsset

    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.gray.opacity(0.15))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topTrailing) {
                // Subtle iCloud affordance — only present for iCloud-only
                // assets. Lookup is O(1) against the controller's cached
                // `cloudOnlyAssetIDs` so this stays cheap on a large grid.
                if library.isCloudOnly(asset) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(4)
                        .accessibilityLabel("iCloud only")
                        .accessibilityIdentifier("cell-icloud-badge")
                }
            }
            .task(id: asset.localIdentifier) {
                let scale = 2.0
                let target = CGSize(width: geo.size.width * scale,
                                    height: geo.size.height * scale)
                image = await library.thumbnail(for: asset, size: target)
            }
        }
    }
}
