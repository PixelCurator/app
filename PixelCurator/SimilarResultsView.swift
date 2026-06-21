import SwiftUI
import Photos

/// Displays the query photo at the top and a grid of visually similar results
/// below. Presented as a sheet from `PhotoGridView` when the user taps
/// "Find Similar" on a photo.
struct SimilarResultsView: View {

    // MARK: - Dependencies

    @Environment(SimilaritySearch.self) private var search
    @Environment(PhotoController.self) private var library

    // MARK: - Input

    /// The asset the user tapped "Find Similar" on.
    let queryAsset: PHAsset

    // MARK: - State

    @Environment(\.dismiss) private var dismiss

    @State private var results: [PHAsset] = []
    @State private var hasSearched = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    queryHeader
                    resultGrid
                }
                .animation(.easeInOut(duration: 0.3), value: search.isSearching)
                .animation(.easeInOut(duration: 0.3), value: hasSearched)
            }
            .navigationTitle("Similar Photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityIdentifier("similar-results-view")
            .toolbar {
                // HIG: sheets need an explicit dismiss affordance. Swipe-down
                // works on iOS but not for keyboard / Switch Control users,
                // and macOS sheets have no swipe gesture at all.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                results = await search.similarAssets(to: queryAsset.localIdentifier)
                hasSearched = true
            }
        }
    }

    // MARK: - Subviews

    /// Hero thumbnail of the photo the user searched from.
    private var queryHeader: some View {
        SimilarThumbnailCell(asset: queryAsset)
            .aspectRatio(1, contentMode: .fill)
            .frame(maxWidth: 200, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding()
            .overlay(alignment: .bottom) {
                Text("Query photo")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .accessibilityLabel(Text("Query photo — searching for visually similar photos"))
    }

    /// Grid of similar results — or appropriate empty/loading state.
    @ViewBuilder
    private var resultGrid: some View {
        if search.isSearching {
            ProgressView("Finding similar photos…")
                .controlSize(.large)
                .padding(.top, 40)
                .transition(.opacity)
        } else if hasSearched && results.isEmpty {
            emptyState
                .transition(.opacity)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(results, id: \.localIdentifier) { asset in
                    SimilarThumbnailCell(asset: asset)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .contentShape(Rectangle())
                }
            }
            .padding(2)
            .transition(.opacity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Similar Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Indexing may still be running. Try again once the progress indicator disappears.")
        )
    }
}

// MARK: - Thumbnail Cell

/// Lightweight thumbnail cell for `SimilarResultsView`. Mirrors the pattern
/// used by `ThumbnailCell` in `PhotoGridView` — lazy load on appearance via
/// `.task(id:)`.
private struct SimilarThumbnailCell: View {
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
