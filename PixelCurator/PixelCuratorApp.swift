import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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

    /// Entitlement provider.
    ///
    /// DEBUG builds use `DebugEntitlementProvider` so the full multi-variant
    /// pipeline is exercisable without App Store Connect products.
    ///
    /// RELEASE builds use `BundledOnlyEntitlementProvider`: only the bundled
    /// `.s0` variant is unlocked, Pro variants stay locked. This is the
    /// safe-for-App-Review default until StoreKit + ASC IAP products are
    /// configured — at which point this `#else` branch flips to
    /// `StoreKitEntitlementProvider()`.
    #if DEBUG
    @State private var entitlements: any EntitlementProvider = DebugEntitlementProvider()
    #else
    @State private var entitlements: any EntitlementProvider = BundledOnlyEntitlementProvider()
    #endif

    /// Guards against concurrent variant-switch calls.
    @State private var isSwitchingVariant = false

    /// B-6. Holds the boot-time error surfaced from `bootIndexer(variant:)`
    /// so the root view can render an alert with a Retry affordance. The
    /// previous catch block only `print`-logged, leaving the Sort tab in a
    /// silent empty state when (e.g.) model compilation failed due to a
    /// full disk or a corrupt model bundle. Identifiable so SwiftUI can key
    /// the alert presentation on a stable id.
    @State private var bootError: BootError?

    /// F-02 mitigation. Holds the `pendingCascadeReplay` flag. Modeled as an
    /// `@Observable` class rather than `@State Bool` so the cascade closure
    /// (which is stored on `PhotoController` and outlives any single App body
    /// evaluation) can read + write the flag through a `weak` capture without
    /// reaching through a struct-typed `@State` projection. See
    /// `installLibraryChangeCascade` for why the closure must not strongly
    /// retain the App struct.
    @State private var cascadeGate = CascadeGate()

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
            modelContainer = try ModelContainer(for: PhotoEmbedding.self, AlbumCorrection.self, UnindexableAsset.self)
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
                // B-6. Surface boot failures from `bootIndexer(variant:)`
                // as an actionable alert. Without this the Sort tab silently
                // shows the empty state forever (no indexer = no queue).
                .alert(
                    Text("Couldn't prepare indexer"),
                    isPresented: Binding(
                        get: { bootError != nil },
                        set: { isPresented in
                            if !isPresented { bootError = nil }
                        }
                    ),
                    presenting: bootError
                ) { error in
                    Button("Try again") {
                        let variant = error.variant
                        bootError = nil
                        Task { await bootIndexer(variant: variant) }
                    }
                    Button("Cancel", role: .cancel) {
                        bootError = nil
                    }
                } message: { _ in
                    Text("Indexing isn't available right now. Try again — if the problem persists, restart PixelCurator.")
                }
                // F-02 trailing-edge replay. Whenever the cascade gate state
                // changes (indexing flipped, variant switch settled), check
                // whether a cascade was deferred and replay it now that the
                // shared mainContext has no in-flight writer. The id captures
                // both gates so either flip triggers the modifier re-run; the
                // body itself re-checks both gates before running, so a flip
                // that opens one gate while the other is still closed is a
                // no-op (the deferred work waits for the second gate too).
                .task(id: CascadeReplayKey(
                    isIndexing: indexer?.isIndexing == true,
                    isSwitchingVariant: isSwitchingVariant
                )) {
                    await replayCascadeIfPending()
                }
                // App-wide indexing lock: presented whenever the indexer is
                // actively running. On iOS we use .fullScreenCover so it sits
                // above sheets and navigation stacks; on macOS .fullScreenCover
                // is unavailable in SwiftUI, so we fall back to a modal .sheet
                // (already window-modal on macOS). interactiveDismissDisabled
                // prevents swipe-to-dismiss / tap-outside while the rebuild
                // is in flight.
                #if os(iOS)
                .fullScreenCover(isPresented: Binding(
                    get: { indexer?.isIndexing == true },
                    set: { _ in } // read-only; dismissal is gated by isIndexing flipping false
                )) {
                    if let liveIndexer = indexer {
                        IndexingLockOverlay(indexer: liveIndexer)
                            .interactiveDismissDisabled()
                            .task { beginBackgroundIndexingTask() }
                            .onDisappear { endBackgroundIndexingTask() }
                    }
                }
                #else
                .sheet(isPresented: Binding(
                    get: { indexer?.isIndexing == true },
                    set: { _ in }
                )) {
                    if let liveIndexer = indexer {
                        IndexingLockOverlay(indexer: liveIndexer)
                            .interactiveDismissDisabled()
                            .task { beginBackgroundIndexingTask() }
                            .onDisappear { endBackgroundIndexingTask() }
                            .frame(minWidth: 480, minHeight: 360)
                    }
                }
                #endif
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
        //
        // The Settings scene is separate from the WindowGroup so it does NOT
        // inherit `.modelContainer(modelContainer)` or the injected environments
        // automatically. We re-inject the subset that `AppSettingsView` needs so
        // the Index Reset button is functional from the macOS Settings pane.
        Settings {
            // N-2. Wrap in NavigationStack so the new "Help & Tips" row in
            // AppSettingsView pushes HelpView correctly on macOS. The iOS
            // sheet path (in PhotoGridView) already wraps in its own
            // NavigationStack, so AppSettingsView itself stays unwrapped.
            NavigationStack {
                AppSettingsView()
                    .environment(library)
                    .environment(\.embeddingIndexer, indexer)
                    .environment(\.activeVariant, activeVariant)
                    // F-13. Inject the variant-switch flag here too — the macOS
                    // Settings scene does not inherit WindowGroup's environment,
                    // and AppSettingsView's Delete Index button gate relies on
                    // reading this value.
                    .environment(\.isSwitchingVariant, isSwitchingVariant)
                    .modelContainer(modelContainer)
            }
        }
        #endif
    }

    // MARK: - Background task management

    /// iOS: a `UIBackgroundTask` bought by `beginBackgroundTaskWithName(_:expirationHandler:)`
    /// gives the app up to ~30 s of extra CPU after the user backgrounds it
    /// while indexing is in flight. No new entitlements needed — this is the
    /// standard background-task API available to every app.
    ///
    /// macOS: a `NSProcessInfo.Activity` with `.userInitiated` keeps the process
    /// alive and prevents App Nap while the index rebuild runs.
    ///
    /// Both ends are cleaned up in `endBackgroundIndexingTask()`, which is called
    /// when the `IndexingLockOverlay` disappears (i.e. indexing finished).
    #if canImport(UIKit)
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    private func beginBackgroundIndexingTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PixelCurator.IndexRebuild") {
            // Expiration handler: iOS is about to suspend us. End the task
            // gracefully so the system doesn't kill the process outright.
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    @MainActor
    private func endBackgroundIndexingTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    #elseif canImport(AppKit)
    @State private var activityToken: NSObjectProtocol?

    @MainActor
    private func beginBackgroundIndexingTask() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Rebuilding photo index"
        )
    }

    @MainActor
    private func endBackgroundIndexingTask() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
    #endif

    // MARK: - Boot

    @MainActor
    private func bootIndexer(variant: CLIPVariant) async {
        guard !isSwitchingVariant else { return }
        isSwitchingVariant = true
        defer { isSwitchingVariant = false }

        // Create the shared DecisionLog once (on first boot). Variant switches
        // don't need a fresh log — the same albums instance backs undo operations.
        if sharedDecisionLog == nil {
            let log = DecisionLog(operations: albums)
            // F-12. The DecisionLog fires `onFirstDecisionRecorded` exactly
            // once per app launch, the moment the user records their first
            // assignment or move. We rebroadcast as a Notification so any
            // currently-visible view (PhotoGridView, SortingInboxView) can
            // show the one-shot "Undo lasts only this session" toast through
            // its existing `showToast` pipeline. The persistent across-launch
            // gate (`@AppStorage("hasShownUndoSessionHint")`) lives at the
            // call site so the DecisionLog itself stays free of UserDefaults
            // coupling.
            log.onFirstDecisionRecorded = {
                NotificationCenter.default.post(
                    name: .pixelCuratorFirstDecisionRecorded,
                    object: nil
                )
            }
            sharedDecisionLog = log
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
                    source: newStore,
                    suggester: AlbumSuggester(),
                    correctionStore: newCorrectionStore,
                    modelID: variant.modelID
                )
            } else {
                self.sortingCoordinator = SortingCoordinator(
                    source: newStore,
                    suggester: AlbumSuggester(),
                    albumManager: albums,
                    photoController: library,
                    modelID: variant.modelID,
                    decisionLog: sharedDecisionLog,
                    correctionStore: newCorrectionStore
                )
            }
        } catch {
            // B-6. Surface the failure to the user via an alert with a
            // Retry button instead of silently leaving `indexer == nil`.
            // The most common causes are a corrupt model bundle, a full
            // disk during model compilation, and a transient PhotoKit
            // I/O hiccup — all transiently fixable, so a retry is the
            // right primary action.
            print("PixelCuratorApp: failed to boot indexer for \(variant.displayName): \(error)")
            self.bootError = BootError(variant: variant, underlying: error)
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
        // F-02. The closure is the gated entrypoint; it never touches the
        // shared `modelContainer.mainContext` directly. If indexing or a
        // variant switch is in flight, set `cascadeGate.pendingReplay` and
        // return — the root's `.task(id:)` replay modifier will re-run the
        // prune once both gates open. Otherwise dispatch to
        // `runCascadePrune()` immediately. The deferred-replay path is what
        // keeps the cascade from interleaving `context.save()` with
        // `EmbeddingIndexer.runIndex`, which writes the same context across
        // `await embedder.embed(_:)` suspension points.
        //
        // Captures: `gate` is weak so the closure (retained by
        // `PhotoController.onLibraryDidChange`) does not pin the App's
        // `@State` storage. `runPrune` is a value-typed closure that
        // captures the run helper indirectly through the same weak gate.
        let gate = cascadeGate
        let isIndexingGate: @MainActor () -> Bool = { [weak indexer] in
            indexer?.isIndexing == true
        }
        let isSwitchingGate: @MainActor () -> Bool = { [self] in
            // `self` is the value-typed App struct; capturing it by value is
            // safe (no class retain). The `_isSwitchingVariant` projection
            // reads through SwiftUI's `@State` storage which outlives any
            // single App body evaluation.
            self.isSwitchingVariant
        }
        let runPrune: @MainActor () async -> Void = { [self] in
            await self.runCascadePrune()
        }
        library.onLibraryDidChange = { @MainActor [weak gate] in
            // Route through `CascadeGate.deferIfBusy` so unit tests can
            // exercise the same gate semantics directly (see
            // CascadeRaceTests).
            let deferred = gate?.deferIfBusy(
                isIndexing: isIndexingGate(),
                isSwitchingVariant: isSwitchingGate()
            ) ?? false
            if deferred { return }
            await runPrune()
        }
    }

    /// F-02 trailing-edge replay hook. Wired to `.task(id:)` on the root —
    /// rerun whenever `isIndexing` or `isSwitchingVariant` changes. The body
    /// re-checks both gates (the id can fire on a closing edge too) and only
    /// drains a pending cascade when both gates are open.
    @MainActor
    private func replayCascadeIfPending() async {
        let shouldReplay = cascadeGate.consumePendingReplay(
            isIndexing: indexer?.isIndexing == true,
            isSwitchingVariant: isSwitchingVariant
        )
        guard shouldReplay else { return }
        await runCascadePrune()
    }

    /// Performs the cascade prune across `EmbeddingStore`, `CorrectionStore`,
    /// and `DecisionLog`, then saves the shared `mainContext`. Pulled out of
    /// `installLibraryChangeCascade` so the trailing-edge replay path can
    /// reuse the identical body without duplicating the prune order.
    ///
    /// F-10/F-11. This routine is **destructive** — it deletes rows whose
    /// `localIdentifier` is not in `library.assets`. Under reduced
    /// authorization states `library.assets` does NOT represent "every
    /// photo the user owns":
    ///
    ///   - `.limited`: `PHAsset.fetchAssets` returns only the user-picked
    ///     subset. The other photos still exist; we just can't see them
    ///     right now. Pruning would wipe embeddings for tens of thousands
    ///     of perfectly valid assets every time the Limited-Library
    ///     selection changes.
    ///   - `.denied` / `.restricted`: `library.assets` is `[]` (the change
    ///     handler clears it). Pruning would erase the entire derived
    ///     dataset on a transient permission revoke — exactly the F-11
    ///     symptom: 10k+ embeddings lost on a single auth flicker.
    ///   - `.authorized`: `library.assets` is the full library snapshot,
    ///     so pruning against it is correct.
    ///
    /// We therefore skip the prune unless `library.authState == .authorized`.
    /// A destructive index wipe remains available on demand via
    /// Settings → Delete Index (see F-19).
    @MainActor
    private func runCascadePrune() async {
        let context = modelContainer.mainContext
        let embeddings = EmbeddingStore(context: context)
        let corrections = CorrectionStore(context: context)

        // Reload albums first so the prune sees current state. PhotoController
        // already reloaded `assets` before invoking the cascade closure.
        albums.loadAlbums()

        // F-10/F-11. Skip the prune unless we're operating against the
        // full library snapshot. `.limited` and `.denied` / `.restricted`
        // both produce a partial `library.assets` view; treating every
        // off-list asset as deleted is what destroyed user embeddings on
        // transient auth changes. The gate decision is factored into a
        // pure static so unit tests can exercise the policy without
        // standing up the full App.
        guard CascadeGate.shouldRunDestructivePrune(authState: library.authState) else {
            return
        }

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

// MARK: - BootError

/// B-6. Failure record from `bootIndexer(variant:)` — carried via
/// `@State private var bootError` so the root view can present a Retry alert.
/// The `variant` is needed because Retry should re-attempt the *same* variant
/// the user (or the initial boot) requested, not whatever `activeVariant`
/// has drifted to in the meantime. Value-typed so it composes with SwiftUI
/// state diffing. `Identifiable` makes it eligible for the
/// `alert(_:isPresented:presenting:)` overload that re-renders cleanly on
/// repeated failures (different `id` → fresh alert).
struct BootError: Identifiable {
    let id = UUID()
    let variant: CLIPVariant
    let underlying: Error
}

/// F-02. Identity wrapper for the cascade-replay `.task(id:)` modifier.
/// Hashable equality flips whenever either gate (indexing in flight, variant
/// switch in flight) changes value, which is exactly when the cascade may
/// have unblocked.
private struct CascadeReplayKey: Hashable {
    let isIndexing: Bool
    let isSwitchingVariant: Bool
}

/// F-02. Mutable holder for the pending-replay flag. A reference type lets
/// the cascade closure (stored on `PhotoController.onLibraryDidChange`,
/// outliving any single App body evaluation) mutate the flag via a weak
/// capture without retaining the App's value-typed `@State` storage. Marked
/// `@MainActor` because both the cascade closure and the replay reader run
/// on the main actor.
@MainActor
final class CascadeGate {
    var pendingReplay: Bool = false

    /// F-02 gate-decision shim. Pure function over `(isIndexing,
    /// isSwitchingVariant)` so unit tests can exercise the deferral semantics
    /// without spinning up a full `PixelCuratorApp` (the closure that
    /// `installLibraryChangeCascade` installs on `PhotoController` is a
    /// private member of an `@main` App struct and is not directly
    /// instantiable from tests).
    ///
    /// - Returns: `true` if the change should be deferred (and the caller
    ///   should NOT run the prune); `false` if the cascade is free to run.
    ///   Mutates `pendingReplay` to `true` when deferring.
    @discardableResult
    func deferIfBusy(isIndexing: Bool, isSwitchingVariant: Bool) -> Bool {
        if isIndexing || isSwitchingVariant {
            pendingReplay = true
            return true
        }
        return false
    }

    /// F-02 replay-decision shim. Mirror of `replayCascadeIfPending` semantics
    /// in pure-function form. Returns `true` when the caller should run the
    /// prune (and clears `pendingReplay` as a side effect).
    @discardableResult
    func consumePendingReplay(isIndexing: Bool, isSwitchingVariant: Bool) -> Bool {
        guard pendingReplay, !isIndexing, !isSwitchingVariant else { return false }
        pendingReplay = false
        return true
    }

    /// F-10/F-11. Decision shim for the destructive prune in
    /// `PixelCuratorApp.runCascadePrune`. Pure function over
    /// `PhotoController.AuthState` so unit tests can lock the policy
    /// without standing up the App.
    ///
    /// - Returns: `true` only when `library.assets` is known to be the
    ///   full library snapshot (`.authorized`). All other states return
    ///   `false`:
    ///   - `.limited`: `PHAsset.fetchAssets` returns only the user-picked
    ///     subset. Pruning would wipe embeddings for every off-list asset.
    ///   - `.denied` / `.restricted`: `library.assets` is empty; pruning
    ///     would erase the entire derived dataset on a transient revoke.
    ///   - `.unknown`: pre-determination state — never destructive.
    static func shouldRunDestructivePrune(authState: PhotoController.AuthState) -> Bool {
        switch authState {
        case .authorized: return true
        case .limited, .denied, .restricted, .unknown: return false
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// F-12. Posted on the main thread the moment the shared `DecisionLog`
    /// records its first decision in the current app launch. Observers (the
    /// grid and inbox toast helpers) decide whether to render the
    /// session-only Undo hint by consulting an `@AppStorage` flag — the
    /// notification itself fires once per launch unconditionally.
    static let pixelCuratorFirstDecisionRecorded = Notification.Name(
        "PixelCurator.firstDecisionRecorded"
    )
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
