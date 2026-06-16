import Foundation
import SwiftData

/// Persisted embedding for a single photo + model-variant combination.
///
/// The composite key `"\(assetID)|\(modelID)"` ensures that the same asset
/// can hold one embedding per `CLIPVariant` simultaneously, and that a
/// re-index of a specific variant overwrites only its own rows.
@Model
final class PhotoEmbedding {

    // MARK: - Stored properties

    /// Composite primary key: `"\(assetID)|\(modelID)"`.
    @Attribute(.unique) var key: String

    /// `PHAsset.localIdentifier` of the source photo.
    var assetID: String

    /// `CLIPVariant.modelID` that produced this vector.
    var modelID: String

    /// Raw little-endian IEEE-754 Float32 blob.
    var vector: Data

    /// Number of Float32 values in `vector`. Matches `CLIPVariant.expectedEmbeddingDimension`
    /// for well-formed rows; the authoritative count is `vector.count / 4`.
    var dimension: Int

    /// `PHAsset.modificationDate` at the time of indexing, used to detect
    /// stale embeddings when the original photo is edited.
    var assetModificationDate: Date?

    /// Wall-clock time when this row was last written.
    var createdAt: Date

    // MARK: - Init

    init(
        assetID: String,
        modelID: String,
        vector: [Float],
        dimension: Int,
        assetModificationDate: Date?
    ) {
        self.assetID = assetID
        self.modelID = modelID
        self.key = "\(assetID)|\(modelID)"
        self.vector = PhotoEmbedding.encode(vector)
        self.dimension = dimension
        self.assetModificationDate = assetModificationDate
        self.createdAt = Date()
    }

    // MARK: - Float ↔ Data codec

    /// Encodes a Float32 array into a little-endian raw-bytes `Data` blob.
    static func encode(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    /// Decodes a little-endian raw-bytes `Data` blob back into a Float32 array.
    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return [] }
            let count = data.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
    }

    // MARK: - Computed

    /// Round-trips `vector` back to a `[Float]` array. The decode is exact
    /// (same bit pattern as encoding).
    var floats: [Float] {
        PhotoEmbedding.decode(vector)
    }
}
