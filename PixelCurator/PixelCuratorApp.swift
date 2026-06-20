import SwiftUI
import SwiftData

@main
struct PixelCuratorApp: App {
    @State private var library = PhotoController()
    @State private var albums = AlbumManager()
    @State private var indexer: EmbeddingIndexer?
    @State private var similaritySearch: SimilaritySearch?

    /// The app's **single** `SortingCoordinator`, allocated once on first boot
    /// and rebound across variant switches via `updateVariant(...)`. Allocating
    /// a fresh coordinator per variant switch would (a) silently wipe Undo
    /// history (the per-coordinator `decisionLog` is brand-new) and (b) leave
    /// any view that captured the prior reference holding an orphan.
    @State private var sortingCoordinator: SortingCoordinator?

    /// Shared DecisionLog for the grid's tap-to-assign undo flow.
    ///
    /// Same instance as `sortingCoordinator.decisionLog` so the inbox toolbar's
    /// Undo and the grid toolbar's Undo share one history — the previous
    /// "future milestone can unify both logs" TODO is now closed at the seam
    /// where the coordinator survives variant switches.
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
                .environment(\.isSwitchingVariant, isSwitchingVariant)
                .task { await bootIndexer(variant: .bundledDefault) }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
        .modelContainer(modelContainer)

        #if os(macOS)
        // Native macOS Settings scene — accessible via Cmd-, by default. The
        // same `@AppStorage("hideICloudPhotos")` key is read by `PhotoGridView`,
        // which mirrors it into `PhotoController.hideICloudPhotos`, so flipping
        // the toggle here propagates to the grid filter on the next render.
        Settings {
            AppSettingsView()
        }
        #endif
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

        // Wire the library-change cascade once. The handler captures the
        // single ModelContainer's mainContext so prune touches the same store
        // every other service writes to (see the `modelContainer` declaration
        // for why per-service containers trap). Set unconditionally each boot
        // so the closure keeps referring to the still-current `sharedDecisionLog`.
        installLibraryChangeCascade()

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

            // SortingCoordinator lives for the app's lifetime — only its data
            // sources are swapped on variant switch. This preserves Undo
            // history (decisionLog) and prevents views that captured the prior
            // reference from holding an orphan after a switch.
            let newStore = EmbeddingStore(context: context)
            let newCorrectionStore = CorrectionStore(context: context)
            if let coordinator = sortingCoordinator {
                coordinator.updateVariant(
                    store: newStore,
                    suggester: AlbumSuggester(),
                    correctionStore: newCorrectionStore,
                    modelID: variant.modelID
                )
            } else {
                self.sortingCoordinator = SortingCoordinator(
                    store: newStore,
                    suggester: AlbumSuggester(),
                    albumManager: albums,
                    photoController: library,
                    modelID: variant.modelID,
                    decisionLog: sharedDecisionLog,
                    correctionStore: newCorrectionStore
                )
            }
        } catch {
            print("PixelCuratorApp: failed to boot indexer for \(variant.displayName): \(error)")
        }
    }

    // MARK: - Variant switch

    /// Switches the active CLIP variant. Called from `VariantSettingsView`.
    ///
    /// Guard: locked variants are rejected. The switch cancels any in-flight
    /// indexing, **awaits its actual completion**, and only then rebuilds the
    /// Embedder + EmbeddingIndexer + SimilaritySearch for the new variant.
    /// Old embeddings for other variants remain in SwiftData and are
    /// reactivated if the user switches back.
    ///
    /// The await-before-rebuild step is load-bearing: every service shares the
    /// same `modelContainer.mainContext`, and the prior indexer's trailing
    /// `context.save()` plus `isIndexing = false` writes must land before a
    /// replacement indexer starts touching that context. Without the await,
    /// the two indexers transiently share the context — save-ordering is
    /// undefined and the dead indexer can flip the new one's `isIndexing` flag.
    @MainActor
    private func switchVariant(_ variant: CLIPVariant) {
        guard entitlements.isUnlocked(variant) else {
            print("PixelCuratorApp: attempted to switch to locked variant \(variant.displayName)")
            return
        }
        guard variant != activeVariant else { return }

        let priorIndexer = indexer

        Task {
            // Cancel + await completion of the in-flight indexer before
            // constructing the replacement against the same ModelContext.
            await priorIndexer?.cancelAndWait()
            await bootIndexer(variant: variant)
        }
    }

    // MARK: - Library-change cascade (B-2)

    /// Wires `PhotoController.onLibraryDidChange` so that a change observed in
    /// Photos.app (or iCloud Shared Library) cascades through:
    ///
    ///   1. `AlbumManager.loadAlbums()` — refresh the album list off the new
    ///       PHFetchResult; `PhotoController` already refreshed the asset list.
    ///   2. `EmbeddingStore.prune(keeping:)` — drop embeddings for deleted
    ///       assets across all variants.
    ///   3. `CorrectionStore.prune(...)` — drop corrections for deleted assets
    ///       and corrections pointing at deleted albums (by title).
    ///   4. `DecisionLog.prune(keepingAssets:livingAlbumIDs:)` — drop undo and
    ///       redo entries whose asset or album-by-id is gone.
    ///   5. `context.save()` — persist the prune so a relaunch doesn't see
    ///       resurrected rows.
    ///
    /// The closure captures `self` weakly through the dependency view; the
    /// `library` controller holds the strong reference, so cycle risk is one
    /// way only and cleared on app teardown.
    @MainActor
    private func installLibraryChangeCascade() {
        let context = modelContainer.mainContext
        let embeddings = EmbeddingStore(context: context)
        let corrections = CorrectionStore(context: context)
        // Capture `library` and `albums` weakly: each retains its own
        // `onLibraryDidChange` closure, so a strong capture would create a
        // retain cycle. `sharedDecisionLog` is captured weakly for symmetry —
        // if the log is ever recreated the cascade should pick up the new one
        // via the next `installLibraryChangeCascade` rather than fire on a
        // stale instance.
        library.onLibraryDidChange = { [weak library, weak albums, weak sharedDecisionLog] in
            guard let library, let albums else { return }
            // Reload albums first so the prune sees current state. PhotoController
            // already reloaded `assets` before invoking this callback.
            albums.loadAlbums()

            let livingAssetIDs = Set(library.assets.map(\.localIdentifier))
            let livingAlbumIDs = Set(albums.albums.map(\.id))
            let livingAlbumNames = Set(albums.albums.map(\.title))

            embeddings.prune(keeping: livingAssetIDs)
            corrections.prune(
                keepingAssetIDs: livingAssetIDs,
                livingAlbumNames: livingAlbumNames
            )
            sharedDecisionLog?.prune(
                keepingAssets: livingAssetIDs,
                livingAlbumIDs: livingAlbumIDs
            )

            // Persist the prune. Failing to save here means a relaunch could
            // reload the now-pruned rows from disk.
            do {
                try context.save()
            } catch {
                print("PixelCuratorApp: failed to save after library-change cascade: \(error)")
            }
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

/// `true` while a variant switch is in flight — the prior indexer's
/// `cancelAndWait()` is pending, or `bootIndexer(variant:)` has not yet
/// finished rebuilding services for the new variant. Views must gate
/// re-entrant work that touches the indexer (notably `PhotoGridView`'s
/// `task(id: library.assets.count)`) on this flag, otherwise an unrelated
/// library-count change can call `index(assets:)` on the about-to-be-discarded
/// indexer mid-switch.
private struct IsSwitchingVariantKey: EnvironmentKey {
    static let defaultValue: Bool = false
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

    var isSwitchingVariant: Bool {
        get { self[IsSwitchingVariantKey.self] }
        set { self[IsSwitchingVariantKey.self] = newValue }
    }
}
