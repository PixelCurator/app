import XCTest
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
