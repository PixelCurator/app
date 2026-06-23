import Foundation

// MARK: - EmbeddingSnapshot

/// Pure value-type projection of a `PhotoEmbedding` row, safe to construct in
/// unit tests without touching SwiftData.
///
/// `PhotoEmbedding` is `@Model` — allocating one in a test forces SwiftData to
/// stand up a `ModelContext`, and on iOS 26 simulator a `context.fetch` against
/// an `isStoredInMemoryOnly: true` container reliably SIGTRAPs inside SwiftData
/// (see `EmbeddingStore.embedding(_:_:)` and the `pixelcurator-backlog`
/// entries N-7 / N-8). The suggestion / similarity pipelines only need the
/// vector + asset/model identifiers, so the protocol surface vends snapshots
/// rather than the live `@Model` instances.
struct EmbeddingSnapshot: Hashable {

    /// `PHAsset.localIdentifier` of the source photo.
    let assetID: String

    /// `CLIPVariant.modelID` that produced this vector.
    let modelID: String

    /// L2-normalised CLIP embedding vector (Float32 components).
    let vector: [Float]
}

// MARK: - SuggestionSourcing

/// The minimal data-source surface that `SortingCoordinator` and
/// `AlbumSuggester` need to compute album suggestions.
///
/// In production this is implemented by `EmbeddingStore` via an adapter
/// (`EmbeddingStore` already conforms in an extension below); tests inject a
/// pure-Swift mock that returns pre-baked `EmbeddingSnapshot` arrays without
/// allocating any SwiftData `@Model` instance.
///
/// This replaces the prior `_suppressSuggestionsForTesting` /
/// `_seedQueueForTesting` workarounds in `SortingCoordinator` — see the
/// backlog N-8 entry for context.
@MainActor
protocol SuggestionSourcing {

    /// All embeddings produced by `modelID`, projected as immutable snapshots.
    ///
    /// `AlbumSuggester.suggestions(...)` calls this exactly once per request and
    /// builds an in-memory `[assetID: [Float]]` index for O(1) lookups, so the
    /// cost of materialising the snapshots is dominated by the underlying
    /// fetch — the projection itself is cheap.
    func allEmbeddingSnapshots(modelID: String) -> [EmbeddingSnapshot]

    /// The set of `assetID`s that already have an embedding for `modelID`.
    ///
    /// Used by `SortingCoordinator.buildQueue()` / `unsortedCount()` to filter
    /// the inbox to "embedded + not in any album". Modelled separately from
    /// `allEmbeddingSnapshots` because the queue-build path does not need the
    /// vectors, only the IDs.
    func embeddedAssetIDs(modelID: String) -> Set<String>
}

// MARK: - EmbeddingStore conformance

extension EmbeddingStore: SuggestionSourcing {

    /// Wraps the underlying `PhotoEmbedding` rows into value-type snapshots so
    /// callers never see the `@Model` instances. The conversion runs once per
    /// fetch and is bounded by the number of indexed photos for `modelID`.
    func allEmbeddingSnapshots(modelID: String) -> [EmbeddingSnapshot] {
        allEmbeddings(modelID: modelID).map { row in
            EmbeddingSnapshot(
                assetID: row.assetID,
                modelID: row.modelID,
                vector: row.floats
            )
        }
    }
}
