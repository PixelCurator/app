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
    @Environment(PhotoController.self) private var library
    @Environment(AlbumManager.self) private var albums
    @Environment(\.embeddingIndexer) private var indexer
    @Environment(\.similaritySearch) private var search

    @State private var selectedAsset: PHAsset?
    @State private var showAssignDialog = false
    @State private var similarAssetItem: IdentifiableAsset?
    @State private var toast: String?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.assets, id: \.localIdentifier) { asset in
                        ThumbnailCell(asset: asset)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAsset = asset
                                showAssignDialog = true
                            }
                            .contextMenu {
                                Button {
                                    similarAssetItem = IdentifiableAsset(asset)
                                } label: {
                                    Label("Find Similar", systemImage: "sparkle.magnifyingglass")
                                }
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
            .confirmationDialog(
                "Add to album",
                isPresented: $showAssignDialog,
                titleVisibility: .visible
            ) {
                // A few existing albums as quick targets…
                ForEach(albums.albums.prefix(8)) { album in
                    Button(album.title) { assign(to: album.title) }
                }
                // …plus a default PixelCurator bucket to prove create-on-demand.
                Button("➕ PixelCurator") { assign(to: "PixelCurator") }
                Button("Cancel", role: .cancel) {}
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
                guard let indexer, !library.assets.isEmpty else { return }
                if !indexer.isIndexing {
                    await indexer.index(assets: library.assets)
                }
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
            let ok = await albums.assign(asset, toAlbumNamed: albumName)
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
            .task(id: asset.localIdentifier) {
                let scale = 2.0
                let target = CGSize(width: geo.size.width * scale,
                                    height: geo.size.height * scale)
                image = await library.thumbnail(for: asset, size: target)
            }
        }
    }
}
