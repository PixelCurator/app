import Foundation
import SwiftData

/// Persistent marker for a `PHAsset` that the indexer attempted but could
/// not produce a `CGImage` for (typically: iCloud-only originals that the
/// `PhotoKitCGImageProvider` declines to download, corrupted RAW files,
/// HEIF variants the Photos library hides from the standard request).
///
/// ## Why this exists (F-22)
///
/// `EmbeddingIndexer.runIndex` previously logged-and-continued for any asset
/// where `cgImageProvider.cgImage(for:)` returned `nil`. That made
/// `indexed < total` a permanent state: every library-change tick fired the
/// `task(id:)` re-entry path, re-attempted the same dead assets, and
/// re-failed in lockstep. The loop never settled.
///
/// Persisting the failure breaks the loop. Once an asset is recorded here,
/// the indexer's skip-set treats it like an already-indexed asset *until*
/// its `PHAsset.modificationDate` advances past the stored
/// `modificationDate` — at which point the user has clearly done something
/// to the asset in Photos.app (re-uploaded it, edited it, finished an
/// iCloud download), and a retry is warranted.
///
/// ## Per-variant
///
/// The record is keyed by `(modelID, assetID)` because indexability is a
/// function of pixel availability, but recording per-variant keeps us
/// honest: a future variant whose pre-processing differs (e.g. a model
/// that accepts depth maps) could legitimately re-classify the asset.
///
/// ## Schema wiring (open follow-up)
///
/// `pixelcurator-expert` owns `PixelCuratorApp.modelContainer`. Until that
/// container's schema is extended with `UnindexableAsset.self`, this type
/// is functional in tests (which construct their own containers) but
/// no-ops in production — `EmbeddingStore` traps cleanly and falls back
/// to an in-process `Set` so the runtime never crashes. Flag for the
/// orchestrator to add this model to the shared `ModelContainer`.
@Model
final class UnindexableAsset {

    // MARK: - Stored properties

    /// Composite primary key: `"\(modelID)|\(assetID)"`.
    @Attribute(.unique) var key: String

    /// `CLIPVariant.modelID` that attempted to index this asset.
    var modelID: String

    /// `PHAsset.localIdentifier` of the asset we could not index.
    var assetID: String

    /// `PHAsset.modificationDate` at the time of the failed attempt.
    ///
    /// The next indexing pass compares this against the asset's current
    /// `modificationDate`: a strictly later date is treated as "something
    /// about the asset has changed" and warrants a retry. A `nil` here
    /// (asset had no modification date when we recorded it) only retries
    /// when the asset later acquires a non-nil date.
    var modificationDate: Date?

    /// Free-form reason string. Currently always `"nilCGImage"` — added
    /// pre-emptively so future failure modes (compilation error per asset,
    /// pre-processing crash, dimension mismatch) can be distinguished
    /// without a schema migration.
    var reason: String

    /// Wall-clock time when this row was last written.
    var createdAt: Date

    // MARK: - Init

    init(
        modelID: String,
        assetID: String,
        modificationDate: Date?,
        reason: String
    ) {
        self.modelID = modelID
        self.assetID = assetID
        self.key = "\(modelID)|\(assetID)"
        self.modificationDate = modificationDate
        self.reason = reason
        self.createdAt = Date()
    }
}
