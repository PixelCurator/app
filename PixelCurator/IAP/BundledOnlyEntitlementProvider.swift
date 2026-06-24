import Foundation

/// Production-safe entitlement provider used for the Beta App Review release.
///
/// Only the bundled free-tier variant (`CLIPVariant.bundledDefault` = `.s0`) is
/// unlocked. Pro variants (`.s1`, `.s2`, `.b`) stay locked until StoreKit +
/// App Store Connect IAP products are wired up post-Beta.
///
/// Rationale: shipping `DebugEntitlementProvider` in a release build would
/// violate Apple Guideline 3.1.1 (IAP must gate paid features) and 2.3.1
/// (metadata accuracy) because `VariantSettingsView` advertises a "Pro" tier
/// with an "Unlock" affordance. Until the StoreKit pipeline + ASC products are
/// configured, the safest reviewable state is "Pro variants are locked, no
/// purchase affordance is offered."
///
/// To enable Pro variants later, swap this for `StoreKitEntitlementProvider`
/// in `PixelCuratorApp`'s release-build `@State` default.
final class BundledOnlyEntitlementProvider: EntitlementProvider {
    func isUnlocked(_ variant: CLIPVariant) -> Bool {
        variant == .bundledDefault
    }

    var unlockedVariants: Set<CLIPVariant> {
        [.bundledDefault]
    }
}
