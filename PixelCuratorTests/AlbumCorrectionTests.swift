import XCTest
import SwiftData
@testable import PixelCurator

@MainActor
final class AlbumCorrectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> (ModelContainer, CorrectionStore) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, CorrectionStore(context: container.mainContext))
    }

    // MARK: - Persistence

    func testRecordAndFetch() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        let c = try XCTUnwrap(store.correction(assetID: "a1", modelID: "mobileclip_s0"))
        XCTAssertEqual(c.albumName, "Beach")
        _ = container
    }

    func testSecondRecordOverwritesKeepsCountOne() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        store.record(assetID: "a1", albumName: "City", modelID: "mobileclip_s0")
        let all = store.corrections(modelID: "mobileclip_s0")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.albumName, "City")
        _ = container
    }

    func testCorrectionsFilterByModelID() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        store.record(assetID: "a2", albumName: "City", modelID: "mobileclip_b")
        XCTAssertEqual(store.corrections(modelID: "mobileclip_s0").map(\.assetID), ["a1"])
        XCTAssertEqual(store.corrections(modelID: "mobileclip_b").map(\.assetID), ["a2"])
        _ = container
    }

    func testDeleteAll() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        store.deleteAll(modelID: "mobileclip_s0")
        XCTAssertTrue(store.corrections(modelID: "mobileclip_s0").isEmpty)
        _ = container
    }

    // MARK: - Prune (B-2: cascade from library change)

    /// Prune must drop corrections whose asset is gone, regardless of variant.
    func testPruneDropsCorrectionsForDeletedAssets() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        store.record(assetID: "a2", albumName: "Beach", modelID: "mobileclip_s0")
        store.record(assetID: "a3", albumName: "City",  modelID: "mobileclip_b")

        // a2 was deleted in Photos.app.
        let deleted = store.prune(
            keepingAssetIDs: ["a1", "a3"],
            livingAlbumNames: ["Beach", "City"]
        )
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(store.corrections(modelID: "mobileclip_s0").map(\.assetID), ["a1"])
        XCTAssertEqual(store.corrections(modelID: "mobileclip_b").map(\.assetID),  ["a3"])
        _ = container
    }

    /// Prune must drop corrections pointing at deleted albums — a stale
    /// "Vacation" exemplar after the album is gone would be a ghost label.
    func testPruneDropsCorrectionsForDeletedAlbums() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        store.record(assetID: "a2", albumName: "OldAlbum", modelID: "mobileclip_s0")

        let deleted = store.prune(
            keepingAssetIDs: ["a1", "a2"],
            livingAlbumNames: ["Beach"]
        )
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(store.corrections(modelID: "mobileclip_s0").map(\.assetID), ["a1"])
        _ = container
    }

    /// Prune must clean up corrections that fail **either** predicate — the
    /// OR semantics matter so a row that lost both its asset and its album
    /// still gets dropped exactly once. Distinct (assetID, modelID) composite
    /// keys are used so the `@Attribute(.unique)` upsert path doesn't collapse
    /// the rows into one.
    func testPruneDropsRowsFailingEitherPredicate() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "alive-asset", albumName: "dead-album",  modelID: "mobileclip_s0")
        store.record(assetID: "dead-asset",  albumName: "alive-album", modelID: "mobileclip_s0")
        store.record(assetID: "dead-asset",  albumName: "dead-album",  modelID: "mobileclip_b")
        store.record(assetID: "alive-asset", albumName: "alive-album", modelID: "mobileclip_b")

        let deleted = store.prune(
            keepingAssetIDs: ["alive-asset"],
            livingAlbumNames: ["alive-album"]
        )
        // Three of four rows fail either predicate (only alive-asset+alive-album survives).
        XCTAssertEqual(deleted, 3)
        let s0Survivors = store.corrections(modelID: "mobileclip_s0")
        let bSurvivors  = store.corrections(modelID: "mobileclip_b")
        XCTAssertTrue(s0Survivors.isEmpty)
        XCTAssertEqual(bSurvivors.count, 1)
        XCTAssertEqual(bSurvivors.first?.assetID, "alive-asset")
        XCTAssertEqual(bSurvivors.first?.albumName, "alive-album")
        _ = container
    }

    func testPruneNoopWhenEverythingAlive() throws {
        let (container, store) = try makeStore()
        store.record(assetID: "a1", albumName: "Beach", modelID: "mobileclip_s0")
        let deleted = store.prune(
            keepingAssetIDs: ["a1"],
            livingAlbumNames: ["Beach"]
        )
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(store.corrections(modelID: "mobileclip_s0").count, 1)
        _ = container
    }

    // MARK: - Behavioral: a correction shifts the ranking

    /// A correction is, in effect, an extra labeled point fed into `rank`.
    /// Adding a "Beach" exemplar very close to the query must raise Beach's score
    /// — proving the retrain feedback actually changes suggestions.
    func testCorrectionPointRaisesAlbumScore() {
        let query = Similarity.normalize([1, 0, 0])
        let base: [(album: String, vector: [Float])] = [
            ("City", Similarity.normalize([0.9, 0.2, 0])),
            ("City", Similarity.normalize([0.85, 0.3, 0])),
            ("Beach", Similarity.normalize([0.1, 1, 0]))   // far
        ]
        let before = AlbumSuggester.rank(query: query, labeledPoints: base, k: 5)
        XCTAssertEqual(before.first?.albumTitle, "City")

        let corrected = base + [("Beach", Similarity.normalize([0.99, 0.05, 0]))]
        let after = AlbumSuggester.rank(query: query, labeledPoints: corrected, k: 5)

        let beachBefore = before.first { $0.albumTitle == "Beach" }?.score ?? 0
        let beachAfter = after.first { $0.albumTitle == "Beach" }?.score ?? 0
        XCTAssertGreaterThan(beachAfter, beachBefore, "Correction should raise Beach's score")
    }
}
