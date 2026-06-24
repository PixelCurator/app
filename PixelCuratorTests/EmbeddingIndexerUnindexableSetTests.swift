import XCTest
import SwiftData
@preconcurrency import Photos
import CoreGraphics
@testable import PixelCurator

/// Coverage for F-22: assets that the `CGImageProviding` declines to deliver
/// pixels for (iCloud-only originals, corrupted RAWs, etc.) must be recorded
/// in `UnindexableAsset` so the indexer's skip-set excludes them on
/// subsequent runs *until* their `PHAsset.modificationDate` advances. Prior
/// behaviour was log-and-continue, which made every library-change tick
/// re-attempt the same dead assets forever.
@MainActor
final class EmbeddingIndexerUnindexableSetTests: XCTestCase {

    // MARK: - F-22: skip-on-repeat

    /// Half the assets return nil from the provider on the first pass. The
    /// second pass — identical asset list, identical provider — must skip
    /// the previously-failed assets entirely (no embed calls, no markUn-
    /// indexable writes for them). The healthy half re-runs through
    /// `embeddedAssetIDs` and is also skipped because it embedded
    /// successfully on the first pass.
    func testSecondRunSkipsUnindexableAssetsEntirely() async throws {
        let (container, embedder, provider) = try setUpReentryFixture()
        defer { _ = container }

        let healthyA = StubModifiableAsset(localIdentifier: "ok-A", modificationDate: nil)
        let badB = StubModifiableAsset(localIdentifier: "bad-B", modificationDate: nil)
        let healthyC = StubModifiableAsset(localIdentifier: "ok-C", modificationDate: nil)
        let badD = StubModifiableAsset(localIdentifier: "bad-D", modificationDate: nil)

        provider.nilFor = ["bad-B", "bad-D"]

        let indexer = makeIndexer(container: container, embedder: embedder, provider: provider)
        await indexer.index(assets: [healthyA, badB, healthyC, badD])

        let firstCallCount = await embedder.callCount
        XCTAssertEqual(firstCallCount, 2, "First run should embed only the two healthy assets")

        // Persist the round-1 unindexable records so a fresh indexer (same
        // pattern as a new launch) reads them on round 2.
        try container.mainContext.save()

        // Round 2: fresh indexer, same assets, same provider. The previously
        // bad assets should now be excluded by the skip-set; the previously
        // healthy ones by the `embeddedAssetIDs` set. Net: zero embed calls.
        let indexer2 = makeIndexer(container: container, embedder: embedder, provider: provider)
        await indexer2.index(assets: [healthyA, badB, healthyC, badD])

        let secondCallCount = await embedder.callCount
        XCTAssertEqual(secondCallCount, 2,
                       "Second run must not re-attempt unindexable assets — embed count should stay at 2")

        // total counter on the second run should be 0 (nothing pending).
        XCTAssertEqual(indexer2.total, 0, "Second run's pending count must be 0")
        XCTAssertEqual(indexer2.indexed, 0)

        // Sanity: only the two healthy assets ended up in the embedding store.
        let store = EmbeddingStore(context: container.mainContext)
        let embedded = store.embeddedAssetIDs(modelID: CLIPVariant.bundledDefault.modelID)
        XCTAssertEqual(embedded, Set(["ok-A", "ok-C"]))

        // The unindexable rows survived both runs.
        let unindexable = store.unindexableRecords(modelID: CLIPVariant.bundledDefault.modelID)
        XCTAssertEqual(Set(unindexable.keys), Set(["bad-B", "bad-D"]))
    }

    /// When a previously-unindexable asset's `modificationDate` advances —
    /// i.e. the user did something to it in Photos.app — the indexer must
    /// retry. This is the escape hatch that prevents the unindexable set
    /// from becoming a permanent quarantine.
    func testRetryFiresWhenModificationDateAdvances() async throws {
        let (container, embedder, provider) = try setUpReentryFixture()
        defer { _ = container }

        let asset = StubModifiableAsset(localIdentifier: "asset-X", modificationDate: Date(timeIntervalSince1970: 1000))
        provider.nilFor = ["asset-X"]

        let indexer = makeIndexer(container: container, embedder: embedder, provider: provider)
        await indexer.index(assets: [asset])
        try container.mainContext.save()

        // Round 2: still nil — should still be skipped.
        let indexer2 = makeIndexer(container: container, embedder: embedder, provider: provider)
        await indexer2.index(assets: [asset])
        let count2 = await embedder.callCount
        XCTAssertEqual(count2, 0, "Same modificationDate → no retry")

        // Round 3: user updated the asset in Photos.app (later
        // modificationDate) AND the provider now hands back pixels.
        let refreshedAsset = StubModifiableAsset(
            localIdentifier: "asset-X",
            modificationDate: Date(timeIntervalSince1970: 2000)
        )
        provider.nilFor = []
        let indexer3 = makeIndexer(container: container, embedder: embedder, provider: provider)
        await indexer3.index(assets: [refreshedAsset])
        let count3 = await embedder.callCount
        XCTAssertEqual(count3, 1, "Advanced modificationDate must trigger a retry")

        // Successful retry clears the unindexable row.
        let store = EmbeddingStore(context: container.mainContext)
        let leftovers = store.unindexableRecords(modelID: CLIPVariant.bundledDefault.modelID)
        XCTAssertNil(leftovers["asset-X"], "Successful retry must clear the unindexable record")
    }

    // MARK: - shouldRetryUnindexable predicate

    func testShouldRetryPredicateCases() {
        let nilRecord = UnindexableAsset(modelID: "m", assetID: "a", modificationDate: nil, reason: "r")
        let datedRecord = UnindexableAsset(
            modelID: "m",
            assetID: "a",
            modificationDate: Date(timeIntervalSince1970: 1000),
            reason: "r"
        )

        XCTAssertTrue(EmbeddingIndexer.shouldRetryUnindexable(
            record: nilRecord,
            currentModificationDate: Date(timeIntervalSince1970: 500)
        ), "nil → non-nil should retry")

        XCTAssertFalse(EmbeddingIndexer.shouldRetryUnindexable(
            record: nilRecord,
            currentModificationDate: nil
        ), "nil → nil should not retry")

        XCTAssertTrue(EmbeddingIndexer.shouldRetryUnindexable(
            record: datedRecord,
            currentModificationDate: Date(timeIntervalSince1970: 2000)
        ), "Later date should retry")

        XCTAssertFalse(EmbeddingIndexer.shouldRetryUnindexable(
            record: datedRecord,
            currentModificationDate: Date(timeIntervalSince1970: 1000)
        ), "Same date should not retry")

        XCTAssertFalse(EmbeddingIndexer.shouldRetryUnindexable(
            record: datedRecord,
            currentModificationDate: Date(timeIntervalSince1970: 500)
        ), "Earlier date should not retry")

        XCTAssertFalse(EmbeddingIndexer.shouldRetryUnindexable(
            record: datedRecord,
            currentModificationDate: nil
        ), "non-nil → nil should not retry (regression suggests in-flight mutation)")
    }

    // MARK: - Helpers

    private func setUpReentryFixture() throws -> (ModelContainer, FakeEmbedder, ScriptableCGImageProvider) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self, UnindexableAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, FakeEmbedder(), ScriptableCGImageProvider())
    }

    private func makeIndexer(
        container: ModelContainer,
        embedder: FakeEmbedder,
        provider: ScriptableCGImageProvider
    ) -> EmbeddingIndexer {
        EmbeddingIndexer(
            context: container.mainContext,
            embedder: embedder,
            modelStore: ModelStore(),
            variant: .bundledDefault,
            cgImageProvider: provider
        )
    }
}

// MARK: - Test doubles

/// `PHAsset` subclass that exposes a mutable `modificationDate` alongside
/// the `localIdentifier` override from `StubPHAsset`. We need our own
/// subclass because `StubPHAsset` (in `DecisionLogTests.swift`) doesn't
/// override `modificationDate`, and PHAsset's stored property is a fixed
/// nil in a default-init subclass.
final class StubModifiableAsset: PHAsset {
    private let stubID: String
    private let stubModificationDate: Date?

    init(localIdentifier: String, modificationDate: Date?) {
        self.stubID = localIdentifier
        self.stubModificationDate = modificationDate
        super.init()
    }

    override var localIdentifier: String { stubID }
    override var modificationDate: Date? { stubModificationDate }
}

/// `CGImageProviding` whose return value can be scripted per-asset via the
/// `nilFor` set. Any asset whose `localIdentifier` is in the set yields
/// `nil`; everything else gets a fresh 1×1 image.
final class ScriptableCGImageProvider: CGImageProviding, @unchecked Sendable {
    /// `localIdentifier`s for which `cgImage(for:)` returns nil.
    var nilFor: Set<String> = []

    func cgImage(for asset: PHAsset) async -> CGImage? {
        if nilFor.contains(asset.localIdentifier) {
            return nil
        }
        return TinyCGImage.make()
    }
}
