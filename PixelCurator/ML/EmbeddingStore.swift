import Foundation
import SwiftData

/// Thin synchronous façade over a SwiftData `ModelContext` for `PhotoEmbedding` rows.
///
/// The caller owns the `ModelContext` and its container — this type does not
/// create or manage persistence. Pass a context that is already bound to a
/// container that includes `PhotoEmbedding.self` in its schema.
struct EmbeddingStore {

    // MARK: - Dependencies

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Write

    /// Inserts or overwrites the embedding for `(assetID, modelID)`.
    ///
    /// SwiftData's `@Attribute(.unique)` on `key` prevents duplicates, but to
    /// produce a clean upsert semantics we delete the existing row first so
    /// that all mutable fields (vector, dimension, dates) are refreshed.
    func upsert(
        assetID: String,
        modelID: String,
        vector: [Float],
        assetModificationDate: Date?
    ) {
        // Remove any existing row for this composite key.
        if let existing = embedding(assetID: assetID, modelID: modelID) {
            context.delete(existing)
        }

        let row = PhotoEmbedding(
            assetID: assetID,
            modelID: modelID,
            vector: vector,
            dimension: vector.count,
            assetModificationDate: assetModificationDate
        )
        context.insert(row)
    }

    // MARK: - Read

    /// Returns the embedding for `(assetID, modelID)`, or `nil` if not indexed yet.
    func embedding(assetID: String, modelID: String) -> PhotoEmbedding? {
        let compositeKey = "\(assetID)|\(modelID)"
        var descriptor = FetchDescriptor<PhotoEmbedding>(
            predicate: #Predicate { $0.key == compositeKey }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Returns all embeddings produced by `modelID`.
    func allEmbeddings(modelID: String) -> [PhotoEmbedding] {
        let descriptor = FetchDescriptor<PhotoEmbedding>(
            predicate: #Predicate { $0.modelID == modelID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Returns the set of `assetID`s that already have an embedding for `modelID`.
    /// The indexer uses this as a skip-set to avoid re-embedding unchanged photos.
    func embeddedAssetIDs(modelID: String) -> Set<String> {
        let rows = allEmbeddings(modelID: modelID)
        return Set(rows.map(\.assetID))
    }

    // MARK: - Delete

    /// Removes all embeddings produced by `modelID` (e.g. when a variant is swapped out).
    func deleteAll(modelID: String) {
        let rows = allEmbeddings(modelID: modelID)
        for row in rows {
            context.delete(row)
        }
    }
}
