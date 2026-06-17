import SwiftUI
import Photos

// MARK: - AlbumsListView

/// Presents the user's Photos.app albums as a navigable list.
/// Tapping an album pushes `AlbumDetailView` via `NavigationStack` destination routing.
struct AlbumsListView: View {
    @Environment(AlbumManager.self) private var albumManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if albumManager.albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums Yet",
                        systemImage: "rectangle.stack",
                        description: Text("Albums you create in Photos will appear here.")
                    )
                } else {
                    List(albumManager.albums) { album in
                        NavigationLink(value: album) {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Text("\(album.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Albums")
            .accessibilityIdentifier("albums-list")
            .navigationDestination(for: AlbumManager.Album.self) { album in
                AlbumDetailView(album: album)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                albumManager.loadAlbums()
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

    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var showingPhotoDialog = false
    @State private var showingMoveDialog = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    var body: some View {
        ScrollView {
            if assets.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle",
                    description: Text("This album has no photos.")
                )
                .padding(.top, 60)
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
                    }
                }
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
                        Task {
                            _ = await albumManager.assign(asset, toAlbumNamed: target.title)
                            _ = await albumManager.remove(asset, fromAlbumNamed: album.title)
                            await loadAssets()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Helpers

    @MainActor
    private func loadAssets() async {
        let ids = albumManager.memberAssetIDs(of: album.id)
        guard !ids.isEmpty else {
            assets = []
            return
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        // Preserve the order returned by memberAssetIDs (album order).
        let fetched: [String: PHAsset] = {
            var map: [String: PHAsset] = [:]
            result.enumerateObjects { asset, _, _ in
                map[asset.localIdentifier] = asset
            }
            return map
        }()
        assets = ids.compactMap { fetched[$0] }
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
                } else {
                    Rectangle().fill(.gray.opacity(0.15))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
