import XCTest
@testable import PixelCurator

/// F-02 regression coverage. The library-change cascade in
/// `PixelCuratorApp.installLibraryChangeCascade` must NOT run its
/// `prune + context.save()` body while either `EmbeddingIndexer.isIndexing`
/// or `PixelCuratorApp.isSwitchingVariant` is `true` — both states have
/// writers in flight against the shared `modelContainer.mainContext`, and a
/// concurrent prune would interleave saves with the in-flight writer mid
/// `await` and either trap or silently drop rows.
///
/// `PixelCuratorApp` is an `@main` App struct and is not directly
/// constructable from tests. The gate semantics it relies on are factored
/// into `CascadeGate.deferIfBusy(...)` / `consumePendingReplay(...)`; this
/// suite drives those shims directly so the deferral + replay contract is
/// locked under unit-test coverage.
@MainActor
final class CascadeRaceTests: XCTestCase {

    // MARK: - Deferral semantics

    func testGate_deferIfBusy_whileIndexing_setsPendingAndReturnsTrue() {
        let gate = CascadeGate()
        XCTAssertFalse(gate.pendingReplay)

        let deferred = gate.deferIfBusy(isIndexing: true, isSwitchingVariant: false)

        XCTAssertTrue(deferred, "Cascade must defer while indexing is in flight")
        XCTAssertTrue(gate.pendingReplay, "Pending-replay flag must be set when deferring")
    }

    func testGate_deferIfBusy_whileSwitchingVariant_setsPendingAndReturnsTrue() {
        let gate = CascadeGate()

        let deferred = gate.deferIfBusy(isIndexing: false, isSwitchingVariant: true)

        XCTAssertTrue(deferred, "Cascade must defer while a variant switch is in flight")
        XCTAssertTrue(gate.pendingReplay)
    }

    func testGate_deferIfBusy_whileBothBusy_setsPendingAndReturnsTrue() {
        let gate = CascadeGate()

        let deferred = gate.deferIfBusy(isIndexing: true, isSwitchingVariant: true)

        XCTAssertTrue(deferred)
        XCTAssertTrue(gate.pendingReplay)
    }

    func testGate_deferIfBusy_whileIdle_returnsFalseAndLeavesPendingUnchanged() {
        let gate = CascadeGate()

        let deferred = gate.deferIfBusy(isIndexing: false, isSwitchingVariant: false)

        XCTAssertFalse(deferred, "Cascade must run inline when no writer is in flight")
        XCTAssertFalse(gate.pendingReplay,
                       "Idle path must not set the pending-replay flag")
    }

    // MARK: - Coalescing

    func testGate_burstOfChanges_whileIndexing_collapsesToOneReplay() {
        let gate = CascadeGate()

        // Simulate Photos.app delivering many bursty change callbacks while
        // indexing is in flight (iCloud Shared Library re-sync pattern).
        for _ in 0 ..< 10 {
            _ = gate.deferIfBusy(isIndexing: true, isSwitchingVariant: false)
        }

        XCTAssertTrue(gate.pendingReplay)

        // Gate opens (indexing finished). Consume + replay exactly once.
        let firstReplay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: false)
        XCTAssertTrue(firstReplay, "First post-gate consume must drain the pending flag")

        // A second consume immediately after must be a no-op (the bursty
        // callbacks have already been coalesced into the single replay).
        let secondReplay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: false)
        XCTAssertFalse(secondReplay, "Coalesced replay must not fire a second time")
    }

    // MARK: - Replay semantics

    func testGate_consumePending_whileStillIndexing_doesNotReplay() {
        let gate = CascadeGate()
        gate.pendingReplay = true

        let replay = gate.consumePendingReplay(isIndexing: true, isSwitchingVariant: false)

        XCTAssertFalse(replay, "Replay must wait until indexing finishes")
        XCTAssertTrue(gate.pendingReplay,
                      "Pending flag must persist until the gate fully opens")
    }

    func testGate_consumePending_whileStillSwitching_doesNotReplay() {
        let gate = CascadeGate()
        gate.pendingReplay = true

        let replay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: true)

        XCTAssertFalse(replay)
        XCTAssertTrue(gate.pendingReplay)
    }

    func testGate_consumePending_whenNothingPending_returnsFalse() {
        let gate = CascadeGate()

        let replay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: false)

        XCTAssertFalse(replay, "Consume must be a no-op when nothing was deferred")
        XCTAssertFalse(gate.pendingReplay)
    }

    func testGate_consumePending_drainsAfterOnlyOneGateOpens_whenOtherStillClosed() {
        let gate = CascadeGate()
        // Cascade arrived while both gates were closed.
        _ = gate.deferIfBusy(isIndexing: true, isSwitchingVariant: true)
        XCTAssertTrue(gate.pendingReplay)

        // Indexing finished, but the variant switch is still in flight.
        let earlyReplay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: true)
        XCTAssertFalse(earlyReplay, "Must wait for the second gate to open too")
        XCTAssertTrue(gate.pendingReplay, "Pending flag must persist across the partial open")

        // Now the variant switch finishes too — drain.
        let finalReplay = gate.consumePendingReplay(isIndexing: false, isSwitchingVariant: false)
        XCTAssertTrue(finalReplay)
        XCTAssertFalse(gate.pendingReplay)
    }
}
