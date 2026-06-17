import SwiftUI
import SwiftData

@main
struct PixelCuratorApp: App {
    @State private var library = PhotoController()
    @State private var albums = AlbumManager()
    @State private var indexer: EmbeddingIndexer?
    @State private var similaritySearch: SimilaritySearch?
    @State private var sortingCoordinator: SortingCoordinator?

    /// Shared DecisionLog for the grid's tap-to-assign undo flow.
    /// SortingCoordinator owns its own internal log (separate history); a future
    /// milestone can unify both logs into this one.
    @State private var sharedDecisionLog: DecisionLog?

    /// The active CLIP variant. Changing this triggers variant-switch orchestration.
    @State private var activeVariant: CLIPVariant = .bundledDefault

    /// Entitlement provider. `DebugEntitlementProvider` is the default so the full
    /// multi-variant pipeline is testable without App Store Connect products.
    ///
    /// ⚠️  DEVELOPMENT DEFAULT — replace with `StoreKitEntitlementProvider` before release.
    @State private var entitlements: any EntitlementProvider = DebugEntitlementProvider()

    /// Guards against concurrent variant-switch calls.
    @State private var isSwitchingVariant = false

    /// The single SwiftData container shared by the SwiftUI scene and every ML
    /// service (indexer, similarity search, sorting). Using one container —
    /// rather than one per service — is essential: multiple independent
    /// `ModelContainer`s over the same on-disk store run separate store
    /// coordinators, and fetching rows written through one coordinator from
    /// another traps inside SwiftData on the main thread (EXC_BREAKPOINT). It
    /// also collapses four store openings at launch into one.
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: PhotoEmbedding.self, AlbumCorrection.self)
        } catch {
            fatalError("PixelCurator: failed to create the shared ModelContainer: \(error)")
        }
    }

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
                .environment(\.sortingCoordinator, sortingCoordinator)
                .environment(\.decisionLog, sharedDecisionLog)
                .task { await bootIndexer(variant: .bundledDefault) }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
        .modelContainer(modelContainer)
    }

    // MARK: - Boot

    @MainActor
    private func bootIndexer(variant: CLIPVariant) async {
        guard !isSwitchingVariant else { return }
        isSwitchingVariant = true
        defer { isSwitchingVariant = false }

        // Create the shared DecisionLog once (on first boot). Variant switches
        // don't need a fresh log — the same albums instance backs undo operations.
        if sharedDecisionLog == nil {
            sharedDecisionLog = DecisionLog(operations: albums)
        }

        do {
            let modelURL = try await ModelStore.compiledModelURL(for: variant)
            let embedder = try await Embedder(modelURL: modelURL)

            // All services share the app's single ModelContainer (see the
            // `modelContainer` declaration for why per-service containers trap).
            let context = modelContainer.mainContext

            let newIndexer = EmbeddingIndexer(
                context: context,
                embedder: embedder,
                modelStore: ModelStore(),
                variant: variant
            )
            self.indexer = newIndexer

            self.similaritySearch = SimilaritySearch(
                embedder: embedder,
                context: context,
                library: library,
                variant: variant
            )
            self.activeVariant = variant

            self.sortingCoordinator = SortingCoordinator(
                store: EmbeddingStore(context: context),
                suggester: AlbumSuggester(),
                albumManager: albums,
                photoController: library,
                modelID: variant.modelID,
                correctionStore: CorrectionStore(context: context)
            )
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
