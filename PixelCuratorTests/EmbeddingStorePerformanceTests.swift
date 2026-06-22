import XCTest
import SwiftData
@testable import PixelCurator

/// Performance baselines for `EmbeddingStore` hot paths.
///
/// `EmbeddingStore.embedding(assetID:modelID:)` and `allEmbeddings(modelID:)`
/// both do a full `context.fetch(FetchDescriptor<PhotoEmbedding>())` followed
/// by an in-Swift filter — the iOS 26 `#Predicate`-trap workaround documented
/// in EmbeddingStore.swift. That makes the absolute baseline cost grow with
/// the table size on every read, not with the result size.
///
/// PR #44 fixed the N² consequence of this in `AlbumSuggester.suggestions(...)`
/// by hydrating once into a `[String: [Float]]` dictionary instead of calling
/// `embedding(assetID:)` N times. These tests pin the read-cost so a future
/// "let me just call embedding() in a loop again" regression surfaces as a
/// measure-block regression rather than as a user-visible inbox freeze.
@MainActor
final class EmbeddingStorePerformanceTests: XCTestCase {

    // MARK: - Fixtures

    private let modelID = "mobileclip_s0"

    /// Builds an in-memory SwiftData container holding `count` `PhotoEmbedding`
    /// rows for `modelID`. Vectors are small (8-dim) so the test cost is
    /// dominated by SwiftData fetch/filter, not vector blob serialisation.
    private func makeSeededStore(count: Int) throws -> (ModelContainer, EmbeddingStore) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = EmbeddingStore(context: container.mainContext)
        // Synthetic vectors — we never decode them in these tests; they only
        // pad the row size to a realistic shape.
        let vector: [Float] = [0.1, 0.2, 0.3, 0.4, -0.1, -0.2, -0.3, -0.4]
        for i in 0..<count {
            store.upsert(
                assetID: "asset-\(i)",
                modelID: modelID,
                vector: vector,
                assetModificationDate: nil
            )
        }
        try? container.mainContext.save()
        return (container, store)
    }

    // MARK: - allEmbeddings: the PR #44 hot path

    /// Mid-library size: 1 000 embeddings. `AlbumSuggester.suggestions(for:)`
    /// calls `allEmbeddings(modelID:)` exactly once per inbox advance — so
    /// every tap pays this cost on the main actor.
    func testAllEmbeddings_1000Rows() throws {
        let (container, store) = try makeSeededStore(count: 1_000)
        // Warm-up so the first measure block isn't an outlier.
        _ = store.allEmbeddings(modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.allEmbeddings(modelID: modelID)
        }
        _ = container
    }

    /// 10 000 embeddings — a heavy-user library. Pinning the absolute cost
    /// at this scale catches regressions that look fine at 1 000.
    func testAllEmbeddings_10000Rows() throws {
        let (container, store) = try makeSeededStore(count: 10_000)
        _ = store.allEmbeddings(modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.allEmbeddings(modelID: modelID)
        }
        _ = container
    }

    // MARK: - embeddedAssetIDs: the indexer skip-set

    /// `EmbeddingIndexer.runIndex(assets:)` calls `embeddedAssetIDs(modelID:)`
    /// once at the start of every indexing run to know which assets to skip.
    /// On a re-launch with a fully-indexed library, this is a 10 000-row
    /// fetch followed by a `Set` build — must stay snappy or the indexer's
    /// first-frame pass after launch stutters.
    func testEmbeddedAssetIDs_10000Rows() throws {
        let (container, store) = try makeSeededStore(count: 10_000)
        _ = store.embeddedAssetIDs(modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.embeddedAssetIDs(modelID: modelID)
        }
        _ = container
    }

    // MARK: - embedding(assetID:modelID:): single-row lookup cost

    /// `embedding(assetID:)` does the same full-table fetch as
    /// `allEmbeddings(modelID:)` and then returns the first match. That's
    /// expensive for a single-row lookup — PR #44 was the immediate consequence.
    ///
    /// This test pins the cost so a future caller that decides to fall back to
    /// the per-asset API in a loop surfaces immediately. If this measure block
    /// stays low-millisecond and a future commit makes the *suggestions* call
    /// slow, you know the regression is at the call-site (looping over assets),
    /// not in the store's single-row path itself.
    func testEmbeddingSingleLookup_in1000RowsTable() throws {
        let (container, store) = try makeSeededStore(count: 1_000)
        _ = store.embedding(assetID: "asset-500", modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.embedding(assetID: "asset-500", modelID: modelID)
        }
        _ = container
    }

    // MARK: - upsert batched writes: the indexer's hot write path

    /// `EmbeddingIndexer` does `upsert` per asset and batched `save()` every
    /// 20 embeddings. Measure the cost of 100 upserts (5 save windows) so a
    /// regression in the existing-row-delete-before-insert step surfaces as
    /// indexer slow-down, which the user perceives as fewer photos/second
    /// while the lock overlay is up.
    func testUpsert_100Writes_FreshStore() throws {
        let container = try ModelContainer(
            for: PhotoEmbedding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = EmbeddingStore(context: container.mainContext)
        let vector: [Float] = [0.1, 0.2, 0.3, 0.4, -0.1, -0.2, -0.3, -0.4]

        measure(metrics: [XCTClockMetric()]) {
            for i in 0..<100 {
                store.upsert(
                    assetID: "asset-\(i)",
                    modelID: modelID,
                    vector: vector,
                    assetModificationDate: nil
                )
            }
            // No save() — match the indexer's "save every 20" cadence by
            // letting the measure block end without a final flush. We're
            // measuring the upsert+insert cost, not the SQLite commit.
        }
        _ = container
    }

    // MARK: - prune: library-change cascade hot path

    /// The library-change cascade in `PixelCuratorApp.installLibraryChangeCascade`
    /// calls `EmbeddingStore.prune(keeping:)` whenever Photos notifies of a
    /// change. With 10 000 rows and a similarly-sized living set, the prune
    /// is dominated by the in-Swift filter — must stay snappy or every
    /// background-iCloud-sync notification stutters the main actor.
    func testPrune_10000Rows_NoneDeleted() throws {
        let (container, store) = try makeSeededStore(count: 10_000)
        let livingSet = Set((0..<10_000).map { "asset-\($0)" })

        measure(metrics: [XCTClockMetric()]) {
            _ = store.prune(keeping: livingSet)
        }
        _ = container
    }
}
