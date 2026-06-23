import XCTest
import CoreGraphics
import Photos
import SwiftData
@testable import PixelCurator

/// Regression tests for the variant-switch race fixed by PR #26.
///
/// PR #26 introduced `cancelAndWait()` and the `currentTask` handle on
/// `EmbeddingIndexer` so that switching `CLIPVariant` does not leave two
/// indexers racing the same `ModelContext`. Before that fix, the sequence
///
///   1. user starts indexing on S0
///   2. user switches to S1 mid-flight
///   3. orchestrator calls `cancelIndexing()` (request-only)
///   4. orchestrator builds a fresh S1 indexer
///
/// would leave the in-flight S0 `embed(_:)` `await` resumed *after* the new
/// S1 indexer had already begun, so the trailing `context.save()` and
/// `isIndexing = false` writes from the old run would race the new run and
/// the inbox UI would observe torn counters (`indexed` snapping back, `total`
/// flipping between two values).
///
/// These tests pin down the post-fix invariants:
///
/// * `cancelAndWait()` returns only AFTER the in-flight `embed(_:)` has
///   completed — no torn state when the orchestrator subsequently swaps
///   the shared `ModelContext`.
/// * A second `index(assets:)` call after `cancelAndWait()` starts from a
///   fresh `indexed`/`total` baseline — no leakage from the prior run's
///   counters or queue state.
///
/// Implementation notes:
///
/// * The test injects an `ImageEmbedding` fake that sleeps ~50ms per embed,
///   so the cancel signal lands while a real `embed(_:)` is awaiting.
/// * `CGImageProviding` is stubbed with a 1×1 synthetic image so the
///   indexer's run-loop does not skip on nil.
/// * `alreadyIndexedAssetIDs` is stubbed to return an empty set so the
///   production `EmbeddingStore.embeddedAssetIDs(modelID:)` fetch — which
///   SIGTRAPs against an in-memory SwiftData store on iOS 26 / macOS 26
///   (backlog N-7) — is bypassed entirely.
@MainActor
final class EmbeddingIndexerVariantSwitchTests: XCTestCase {

    // MARK: - Fakes

    /// `ImageEmbedding` actor that sleeps a controllable interval per call and
    /// records how many embeds completed. Used to widen the cancel race window
    /// so `cancelAndWait()` lands while an `embed(_:)` is awaiting.
    private actor SlowFakeEmbedder: ImageEmbedding {
        nonisolated var embeddingDimension: Int { 4 }
        private(set) var completedEmbedCount: Int = 0
        private(set) var inFlightEmbedCount: Int = 0
        private let sleepNanos: UInt64

        init(sleepMilliseconds: UInt64 = 50) {
            self.sleepNanos = sleepMilliseconds * 1_000_000
        }

        func embed(_ cgImage: CGImage) async throws -> [Float] {
            inFlightEmbedCount += 1
            defer { inFlightEmbedCount -= 1 }
            try await Task.sleep(nanoseconds: sleepNanos)
            completedEmbedCount += 1
            // Deterministic L2-normalised stub vector.
            return [1, 0, 0, 0]
        }
    }

    /// Returns a 1×1 grey `CGImage` for every asset request so the indexer's
    /// run-loop never short-circuits on nil.
    private struct OnePixelCGImageProvider: CGImageProviding {
        func cgImage(for asset: PHAsset) async -> CGImage? {
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let ctx = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 1,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            return ctx.makeImage()
        }
    }

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return container.mainContext
    }

    private func makeIndexer(
        context: ModelContext,
        embedder: SlowFakeEmbedder
    ) -> EmbeddingIndexer {
        EmbeddingIndexer(
            context: context,
            embedder: embedder,
            modelStore: ModelStore(),
            variant: .bundledDefault,
            cgImageProvider: OnePixelCGImageProvider(),
            // Bypass the SwiftData fetch that SIGTRAPs on iOS 26 in-memory
            // contexts (N-7). The empty set means every asset in `pending`
            // will be embedded.
            alreadyIndexedAssetIDs: { _ in [] }
        )
    }

    private func assets(prefix: String, count: Int) -> [PHAsset] {
        (0..<count).map { StubPHAsset(localIdentifier: "\(prefix)-\($0)") }
    }

    // MARK: - Test 1: cancelAndWait waits for the in-flight embed

    /// Locks in PR #26: `cancelAndWait()` must not return until the embed
    /// call that was already awaiting at the moment of cancellation has
    /// completed. Otherwise the trailing `context.save()` from the cancelled
    /// run can race a freshly-built replacement indexer over the same context.
    func testCancelAndWaitReturnsOnlyAfterInFlightEmbedCompletes() async throws {
        let context = try makeContext()
        let embedder = SlowFakeEmbedder(sleepMilliseconds: 50)
        let indexer = makeIndexer(context: context, embedder: embedder)

        // Kick off indexing on 8 assets — at 50ms each that's ~400ms of work,
        // wide enough to land a cancel mid-flight without flakiness.
        let firstBatch = assets(prefix: "first", count: 8)
        let indexingTask = Task { await indexer.index(assets: firstBatch) }

        // Wait until at least one embed has completed so we know the loop is
        // genuinely mid-flight and an embed is awaiting on `Task.sleep`.
        try await waitUntil(timeout: 2.0) {
            await embedder.completedEmbedCount >= 1
        }

        XCTAssertTrue(indexer.isIndexing, "Indexer should be running mid-flight")
        let inFlightAtCancel = await embedder.inFlightEmbedCount
        XCTAssertEqual(
            inFlightAtCancel, 1,
            "Exactly one embed should be awaiting when cancel lands"
        )
        let completedAtCancel = await embedder.completedEmbedCount

        // Request cancel + await — must not return until the awaiting embed
        // has resumed and completed.
        await indexer.cancelAndWait()

        let inFlightAfter = await embedder.inFlightEmbedCount
        let completedAfter = await embedder.completedEmbedCount

        XCTAssertEqual(
            inFlightAfter, 0,
            "cancelAndWait() must not return while an embed is still in flight"
        )
        XCTAssertGreaterThanOrEqual(
            completedAfter, completedAtCancel,
            "The embed awaiting at cancel time must have completed before cancelAndWait() returned"
        )
        XCTAssertLessThan(
            completedAfter, firstBatch.count,
            "Cancel must have short-circuited the loop — not every asset should have been embedded"
        )
        XCTAssertFalse(
            indexer.isIndexing,
            "After cancelAndWait() the indexer must report idle so the orchestrator can swap contexts"
        )

        // The Task that wraps `index(assets:)` should now be complete.
        await indexingTask.value
    }

    // MARK: - Test 2: second run starts from fresh counters

    /// Locks in PR #26 / the `currentTask` rebuild contract: after
    /// `cancelAndWait()`, the next `index(assets:)` call must NOT inherit
    /// counters or queue state from the prior run. Production rebuilds the
    /// `EmbeddingIndexer` instance entirely on variant switch — this test
    /// covers the in-instance equivalent because the same `cancelAndWait()`
    /// guarantee underpins both.
    func testSecondIndexRunAfterCancelStartsWithFreshCounters() async throws {
        let context = try makeContext()
        let embedder = SlowFakeEmbedder(sleepMilliseconds: 50)
        let indexer = makeIndexer(context: context, embedder: embedder)

        // First run — 8 assets, cancel mid-flight.
        let firstBatch = assets(prefix: "first", count: 8)
        let firstTask = Task { await indexer.index(assets: firstBatch) }
        try await waitUntil(timeout: 2.0) {
            await embedder.completedEmbedCount >= 1
        }
        await indexer.cancelAndWait()
        await firstTask.value

        let indexedAfterFirstRun = indexer.indexed
        let totalAfterFirstRun = indexer.total
        XCTAssertGreaterThan(
            totalAfterFirstRun, 0,
            "First run should have set total to the size of its pending list"
        )
        XCTAssertLessThan(
            indexedAfterFirstRun, firstBatch.count,
            "First run should have been cancelled before completing all assets"
        )

        // Second run — DIFFERENT, smaller set. Counters must reset to that
        // set's size, not inherit `total = 8` or `indexed = N` from before.
        let secondBatch = assets(prefix: "second", count: 3)
        await indexer.index(assets: secondBatch)

        XCTAssertEqual(
            indexer.total, secondBatch.count,
            "Second run's total must reflect the new batch size, not leak the first run's total"
        )
        XCTAssertEqual(
            indexer.indexed, secondBatch.count,
            "Second run should have embedded every asset in its (smaller) batch"
        )
        XCTAssertFalse(indexer.isIndexing, "Second run must report idle on completion")
    }

    // MARK: - Polling helper

    /// Polls `condition` every 10ms up to `timeout` seconds. Fails the test if
    /// the timeout elapses. Used instead of fixed `Task.sleep` to keep the
    /// suite fast and non-flaky under load.
    private func waitUntil(
        timeout: TimeInterval,
        file: StaticString = #file,
        line: UInt = #line,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }
}
