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
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26; revisit when fixed.
        let compositeKey = "\(assetID)|\(modelID)"
        let all = (try? context.fetch(FetchDescriptor<PhotoEmbedding>())) ?? []
        return all.first { $0.key == compositeKey }
    }

    /// Returns all embeddings produced by `modelID`.
    func allEmbeddings(modelID: String) -> [PhotoEmbedding] {
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26; revisit when fixed.
        let all = (try? context.fetch(FetchDescriptor<PhotoEmbedding>())) ?? []
        return all.filter { $0.modelID == modelID }
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

    /// Removes embeddings whose `assetID` is not in `livingAssetIDs`, across
    /// **all** variants.
    ///
    /// Called when the Photos library reports a change (an asset was deleted
    /// in Photos.app or removed from iCloud Shared Library) so that stale
    /// embeddings cannot continue to vote in `AlbumSuggester` or surface as
    /// ghost results in similarity search. The set is the union of every
    /// `PHAsset.localIdentifier` currently visible to the app — anything else
    /// is presumed permanently gone.
    ///
    /// Returns the number of rows deleted, for logging / test assertions. Does
    /// not call `context.save()` — the caller owns the context's save cadence.
    @discardableResult
    func prune(keeping livingAssetIDs: Set<String>) -> Int {
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26.
        let all = (try? context.fetch(FetchDescriptor<PhotoEmbedding>())) ?? []
        var deleted = 0
        for row in all where !livingAssetIDs.contains(row.assetID) {
            context.delete(row)
            deleted += 1
        }
        return deleted
    }

    // MARK: - Unindexable set (F-22)

    /// Returns every persisted `UnindexableAsset` for `modelID`, keyed by
    /// `assetID` for O(1) lookup by the indexer.
    ///
    /// Returns an empty dictionary if the container's schema lacks
    /// `UnindexableAsset.self` (production today, until the orchestrator
    /// wires the model into the shared `ModelContainer`). This degrades
    /// behaviour to "no persistence" rather than crashing — the F-22 loop
    /// will still re-attempt each launch, but never trap.
    func unindexableRecords(modelID: String) -> [String: UnindexableAsset] {
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26.
        guard let all = try? context.fetch(FetchDescriptor<UnindexableAsset>()) else {
            return [:]
        }
        var byAssetID: [String: UnindexableAsset] = [:]
        for row in all where row.modelID == modelID {
            byAssetID[row.assetID] = row
        }
        return byAssetID
    }

    /// Records that the indexer attempted `assetID` for `modelID` and could
    /// not retrieve pixels. Overwrites any prior record (refreshes
    /// `modificationDate` to the latest attempt).
    func markUnindexable(
        assetID: String,
        modelID: String,
        modificationDate: Date?,
        reason: String = "nilCGImage"
    ) {
        // Best-effort fetch of the prior row so we replace it rather than
        // dupe-trap on the `@Attribute(.unique)` key. Silent no-op if the
        // schema isn't present.
        if let existing = unindexableRecords(modelID: modelID)[assetID] {
            context.delete(existing)
        }
        let row = UnindexableAsset(
            modelID: modelID,
            assetID: assetID,
            modificationDate: modificationDate,
            reason: reason
        )
        context.insert(row)
    }

    /// Deletes the `UnindexableAsset` row for `(modelID, assetID)`, if any.
    /// Called after a successful retry so the row doesn't outlive its cause.
    func clearUnindexable(assetID: String, modelID: String) {
        if let existing = unindexableRecords(modelID: modelID)[assetID] {
            context.delete(existing)
        }
    }
}
