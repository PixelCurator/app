import XCTest
@testable import PixelCurator

// MARK: - DecisionLogTests
//
// Tests the undo/redo stack mechanics of UndoRedoStack (pure) and DecisionLog
// (with a mock AlbumOperations). No PHPhotoLibrary is touched.

// MARK: - UndoRedoStack (pure mechanics)

final class UndoRedoStackTests: XCTestCase {

    // MARK: - Initial state

    func testInitiallyEmpty() {
        let stack = UndoRedoStack<String>()
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertTrue(stack.undoStack.isEmpty)
        XCTAssertTrue(stack.redoStack.isEmpty)
    }

    // MARK: - record

    func testRecordPushesOntoUndoStack() {
        var stack = UndoRedoStack<String>()
        stack.record("a")
        XCTAssertEqual(stack.undoStack, ["a"])
        XCTAssertTrue(stack.canUndo)
    }

    func testRecordClearsRedoStack() {
        var stack = UndoRedoStack<String>()
        stack.record("a")
        let _ = stack.popUndo()  // move "a" to potential redo candidate manually
        stack.pushRedo("a")
        XCTAssertTrue(stack.canRedo)

        // Recording a new entry must clear redo.
        stack.record("b")
        XCTAssertFalse(stack.canRedo, "New record must clear the redo stack")
    }

    func testRecordMultiplePreservesOrder() {
        var stack = UndoRedoStack<Int>()
        stack.record(1)
        stack.record(2)
        stack.record(3)
        XCTAssertEqual(stack.undoStack, [1, 2, 3])
    }

    // MARK: - popUndo / pushRedo

    func testPopUndoReturnsLastEntry() {
        var stack = UndoRedoStack<String>()
        stack.record("x")
        stack.record("y")
        let popped = stack.popUndo()
        XCTAssertEqual(popped, "y")
        XCTAssertEqual(stack.undoStack, ["x"])
    }

    func testPopUndoOnEmptyReturnsNil() {
        var stack = UndoRedoStack<String>()
        XCTAssertNil(stack.popUndo())
    }

    func testPushRedoAndCanRedo() {
        var stack = UndoRedoStack<String>()
        stack.pushRedo("z")
        XCTAssertTrue(stack.canRedo)
        XCTAssertEqual(stack.redoStack, ["z"])
    }

    // MARK: - popRedo / pushUndo

    func testPopRedoReturnsLastEntry() {
        var stack = UndoRedoStack<String>()
        stack.pushRedo("p")
        stack.pushRedo("q")
        let popped = stack.popRedo()
        XCTAssertEqual(popped, "q")
        XCTAssertEqual(stack.redoStack, ["p"])
    }

    func testPopRedoOnEmptyReturnsNil() {
        var stack = UndoRedoStack<String>()
        XCTAssertNil(stack.popRedo())
    }

    func testPushUndoAfterRedo() {
        var stack = UndoRedoStack<String>()
        stack.pushUndo("reapplied")
        XCTAssertEqual(stack.undoStack, ["reapplied"])
        XCTAssertTrue(stack.canUndo)
    }

    // MARK: - Full round-trip sequence

    func testUndoRedoRoundTrip() {
        // record a, b → undo b → redo b
        var stack = UndoRedoStack<String>()
        stack.record("a")
        stack.record("b")

        // Simulate undo of "b": pop from undo, push to redo
        let undone = stack.popUndo()
        XCTAssertEqual(undone, "b")
        stack.pushRedo(undone!)

        XCTAssertEqual(stack.undoStack, ["a"])
        XCTAssertEqual(stack.redoStack, ["b"])
        XCTAssertTrue(stack.canUndo)
        XCTAssertTrue(stack.canRedo)

        // Simulate redo of "b": pop from redo, push to undo
        let redone = stack.popRedo()
        XCTAssertEqual(redone, "b")
        stack.pushUndo(redone!)

        XCTAssertEqual(stack.undoStack, ["a", "b"])
        XCTAssertTrue(stack.redoStack.isEmpty)
    }
}

// MARK: - Mock AlbumOperations

import Photos

/// Records calls without touching PhotoKit.
///
/// Each call captures the routing surface (`byName` vs `byID`) so tests can
/// assert that DecisionLog actually routes through the duplicate-name-safe
/// by-id path when the decision carries a `localIdentifier`.
final class MockAlbumOperations: AlbumOperations {
    struct Call: Equatable {
        enum Kind { case assign, remove }
        enum Surface { case byName, byID }
        let kind: Kind
        let surface: Surface
        let assetID: String
        /// Album title (when `surface == .byName`) or `PHAssetCollection.localIdentifier`
        /// (when `surface == .byID`).
        let target: String
    }

    var calls: [Call] = []
    var assignShouldSucceed = true
    var removeShouldSucceed = true

    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool {
        calls.append(Call(
            kind: .assign, surface: .byName,
            assetID: asset.localIdentifier, target: name
        ))
        return assignShouldSucceed
    }

    func assign(_ asset: PHAsset, toAlbumWithID albumLocalIdentifier: String) async -> Bool {
        calls.append(Call(
            kind: .assign, surface: .byID,
            assetID: asset.localIdentifier, target: albumLocalIdentifier
        ))
        return assignShouldSucceed
    }

    func remove(_ asset: PHAsset, fromAlbumNamed name: String) async -> Bool {
        calls.append(Call(
            kind: .remove, surface: .byName,
            assetID: asset.localIdentifier, target: name
        ))
        return removeShouldSucceed
    }

    func remove(_ asset: PHAsset, fromAlbumWithID albumLocalIdentifier: String) async -> Bool {
        calls.append(Call(
            kind: .remove, surface: .byID,
            assetID: asset.localIdentifier, target: albumLocalIdentifier
        ))
        return removeShouldSucceed
    }
}

// MARK: - DecisionLog stack mechanics (via string-keyed fake decisions)
//
// We can't construct a real PHAsset in unit tests (it requires PhotoKit
// infrastructure). DecisionLog's stack mechanics are therefore tested
// through the pure UndoRedoStack<String> above, plus smoke tests on
// DecisionLog's record/canUndo/canRedo properties using the same
// UndoRedoStack<AssignmentDecision> path.
//
// Because PHAsset is not constructable, the DecisionLog tests
// verify: (a) record→canUndo, (b) record clears redo, (c) canRedo
// transitions — all state that does NOT require calling assign/remove.

/// A `PHAsset` subclass that fakes only the bits DecisionLog cares about
/// (`localIdentifier`) without requiring a real PhotoKit fetch. Photos is
/// Objective-C-bridged so this Swift override works at runtime.
final class StubPHAsset: PHAsset {
    private let stubID: String
    init(localIdentifier: String) {
        self.stubID = localIdentifier
        super.init()
    }
    override var localIdentifier: String { stubID }
}

@MainActor
final class DecisionLogStateTests: XCTestCase {

    var mock: MockAlbumOperations!
    var log: DecisionLog!

    override func setUp() async throws {
        mock = MockAlbumOperations()
        log = DecisionLog(operations: mock)
    }

    // MARK: - Initial state

    func testInitiallyCannotUndoOrRedo() {
        XCTAssertFalse(log.canUndo)
        XCTAssertFalse(log.canRedo)
        XCTAssertTrue(log.undoStack.isEmpty)
        XCTAssertTrue(log.redoStack.isEmpty)
    }

    // MARK: - record

    func testRecordPushesOntoUndoStack() {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        XCTAssertTrue(log.canUndo)
        XCTAssertFalse(log.canRedo)
        XCTAssertEqual(log.undoStack.count, 1)
        XCTAssertEqual(log.undoStack.first?.albumName, "Vacation")
        XCTAssertEqual(log.undoStack.first?.albumLocalIdentifier, "album-id-1")
    }

    func testRecordClearsLastUndoneAndLastRedone() async {
        // Bring the log into a state where lastUndoneAlbumName is set,
        // then verify a new record() resets it.
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        XCTAssertEqual(log.lastUndoneAlbumName, "Vacation")

        log.record(asset: asset, albumName: "Family", albumLocalIdentifier: "album-id-2")
        XCTAssertNil(log.lastUndoneAlbumName, "Recording must reset lastUndoneAlbumName")
        XCTAssertNil(log.lastRedoneAlbumName)
    }
}

// MARK: - DecisionLog side-effect tests (T-1 gap)
//
// Drives the async undo/redo paths through the MockAlbumOperations seam to
// cover:
//   • by-id routing when albumLocalIdentifier is present, title fallback when not
//   • lastUndoneAlbumName / lastRedoneAlbumName transitions, including the
//     nil → value reset that drives the toast (DecisionLog.swift:140 / :160)
//   • rollback semantics on operation failure (the entry stays on its stack)
//   • duplicate-name regression: id, not title, decides which album is mutated

@MainActor
final class DecisionLogSideEffectTests: XCTestCase {

    var mock: MockAlbumOperations!
    var log: DecisionLog!

    override func setUp() async throws {
        mock = MockAlbumOperations()
        log = DecisionLog(operations: mock)
    }

    // MARK: - undo() success path

    func testUndoSuccess_movesEntryToRedoStackAndSetsLastUndoneAlbumName() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")

        await log.undo()

        XCTAssertFalse(log.canUndo)
        XCTAssertTrue(log.canRedo)
        XCTAssertEqual(log.redoStack.count, 1)
        XCTAssertEqual(log.lastUndoneAlbumName, "Vacation")
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].kind, .remove)
        XCTAssertEqual(mock.calls[0].surface, .byID)
        XCTAssertEqual(mock.calls[0].target, "album-id-1")
    }

    // MARK: - undo() failure path

    func testUndoFailure_keepsEntryOnUndoStack_andLeavesLastUndoneNil() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        mock.removeShouldSucceed = false

        await log.undo()

        XCTAssertTrue(log.canUndo, "Failed undo must roll the entry back onto the undo stack")
        XCTAssertFalse(log.canRedo)
        XCTAssertEqual(log.undoStack.count, 1)
        XCTAssertNil(log.lastUndoneAlbumName)
    }

    // MARK: - undo() toast trigger contract (DecisionLog.swift:140-149)

    func testTwoConsecutiveUndosToSameAlbumEachProduceNilThenValueTransition() async {
        // Two assignments to the SAME album. The second undo must still
        // produce an observable nil → "Vacation" transition for the toast,
        // even though the property value (Vacation) does not change.
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")
        log.record(asset: asset1, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        log.record(asset: asset2, albumName: "Vacation", albumLocalIdentifier: "album-id-1")

        await log.undo()
        XCTAssertEqual(log.lastUndoneAlbumName, "Vacation")

        // Spy on the transition by instrumenting the mock to capture the
        // value of lastUndoneAlbumName the instant the underlying operation
        // is invoked — at that point DecisionLog must have reset it to nil.
        var observedDuringRemoveCall: String? = "<not set>"
        let spy = TransitionSpyAlbumOperations { [weak self] in
            observedDuringRemoveCall = self?.log.lastUndoneAlbumName
        }
        log = DecisionLog(operations: spy)
        log.record(asset: asset1, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        log.record(asset: asset2, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        XCTAssertEqual(observedDuringRemoveCall, nil,
                       "lastUndoneAlbumName must be reset to nil before the operation runs " +
                       "so two undos to the same album each produce a nil → value transition")
        XCTAssertEqual(log.lastUndoneAlbumName, "Vacation",
                       "After the operation succeeds, lastUndoneAlbumName must be set again")
    }

    // MARK: - redo() success path

    func testRedoSuccess_movesEntryToUndoStackAndSetsLastRedoneAlbumName() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        mock.calls.removeAll()

        await log.redo()

        XCTAssertTrue(log.canUndo)
        XCTAssertFalse(log.canRedo)
        XCTAssertEqual(log.undoStack.count, 1)
        XCTAssertEqual(log.lastRedoneAlbumName, "Vacation")
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].kind, .assign)
        XCTAssertEqual(mock.calls[0].surface, .byID)
        XCTAssertEqual(mock.calls[0].target, "album-id-1")
    }

    // MARK: - redo() failure path

    func testRedoFailure_keepsEntryOnRedoStack_andLeavesLastRedoneNil() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        mock.assignShouldSucceed = false

        await log.redo()

        XCTAssertTrue(log.canRedo, "Failed redo must roll the entry back onto the redo stack")
        XCTAssertFalse(log.canUndo)
        XCTAssertEqual(log.redoStack.count, 1)
        XCTAssertNil(log.lastRedoneAlbumName)
    }

    // MARK: - redo() toast trigger contract

    func testTwoConsecutiveRedosToSameAlbumEachProduceNilThenValueTransition() async {
        let asset1 = StubPHAsset(localIdentifier: "asset-1")
        let asset2 = StubPHAsset(localIdentifier: "asset-2")

        var observedDuringAssignCall: String? = "<not set>"
        let spy = TransitionSpyAlbumOperations { [weak self] in
            observedDuringAssignCall = self?.log.lastRedoneAlbumName
        }
        log = DecisionLog(operations: spy)
        // Record two, undo two — gets us to two redo-stack entries for the same album.
        log.record(asset: asset1, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        log.record(asset: asset2, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        await log.undo()
        // First redo lands.
        await log.redo()
        // Second redo to the SAME album — verify the nil → value transition.
        observedDuringAssignCall = "<not set>"
        await log.redo()
        XCTAssertEqual(observedDuringAssignCall, nil,
                       "lastRedoneAlbumName must be reset to nil before the operation runs " +
                       "so two redos to the same album each produce a nil → value transition")
        XCTAssertEqual(log.lastRedoneAlbumName, "Vacation")
    }

    // MARK: - by-id migration: routing

    func testUndoUsesAlbumIDWhenAvailable_titleFallbackWhenNot() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        // Legacy in-memory decision (no albumLocalIdentifier) → fallback to title.
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: nil)
        await log.undo()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].surface, .byName,
                       "Legacy decision without albumLocalIdentifier must fall back to by-name remove")
        XCTAssertEqual(mock.calls[0].target, "Vacation")

        // New decision with an id → by-id surface.
        mock.calls.removeAll()
        log.record(asset: asset, albumName: "Family", albumLocalIdentifier: "album-id-fam")
        await log.undo()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].surface, .byID,
                       "Decision carrying albumLocalIdentifier must route through by-id remove")
        XCTAssertEqual(mock.calls[0].target, "album-id-fam")
    }

    func testRedoUsesAlbumIDWhenAvailable_titleFallbackWhenNot() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: nil)
        await log.undo()
        mock.calls.removeAll()
        await log.redo()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].kind, .assign)
        XCTAssertEqual(mock.calls[0].surface, .byName)
        XCTAssertEqual(mock.calls[0].target, "Vacation")

        log = DecisionLog(operations: mock)
        mock.calls.removeAll()
        log.record(asset: asset, albumName: "Family", albumLocalIdentifier: "album-id-fam")
        await log.undo()
        mock.calls.removeAll()
        await log.redo()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].kind, .assign)
        XCTAssertEqual(mock.calls[0].surface, .byID)
        XCTAssertEqual(mock.calls[0].target, "album-id-fam")
    }

    // MARK: - lastUndoError / lastRedoError (S-5)

    /// A single undo failure must surface `lastUndoError` and roll the entry
    /// back onto the undo stack so the user can retry.
    func testUndoFailure_setsLastUndoError() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        mock.removeShouldSucceed = false

        await log.undo()

        XCTAssertNotNil(log.lastUndoError,
                       "First undo failure must surface lastUndoError so the toast fires")
        XCTAssertTrue(log.canUndo, "Entry must stay on the undo stack for retry")
    }

    /// Two consecutive failures of the *same* undo entry must drop the entry
    /// so `canUndo` no longer lies — the album is presumed permanently broken.
    func testUndoFailureTwiceForSameEntry_dropsEntry() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        mock.removeShouldSucceed = false

        await log.undo()
        XCTAssertTrue(log.canUndo, "First failure: entry rolled back for retry")

        await log.undo()
        XCTAssertFalse(log.canUndo,
                       "Second failure of the same entry must drop it so canUndo reflects reality")
        XCTAssertNotNil(log.lastUndoError,
                       "The drop must still set lastUndoError so the user sees a toast")
    }

    /// A successful undo following a failed undo must clear `lastUndoError` so
    /// the toast doesn't fire spuriously.
    func testUndoSuccess_clearsLastUndoError() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        mock.removeShouldSucceed = false
        await log.undo()
        XCTAssertNotNil(log.lastUndoError)

        mock.removeShouldSucceed = true
        await log.undo()
        XCTAssertNil(log.lastUndoError)
        XCTAssertEqual(log.lastUndoneAlbumName, "Vacation")
    }

    /// Symmetric drop-on-persistent-failure for redo.
    func testRedoFailureTwiceForSameEntry_dropsEntry() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        await log.undo()
        XCTAssertTrue(log.canRedo)

        mock.assignShouldSucceed = false
        await log.redo()
        XCTAssertTrue(log.canRedo, "First failure: entry rolled back for retry")

        await log.redo()
        XCTAssertFalse(log.canRedo,
                       "Second redo failure of the same entry must drop it")
        XCTAssertNotNil(log.lastRedoError)
    }

    /// Recording a fresh decision after a failure clears `lastUndoError` so
    /// stale failure context doesn't bleed into a new session.
    func testRecord_clearsLastUndoErrorAndFailureTracking() async {
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-id-1")
        mock.removeShouldSucceed = false
        await log.undo()
        XCTAssertNotNil(log.lastUndoError)

        log.record(asset: asset, albumName: "Family", albumLocalIdentifier: "album-id-2")
        XCTAssertNil(log.lastUndoError, "record() must clear lastUndoError")

        // And the per-entry failure counter must reset too — the first failure
        // on the new entry should roll back (not drop) even after a previous
        // failure existed for the prior entry.
        await log.undo()
        XCTAssertTrue(log.canUndo,
                       "Fresh record's first failure must roll back (drop counter reset by record())")
    }

    // MARK: - duplicate-name regression

    func testUndoOnDuplicateNamedAlbums_targetsTheOriginalCollection() async {
        // Two albums share the title "Vacation" but have distinct local
        // identifiers. The decision was recorded against `album-A`; the undo
        // must route to `album-A` regardless of which collection the title
        // lookup would resolve to.
        let asset = StubPHAsset(localIdentifier: "asset-1")
        log.record(asset: asset, albumName: "Vacation", albumLocalIdentifier: "album-A")
        await log.undo()
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].surface, .byID)
        XCTAssertEqual(mock.calls[0].target, "album-A",
                       "Undo must target the original album by id, never the duplicate-named sibling")
        // The title is NOT used as the target — confirm it never appears.
        XCTAssertNotEqual(mock.calls[0].target, "Vacation")
    }
}

// MARK: - Transition spy for toast contract

/// An `AlbumOperations` mock that runs a `@MainActor` callback the instant an
/// operation is invoked, so tests can observe the DecisionLog's
/// `lastUndoneAlbumName` / `lastRedoneAlbumName` *during* the operation
/// (the nil reset window).
final class TransitionSpyAlbumOperations: AlbumOperations {
    private let onCall: @MainActor () -> Void

    init(onCall: @escaping @MainActor () -> Void) {
        self.onCall = onCall
    }

    func assign(_ asset: PHAsset, toAlbumNamed name: String) async -> Bool {
        await MainActor.run { onCall() }
        return true
    }

    func assign(_ asset: PHAsset, toAlbumWithID albumLocalIdentifier: String) async -> Bool {
        await MainActor.run { onCall() }
        return true
    }

    func remove(_ asset: PHAsset, fromAlbumNamed name: String) async -> Bool {
        await MainActor.run { onCall() }
        return true
    }

    func remove(_ asset: PHAsset, fromAlbumWithID albumLocalIdentifier: String) async -> Bool {
        await MainActor.run { onCall() }
        return true
    }
}

// MARK: - UndoRedoStack full simulation of DecisionLog semantics

/// Drives the same state machine as DecisionLog but with String keys,
/// proving the algorithm without needing PHAsset.
final class DecisionLogAlgorithmTests: XCTestCase {

    struct FakeDecision: Equatable {
        let assetID: String
        let albumName: String
    }

    // Simulates DecisionLog.record + undo + redo using the same UndoRedoStack mechanics.

    func testRecordThenUndoMovesEntryToRedo() {
        var stack = UndoRedoStack<FakeDecision>()

        // record two decisions
        stack.record(FakeDecision(assetID: "asset1", albumName: "Vacation"))
        stack.record(FakeDecision(assetID: "asset2", albumName: "Family"))

        XCTAssertEqual(stack.undoStack.count, 2)
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)

        // undo last (asset2 / Family)
        let undone = stack.popUndo()!
        // Side effect would be: remove asset2 from "Family"
        XCTAssertEqual(undone.assetID, "asset2")
        XCTAssertEqual(undone.albumName, "Family")
        stack.pushRedo(undone)

        XCTAssertEqual(stack.undoStack.count, 1)
        XCTAssertEqual(stack.redoStack.count, 1)
        XCTAssertTrue(stack.canUndo)
        XCTAssertTrue(stack.canRedo)
    }

    func testRedoMovesEntryBackToUndo() {
        var stack = UndoRedoStack<FakeDecision>()
        stack.record(FakeDecision(assetID: "asset1", albumName: "Vacation"))

        // undo
        let undone = stack.popUndo()!
        stack.pushRedo(undone)

        // redo
        let redone = stack.popRedo()!
        // Side effect would be: re-assign asset1 to "Vacation"
        XCTAssertEqual(redone.assetID, "asset1")
        stack.pushUndo(redone)

        XCTAssertEqual(stack.undoStack.count, 1)
        XCTAssertTrue(stack.redoStack.isEmpty)
        XCTAssertFalse(stack.canRedo)
        XCTAssertTrue(stack.canUndo)
    }

    func testNewRecordAfterUndoClearsRedo() {
        var stack = UndoRedoStack<FakeDecision>()
        stack.record(FakeDecision(assetID: "asset1", albumName: "Vacation"))

        let undone = stack.popUndo()!
        stack.pushRedo(undone)
        XCTAssertTrue(stack.canRedo)

        // Record a new decision — redo history must be cleared.
        stack.record(FakeDecision(assetID: "asset2", albumName: "Family"))
        XCTAssertFalse(stack.canRedo, "New record must invalidate redo history")
        XCTAssertEqual(stack.undoStack.count, 1)
        XCTAssertEqual(stack.undoStack.first?.albumName, "Family")
    }

    func testUndoOnEmptyStackIsNoop() {
        var stack = UndoRedoStack<FakeDecision>()
        XCTAssertNil(stack.popUndo())
        XCTAssertFalse(stack.canUndo)
    }

    func testRedoOnEmptyStackIsNoop() {
        var stack = UndoRedoStack<FakeDecision>()
        XCTAssertNil(stack.popRedo())
        XCTAssertFalse(stack.canRedo)
    }

    func testMultipleUndosThenRedos() {
        var stack = UndoRedoStack<FakeDecision>()
        let d1 = FakeDecision(assetID: "a1", albumName: "A")
        let d2 = FakeDecision(assetID: "a2", albumName: "B")
        let d3 = FakeDecision(assetID: "a3", albumName: "C")

        stack.record(d1)
        stack.record(d2)
        stack.record(d3)

        // Undo all three
        let u3 = stack.popUndo()!; stack.pushRedo(u3)
        let u2 = stack.popUndo()!; stack.pushRedo(u2)
        let u1 = stack.popUndo()!; stack.pushRedo(u1)

        XCTAssertFalse(stack.canUndo)
        XCTAssertEqual(stack.redoStack.map(\.albumName), ["C", "B", "A"])

        // Redo all three
        let r1 = stack.popRedo()!; stack.pushUndo(r1)
        let r2 = stack.popRedo()!; stack.pushUndo(r2)
        let r3 = stack.popRedo()!; stack.pushUndo(r3)

        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.undoStack.map(\.albumName), ["A", "B", "C"])
    }
}
