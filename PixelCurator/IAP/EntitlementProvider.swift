import Foundation

/// Protocol that gate-keeps access to pro CLIP variants.
///
/// Free-tier variants (`.tier == .free`) are ALWAYS unlocked regardless of
/// provider implementation.
protocol EntitlementProvider: AnyObject {
    /// Returns `true` if `variant` is accessible to the user.
    /// Free variants must always return `true`.
    func isUnlocked(_ variant: CLIPVariant) -> Bool

    /// The set of variants the user can currently use.
    var unlockedVariants: Set<CLIPVariant> { get }
}

// MARK: - Debug provider (development default)

/// All variants are unlocked. Used as the default during development so the
/// full multi-variant pipeline is exercisable without App Store Connect products.
///
/// ⚠️  DEVELOPMENT ONLY — swap for `StoreKitEntitlementProvider` before release.
final class DebugEntitlementProvider: EntitlementProvider {
    func isUnlocked(_ variant: CLIPVariant) -> Bool { true }
    var unlockedVariants: Set<CLIPVariant> { Set(CLIPVariant.allCases) }
}
