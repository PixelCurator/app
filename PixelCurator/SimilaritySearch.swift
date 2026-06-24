@preconcurrency import Photos
import SwiftData
import SwiftUI

// MARK: - Result type

/// F-09. Typed outcome of a similarity query so the view can render a
/// disambiguated empty state instead of the generic
/// "Indexing may still be running" message.
///
/// `[PHAsset]` alone collapses three very different failure modes (not yet
/// indexed, iCloud-only / can't fetch, true zero matches) into one render
/// path, which mis-attributes a permanent iCloud-only block to a transient
/// indexing-in-progress state.
enum SimilarSearchResult: Equatable {
    /// Ranked results, ordered by descending cosine similarity. Non-empty
    /// by construction in production (the call site routes empty matches
    /// to `.empty` instead) but kept as `[PHAsset]` rather than a
    /// non-empty type to avoid forcing an extra invariant on callers.
    case results([PHAsset])
    /// Query asset has no stored embedding yet AND the on-the-fly embed
    /// path is still viable (CGImage was fetchable). Today this case
    /// arises before indexing finishes; the on-the-fly embed actually
    /// persists, so a future call will hit `.results` directly.
    case notIndexedYet
    /// Query asset has no stored embedding AND its pixels are not
    /// available locally — typically iCloud-only assets, but also covers
    /// the edge case where `requestCGImage` returns nil for any other
    /// reason (e.g. asset deleted mid-flight). User-facing copy points
    /// the user to Photos.app to trigger an iCloud download.
    case notAvailable
    /// Index is complete and was searched, but no candidates other than
    /// the query itself exist (or all candidates ranked below the
    /// returned top-K cut-off — today the cut-off is open so this collapses
    /// to "no other embeddings exist for this variant").
    case empty

    static func == (lhs: SimilarSearchResult, rhs: SimilarSearchResult) -> Bool {
        switch (lhs, rhs) {
        case (.results(let a), .results(let b)):
            return a.map(\.localIdentifier) == b.map(\.localIdentifier)
        case (.notIndexedYet, .notIndexedYet): return true
        case (.notAvailable, .notAvailable):   return true
        case (.empty, .empty):                 return true
        default: return false
        }
    }
}

/// Encapsulates a single "find similar photos" query against the on-device
/// CLIP embedding index.
///
/// Inject via `.environment(similaritySearch)` and consume with
/// `@Environment(SimilaritySearch.self)`.
@MainActor
@Observable
final class SimilaritySearch {

    // MARK: - Published state

    /// `true` while a query is executing.
    var isSearching: Bool = false

    // MARK: - Dependencies

    private let embedder: Embedder?
    private let store: EmbeddingStore
    private let library: PhotoController
    private let variant: CLIPVariant

    /// F-09 test seam. Resolves a `localIdentifier` to the matching
    /// `PHAsset` (or `nil` if it no longer exists). Production wires this
    /// to `PHAsset.fetchAssets(withLocalIdentifiers:)`; tests inject a
    /// closure that returns a `StubPHAsset` so the iCloud-only branch
    /// (which relies on `PhotoController.isCloudOnly(_:)`) can be exercised
    /// without standing up a real Photos library.
    private let assetResolver: @MainActor (String) -> PHAsset?

    // MARK: - Init

    /// - Parameters:
    ///   - embedder: Pre-loaded `Embedder` actor for the active variant.
    ///   - context:  A `ModelContext` backed by a container that includes `PhotoEmbedding.self`.
    ///   - library:  `PhotoController` used to fetch a CGImage when the query asset
    ///               is not yet indexed.
    ///   - variant:  The active `CLIPVariant`; defaults to `.bundledDefault`.
    init(
        embedder: Embedder,
        context: ModelContext,
        library: PhotoController,
        variant: CLIPVariant = .bundledDefault
    ) {
        self.embedder = embedder
        self.store = EmbeddingStore(context: context)
        self.library = library
        self.variant = variant
        self.assetResolver = { id in
            PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        }
    }

    /// F-09 test-only initialiser. Allows tests to drive the iCloud-only
    /// short-circuit without owning a real `Embedder` or a PhotoKit
    /// library — pass `embedder: nil` plus a custom `assetResolver` that
    /// returns a `StubPHAsset` for the queried ID.
    ///
    /// `embedder: nil` is safe because the iCloud-only branch returns
    /// `.notAvailable` BEFORE the on-the-fly embed path runs. Any test
    /// that reaches the embed path with `embedder == nil` will fall into
    /// the `.notIndexedYet` branch (the `try? await embedder.embed`
    /// becomes `nil`).
    init(
        embedderForTesting embedder: Embedder?,
        context: ModelContext,
        library: PhotoController,
        variant: CLIPVariant = .bundledDefault,
        assetResolver: @escaping @MainActor (String) -> PHAsset?
    ) {
        self.embedder = embedder
        self.store = EmbeddingStore(context: context)
        self.library = library
        self.variant = variant
        self.assetResolver = assetResolver
    }

    // MARK: - Query

    /// Returns up to `limit` assets visually similar to `assetID`, ranked by
    /// cosine similarity (most similar first), wrapped in a typed
    /// `SimilarSearchResult` so the caller can disambiguate true-empty
    /// from not-yet-indexed from not-available-on-device (F-09).
    ///
    /// **Query embedding resolution:**
    /// 1. Reads the stored embedding for `assetID` if it exists → searches.
    /// 2. Otherwise, if the asset is iCloud-only (per `PhotoController`),
    ///    returns `.notAvailable` immediately — `requestCGImage` would
    ///    fail and the user needs to download the original from Photos.app.
    /// 3. Otherwise, fetches a CGImage via `PhotoController` (~256 px) and
    ///    runs `Embedder.embed(_:)` on the fly, then upserts the result so
    ///    future queries are instant.
    /// 4. Returns `.notAvailable` if the CGImage fetch fails for any other
    ///    reason (asset deleted mid-flight, etc.), `.notIndexedYet` if the
    ///    embedder itself returned no vector (model not loaded etc.).
    ///
    /// The query's own `assetID` is excluded from the results.
    func similarAssets(to assetID: String, limit: Int = 30) async -> SimilarSearchResult {
        isSearching = true
        defer { isSearching = false }

        // 1. Resolve the query vector.
        let queryVector: [Float]

        if let stored = store.embedding(assetID: assetID, modelID: variant.modelID) {
            queryVector = stored.floats
        } else {
            // Asset not indexed yet — embed it on the fly.
            guard let asset = assetResolver(assetID) else {
                return .notAvailable
            }

            // F-09. Short-circuit iCloud-only assets BEFORE issuing the
            // `requestCGImage` round-trip. `PhotoController.requestCGImage`
            // sets `isNetworkAccessAllowed = false` and returns nil for
            // iCloud-only assets — that nil is indistinguishable from
            // "asset deleted mid-flight" at the call site, but the cloud
            // status check disambiguates and lets us surface a precise
            // "open in Photos.app to download" empty state.
            if library.isCloudOnly(asset) {
                return .notAvailable
            }

            guard
                let cgImage = await library.requestCGImage(
                    for: asset,
                    targetSize: CGSize(width: 256, height: 256)
                )
            else {
                return .notAvailable
            }

            // `embedder` is optional only on the F-09 test-init path.
            // In production it's non-nil (the standard `init` enforces it).
            guard
                let embedder,
                let vector = try? await embedder.embed(cgImage)
            else {
                // Embedder failure (e.g. model not loaded) is closer to
                // "indexing not ready" than to "asset unavailable" —
                // surface as `.notIndexedYet` so the user retries after
                // the progress indicator clears.
                return .notIndexedYet
            }

            // Persist so future queries are instant.
            store.upsert(
                assetID: assetID,
                modelID: variant.modelID,
                vector: vector,
                assetModificationDate: asset.modificationDate
            )

            queryVector = vector
        }

        // 2. Build candidates, excluding the query asset itself.
        let all = store.allEmbeddings(modelID: variant.modelID)
        guard !all.isEmpty else { return .empty }

        let candidates: [(id: String, vector: [Float])] = all.compactMap { row in
            guard row.assetID != assetID else { return nil }
            return (id: row.assetID, vector: row.floats)
        }
        guard !candidates.isEmpty else { return .empty }

        // 3. Rank by cosine similarity.
        let ranked = Similarity.cosineTopK(query: queryVector, candidates: candidates, k: limit)

        // 4. Fetch PHAssets and restore cosine ranking order.
        let ids = ranked.map(\.id)
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: ids,
            options: nil
        )
        var byID = [String: PHAsset]()
        fetchResult.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }

        let assets = ids.compactMap { byID[$0] }
        return assets.isEmpty ? .empty : .results(assets)
    }

}

// MARK: - Environment keys for optional @Observable dependencies

/// `EnvironmentKey` for an optional `SimilaritySearch` instance.
///
/// Use `.environment(\.similaritySearch, search)` to inject and
/// `@Environment(\.similaritySearch)` to consume.
private struct SimilaritySearchKey: EnvironmentKey {
    static let defaultValue: SimilaritySearch? = nil
}

/// `EnvironmentKey` for an optional `EmbeddingIndexer` instance.
///
/// Use `.environment(\.embeddingIndexer, indexer)` to inject and
/// `@Environment(\.embeddingIndexer)` to consume.
private struct EmbeddingIndexerKey: EnvironmentKey {
    static let defaultValue: EmbeddingIndexer? = nil
}

extension EnvironmentValues {
    /// The active `SimilaritySearch` engine, or `nil` before the ML model has loaded.
    var similaritySearch: SimilaritySearch? {
        get { self[SimilaritySearchKey.self] }
        set { self[SimilaritySearchKey.self] = newValue }
    }

    /// The active `EmbeddingIndexer`, or `nil` before the ML model has loaded.
    var embeddingIndexer: EmbeddingIndexer? {
        get { self[EmbeddingIndexerKey.self] }
        set { self[EmbeddingIndexerKey.self] = newValue }
    }
}
