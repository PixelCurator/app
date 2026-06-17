import Foundation
import SwiftData

// MARK: - AlbumCorrection

/// A user correction — "this photo belongs in this album" — recorded when the
/// user assigns a photo to an album other than the top suggestion (or picks an
/// album when there was no suggestion).
///
/// Corrections are fed back into `AlbumSuggester` as labeled exemplars so that
/// future k-NN suggestions improve. This is the lightweight on-device "retrain":
/// no model training, just a growing labeled set scoped per embedding space.
@Model
final class AlbumCorrection {

    /// Composite key `"\(assetID)|\(modelID)"` — one correction per asset per
    /// variant; a later correction for the same photo overwrites the earlier one.
    @Attribute(.unique) var key: String

    /// `PHAsset.localIdentifier` of the corrected photo.
    var assetID: String

    /// Title of the album the user assigned the photo to.
    var albumName: String

    /// `CLIPVariant.modelID` whose embedding space this correction lives in.
    var modelID: String

    /// When the correction was last recorded.
    var createdAt: Date

    init(assetID: String, albumName: String, modelID: String) {
        self.assetID = assetID
        self.albumName = albumName
        self.modelID = modelID
        self.key = "\(assetID)|\(modelID)"
        self.createdAt = Date()
    }
}

// MARK: - CorrectionStore

/// Thin synchronous façade over a SwiftData `ModelContext` for `AlbumCorrection`.
///
/// The caller owns the context; its container's schema MUST include
/// `AlbumCorrection` (otherwise SwiftData raises a schema error at use time).
struct CorrectionStore {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Inserts or overwrites the correction for `(assetID, modelID)`.
    func record(assetID: String, albumName: String, modelID: String) {
        if let existing = correction(assetID: assetID, modelID: modelID) {
            context.delete(existing)
        }
        context.insert(AlbumCorrection(assetID: assetID, albumName: albumName, modelID: modelID))
    }

    /// Returns the correction for `(assetID, modelID)`, or nil.
    func correction(assetID: String, modelID: String) -> AlbumCorrection? {
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26; revisit when fixed.
        let compositeKey = "\(assetID)|\(modelID)"
        let all = (try? context.fetch(FetchDescriptor<AlbumCorrection>())) ?? []
        return all.first { $0.key == compositeKey }
    }

    /// All corrections recorded for `modelID`.
    func corrections(modelID: String) -> [AlbumCorrection] {
        // NOTE: in-Swift filter avoids a SwiftData #Predicate trap on iOS 26; revisit when fixed.
        let all = (try? context.fetch(FetchDescriptor<AlbumCorrection>())) ?? []
        return all.filter { $0.modelID == modelID }
    }

    /// Removes all corrections for `modelID` (e.g. when re-indexing a variant).
    func deleteAll(modelID: String) {
        for row in corrections(modelID: modelID) {
            context.delete(row)
        }
    }
}
