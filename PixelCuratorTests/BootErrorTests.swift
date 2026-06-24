import XCTest
@testable import PixelCurator

/// B-6. The production `bootIndexer(variant:)` lives inside `@main struct
/// PixelCuratorApp` and is `@MainActor private`. We can't drive it directly
/// from tests without spinning up the SwiftUI runtime, which is exactly the
/// kind of brittle full-stack harness we want to avoid here. Instead, this
/// suite pins the parts of the boot-error contract that are exercisable
/// from a unit-test target:
///
///   1. `BootError` is value-typed and Identifiable so SwiftUI's
///      `alert(_:isPresented:presenting:)` overload can key on it.
///   2. `BootError` carries the variant — Retry must re-attempt the variant
///      that failed, NOT whatever `activeVariant` happens to be when the
///      user taps Retry (this matters when the failure is on a Pro variant
///      switch and the live `activeVariant` is still the previous one).
///   3. A `MockBootSurface` that simulates `bootIndexer` throwing once then
///      succeeding on retry behaves exactly as the production alert handler
///      requires: clears `bootError` and re-invokes the boot for the failed
///      variant.
///
/// Tests are `@MainActor` because the simulated boot surface and BootError
/// state both live on the main actor in production.
@MainActor
final class BootErrorTests: XCTestCase {

    // MARK: - BootError shape

    func testBootErrorCarriesVariantForRetry() {
        let underlying = NSError(domain: "test", code: -1, userInfo: nil)
        let error = BootError(variant: .s1, underlying: underlying)

        XCTAssertEqual(
            error.variant, .s1,
            "BootError must remember the variant that failed so Retry " +
            "re-attempts the same one, not the (possibly stale) activeVariant."
        )
        XCTAssertEqual((error.underlying as NSError).code, -1)
    }

    func testBootErrorsHaveDistinctIdentities() {
        // Two errors for the same variant must still be Identifiable-distinct
        // so SwiftUI re-presents the alert if a second failure follows a
        // dismissed first one (otherwise the second alert would silently
        // dedupe against the first).
        let e = NSError(domain: "test", code: 1, userInfo: nil)
        let a = BootError(variant: .s0, underlying: e)
        let b = BootError(variant: .s0, underlying: e)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Retry flow contract

    func testRetryFlowOnMockBootSurface() async {
        // Surface that throws on the first boot, succeeds on the second.
        let surface = MockBootSurface(failuresBeforeSuccess: 1)

        // First attempt: should fail and surface a BootError.
        await surface.boot(variant: .s1)
        XCTAssertNotNil(surface.bootError, "First boot must populate bootError")
        XCTAssertEqual(surface.bootError?.variant, .s1)
        XCTAssertFalse(surface.didSucceed)

        // Simulate the Retry button handler:
        //   1. capture variant from bootError
        //   2. clear bootError
        //   3. re-invoke boot for the captured variant
        guard let variant = surface.bootError?.variant else {
            return XCTFail("Expected a captured variant on bootError")
        }
        surface.bootError = nil
        await surface.boot(variant: variant)

        XCTAssertNil(surface.bootError, "Second boot must clear bootError")
        XCTAssertTrue(surface.didSucceed, "Mock boot succeeds on second attempt")
        XCTAssertEqual(surface.bootAttempts, 2)
    }

    func testRetryUsesFailedVariantNotCurrentActiveVariant() async {
        // The user attempted to switch from S0 to S2. Switch boot fails.
        // Even if some other observer has flipped a notional "active"
        // variant back to S0 in the meantime, Retry must replay S2 —
        // because that's what the user asked for. We simulate this by
        // hard-coding the surface's notion of "active" to S0 while the
        // failed variant is S2.
        let surface = MockBootSurface(failuresBeforeSuccess: 1)
        surface.activeVariant = .s0

        await surface.boot(variant: .s2)
        XCTAssertEqual(surface.bootError?.variant, .s2)
        XCTAssertEqual(surface.activeVariant, .s0,
                       "Failed boot must not flip activeVariant")

        // Retry handler reads variant from bootError, not activeVariant.
        let retryVariant = surface.bootError?.variant ?? surface.activeVariant
        XCTAssertEqual(retryVariant, .s2,
                       "Retry must replay the FAILED variant, not the stale activeVariant.")
    }
}

// MARK: - Mock

/// Minimal surface that mirrors the contract of `PixelCuratorApp.bootIndexer`
/// without dragging in SwiftUI, the embedder, the model store, or the
/// SwiftData container. Two outcomes only: throw `N` times, then succeed.
@MainActor
private final class MockBootSurface {
    var bootError: BootError?
    var didSucceed: Bool = false
    var bootAttempts: Int = 0
    var activeVariant: CLIPVariant = .bundledDefault

    private var remainingFailures: Int

    init(failuresBeforeSuccess: Int) {
        self.remainingFailures = failuresBeforeSuccess
    }

    func boot(variant: CLIPVariant) async {
        bootAttempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            let err = NSError(domain: "MockBoot", code: 42, userInfo: nil)
            bootError = BootError(variant: variant, underlying: err)
            return
        }
        didSucceed = true
        activeVariant = variant
    }
}
