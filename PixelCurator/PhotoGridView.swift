import SwiftUI
import Photos

struct PhotoGridView: View {
    @Environment(PhotoController.self) private var library
    @Environment(AlbumManager.self) private var albums

    @State private var selectedAsset: PHAsset?
    @State private var showAssignDialog = false
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
                    }
                }
                .padding(2)
            }
            .navigationTitle("PixelCurator")
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
        }
    }

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
