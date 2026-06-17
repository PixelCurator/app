import SwiftUI
import SwiftData

@main
struct PixelCuratorApp: App {
    @State private var library = PhotoController()
    @State private var albums = AlbumManager()
    @State private var indexer: EmbeddingIndexer?
    @State private var similaritySearch: SimilaritySearch?

    /// The active CLIP variant. Changing this triggers variant-switch orchestration.
    @State private var activeVariant: CLIPVariant = .bundledDefault

    /// Entitlement provider. `DebugEntitlementProvider` is the default so the full
    /// multi-variant pipeline is testable without App Store Connect products.
    ///
    /// ⚠️  DEVELOPMENT DEFAULT — replace with `StoreKitEntitlementProvider` before release.
    @State private var entitlements: any EntitlementProvider = DebugEntitlementProvider()

    /// Guards against concurrent variant-switch calls.
    @State private var isSwitchingVariant = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(albums)
                .environment(\.embeddingIndexer, indexer)
                .environment(\.similaritySearch, similaritySearch)
                .environment(\.activeVariant, activeVariant)
                .environment(\.entitlementProvider, entitlements)
                .environment(\.switchVariant, switchVariant(_:))
                .task { await bootIndexer(variant: .bundledDefault) }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
        .modelContainer(for: PhotoEmbedding.self)
    }

    // MARK: - Boot

    @MainActor
    private func bootIndexer(variant: CLIPVariant) async {
        guard !isSwitchingVariant else { return }
        isSwitchingVariant = true
        defer { isSwitchingVariant = false }

        do {
            let modelURL = try await ModelStore.compiledModelURL(for: variant)
            let embedder = try await Embedder(modelURL: modelURL)

            let container = try ModelContainer(for: PhotoEmbedding.self)
            let newIndexer = EmbeddingIndexer(
                context: container.mainContext,
                embedder: embedder,
                modelStore: ModelStore(),
                variant: variant
            )
            self.indexer = newIndexer

            let searchContainer = try ModelContainer(for: PhotoEmbedding.self)
            self.similaritySearch = SimilaritySearch(
                embedder: embedder,
                context: searchContainer.mainContext,
                library: library,
                variant: variant
            )
            self.activeVariant = variant
        } catch {
            print("PixelCuratorApp: failed to boot indexer for \(variant.displayName): \(error)")
        }
    }

    // MARK: - Variant switch

    /// Switches the active CLIP variant. Called from `VariantSettingsView`.
    ///
    /// Guard: locked variants are rejected. The switch cancels any in-flight
    /// indexing, rebuilds the Embedder + EmbeddingIndexer + SimilaritySearch for
    /// the new variant, and kicks off a new indexing run. Old embeddings for other
    /// variants remain in SwiftData and are reactivated if the user switches back.
    @MainActor
    private func switchVariant(_ variant: CLIPVariant) {
        guard entitlements.isUnlocked(variant) else {
            print("PixelCuratorApp: attempted to switch to locked variant \(variant.displayName)")
            return
        }
        guard variant != activeVariant else { return }

        // Cancel the current indexer before rebuilding.
        indexer?.cancelIndexing()

        Task {
            await bootIndexer(variant: variant)
        }
    }
}

// MARK: - Environment keys

private struct ActiveVariantKey: EnvironmentKey {
    static let defaultValue: CLIPVariant = .bundledDefault
}

private struct EntitlementProviderKey: EnvironmentKey {
    static let defaultValue: any EntitlementProvider = DebugEntitlementProvider()
}

private struct SwitchVariantKey: EnvironmentKey {
    static let defaultValue: (CLIPVariant) -> Void = { _ in }
}

extension EnvironmentValues {
    var activeVariant: CLIPVariant {
        get { self[ActiveVariantKey.self] }
        set { self[ActiveVariantKey.self] = newValue }
    }

    var entitlementProvider: any EntitlementProvider {
        get { self[EntitlementProviderKey.self] }
        set { self[EntitlementProviderKey.self] = newValue }
    }

    var switchVariant: (CLIPVariant) -> Void {
        get { self[SwitchVariantKey.self] }
        set { self[SwitchVariantKey.self] = newValue }
    }
}
