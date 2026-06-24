import XCTest
import SwiftData
@preconcurrency import Photos
import CoreGraphics
@testable import PixelCurator

/// Coverage for F-07: when `index(assets:)` is re-entered while a prior call
/// is still in flight, the second call's `assets` may contain newly-added
/// photos that weren't part of the first call's `pending` set. Prior
/// behaviour `await inFlight.value; return` silently dropped them. New
/// behaviour: recurse with `assets` after the in-flight task finishes so
/// the skip-set logic picks up exactly the delta.
///
/// Why this lives in its own file: the legacy `EmbeddingIndexerCancelTests`
/// stub documents an iOS 26 simulator interaction (backlog N-7) plus a
/// Core ML / Espresso warning that blocked the original cancel/wait suite.
/// These re-entry tests use the same `ImageEmbedding` and `CGImageProviding`
/// seams but stay on the iOS 17.4 simulator where the suite runs green,
/// and they inject the `alreadyIndexedAssetIDs` closure so the SwiftData
/// fetch path is never exercised against an in-memory store.
@MainActor
final class EmbeddingIndexerReentryTests: XCTestCase {

    // MARK: - F-07: re-entry picks up delta

    /// Re-entering `index(assets:)` with a superset of the original list
    /// must end with every asset in the superset embedded. The prior
    /// behaviour returned after `await inFlight.value` without recursing,
    /// so D + E in this test would have been silently dropped until the
    /// next library-change tick.
    func testReentryDuringInflightIndexesNewlyAddedAssets() async throws {
        let (container, indexer, _) = try makeIndexer()
        defer { _ = container } // keep alive

        let assetA = StubPHAsset(localIdentifier: "asset-A")
        let assetB = StubPHAsset(localIdentifier: "asset-B")
        let assetC = StubPHAsset(localIdentifier: "asset-C")
        let assetD = StubPHAsset(localIdentifier: "asset-D")
        let assetE = StubPHAsset(localIdentifier: "asset-E")

        // First call: 3 assets. Start it but don't await yet — we want a
        // re-entry to happen *during* its run.
        let firstRun = Task { await indexer.index(assets: [assetA, assetB, assetC]) }

        // Yield enough times for the runIndex loop to be inside its
        // for-loop. The fake embedder is deterministic and fast, so we
        // briefly sleep to give the run a chance to begin without
        // guaranteeing it has finished.
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms

        // Second call: 5 assets (superset). With the prior implementation
        // this would `await inFlight.value` then return, leaving D + E
        // unembedded. With the F-07 fix it recurses with [A..E] and the
        // skip-set short-circuits A/B/C.
        let secondRun = Task { await indexer.index(assets: [assetA, assetB, assetC, assetD, assetE]) }

        await firstRun.value
        await secondRun.value

        let store = EmbeddingStore(context: container.mainContext)
        let embedded = store.embeddedAssetIDs(modelID: CLIPVariant.bundledDefault.modelID)
        XCTAssertEqual(embedded, Set(["asset-A", "asset-B", "asset-C", "asset-D", "asset-E"]),
                       "Re-entry must embed the full superset; D + E would be dropped without F-07")
    }

    /// A re-entry whose `assets` is a strict *subset* of the in-flight
    /// run must not lose any embeddings — the skip-set ensures the
    /// recursive call no-ops for the already-embedded subset.
    func testReentryWithSubsetIsHarmless() async throws {
        let (container, indexer, _) = try makeIndexer()
        defer { _ = container }

        let assetA = StubPHAsset(localIdentifier: "asset-A")
        let assetB = StubPHAsset(localIdentifier: "asset-B")
        let assetC = StubPHAsset(localIdentifier: "asset-C")

        let firstRun = Task { await indexer.index(assets: [assetA, assetB, assetC]) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let secondRun = Task { await indexer.index(assets: [assetA]) }

        await firstRun.value
        await secondRun.value

        let store = EmbeddingStore(context: container.mainContext)
        let embedded = store.embeddedAssetIDs(modelID: CLIPVariant.bundledDefault.modelID)
        XCTAssertEqual(embedded, Set(["asset-A", "asset-B", "asset-C"]))
    }

    // MARK: - Helpers

    /// Builds an in-memory container + indexer wired to a deterministic
    /// fake embedder and a CGImage provider that returns a tiny synthetic
    /// image for every asset. The `alreadyIndexedAssetIDs` closure reads
    /// through `EmbeddingStore` so the skip-set logic is exercised
    /// end-to-end. `embeddedAssetIDs` does a SwiftData fetch — the iOS
    /// 17.4 simulator (this suite's target) doesn't trigger the N-7
    /// SIGTRAP that affects iOS 26 simulators.
    fileprivate func makeIndexer() throws -> (ModelContainer, EmbeddingIndexer, FakeEmbedder) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self, UnindexableAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let embedder = FakeEmbedder()
        let indexer = EmbeddingIndexer(
            context: container.mainContext,
            embedder: embedder,
            modelStore: ModelStore(),
            variant: .bundledDefault,
            cgImageProvider: AlwaysSyntheticCGImageProvider()
        )
        return (container, indexer, embedder)
    }
}

// MARK: - Fakes

/// Deterministic in-process embedder that hands back the same 4-dimensional
/// vector for every call. Sufficient for re-entry coverage where we care
/// about *which* assets get embedded, not what their vectors look like.
actor FakeEmbedder: ImageEmbedding {
    nonisolated var embeddingDimension: Int { 4 }
    private(set) var callCount: Int = 0

    func embed(_ cgImage: CGImage) async throws -> [Float] {
        callCount += 1
        return [0.5, 0.5, 0.5, 0.5]
    }
}

/// Synthesises a 1×1 white pixel for every asset so the indexer's
/// `cgImageProvider.cgImage(for:)` call never returns nil. The F-22
/// suite uses a different provider that *does* return nil to exercise
/// the unindexable path.
struct AlwaysSyntheticCGImageProvider: CGImageProviding {
    func cgImage(for asset: PHAsset) async -> CGImage? {
        TinyCGImage.make()
    }
}

/// Single-pixel placeholder image factory. Pulled out as a helper so the
/// reentry + unindexable suites can both reach for the same thing.
enum TinyCGImage {
    static func make() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
