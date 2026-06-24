import SwiftUI
import Photos

// MARK: - AlbumsListView

/// Presents the user's Photos.app albums as a navigable list.
/// Tapping an album pushes `AlbumDetailView` via `NavigationStack` destination routing.
struct AlbumsListView: View {
    @Environment(AlbumManager.self) private var albumManager

    /// Distinguishes "still loading" from "actually empty" so the
    /// ContentUnavailableView only appears once we've confirmed there
    /// genuinely are no albums. Without this state the empty-library copy
    /// flashes for a frame before the real list resolves — HIG-distracting.
    @State private var didLoadOnce = false

    var body: some View {
        NavigationStack {
            Group {
                if albumManager.albums.isEmpty {
                    if didLoadOnce {
                        ContentUnavailableView(
                            "No Albums Yet",
                            systemImage: "rectangle.stack",
                            description: Text("Albums you create in Photos will appear here.")
                        )
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityValue(Text("Loading albums"))
                    }
                } else {
                    List(albumManager.albums) { album in
                        NavigationLink(value: album) {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Text("\(album.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .accessibilityLabel(Text("\(album.count) photos"))
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityHint(Text("Opens album to view and manage photos"))
                    }
                    #if os(macOS)
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    #endif
                    .refreshable {
                        albumManager.loadAlbums()
                    }
                }
            }
            .animation(.smooth(duration: 0.35, extraBounce: 0.05), value: albumManager.albums.isEmpty)
            .animation(.smooth(duration: 0.35, extraBounce: 0.05), value: didLoadOnce)
            .navigationTitle("Albums")
            .accessibilityIdentifier("albums-list")
            .navigationDestination(for: AlbumManager.Album.self) { album in
                AlbumDetailView(album: album)
            }
            .task {
                albumManager.loadAlbums()
                didLoadOnce = true
            }
        }
    }
}

// MARK: - AlbumDetailView

/// Shows all photos in a single album as a grid, with per-photo actions
/// (Remove from album, Move to another album).
struct AlbumDetailView: View {
    let album: AlbumManager.Album

    @Environment(AlbumManager.self) private var albumManager
    @Environment(PhotoController.self) private var library
    @Environment(\.decisionLog) private var decisionLog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var showingPhotoDialog = false
    @State private var showingMoveDialog = false
    @State private var toast: String?
    /// Same loading-vs-empty distinction as `AlbumsListView` — without it the
    /// "No Photos" copy flashes for one frame on tap before the real grid
    /// resolves.
    @State private var didLoadOnce = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    var body: some View {
        ScrollView {
            if assets.isEmpty {
                if didLoadOnce {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.on.rectangle",
                        description: Text("This album has no photos.")
                    )
                    .padding(.top, 60)
                } else {
                    ProgressView("Loading photos…")
                        .controlSize(.regular)
                        .padding(.top, 120)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        AlbumThumbnailCell(asset: asset)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAsset = asset
                                showingPhotoDialog = true
                            }
                            .accessibilityLabel(photoAccessibilityLabel(for: asset))
                            .accessibilityHint(Text("Double-tap to remove or move this photo"))
                    }
                }
                .animation(.smooth(duration: 0.35, extraBounce: 0.05), value: assets.count)
                #if os(iOS)
                .sensoryFeedback(.impact(weight: .light), trigger: showingPhotoDialog)
                #endif
                .padding(2)
            }
        }
        .navigationTitle(album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("album-detail")
        .task(id: album.id) {
            await loadAssets()
        }
        // Primary action dialog: Remove or Move
        .confirmationDialog(album.title, isPresented: $showingPhotoDialog, titleVisibility: .visible) {
            if let asset = selectedAsset {
                Button("Remove from \"\(album.title)\"", role: .destructive) {
                    Task {
                        _ = await albumManager.remove(asset, fromAlbumNamed: album.title)
                        await loadAssets()
                    }
                }
                Button("Move to another album…") {
                    showingMoveDialog = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Secondary dialog: pick the target album
        .confirmationDialog("Move to Album", isPresented: $showingMoveDialog, titleVisibility: .visible) {
            if let asset = selectedAsset {
                ForEach(albumManager.albums.filter { $0.id != album.id }) { target in
                    Button(target.title) {
                        Task { await move(asset, from: album, to: target) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let toast {
                toastBanner(toast)
            }
        }
    }

    // MARK: - Move flow

    /// Moves `asset` from `source` to `target` via the pure `AlbumMover`,
    /// then maps the `MoveOutcome` to a toast and triggers a reload.
    ///
    /// The orchestration logic lives in `AlbumMover` (tested without PhotoKit
    /// via `MoveFlowTests`); this method just renders the result and refreshes
    /// the visible asset list.
    @MainActor
    private func move(
        _ asset: PHAsset,
        from source: AlbumManager.Album,
        to target: AlbumManager.Album
    ) async {
        let outcome = await AlbumMover.move(
            asset,
            from: (id: source.id, title: source.title),
            to: (id: target.id, title: target.title),
            via: albumManager
        )

        switch outcome {
        case .moved(_, let targetTitle):
            // F-15: record the move on the shared DecisionLog so the user
            // has an Undo affordance symmetric with accept / assignTo /
            // batchAssign. Only the `.moved` case records — failure and
            // rollback outcomes leave the library unchanged, so recording
            // them would mis-report the next undo. The MoveDecision carries
            // both album ids so its undo can route through the
            // duplicate-name-safe by-id `AlbumOperations` surface.
            decisionLog?.recordMove(
                asset: asset,
                sourceAlbumID: source.id,
                sourceAlbumName: source.title,
                targetAlbumID: target.id,
                targetAlbumName: target.title
            )
            await showToast("Moved to \(targetTitle)")
        case .assignFailed(let targetTitle, _):
            await showToast(albumManager.lastError ?? "Move failed — could not add to \(targetTitle).")
        case .removeFailedRolledBack(let sourceTitle, _):
            await showToast("Move failed — asset kept in \(sourceTitle).")
        case .orphanInBothAlbums:
            await showToast("Move partially failed — please review in Photos.app.")
        }
        await loadAssets()
    }

    @MainActor
    private func showToast(_ message: String) async {
        let animation: Animation? = reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75)
        withAnimation(animation) { toast = message }
        VoiceOver.announce(message)
        try? await Task.sleep(for: .seconds(2.5))
        withAnimation(animation) { toast = nil }
    }

    @ViewBuilder
    private func toastBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Helpers

    @MainActor
    private func loadAssets() async {
        defer { didLoadOnce = true }
        let albumID = album.id
        // Run the PhotoKit fetches off the main actor. Large albums (thousands
        // of assets) make `PHAssetCollection.fetchAssetCollections` +
        // `PHAsset.fetchAssets(in:)` cost enough to be felt as a multi-second
        // freeze when the user enters an album detail view. The fetch results
        // themselves are thread-safe to enumerate; only the resulting
        // `[PHAsset]` is hopped back to the main actor for state assignment.
        let resolved: [PHAsset] = await Task.detached { () -> [PHAsset] in
            // Resolve the collection on this background task to avoid
            // touching `albumManager` from off-main.
            let collectionResult = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            )
            guard let collection = collectionResult.firstObject else { return [] }
            var ids: [String] = []
            let memberFetch = PHAsset.fetchAssets(in: collection, options: nil)
            memberFetch.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            guard !ids.isEmpty else { return [] }
            let assetFetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var map: [String: PHAsset] = [:]
            assetFetch.enumerateObjects { asset, _, _ in
                map[asset.localIdentifier] = asset
            }
            // Preserve album order from the membership fetch.
            return ids.compactMap { map[$0] }
        }.value
        assets = resolved
    }
}

// MARK: - AlbumThumbnailCell

/// Lazy-loading thumbnail cell for `AlbumDetailView`.
/// Mirrors the pattern from `ThumbnailCell` in `PhotoGridView`.
private struct AlbumThumbnailCell: View {
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
                        .transition(.opacity)
                } else {
                    Rectangle().fill(.gray.opacity(0.15))
                        .shimmer(isAnimating: true)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.2), value: image != nil)
            .task(id: asset.localIdentifier) {
                let scale = 2.0
                let target = CGSize(
                    width: geo.size.width * scale,
                    height: geo.size.height * scale
                )
                image = await library.thumbnail(for: asset, size: target)
            }
        }
    }
}
