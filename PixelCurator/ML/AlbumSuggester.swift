import Foundation
import OSLog

// MARK: - AlbumSuggestion

/// A ranked suggestion pairing an album title with an aggregated confidence
/// score derived from cosine k-NN voting over stored CLIP embeddings.
struct AlbumSuggestion: Identifiable, Hashable {

    /// Display name of the candidate album.
    let albumTitle: String

    /// Aggregated confidence in [0, 1].
    ///
    /// Computed as the album's share of the total cosine mass across the top-k
    /// neighbors: `albumScore / sumOfAllTopKScores`. This means the scores of
    /// all returned suggestions always sum to ≤ 1 (< 1 when some neighbors have
    /// negative cosine, which is clamped to 0 before summing).
    let score: Float

    /// Number of the k nearest neighbors that belong to this album.
    let supportingCount: Int

    var id: String { albumTitle }
}

// MARK: - AlbumSuggester

/// Suggests which album a photo belongs to using cosine k-NN voting over
/// on-device CLIP embeddings.
///
/// Two entry points are provided:
///
/// 1. `rank(query:labeledPoints:k:)` — **pure, static** function with no
///    framework dependencies. Drive this from unit tests or wherever you
///    already have normalized vectors.
///
/// 2. `suggestions(for:modelID:store:albumManager:k:)` — higher-level
///    convenience that assembles `labeledPoints` from SwiftData + PhotoKit
///    and delegates to `rank`.
@MainActor
final class AlbumSuggester {

    /// OSLog signposter for measuring main-thread time inside the
    /// `suggestions(for:...)` hot path. View in Instruments.app → "Logging"
    /// template (filter on subsystem `yves.vogl.pixelcurator`,
    /// category `AlbumSuggester`).
    static let signposter = OSSignposter(subsystem: "yves.vogl.pixelcurator", category: "AlbumSuggester")

    // MARK: - Pure ranking (testable)

    /// Returns album suggestions ranked by weighted cosine vote.
    ///
    /// **Algorithm:**
    /// 1. Find the k nearest `labeledPoints` to `query` by cosine similarity
    ///    (dot product — assumes L2-normalised vectors).
    /// 2. For each album, sum the cosine scores of its members among those k
    ///    neighbors, clamping negative scores to 0 so that dissimilar vectors
    ///    do not penalise an album.
    /// 3. Normalise each album's summed score by the total positive cosine mass
    ///    across all top-k neighbors (i.e. album share of the total mass).
    ///    This bounds `score` to [0, 1] and makes scores across albums
    ///    interpretable as a soft probability distribution.
    /// 4. Sort descending; attach `supportingCount`.
    ///
    /// - Parameters:
    ///   - query: L2-normalised query vector.
    ///   - labeledPoints: Training corpus — each element pairs an album title
    ///     with its L2-normalised embedding.
    ///   - k: Number of nearest neighbors to consider (default 15).
    /// - Returns: Ranked suggestions (empty if `labeledPoints` is empty or
    ///   `query` is empty).
    nonisolated static func rank(
        query: [Float],
        labeledPoints: [(album: String, vector: [Float])],
        k: Int = 15
    ) -> [AlbumSuggestion] {
        guard !query.isEmpty, !labeledPoints.isEmpty else { return [] }

        // Step 1: map labeledPoints → candidates for cosineTopK.
        //   We use a stable index string so we can recover the album label.
        let indexed: [(id: String, vector: [Float])] = labeledPoints
            .enumerated()
            .map { (id: "\($0.offset)", vector: $0.element.vector) }

        let topK = Similarity.cosineTopK(query: query, candidates: indexed, k: k)

        // Step 2: accumulate per-album summed score (clamp negatives to 0).
        var albumScores: [String: Float] = [:]
        var albumCounts: [String: Int] = [:]

        for neighbor in topK {
            guard let idx = Int(neighbor.id), idx < labeledPoints.count else { continue }
            let album = labeledPoints[idx].album
            let contribution = max(0, neighbor.score)
            albumScores[album, default: 0] += contribution
            albumCounts[album, default: 0] += 1
        }

        // Step 3: normalise by total positive cosine mass.
        let totalMass = albumScores.values.reduce(0, +)
        guard totalMass > 0 else {
            // All neighbors had zero or negative cosine — return unscored
            // suggestions with 0 score (still meaningful as "these albums appeared").
            return albumCounts.map { album, count in
                AlbumSuggestion(albumTitle: album, score: 0, supportingCount: count)
            }
            .sorted { $0.supportingCount > $1.supportingCount }
        }

        // Step 4: build and sort.
        return albumScores
            .map { album, summedScore in
                AlbumSuggestion(
                    albumTitle: album,
                    score: summedScore / totalMass,
                    supportingCount: albumCounts[album, default: 0]
                )
            }
            .sorted { $0.score > $1.score }
    }

    // MARK: - Higher-level convenience (PhotoKit + SwiftData)

    /// Returns album suggestions for a photo already indexed in `store`.
    ///
    /// Assembles `labeledPoints` by enumerating every known album's members via
    /// `albumManager`, looking up each member's embedding in `store`, then
    /// calling `rank(query:labeledPoints:k:)`. The query asset is excluded from
    /// its own labeled points to avoid self-matching.
    ///
    /// - Parameters:
    ///   - queryAssetID: `PHAsset.localIdentifier` of the photo to classify.
    ///   - modelID: `CLIPVariant.modelID` that produced the stored embeddings.
    ///   - store: `SuggestionSourcing` data source. Production passes the live
    ///     `EmbeddingStore` (which conforms via an extension); tests inject a
    ///     pure-Swift mock that vends `EmbeddingSnapshot`s without touching
    ///     SwiftData (see backlog N-7 / N-8 for why the seam exists).
    ///   - albumManager: Live `AlbumManager` with already-loaded albums.
    ///   - k: Neighborhood size (default 15).
    /// - Returns: Ranked `AlbumSuggestion` array, empty if the query has no
    ///   stored embedding or no labeled points are available.
    func suggestions(
        for queryAssetID: String,
        modelID: String,
        store: any SuggestionSourcing,
        albumManager: AlbumManager,
        corrections: CorrectionStore? = nil,
        k: Int = 15
    ) -> [AlbumSuggestion] {
        let signpostID = AlbumSuggester.signposter.makeSignpostID()
        let state = AlbumSuggester.signposter.beginInterval("suggestions", id: signpostID)
        defer { AlbumSuggester.signposter.endInterval("suggestions", state) }

        // Step 1: batch-load every embedding for this variant in ONE SwiftData
        // fetch and index it by assetID. Pre-PR-this, this method called
        // `store.embedding(assetID:modelID:)` once per album member, and each
        // such call ran a `context.fetch(FetchDescriptor<PhotoEmbedding>())`
        // over the entire table (an iOS 26 SwiftData #Predicate workaround —
        // see EmbeddingStore.swift). For N embedded photos, M total album
        // memberships and A albums, that was ~N*M Swift-side iterations per
        // suggestion request. On a 5 000-photo / 50-album library that
        // produced multi-second freezes when tapping a thumbnail.
        //
        // The fix is structural: hydrate once, then do O(1) dictionary
        // lookups. The behavioural contract (which embeddings vote, how
        // they're weighted, the corrections fold-in) is unchanged.
        let rows = store.allEmbeddingSnapshots(modelID: modelID)
        var embeddingByID: [String: [Float]] = [:]
        embeddingByID.reserveCapacity(rows.count)
        for row in rows {
            embeddingByID[row.assetID] = row.vector
        }

        // Step 2: resolve query embedding from the in-memory dictionary.
        guard let queryVector = embeddingByID[queryAssetID] else {
            return []
        }

        // Step 3: build labeled corpus from album membership using O(1) lookups.
        var labeledPoints: [(album: String, vector: [Float])] = []
        for album in albumManager.albums {
            let memberIDs = albumManager.memberAssetIDs(of: album.id)
            for memberID in memberIDs {
                // Exclude the query asset itself.
                guard memberID != queryAssetID else { continue }
                guard let memberVector = embeddingByID[memberID] else { continue }
                labeledPoints.append((album: album.title, vector: memberVector))
            }
        }

        // Step 3b: fold in user corrections as additional labeled points (equal
        // weight). A correction "asset X → album A" means X is an example of A;
        // this is the lightweight on-device "retrain" — past overrides nudge
        // future suggestions toward what the user actually chose.
        if let corrections {
            for correction in corrections.corrections(modelID: modelID) {
                guard correction.assetID != queryAssetID else { continue }
                guard let memberVector = embeddingByID[correction.assetID] else { continue }
                labeledPoints.append((album: correction.albumName, vector: memberVector))
            }
        }

        // Step 4: rank.
        return AlbumSuggester.rank(query: queryVector, labeledPoints: labeledPoints, k: k)
    }
}
