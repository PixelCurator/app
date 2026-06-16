@preconcurrency import Photos
import SwiftData
import SwiftUI

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

    private let embedder: Embedder
    private let store: EmbeddingStore
    private let library: PhotoController
    private let variant: CLIPVariant

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
    }

    // MARK: - Query

    /// Returns up to `limit` assets visually similar to `assetID`, ranked by
    /// cosine similarity (most similar first).
    ///
    /// **Query embedding resolution:**
    /// 1. Reads the stored embedding for `assetID` if it exists.
    /// 2. If not indexed yet, fetches a CGImage via `PhotoController` (~256 px)
    ///    and runs `Embedder.embed(_:)` on the fly, then upserts the result so
    ///    future queries are instant.
    /// 3. Returns `[]` if no CGImage is available (e.g. asset deleted).
    ///
    /// The query's own `assetID` is excluded from the results.
    func similarAssets(to assetID: String, limit: Int = 30) async -> [PHAsset] {
        isSearching = true
        defer { isSearching = false }

        // 1. Resolve the query vector.
        let queryVector: [Float]

        if let stored = store.embedding(assetID: assetID, modelID: variant.modelID) {
            queryVector = stored.floats
        } else {
            // Asset not indexed yet — embed it on the fly.
            guard let asset = assetWithID(assetID) else { return [] }

            guard
                let cgImage = await library.requestCGImage(
                    for: asset,
                    targetSize: CGSize(width: 256, height: 256)
                )
            else {
                return []
            }

            guard let vector = try? await embedder.embed(cgImage) else {
                return []
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
        guard !all.isEmpty else { return [] }

        let candidates: [(id: String, vector: [Float])] = all.compactMap { row in
            guard row.assetID != assetID else { return nil }
            return (id: row.assetID, vector: row.floats)
        }
        guard !candidates.isEmpty else { return [] }

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

        return ids.compactMap { byID[$0] }
    }

    // MARK: - Private helpers

    /// Looks up a `PHAsset` by its local identifier. Returns `nil` if the asset
    /// no longer exists in the library.
    private func assetWithID(_ id: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        return result.firstObject
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
