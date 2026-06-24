import XCTest
@testable import PixelCurator

/// F-10 + F-11 regression coverage. The destructive prune in
/// `PixelCuratorApp.runCascadePrune` must NOT run when the photo library
/// is in `.limited`, `.denied`, or `.restricted` — under any of those
/// states `library.assets` is a partial view of the user's photos, and
/// treating every off-list asset as "deleted" is what destroyed user
/// embeddings on a transient auth flicker (F-11 symptom: 10k+ rows lost
/// on a single Limited-Library selection change or permission revoke).
///
/// Tested through the pure-function gate shim
/// `CascadeGate.shouldRunDestructivePrune(authState:)` so the policy
/// stays under unit-test coverage without needing to construct the
/// `@main` `PixelCuratorApp` struct.
@MainActor
final class PhotoControllerCascadeGateTests: XCTestCase {

    // MARK: - Authorized: prune runs

    func testShouldRunDestructivePrune_authorized_returnsTrue() {
        XCTAssertTrue(
            CascadeGate.shouldRunDestructivePrune(authState: .authorized),
            ".authorized is the only state where library.assets is the full library snapshot; " +
            "the prune must run as before"
        )
    }

    // MARK: - F-10: limited library access

    func testShouldRunDestructivePrune_limited_returnsFalse() {
        // F-10. Limited-Library returns only the user-picked subset.
        // Off-list photos still exist; the prune would treat them as
        // deleted and wipe their embeddings on every selection change.
        XCTAssertFalse(
            CascadeGate.shouldRunDestructivePrune(authState: .limited),
            ".limited must skip the prune — `library.assets` is the user-picked subset, " +
            "not the full library"
        )
    }

    // MARK: - F-11: denied / restricted / unknown

    func testShouldRunDestructivePrune_denied_returnsFalse() {
        // F-11. Denied → handleLibraryChange clears `library.assets` to
        // []. Pruning against an empty living-set erases the entire
        // derived dataset on a single revoke.
        XCTAssertFalse(
            CascadeGate.shouldRunDestructivePrune(authState: .denied),
            ".denied must skip the prune — `library.assets` is [] and would erase everything"
        )
    }

    func testShouldRunDestructivePrune_restricted_returnsFalse() {
        // `.restricted` (parental controls / MDM) behaves like `.denied`
        // for our purposes — `library.assets` is empty.
        XCTAssertFalse(
            CascadeGate.shouldRunDestructivePrune(authState: .restricted),
            ".restricted must skip the prune — same erasure risk as .denied"
        )
    }

    func testShouldRunDestructivePrune_unknown_returnsFalse() {
        // `.unknown` is the pre-determination state. Authorisation hasn't
        // been resolved yet so we can't trust `library.assets` to be
        // complete; conservative default is to skip the prune.
        XCTAssertFalse(
            CascadeGate.shouldRunDestructivePrune(authState: .unknown),
            ".unknown must skip the prune — auth not yet resolved, asset view not trustworthy"
        )
    }

    // MARK: - Exhaustiveness pinning

    /// If a new `AuthState` case is added later, this test forces a
    /// decision-by-decision review of `shouldRunDestructivePrune` rather
    /// than silently inheriting the default `false` branch. Iterates over
    /// every known case so adding a new one without updating the switch
    /// will be caught by the compiler in the gate shim first; this test
    /// then locks the no-regression baseline for the existing five.
    func testShouldRunDestructivePrune_coversAllKnownAuthStates() {
        let states: [PhotoController.AuthState] = [
            .unknown, .authorized, .limited, .denied, .restricted,
        ]
        // Expectation matrix: only .authorized is destructive-safe.
        let expected: [PhotoController.AuthState: Bool] = [
            .unknown: false,
            .authorized: true,
            .limited: false,
            .denied: false,
            .restricted: false,
        ]
        for state in states {
            XCTAssertEqual(
                CascadeGate.shouldRunDestructivePrune(authState: state),
                expected[state],
                "Decision for \(state) drifted from the F-10/F-11 policy"
            )
        }
    }
}
