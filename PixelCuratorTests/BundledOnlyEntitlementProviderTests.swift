import XCTest
@testable import PixelCurator

/// Tests the release-build entitlement provider that ships with the Beta App
/// Review build (B-01). Only the bundled `.s0` variant must be unlocked —
/// every Pro variant must report as locked so the StoreKit-less Beta cannot
/// hand out paid features for free.
@MainActor
final class BundledOnlyEntitlementProviderTests: XCTestCase {

    func testBundledDefaultIsUnlocked() {
        let provider = BundledOnlyEntitlementProvider()
        XCTAssertTrue(
            provider.isUnlocked(.bundledDefault),
            "The bundled default variant must always be unlocked in the release-safe provider"
        )
    }

    func testS0IsUnlocked() {
        let provider = BundledOnlyEntitlementProvider()
        XCTAssertTrue(
            provider.isUnlocked(.s0),
            "S0 ships in the app bundle for free-tier users"
        )
    }

    func testProVariantsAreLocked() {
        let provider = BundledOnlyEntitlementProvider()
        for variant in [CLIPVariant.s1, .s2, .b] {
            XCTAssertFalse(
                provider.isUnlocked(variant),
                "Pro variant \(variant.displayName) must be locked until StoreKit + ASC IAP is wired"
            )
        }
    }

    func testUnlockedVariantsContainsOnlyBundledDefault() {
        let provider = BundledOnlyEntitlementProvider()
        XCTAssertEqual(
            provider.unlockedVariants,
            [.bundledDefault],
            "Only the bundled default variant may appear in the unlocked set"
        )
    }

    func testEveryProVariantIsLocked() {
        // Belt-and-suspenders: iterate over every case and assert that any
        // variant whose `tier == .pro` is locked. This catches a regression if
        // a new Pro variant is added to `CLIPVariant` without updating the
        // provider — the test will fail because the new case will be `.pro`
        // and `isUnlocked` will return `false` only for `.bundledDefault`.
        let provider = BundledOnlyEntitlementProvider()
        for variant in CLIPVariant.allCases where variant.tier == .pro {
            XCTAssertFalse(
                provider.isUnlocked(variant),
                "Pro tier variant \(variant.displayName) must be locked"
            )
        }
    }
}
