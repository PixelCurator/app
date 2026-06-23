import XCTest
import SwiftData
@testable import PixelCurator

/// Performance baselines for `CorrectionStore` hot paths.
///
/// `CorrectionStore` mirrors `EmbeddingStore`'s shape (full-table fetch +
/// in-Swift filter to dodge the iOS 26 `#Predicate` trap) and feeds the same
/// `AlbumSuggester.suggestions(for:)` hot path. Symmetric perf coverage to
/// `EmbeddingStorePerformanceTests` so a future regression in either store
/// surfaces as a measure-block regression rather than as a user-visible
/// inbox freeze.
///
/// Sizes are smaller than the embedding store baselines because corrections
/// scale with user intent (number of manual overrides), not with library
/// size — 500 corrections is already an unusually active user.
@MainActor
final class CorrectionStorePerformanceTests: XCTestCase {

    // MARK: - Fixtures

    private let modelID = "mobileclip_s0"

    private func makeSeededStore(count: Int) throws -> (ModelContainer, CorrectionStore) {
        let container = try ModelContainer(
            for: AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = CorrectionStore(context: container.mainContext)
        for i in 0..<count {
            store.record(
                assetID: "asset-\(i)",
                albumName: "Album-\(i % 25)",
                modelID: modelID
            )
        }
        try? container.mainContext.save()
        return (container, store)
    }

    // MARK: - corrections: the AlbumSuggester hot path

    /// `AlbumSuggester.suggestions(for:)` calls `corrections(modelID:)` once
    /// per inbox advance to fold user overrides into the labeled corpus.
    /// 500 corrections is a heavy-curator load.
    func testCorrections_500Rows() throws {
        let (container, store) = try makeSeededStore(count: 500)
        // Warm-up so the first measure block isn't an outlier.
        _ = store.corrections(modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.corrections(modelID: modelID)
        }
        _ = container
    }

    /// 5 000 corrections is well past any realistic user, but pins the
    /// asymptotic shape so a future O(N²) regression is loud.
    func testCorrections_5000Rows() throws {
        let (container, store) = try makeSeededStore(count: 5_000)
        _ = store.corrections(modelID: modelID)

        measure(metrics: [XCTClockMetric()]) {
            _ = store.corrections(modelID: modelID)
        }
        _ = container
    }

    // MARK: - record: per-assign write cost

    /// Every accepted suggestion that disagrees with the current top-N may
    /// produce a `record(...)` call. Measure a burst of 50 records — roughly
    /// what a user might pile up during a focused inbox session.
    ///
    /// `record` does an upsert: lookup existing → delete → insert. The lookup
    /// is a full-table fetch, so a burst is dominated by that read cost.
    func testRecord_50Bursts_FreshStore() throws {
        let container = try ModelContainer(
            for: AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = CorrectionStore(context: container.mainContext)

        measure(metrics: [XCTClockMetric()]) {
            for i in 0..<50 {
                store.record(
                    assetID: "asset-\(i)",
                    albumName: "Album-\(i % 5)",
                    modelID: modelID
                )
            }
        }
        _ = container
    }

    // MARK: - prune: library-change cascade hot path

    /// The library-change cascade calls `prune(keepingAssetIDs:livingAlbumNames:)`
    /// after every Photos.app change. With 1 000 corrections and a matching
    /// living set, prune is dominated by the OR-joined filter — must stay
    /// snappy so iCloud background sync doesn't stutter the main actor.
    func testPrune_1000Rows_NoneDeleted() throws {
        let (container, store) = try makeSeededStore(count: 1_000)
        let livingAssets = Set((0..<1_000).map { "asset-\($0)" })
        let livingAlbums = Set((0..<25).map { "Album-\($0)" })

        measure(metrics: [XCTClockMetric()]) {
            _ = store.prune(
                keepingAssetIDs: livingAssets,
                livingAlbumNames: livingAlbums
            )
        }
        _ = container
    }

    /// Prune with half the assets gone — the dominant work shifts from
    /// filter+keep to filter+delete. Pins the cost of the destructive path
    /// so a "delete is slow" regression surfaces independently.
    func testPrune_1000Rows_HalfDeleted() throws {
        let (container, store) = try makeSeededStore(count: 1_000)
        // Only the even-indexed assets are still alive — every odd row gets pruned.
        let livingAssets = Set((0..<1_000).filter { $0.isMultiple(of: 2) }.map { "asset-\($0)" })
        let livingAlbums = Set((0..<25).map { "Album-\($0)" })

        measure(metrics: [XCTClockMetric()]) {
            _ = store.prune(
                keepingAssetIDs: livingAssets,
                livingAlbumNames: livingAlbums
            )
        }
        _ = container
    }
}
