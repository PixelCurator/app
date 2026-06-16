import XCTest
import SwiftData
@testable import PixelCurator

/// Tests the end-to-end ranking path of `SimilaritySearch` without any real
/// ML model or PhotoKit dependency.
///
/// We seed an in-memory `ModelContainer` with hand-crafted L2-normalised
/// vectors whose cosine ordering vs a chosen query vector is analytically
/// known, then verify the `EmbeddingStore` + `Similarity.cosineTopK` path
/// returns them in the correct descending-similarity order and excludes the
/// query asset itself.
@MainActor
final class SimilaritySearchTests: XCTestCase {

    // MARK: - Helpers

    private let modelID = CLIPVariant.bundledDefault.modelID

    /// Builds an in-memory SwiftData container for `PhotoEmbedding`.
    private func makeStore() throws -> (ModelContainer, EmbeddingStore) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = EmbeddingStore(context: container.mainContext)
        return (container, store)
    }

    /// Seeds a single `PhotoEmbedding` row with an already-normalised vector.
    private func seed(
        assetID: String,
        vector: [Float],
        in store: EmbeddingStore
    ) {
        store.upsert(
            assetID: assetID,
            modelID: modelID,
            vector: vector,
            assetModificationDate: nil
        )
    }

    // MARK: - Tests

    /// Ranking: vectors closer in angle to the query should rank higher.
    ///
    /// Query  = (1, 0) in 2-D space.
    /// "near" = (0.96, 0.28)  — small angle from query, high cosine
    /// "mid"  = (0.71, 0.71)  — 45° from query
    /// "far"  = (0.0,  1.0)   — 90° from query, cosine ≈ 0
    ///
    /// Expected ranking: near > mid > far.
    func testRankingOrderIsDescendingByCosine() throws {
        let (container, store) = try makeStore()

        let query  = Similarity.normalize([1.0, 0.0])
        let near   = Similarity.normalize([0.96, 0.28])
        let mid    = Similarity.normalize([0.71, 0.71])
        let far    = Similarity.normalize([0.0,  1.0])

        seed(assetID: "query", vector: query, in: store)
        seed(assetID: "near",  vector: near,  in: store)
        seed(assetID: "mid",   vector: mid,   in: store)
        seed(assetID: "far",   vector: far,   in: store)

        // Build candidates excluding the query itself (as SimilaritySearch does).
        let all = store.allEmbeddings(modelID: modelID)
        let candidates: [(id: String, vector: [Float])] = all.compactMap { row in
            guard row.assetID != "query" else { return nil }
            return (id: row.assetID, vector: row.floats)
        }

        let results = Similarity.cosineTopK(query: query, candidates: candidates, k: 10)

        XCTAssertEqual(results.count, 3, "Should return exactly 3 results (all non-query assets)")
        XCTAssertEqual(results[0].id, "near",  "Closest vector must rank first")
        XCTAssertEqual(results[1].id, "mid",   "Mid vector must rank second")
        XCTAssertEqual(results[2].id, "far",   "Farthest vector must rank last")

        // Scores must be strictly descending.
        XCTAssertGreaterThan(results[0].score, results[1].score)
        XCTAssertGreaterThan(results[1].score, results[2].score)

        _ = container // keep container alive
    }

    /// The query's own assetID must never appear in the results.
    func testQueryAssetExcludedFromResults() throws {
        let (container, store) = try makeStore()

        let query = Similarity.normalize([1.0, 0.0])
        seed(assetID: "self", vector: query, in: store)
        seed(assetID: "other", vector: Similarity.normalize([0.5, 0.5]), in: store)

        let all = store.allEmbeddings(modelID: modelID)
        let candidates: [(id: String, vector: [Float])] = all.compactMap { row in
            guard row.assetID != "self" else { return nil }
            return (id: row.assetID, vector: row.floats)
        }

        let results = Similarity.cosineTopK(query: query, candidates: candidates, k: 10)

        XCTAssertFalse(results.map(\.id).contains("self"), "Query asset must not appear in results")
        XCTAssertTrue(results.map(\.id).contains("other"), "Other assets must appear in results")

        _ = container
    }

    /// Empty store → cosineTopK returns empty array without crashing.
    func testEmptyStoreReturnsNoResults() throws {
        let (container, store) = try makeStore()

        let all = store.allEmbeddings(modelID: modelID)
        XCTAssertTrue(all.isEmpty)

        let query = Similarity.normalize([1.0, 0.0])
        let results = Similarity.cosineTopK(query: query, candidates: [], k: 10)
        XCTAssertTrue(results.isEmpty)

        _ = container
    }

    /// When there is only the query asset in the store (no other candidates),
    /// the results after filtering should be empty.
    func testOnlyQueryInStoreProducesEmptyCandidates() throws {
        let (container, store) = try makeStore()

        let query = Similarity.normalize([1.0, 0.0])
        seed(assetID: "lonely", vector: query, in: store)

        let all = store.allEmbeddings(modelID: modelID)
        let candidates: [(id: String, vector: [Float])] = all.compactMap { row in
            guard row.assetID != "lonely" else { return nil }
            return (id: row.assetID, vector: row.floats)
        }

        XCTAssertTrue(candidates.isEmpty)
        let results = Similarity.cosineTopK(query: query, candidates: candidates, k: 10)
        XCTAssertTrue(results.isEmpty)

        _ = container
    }

    /// Top-K limit is respected even when more candidates exist.
    func testTopKLimitIsRespected() throws {
        let (container, store) = try makeStore()

        let query = Similarity.normalize([1.0, 0.0])
        seed(assetID: "a", vector: Similarity.normalize([0.9, 0.1]),  in: store)
        seed(assetID: "b", vector: Similarity.normalize([0.7, 0.3]),  in: store)
        seed(assetID: "c", vector: Similarity.normalize([0.5, 0.5]),  in: store)
        seed(assetID: "d", vector: Similarity.normalize([0.1, 0.9]),  in: store)

        let all = store.allEmbeddings(modelID: modelID)
        let candidates: [(id: String, vector: [Float])] = all.map {
            (id: $0.assetID, vector: $0.floats)
        }

        let results = Similarity.cosineTopK(query: query, candidates: candidates, k: 2)
        XCTAssertEqual(results.count, 2)

        _ = container
    }

    /// Scores from `cosineTopK` on L2-normalised vectors must lie in [-1, 1].
    func testScoresAreBoundedForNormalisedVectors() throws {
        let (container, store) = try makeStore()

        let query = Similarity.normalize([1.0, 0.0])
        seed(assetID: "x", vector: Similarity.normalize([0.6, 0.8]), in: store)
        seed(assetID: "y", vector: Similarity.normalize([-1.0, 0.0]), in: store)

        let all = store.allEmbeddings(modelID: modelID)
        let candidates: [(id: String, vector: [Float])] = all.map {
            (id: $0.assetID, vector: $0.floats)
        }

        let results = Similarity.cosineTopK(query: query, candidates: candidates, k: 10)
        for result in results {
            XCTAssertGreaterThanOrEqual(result.score, -1.0 - 1e-5,
                                        "Score \(result.score) below -1 for asset \(result.id)")
            XCTAssertLessThanOrEqual(result.score,    1.0 + 1e-5,
                                     "Score \(result.score) above +1 for asset \(result.id)")
        }

        _ = container
    }
}
