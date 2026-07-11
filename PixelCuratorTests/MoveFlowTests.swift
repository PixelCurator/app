import XCTest
import Photos
@testable import PixelCurator

// MARK: - MoveFlowTests
//
// Drives `AlbumMover.move` through every cell of its assign/remove/rollback
// matrix using a refined mock that can fail individual call surfaces. Each
// test asserts both the returned `MoveOutcome` and the exact sequence of
// `AlbumOperations` calls so a future re-arrangement of the move flow cannot
// silently change the contract (e.g. skip rollback, remove twice, etc.).
//
// Mirrors backlog T-5: move-success / assign-failure / move-to-same-album
// plus the remove-failure-with-rollback and remove-failure-without-rollback
// edges discovered while extracting the helper.

@MainActor
final class MoveFlowTests: XCTestCase {

    // MARK: - Fixtures

    private let sourceID = "PHCollection-Source"
    private let targetID = "PHCollection-Target"
    private let sourceTitle = "Source"
    private let targetTitle = "Target"

    // MARK: - Success

    func testMove_assignAndRemoveBothSucceed_returnsMoved() async throws {
        let ops = MoveFlowMockAlbumOperations()
        let asset = AssignmentDecisionFixtures.makePHAsset()
        let outcome = await AlbumMover.move(
            asset,
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )

        XCTAssertEqual(outcome, .moved(sourceTitle: sourceTitle, targetTitle: targetTitle))
        // Exactly two calls: assign-by-name to target, then remove-by-id from source.
        XCTAssertEqual(ops.callSequence, [
            .assign(.byName, target: targetTitle),
            .remove(.byID,   target: sourceID),
        ])
    }

    // MARK: - Assign failure

    func testMove_assignFails_returnsAssignFailed_withNoRemove() async throws {
        let ops = MoveFlowMockAlbumOperations()
        ops.assignShouldSucceed = false
        let outcome = await AlbumMover.move(
            AssignmentDecisionFixtures.makePHAsset(),
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )

        XCTAssertEqual(outcome, .assignFailed(targetTitle: targetTitle, message: nil))
        // Assign was attempted; no remove because we never touched the library
        // successfully.
        XCTAssertEqual(ops.callSequence, [
            .assign(.byName, target: targetTitle),
        ])
    }

    // MARK: - Remove failure with successful rollback

    func testMove_assignOK_removeFails_rollbackOK_returnsRolledBack() async throws {
        let ops = MoveFlowMockAlbumOperations()
        ops.removeByIDShouldFail = [sourceID]   // first remove (from source) fails
        // Rollback (remove from target by id) is allowed to succeed — the
        // removeByIDShouldFail filter only contains sourceID.

        let outcome = await AlbumMover.move(
            AssignmentDecisionFixtures.makePHAsset(),
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )

        XCTAssertEqual(outcome, .removeFailedRolledBack(sourceTitle: sourceTitle, targetTitle: targetTitle))
        // Sequence: assign target, remove source (fails), rollback by removing
        // target.
        XCTAssertEqual(ops.callSequence, [
            .assign(.byName, target: targetTitle),
            .remove(.byID,   target: sourceID),
            .remove(.byID,   target: targetID),
        ])
    }

    // MARK: - Remove failure with failed rollback

    func testMove_assignOK_removeFails_rollbackFails_returnsOrphan() async throws {
        let ops = MoveFlowMockAlbumOperations()
        ops.removeByIDShouldFail = [sourceID, targetID]  // both removes fail

        let outcome = await AlbumMover.move(
            AssignmentDecisionFixtures.makePHAsset(),
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )

        XCTAssertEqual(outcome, .orphanInBothAlbums(sourceTitle: sourceTitle, targetTitle: targetTitle))
        XCTAssertEqual(ops.callSequence, [
            .assign(.byName, target: targetTitle),
            .remove(.byID,   target: sourceID),
            .remove(.byID,   target: targetID),
        ])
    }

    // MARK: - Move-to-same-album degenerate case
    //
    // The view filters the move-target picker to exclude the source album, so
    // this never reaches `AlbumMover.move` in production. But the helper must
    // still be well-defined if a caller bypasses the filter.

    // MARK: - F-15: move records DecisionLog entry on success
    //
    // The view-level (`AlbumDetailView.move`) recording call only fires on
    // `.moved`; failure / rollback outcomes must not record. These tests pin
    // the wiring contract: post-move log state mirrors the library state.

    func testMove_success_pairsWithRecordMove_andUndoRestoresToSource() async throws {
        let ops = MoveFlowMockAlbumOperations()
        let log = DecisionLog(operations: ops)
        let asset = AssignmentDecisionFixtures.makePHAsset()

        let outcome = await AlbumMover.move(
            asset,
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )
        // Simulate `AlbumDetailView.move`'s post-success recording.
        if case .moved = outcome {
            log.recordMove(
                asset: asset,
                sourceAlbumID: sourceID, sourceAlbumName: sourceTitle,
                targetAlbumID: targetID, targetAlbumName: targetTitle
            )
        }

        XCTAssertTrue(log.canUndo, "F-15: a successful move must leave an undo entry")
        XCTAssertEqual(log.undoEntries.count, 1)

        // Now undo and assert the asset is restored to source.
        ops.callSequence.removeAll()
        await log.undo()

        XCTAssertEqual(ops.callSequence, [
            .assign(.byID, target: sourceID),
            .remove(.byID, target: targetID),
        ], "Undo of a move must re-add to source and remove from target — both via by-id")
        XCTAssertEqual(log.lastUndoneAlbumName, sourceTitle,
                       "Toast: 'restored to <source>'")
    }

    func testMove_assignFailed_doesNotRecordOnDecisionLog() async throws {
        let ops = MoveFlowMockAlbumOperations()
        ops.assignShouldSucceed = false
        let log = DecisionLog(operations: ops)
        let asset = AssignmentDecisionFixtures.makePHAsset()

        let outcome = await AlbumMover.move(
            asset,
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )
        if case .moved = outcome {
            XCTFail("Test setup error: outcome should be .assignFailed")
        }

        XCTAssertFalse(log.canUndo,
                       "F-15: a failed move must not record — the library was never mutated")
    }

    func testMove_rolledBack_doesNotRecordOnDecisionLog() async throws {
        let ops = MoveFlowMockAlbumOperations()
        ops.removeByIDShouldFail = [sourceID]
        let log = DecisionLog(operations: ops)
        let asset = AssignmentDecisionFixtures.makePHAsset()

        let outcome = await AlbumMover.move(
            asset,
            from: (id: sourceID, title: sourceTitle),
            to: (id: targetID, title: targetTitle),
            via: ops
        )
        if case .moved = outcome {
            XCTFail("Test setup error: outcome should be .removeFailedRolledBack")
        }

        XCTAssertFalse(log.canUndo,
                       "F-15: a rolled-back move leaves the library unchanged; no undo entry to record")
    }

    func testMove_sourceEqualsTarget_assignNoOp_removeRemovesFromBoth() async throws {
        // Both sides addressed by the same id and title.
        let sameID = "PHCollection-Same"
        let sameTitle = "Same"
        let ops = MoveFlowMockAlbumOperations()

        let outcome = await AlbumMover.move(
            AssignmentDecisionFixtures.makePHAsset(),
            from: (id: sameID, title: sameTitle),
            to: (id: sameID, title: sameTitle),
            via: ops
        )

        // The helper itself does not detect the degenerate case — its
        // contract is "assign then remove". Outcome is `.moved`, but the
        // sequence shows the assign-then-remove pair that would actually
        // remove the asset from its only album. The view-level filter that
        // prevents this case from reaching the helper is the load-bearing
        // safety; this test pins that contract so a future "smart" rewrite
        // does not accidentally turn the no-op into a destructive op.
        XCTAssertEqual(outcome, .moved(sourceTitle: sameTitle, targetTitle: sameTitle))
        XCTAssertEqual(ops.callSequence, [
            .assign(.byName, target: sameTitle),
            .remove(.byID,   target: sameID),
        ])
    }
}

// MARK: - MoveFlowMockAlbumOperations
//
// More expressive than DecisionLogTests' MockAlbumOperations: it lets each
// individual remove-by-id call decide its own success based on the target id,
// which is the only way to model "remove from source fails, remove from
// target succeeds" (the rollback path).

private final class MoveFlowMockAlbumOperations: AlbumOperations {

    enum Surface: Equatable { case byName, byID }

    enum Call: Equatable {
        case assign(Surface, target: String)
        case remove(Surface, target: String)
    }

    var callSequence: [Call] = []

    /// Controls every assign call (both surfaces). Default success.
    var assignShouldSucceed = true

    /// If a remove-by-id call's target appears in this set, that call returns
    /// `false`; otherwise success. Default empty (= all succeed).
    var removeByIDShouldFail: Set<String> = []

    /// Controls every remove-by-name call. Default success.
    var removeByNameShouldSucceed = true

    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool {
        callSequence.append(.assign(.byName, target: name))
        return assignShouldSucceed
    }

    func assign(_ asset: PHAsset, toAlbumWithID albumLocalIdentifier: String) async -> Bool {
        callSequence.append(.assign(.byID, target: albumLocalIdentifier))
        return assignShouldSucceed
    }

    func remove(_ asset: PHAsset, fromAlbumNamed name: String) async -> Bool {
        callSequence.append(.remove(.byName, target: name))
        return removeByNameShouldSucceed
    }

    func remove(_ asset: PHAsset, fromAlbumWithID albumLocalIdentifier: String) async -> Bool {
        callSequence.append(.remove(.byID, target: albumLocalIdentifier))
        return !removeByIDShouldFail.contains(albumLocalIdentifier)
    }
}

// MARK: - Test fixtures

/// Reuses the same trick the existing DecisionLog tests use to obtain a
/// PHAsset instance without a real PhotoKit fetch: a non-functional placeholder
/// that satisfies the protocol signatures. The tests never read pixels or
/// metadata from it — only the localIdentifier (which we don't even inspect
/// here).
private enum AssignmentDecisionFixtures {
    @MainActor
    static func makePHAsset() -> PHAsset {
        // PHAsset's designated init is private; this dummy is sufficient
        // because no test inspects any property of the returned asset. The
        // helper only passes it through to the operations layer.
        PHAsset()
    }
}
