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
    ///
    /// Copies through `copyBytes` rather than `assumingMemoryBound`: a `Data`
    /// loaded from SwiftData is not guaranteed to be 4-byte aligned, and
    /// reinterpreting an unaligned buffer as `Float` is undefined behaviour
    /// (an alignment trap on ARM). `copyBytes` memcpy's into the aligned
    /// `[Float]` storage, which is correct for any source alignment.
    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }

    // MARK: - Computed

    /// Round-trips `vector` back to a `[Float]` array. The decode is exact
    /// (same bit pattern as encoding).
    var floats: [Float] {
        PhotoEmbedding.decode(vector)
    }
}
