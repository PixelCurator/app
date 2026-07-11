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

    /// F-09. Stores the typed query outcome so the empty-state branch can
    /// pick precise copy. `nil` means "no query has completed yet"
    /// (search may or may not be in flight).
    @State private var result: SimilarSearchResult?

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 2)]

    /// Convenience for the result-grid branch — true iff a query has
    /// returned (any case). Animations key off this so the loading→empty
    /// transition still fades.
    private var hasSearched: Bool { result != nil }

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
                result = await search.similarAssets(to: queryAsset.localIdentifier)
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
        } else if let result {
            switch result {
            case .results(let assets):
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        SimilarThumbnailCell(asset: asset)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                    }
                }
                .padding(2)
                .transition(.opacity)
            case .notAvailable:
                notAvailableState.transition(.opacity)
            case .notIndexedYet:
                notIndexedYetState.transition(.opacity)
            case .empty:
                emptyState.transition(.opacity)
            }
        }
    }

    /// F-09. iCloud-only (or otherwise pixel-unavailable) query asset.
    /// Distinct from `.empty` and `.notIndexedYet` because the user has a
    /// concrete remediation: pull the original onto the device via
    /// Photos.app.
    private var notAvailableState: some View {
        ContentUnavailableView(
            "Photo not available on device",
            systemImage: "icloud.slash",
            description: Text("Open this photo in Photos.app to download the original from iCloud, then try again.")
        )
        .accessibilityIdentifier("similar-results-not-available")
    }

    /// F-09. Query asset hasn't been indexed yet and the on-the-fly embed
    /// path also didn't produce a vector — indexing is most likely still
    /// running. Same copy as the pre-F-09 generic empty state, narrowed
    /// to the case where it's actually correct.
    private var notIndexedYetState: some View {
        ContentUnavailableView(
            "No Similar Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Indexing may still be running. Try again once the progress indicator disappears.")
        )
        .accessibilityIdentifier("similar-results-not-indexed-yet")
    }

    /// F-09. Index is complete and was searched — the library genuinely
    /// has no other photos to compare against (or no other matches
    /// survived ranking). Hides the misleading "still indexing" hint.
    private var emptyState: some View {
        ContentUnavailableView(
            "No Similar Photos",
            systemImage: "photo.on.rectangle.angled",
            description: Text("No similar photos in this library.")
        )
        .accessibilityIdentifier("similar-results-empty")
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
