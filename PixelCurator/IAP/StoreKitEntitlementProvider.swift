import StoreKit
import Foundation

// MARK: - Product ID mapping
// ⚠️  SCAFFOLD — these product IDs do not yet exist in App Store Connect.
// Until ASC products are created and the app is submitted, `Product.products(for:)`
// will return an empty array and `unlockedVariants` will contain only free variants.
// For development, use `DebugEntitlementProvider` (the default wired in PixelCuratorApp).

extension CLIPVariant {
    /// The App Store Connect non-consumable product ID for this pro variant.
    /// Returns `nil` for free variants (they need no purchase).
    var productID: String? {
        switch self {
        case .s0: return nil
        case .s1: return "yves.vogl.pixelcurator.quality.s1"
        case .s2: return "yves.vogl.pixelcurator.quality.s2"
        case .b:  return "yves.vogl.pixelcurator.quality.b"
        }
    }
}

@MainActor
@Observable
final class StoreKitEntitlementProvider: EntitlementProvider {

    // MARK: - State

    private(set) var unlockedVariants: Set<CLIPVariant> = Set(CLIPVariant.allCases.filter { $0.tier == .free })
    private var products: [String: Product] = [:]
    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    // MARK: - Init / teardown

    init() {
        updatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
        Task { await loadProducts() }
        Task { await refreshEntitlements() }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - EntitlementProvider

    func isUnlocked(_ variant: CLIPVariant) -> Bool {
        variant.tier == .free || unlockedVariants.contains(variant)
    }

    // MARK: - Purchase (SCAFFOLD)

    /// Initiates an App Store purchase for `variant`.
    ///
    /// ⚠️  SCAFFOLD — requires the product to exist in App Store Connect.
    /// In the simulator with a StoreKit configuration file this will work;
    /// against the real App Store it will fail until ASC setup is complete.
    func purchase(_ variant: CLIPVariant) async throws {
        guard let productID = variant.productID,
              let product = products[productID] else {
            throw StoreKitEntitlementError.productNotFound(variant)
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
        case .userCancelled:
            break
        case .pending:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Private helpers

    private func loadProducts() async {
        let ids = CLIPVariant.allCases.compactMap(\.productID)
        guard !ids.isEmpty else { return }
        do {
            let fetched = try await Product.products(for: ids)
            for p in fetched { products[p.id] = p }
        } catch {
            // ⚠️  SCAFFOLD — will fail silently until ASC products are created.
            print("StoreKitEntitlementProvider: product load failed (scaffold): \(error)")
        }
    }

    private func refreshEntitlements() async {
        var unlocked = Set(CLIPVariant.allCases.filter { $0.tier == .free })
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if let variant = CLIPVariant.allCases.first(where: { $0.productID == transaction.productID }) {
                    unlocked.insert(variant)
                }
            }
        }
        unlockedVariants = unlocked
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await refreshEntitlements()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}

// MARK: - Errors

enum StoreKitEntitlementError: LocalizedError {
    case productNotFound(CLIPVariant)

    var errorDescription: String? {
        switch self {
        case .productNotFound(let variant):
            return "Product for \(variant.displayName) not found. App Store Connect setup required."
        }
    }
}
