import XCTest
import Photos
@testable import PixelCurator

// MARK: - DecisionLogUndoHintTests
//
// F-12. The DecisionLog must fire `onFirstDecisionRecorded` exactly once
// across the lifetime of the instance — only on the very first decision
// recorded, regardless of whether it is an assignment or a move, and never
// again (not on subsequent records, not on undo→redo cycles which also
// repopulate the undo stack via `pushUndo`).
//
// These tests use the same `MockAlbumOperations` / `StubPHAsset` helpers as
// the existing DecisionLogTests so the seam stays consistent.

@MainActor
final class DecisionLogUndoHintTests: XCTestCase {

    var mock: MockAlbumOperations!
    var log: DecisionLog!

    override func setUp() async throws {
        mock = MockAlbumOperations()
        log = DecisionLog(operations: mock)
    }

    // MARK: - Fires on first decision

    func testHookFiresOnFirstAssignmentRecord() {
        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-1")

        XCTAssertEqual(fireCount, 1, "Hook must fire on the very first record() call")
    }

    func testHookFiresOnFirstMoveRecord() {
        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.recordMove(
            asset: asset,
            sourceAlbumID: "src", sourceAlbumName: "Source",
            targetAlbumID: "tgt", targetAlbumName: "Target"
        )

        XCTAssertEqual(fireCount, 1, "Hook must also fire when the first decision is a move, not just an assignment")
    }

    // MARK: - Does NOT fire on subsequent decisions

    func testHookDoesNotFireOnSecondRecord() {
        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        log.record(asset: asset1, albumName: "Vacation", albumLocalIdentifier: "album-1")
        log.record(asset: asset2, albumName: "Family",   albumLocalIdentifier: "album-2")

        XCTAssertEqual(fireCount, 1,
                       "Hook must fire exactly once — second record must not re-trigger it")
    }

    func testHookDoesNotFireOnManyMixedDecisions() {
        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-1")
        log.recordMove(
            asset: asset,
            sourceAlbumID: "src", sourceAlbumName: "S",
            targetAlbumID: "tgt", targetAlbumName: "T"
        )
        log.record(asset: asset, albumName: "Family", albumLocalIdentifier: "album-2")

        XCTAssertEqual(fireCount, 1,
                       "Hook must remain one-shot across assignment + move + assignment sequence")
    }

    // MARK: - Undo/redo cycles must not re-fire

    func testUndoThenRedoDoesNotReFireHook() async {
        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-1")
        XCTAssertEqual(fireCount, 1)

        // Undo moves the decision to the redo stack and clears the undo stack.
        // Redo then pushes it back onto the undo stack via `pushUndo` — not
        // via `record` — so the hook must not fire on the redo round-trip.
        await log.undo()
        await log.redo()

        XCTAssertEqual(fireCount, 1,
                       "Undo/redo round-trips repopulate the undo stack but must not re-fire the hint")
    }

    // MARK: - No subscriber == no crash

    func testRecordWithoutHookInstalledDoesNotCrash() {
        // Default is `nil`; the record path must tolerate that without
        // crashing — `?.()` on the optional closure.
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-1")
        // If we reached this line without a trap, the optional invocation
        // path is correct.
        XCTAssertTrue(log.canUndo)
    }

    // MARK: - Late-installed hook is silent

    func testInstallingHookAfterFirstRecordDoesNotFireRetroactively() {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-1")
        // First decision already happened with no subscriber.

        var fireCount = 0
        log.onFirstDecisionRecorded = { fireCount += 1 }

        // Subsequent record must NOT fire the hook — the "first" already
        // happened, the gate is latched closed.
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        log.record(asset: asset2, albumName: "Family", albumLocalIdentifier: "album-2")

        XCTAssertEqual(fireCount, 0,
                       "Installing the hook after the first record must not retroactively fire it — the gate has already latched")
    }
}
