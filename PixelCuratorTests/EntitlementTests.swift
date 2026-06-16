import XCTest
@testable import PixelCurator

@MainActor
final class EntitlementTests: XCTestCase {

    // MARK: - DebugEntitlementProvider

    func testDebugProviderUnlocksEveryVariant() {
        let provider = DebugEntitlementProvider()
        for variant in CLIPVariant.allCases {
            XCTAssertTrue(
                provider.isUnlocked(variant),
                "DebugEntitlementProvider must unlock \(variant.displayName)"
            )
        }
    }

    func testDebugProviderUnlockedVariantsContainsAll() {
        let provider = DebugEntitlementProvider()
        let all = Set(CLIPVariant.allCases)
        XCTAssertEqual(provider.unlockedVariants, all)
    }

    // MARK: - Free variant always unlocked

    func testFreeVariantIsAlwaysUnlocked() {
        let provider = DebugEntitlementProvider()
        let freeVariants = CLIPVariant.allCases.filter { $0.tier == .free }
        XCTAssertFalse(freeVariants.isEmpty, "There must be at least one free variant")
        for variant in freeVariants {
            XCTAssertTrue(provider.isUnlocked(variant))
        }
    }

    // MARK: - Mock provider

    func testMockProviderReportsCorrectly() {
        let provider = MockEntitlementProvider(unlocked: [.s1])

        XCTAssertTrue(provider.isUnlocked(.s0), "Free variant s0 must always be unlocked")
        XCTAssertTrue(provider.isUnlocked(.s1), "s1 is in the mock unlocked set")
        XCTAssertFalse(provider.isUnlocked(.s2), "s2 is not unlocked")
        XCTAssertFalse(provider.isUnlocked(.b), "b is not unlocked")

        XCTAssertTrue(provider.unlockedVariants.contains(.s0))
        XCTAssertTrue(provider.unlockedVariants.contains(.s1))
        XCTAssertFalse(provider.unlockedVariants.contains(.s2))
        XCTAssertFalse(provider.unlockedVariants.contains(.b))
    }

    func testMockProviderUnlockedVariantsSet() {
        let provider = MockEntitlementProvider(unlocked: [.s1, .s2])
        // Should include free variants + the explicitly unlocked ones.
        XCTAssertTrue(provider.unlockedVariants.contains(.s0))
        XCTAssertTrue(provider.unlockedVariants.contains(.s1))
        XCTAssertTrue(provider.unlockedVariants.contains(.s2))
        XCTAssertFalse(provider.unlockedVariants.contains(.b))
    }
}

// MARK: - Mock helper

/// A hand-rolled mock `EntitlementProvider` for testing.
/// Free variants (`.tier == .free`) are always unlocked regardless of `unlocked`.
final class MockEntitlementProvider: EntitlementProvider {
    private let _unlocked: Set<CLIPVariant>

    init(unlocked: Set<CLIPVariant>) {
        self._unlocked = unlocked
    }

    func isUnlocked(_ variant: CLIPVariant) -> Bool {
        variant.tier == .free || _unlocked.contains(variant)
    }

    var unlockedVariants: Set<CLIPVariant> {
        let freeOnes = Set(CLIPVariant.allCases.filter { $0.tier == .free })
        return freeOnes.union(_unlocked)
    }
}
