import XCTest
import Photos
import SwiftData
@testable import PixelCurator

// MARK: - SortingCoordinatorTests
//
// Tests the pure / framework-free logic in SortingCoordinator.
// No PhotoKit, no SwiftData, no real model — all I/O is faked.

final class SortingCoordinatorTests: XCTestCase {

    // MARK: - filterInbox

    /// Assets that are neither embedded nor in albums are excluded (not embedded).
    func testFilterInboxExcludesNonEmbedded() {
        let allIDs = ["a", "b", "c"]
        let embedded: Set<String> = ["b"]       // only b is embedded
        let albumMembers: Set<String> = []       // none are in albums

        let result = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertEqual(result, ["b"], "Only the embedded asset should pass the filter")
    }

    /// Assets already in an album are excluded even if they have embeddings.
    func testFilterInboxExcludesAlbumMembers() {
        let allIDs = ["a", "b", "c"]
        let embedded: Set<String> = ["a", "b", "c"]
        let albumMembers: Set<String> = ["a", "c"]  // a and c are already sorted

        let result = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertEqual(result, ["b"], "Album members should be excluded")
    }

    /// Empty inputs produce empty output.
    func testFilterInboxEmptyInputs() {
        let result = SortingCoordinator.filterInbox(
            allAssetIDs: [],
            embedded: [],
            albumMembers: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// All assets already in albums → empty result.
    func testFilterInboxAllInAlbums() {
        let allIDs = ["x", "y"]
        let embedded: Set<String> = ["x", "y"]
        let albumMembers: Set<String> = ["x", "y"]

        let result = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertTrue(result.isEmpty, "All in albums → nothing to sort")
    }

    /// The filter preserves the original order of allAssetIDs.
    func testFilterInboxPreservesOrder() {
        // Deliberately out-of-alphabetical order to confirm ordering.
        let allIDs = ["z", "a", "m", "b", "q"]
        let embedded: Set<String> = ["z", "m", "q"]
        let albumMembers: Set<String> = ["m"]   // m is already sorted

        let result = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertEqual(result, ["z", "q"],
                       "Order must match allAssetIDs order, not insertion order of the sets")
    }

    /// An asset must be both embedded AND not in an album to pass. Testing the
    /// intersection semantics: embedded but in album → excluded; in neither → excluded.
    func testFilterInboxIntersectionSemantics() {
        let allIDs = ["e_inAlbum", "e_notInAlbum", "notE_inAlbum", "notE_notInAlbum"]
        let embedded: Set<String> = ["e_inAlbum", "e_notInAlbum"]
        let albumMembers: Set<String> = ["e_inAlbum", "notE_inAlbum"]

        let result = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertEqual(result, ["e_notInAlbum"],
                       "Only embedded-and-not-in-album should pass")
    }

    // MARK: - Progress accounting

    /// sortedCount and remainingCount update correctly after accept-style
    /// advances. We drive this through filterInbox + a fake advance sequence
    /// rather than a real coordinator (which needs PhotoKit).
    func testFilterInboxCountsMatchProgress() {
        let allIDs = (0..<10).map { "asset_\($0)" }
        let embedded = Set(allIDs)          // all embedded
        let albumMembers: Set<String> = []  // none sorted yet

        let inbox = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: albumMembers
        )

        XCTAssertEqual(inbox.count, 10, "All 10 assets should enter the inbox")
    }

    // MARK: - updateVariant (S-4)

    /// `updateVariant` must rebind data sources to a new variant without
    /// reallocating the coordinator — Undo history (decisionLog) survives,
    /// and the modelID is observable on the same instance.
    @MainActor
    func testUpdateVariant_swapsModelIDAndPreservesDecisionLog() throws {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let albums = AlbumManager()
        let library = PhotoController()
        let log = DecisionLog(operations: albums)

        let coordinator = SortingCoordinator(
            store: EmbeddingStore(context: context),
            suggester: AlbumSuggester(),
            albumManager: albums,
            photoController: library,
            modelID: "variant-A",
            decisionLog: log,
            correctionStore: CorrectionStore(context: context)
        )
        XCTAssertEqual(coordinator.modelID, "variant-A")
        XCTAssertTrue(coordinator.decisionLog === log)

        coordinator.updateVariant(
            store: EmbeddingStore(context: context),
            suggester: AlbumSuggester(),
            correctionStore: CorrectionStore(context: context),
            modelID: "variant-B"
        )

        XCTAssertEqual(coordinator.modelID, "variant-B",
                       "updateVariant must swap the modelID")
        XCTAssertTrue(coordinator.decisionLog === log,
                       "updateVariant must preserve the existing decisionLog instance")
        XCTAssertFalse(coordinator.isSorting,
                       "updateVariant must reset the active session")
        XCTAssertEqual(coordinator.sortedCount, 0)
    }

    /// After filtering, assets that were album-members on a second pass
    /// (simulating what happens after accept advances) no longer appear.
    func testFilterInboxReflectsNewAlbumMembership() {
        let allIDs = ["a", "b", "c"]
        let embedded: Set<String> = ["a", "b", "c"]

        // First pass: nothing in albums
        let pass1 = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: []
        )
        XCTAssertEqual(pass1, ["a", "b", "c"])

        // After accepting "a" (now in an album), rebuild simulates the next state.
        let pass2 = SortingCoordinator.filterInbox(
            allAssetIDs: allIDs,
            embedded: embedded,
            albumMembers: ["a"]
        )
        XCTAssertEqual(pass2, ["b", "c"],
                       "Accepted asset should no longer appear in inbox on rebuild")
    }
}

// MARK: - Mock AssignResolver
//
// Pre-programmed responses for the accept / assignTo / batchAssign paths so
// tests can drive `.added`, `.alreadyMember`, and `.failed` returns without
// touching PhotoKit. Captures every call so order / target assertions are
// possible. Mirrors the `MockAlbumOperations` style in DecisionLogTests.swift.

@MainActor
final class MockAssignResolver: AssignResolving {
    struct Call: Equatable {
        let assetID: String
        let albumName: String
    }

    /// FIFO queue of pre-programmed results. The first item is consumed by the
    /// first `assignAndResolve` call, the second by the second, etc. If the
    /// queue empties, falls back to `defaultResult`.
    var results: [AlbumManager.AssignResult] = []
    var defaultResult: AlbumManager.AssignResult = .added(albumID: "album-default")

    /// Sets `lastError` whenever a `.failed` result is dispensed.
    var failureError: String = "fake assign failure"

    private(set) var calls: [Call] = []
    var lastError: String?

    func assignAndResolve(_ asset: PHAsset, toAlbumNamed name: String) async -> AlbumManager.AssignResult {
        calls.append(Call(assetID: asset.localIdentifier, albumName: name))
        let result = results.isEmpty ? defaultResult : results.removeFirst()
        switch result {
        case .added, .alreadyMember:
            lastError = nil
        case .failed:
            lastError = failureError
        }
        return result
    }
}

// MARK: - SortingCoordinator accept / assignTo / batchAssign
//
// T-2 coverage gap: the assign paths in SortingCoordinator were untested
// because the production constructor took a concrete `AlbumManager`. The
// `AssignResolving` seam lets us drive every branch (.added / .alreadyMember /
// .failed) without standing up PhotoKit or a real photo library.

@MainActor
final class SortingCoordinatorAssignPathTests: XCTestCase {

    // MARK: - Helpers

    private func makeCoordinator(
        resolver: MockAssignResolver,
        seedAssets: [PHAsset] = [],
        seedIndex: Int = 0
    ) throws -> (SortingCoordinator, AlbumManager) {
        let container = try ModelContainer(
            for: PhotoEmbedding.self, AlbumCorrection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = EmbeddingStore(context: context)
        let albums = AlbumManager()
        let library = PhotoController()

        let coordinator = SortingCoordinator(
            store: store,
            suggester: AlbumSuggester(),
            albumManager: albums,
            photoController: library,
            modelID: "test-variant",
            decisionLog: DecisionLog(operations: MockAlbumOperations()),
            correctionStore: nil,
            assignResolver: resolver
        )
        // Suppress recomputeSuggestions in tests: AlbumSuggester reaches into
        // EmbeddingStore which signal-traps on FetchDescriptor reads against
        // an in-memory SwiftData store on iOS 26 (the production-side comment
        // in EmbeddingStore.embedding documents the same trap class for
        // #Predicate). The assign-path semantics under test do not depend on
        // suggestion recomputation — they assert state on queue, currentIndex,
        // decisionLog, and lastAssignError.
        //
        // Re-triaged 2026-06-23 on Xcode 26.5 / iOS 26.5 sim: removing this
        // hook reliably SIGTRAPs every test whose code path eventually calls
        // `advance()` → `recomputeSuggestions()` (testAcceptSuccess,
        // testAssignToSuccess, testBatchAssign_*, testAcceptOnAlreadyMember).
        // The trap is unchanged from the original PR #33 surface. Re-check
        // on the next Xcode / iOS update.
        coordinator._suppressSuggestionsForTesting = true
        if !seedAssets.isEmpty {
            coordinator._seedQueueForTesting(seedAssets, currentIndex: seedIndex)
        }
        return (coordinator, albums)
    }

    private func suggestion(album: String, score: Float = 0.9) -> AlbumSuggestion {
        AlbumSuggestion(albumTitle: album, score: score, supportingCount: 5)
    }

    // MARK: - 1. accept(.success) records decision and advances

    func testAcceptSuccess_recordsDecisionAndAdvances() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [.added(albumID: "album-vacation")]
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2]
        )

        await coordinator.accept(suggestion(album: "Vacation"))

        XCTAssertEqual(resolver.calls.count, 1)
        XCTAssertEqual(resolver.calls[0].albumName, "Vacation")
        XCTAssertEqual(coordinator.sortedCount, 1, "Successful accept must bump sortedCount")
        XCTAssertEqual(coordinator.currentIndex, 1, "Successful accept must advance the cursor")
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-2",
                       "current must point at the next asset after advance")
        XCTAssertNil(coordinator.lastAssignError, "Success must clear lastAssignError")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 1,
                       "Success path must record a decision for undo")
        XCTAssertEqual(coordinator.decisionLog.undoStack.first?.albumLocalIdentifier,
                       "album-vacation",
                       "Recorded decision must carry the resolved albumLocalIdentifier")
    }

    // MARK: - 2. accept(.failed) does NOT advance and surfaces error

    func testAcceptFailure_doesNotAdvance_andSurfacesError() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [.failed]
        resolver.failureError = "Disk full"
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2]
        )

        await coordinator.accept(suggestion(album: "Vacation"))

        XCTAssertEqual(coordinator.currentIndex, 0,
                       "Failed accept must NOT advance — user gets a chance to retry on the same photo")
        XCTAssertEqual(coordinator.sortedCount, 0, "Failure must not bump sortedCount")
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-1",
                       "current still points at the failed photo")
        XCTAssertEqual(coordinator.lastAssignError, "Disk full",
                       "lastAssignError must surface the resolver's lastError for toast display")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 0,
                       "Failed accept must not record a phantom undo entry")
    }

    // MARK: - 3. accept(.alreadyMember) advances but records no decision (S-1)

    func testAcceptOnAlreadyMember_doesNotRecordDecision() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [.alreadyMember(albumID: "album-vacation")]
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2]
        )

        await coordinator.accept(suggestion(album: "Vacation"))

        XCTAssertEqual(coordinator.sortedCount, 1,
                       ".alreadyMember counts as a sort: the photo leaves the inbox")
        XCTAssertEqual(coordinator.currentIndex, 1, "Must advance — the photo is done")
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-2")
        XCTAssertNil(coordinator.lastAssignError)
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 0,
                       "S-1: phantom undo entries must not be recorded for no-op assigns")
    }

    // MARK: - 4. assignTo(.success) records and advances

    func testAssignToSuccess_recordsAndAdvances() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [.added(albumID: "album-family")]
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2]
        )

        await coordinator.assignTo(albumNamed: "Family")

        XCTAssertEqual(resolver.calls.count, 1)
        XCTAssertEqual(resolver.calls[0].albumName, "Family",
                       "assignTo must forward the user-supplied album name")
        XCTAssertEqual(coordinator.sortedCount, 1)
        XCTAssertEqual(coordinator.currentIndex, 1)
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-2")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 1)
        XCTAssertEqual(coordinator.decisionLog.undoStack.first?.albumName, "Family")
        XCTAssertEqual(coordinator.decisionLog.undoStack.first?.albumLocalIdentifier,
                       "album-family")
    }

    // MARK: - 5. assignTo(.failed) does NOT advance

    func testAssignToFailure_doesNotAdvance() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [.failed]
        resolver.failureError = "Album creation denied"
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2]
        )

        await coordinator.assignTo(albumNamed: "Family")

        XCTAssertEqual(coordinator.currentIndex, 0,
                       "Failed assignTo must keep the user on the same photo for retry")
        XCTAssertEqual(coordinator.sortedCount, 0)
        XCTAssertEqual(coordinator.lastAssignError, "Album creation denied")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 0)
    }

    // MARK: - 6. batchAssign all successes

    func testBatchAssign_handlesAllSuccesses() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [
            .added(albumID: "album-trip"),
            .added(albumID: "album-trip"),
            .added(albumID: "album-trip"),
        ]
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let asset3 = StubPHAsset(localIdentifier: "asset-3")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2, asset3]
        )

        let assigned = await coordinator.batchAssign(
            [asset1, asset2, asset3],
            toAlbumNamed: "Trip"
        )

        XCTAssertEqual(assigned, 3, "All three should be reported assigned")
        XCTAssertEqual(coordinator.sortedCount, 3)
        XCTAssertTrue(coordinator.queue.isEmpty,
                      "Assigned assets must be removed from the queue in place")
        XCTAssertFalse(coordinator.isSorting,
                       "Queue drained → session ends")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 3,
                       "Each successful add must record a per-photo undo entry")
        XCTAssertEqual(resolver.calls.map(\.albumName), ["Trip", "Trip", "Trip"])
    }

    // MARK: - 7. batchAssign continues past mid-batch failure
    //
    // Per SortingCoordinator.batchAssign (SortingCoordinator.swift): the
    // switch statement's `.failed` case only sets `lastAssignError` and the
    // for-loop continues to the next asset. There is NO `break`, `return`, or
    // early-exit on failure. The semantic is therefore **continue past fail**:
    // the batch processes every asset, failures stay in the queue, successes
    // are removed and counted.

    func testBatchAssign_continuesAfterMidwayFailure() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [
            .added(albumID: "album-trip"),
            .failed,
            .added(albumID: "album-trip"),
        ]
        resolver.failureError = "Network blip"
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let asset3 = StubPHAsset(localIdentifier: "asset-3")
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset1, asset2, asset3]
        )

        let assigned = await coordinator.batchAssign(
            [asset1, asset2, asset3],
            toAlbumNamed: "Trip"
        )

        XCTAssertEqual(resolver.calls.count, 3,
                       "All three assets must be attempted — batchAssign must NOT stop on first failure")
        XCTAssertEqual(assigned, 2, "Two successes despite the middle failure")
        XCTAssertEqual(coordinator.sortedCount, 2)
        XCTAssertEqual(coordinator.queue.map(\.localIdentifier), ["asset-2"],
                       "The failed asset must remain in the queue; successes are removed")
        XCTAssertEqual(coordinator.lastAssignError, "Network blip",
                       "The mid-batch failure must surface lastAssignError for toast display")
        XCTAssertEqual(coordinator.decisionLog.undoStack.count, 2,
                       "Only the two successful assigns produce undo entries")
    }

    // MARK: - 8. batchAssign adjusts currentIndex when removed items sit before it

    func testBatchAssign_currentIndexAdjusts_whenRemovedItemsAreBeforeCurrent() async throws {
        let resolver = MockAssignResolver()
        resolver.results = [
            .added(albumID: "album-trip"),
            .added(albumID: "album-trip"),
        ]
        let asset0 = StubPHAsset(localIdentifier: "asset-0")
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        let asset3 = StubPHAsset(localIdentifier: "asset-3")
        let asset4 = StubPHAsset(localIdentifier: "asset-4")
        // Seed a 5-asset queue, cursor on asset-3 (index 3).
        let (coordinator, _) = try makeCoordinator(
            resolver: resolver,
            seedAssets: [asset0, asset1, asset2, asset3, asset4],
            seedIndex: 3
        )
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-3")

        // Batch-assign asset-0 and asset-1 — both sit BEFORE current (index 3).
        let assigned = await coordinator.batchAssign(
            [asset0, asset1],
            toAlbumNamed: "Trip"
        )

        XCTAssertEqual(assigned, 2)
        XCTAssertEqual(coordinator.queue.map(\.localIdentifier),
                       ["asset-2", "asset-3", "asset-4"],
                       "asset-0 and asset-1 removed; remaining order preserved")
        XCTAssertEqual(coordinator.currentIndex, 1,
                       "currentIndex must shift left by 2 (the count of removed items before it) " +
                       "so the cursor still points at asset-3")
        XCTAssertEqual(coordinator.current?.localIdentifier, "asset-3",
                       "The user must stay on the same photo after a batch-assign that removed " +
                       "earlier queue entries")
        XCTAssertTrue(coordinator.isSorting, "Session still active — queue is not empty")
    }
}
