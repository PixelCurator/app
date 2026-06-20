import Foundation
import Photos
import SwiftData
import SwiftUI

// MARK: - SortingCoordinator

/// Manages a single inbox-review session: builds a queue of unsorted, embedded
/// photos, exposes the current photo + suggestions, and records accept/skip
/// decisions that advance through the queue.
///
/// **DESIGN DEFAULT — queue definition:** the queue contains photos that (a)
/// have an embedding for the active modelID AND (b) are not already a member of
/// any album. Flag for Yves: "unsorted + embedded" may be too narrow on first
/// run before the indexer completes. Consider a fallback that shows
/// non-embedded photos with a "needs indexing" placeholder.
///
/// **DESIGN DEFAULT — single-card flow:** one photo is shown at a time (not a
/// swipe stack or batch mode). This keeps decision overhead low but means long
/// queues require many taps. Flag for review.
@MainActor
@Observable
final class SortingCoordinator {

    // MARK: - Dependencies

    private var store: EmbeddingStore
    private var suggester: AlbumSuggester
    let albumManager: AlbumManager
    private let photoController: PhotoController
    /// `modelID` is mutable because `updateVariant(...)` rebinds the coordinator
    /// to a new variant's data sources without throwing away `decisionLog`
    /// (Undo history must survive a variant switch).
    private(set) var modelID: String
    let decisionLog: DecisionLog
    private var correctionStore: CorrectionStore?

    // MARK: - State

    /// Ordered asset IDs eligible for sorting (unsorted + embedded).
    private(set) var queue: [PHAsset] = []

    /// Index into `queue` for the currently displayed photo.
    private(set) var currentIndex: Int = 0

    /// Whether a sorting session is active (queue built, not yet exhausted).
    private(set) var isSorting: Bool = false

    /// Suggestions for the current photo, ranked best-first.
    private(set) var currentSuggestions: [AlbumSuggestion] = []

    /// Number of photos actioned (accepted or assigned) in this session.
    private(set) var sortedCount: Int = 0

    /// Error from the most recent assign operation, or nil.
    var lastAssignError: String?

    // MARK: - Computed

    var current: PHAsset? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var remainingCount: Int {
        max(0, queue.count - currentIndex)
    }

    var totalCount: Int { queue.count }

    var isExhausted: Bool { currentIndex >= queue.count }

    // MARK: - Init

    init(
        store: EmbeddingStore,
        suggester: AlbumSuggester,
        albumManager: AlbumManager,
        photoController: PhotoController,
        modelID: String = CLIPVariant.bundledDefault.modelID,
        decisionLog: DecisionLog? = nil,
        correctionStore: CorrectionStore? = nil
    ) {
        self.store = store
        self.suggester = suggester
        self.albumManager = albumManager
        self.photoController = photoController
        self.modelID = modelID
        // If no DecisionLog is provided, create one backed by the shared albumManager.
        self.decisionLog = decisionLog ?? DecisionLog(operations: albumManager)
        self.correctionStore = correctionStore
    }

    // MARK: - Variant switch

    /// Rebinds the coordinator to a new variant's data sources without
    /// reallocating the coordinator itself.
    ///
    /// Preserves `decisionLog` (and therefore Undo history) across variant
    /// switches — reallocating a `SortingCoordinator` per switch would silently
    /// wipe the user's undo stack. The active session, if any, is also reset:
    /// the queue is rebuilt against the new variant's embedded set.
    ///
    /// Called by `PixelCuratorApp.bootIndexer(variant:)` after the prior
    /// indexer has been awaited to completion (see `EmbeddingIndexer.cancelAndWait`).
    func updateVariant(
        store newStore: EmbeddingStore,
        suggester newSuggester: AlbumSuggester,
        correctionStore newCorrectionStore: CorrectionStore?,
        modelID newModelID: String
    ) {
        self.store = newStore
        self.suggester = newSuggester
        self.correctionStore = newCorrectionStore
        self.modelID = newModelID
        // Clear the active session; the queue is variant-specific (embedded set
        // is keyed by modelID). The caller will rebuild before presenting.
        queue = []
        currentIndex = 0
        sortedCount = 0
        isSorting = false
        currentSuggestions = []
        lastAssignError = nil
    }

    // MARK: - Queue building

    /// Builds (or rebuilds) the review queue. Must be called before presenting
    /// `SortingInboxView`. Safe to call again mid-session to refresh.
    func buildQueue() {
        // Compute the set of all album members across all known albums.
        let albumMembers: Set<String> = albumManager.albums.reduce(into: Set()) { result, album in
            result.formUnion(albumManager.memberAssetIDs(of: album.id))
        }

        let embeddedIDs = store.embeddedAssetIDs(modelID: modelID)

        let filteredIDs = SortingCoordinator.filterInbox(
            allAssetIDs: photoController.assets.map(\.localIdentifier),
            embedded: embeddedIDs,
            albumMembers: albumMembers
        )

        // Map filtered IDs back to PHAsset objects, preserving filtered order.
        let assetByID: [String: PHAsset] = Dictionary(
            uniqueKeysWithValues: photoController.assets.map { ($0.localIdentifier, $0) }
        )
        queue = filteredIDs.compactMap { assetByID[$0] }
        currentIndex = 0
        sortedCount = 0
        isSorting = !queue.isEmpty
        recomputeSuggestions()
    }

    // MARK: - Pure inbox filter (testable without PhotoKit)

    /// Returns the ordered subset of `allAssetIDs` that are both embedded and
    /// not already placed in an album. Order is preserved.
    ///
    /// This is a **pure function** — no PhotoKit or SwiftData I/O. Call it
    /// from unit tests by passing synthetic IDs.
    nonisolated static func filterInbox(
        allAssetIDs: [String],
        embedded: Set<String>,
        albumMembers: Set<String>
    ) -> [String] {
        allAssetIDs.filter { id in
            embedded.contains(id) && !albumMembers.contains(id)
        }
    }

    // MARK: - Actions

    /// Accepts a suggestion: assigns the current photo to the suggested album,
    /// then advances to the next photo.
    ///
    /// - Parameter suggestion: The top-ranked suggestion accepted by the user.
    ///   `isSuggestionAccept` is `true` here, which M3-D can use to distinguish
    ///   corrections (user picks a *non-top* album) from confirmations.
    func accept(_ suggestion: AlbumSuggestion) async {
        guard let asset = current else { return }
        let result = await albumManager.assignAndResolve(asset, toAlbumNamed: suggestion.albumTitle)
        switch result {
        case .added(let albumID):
            sortedCount += 1
            lastAssignError = nil
            decisionLog.record(
                asset: asset,
                albumName: suggestion.albumTitle,
                albumLocalIdentifier: albumID
            )
            recordCorrectionIfNeeded(asset: asset, albumName: suggestion.albumTitle)
            advance()
        case .alreadyMember:
            // The asset is already in the target album — treat as success but
            // do NOT record a phantom decision (S-1: assign idempotency).
            sortedCount += 1
            lastAssignError = nil
            recordCorrectionIfNeeded(asset: asset, albumName: suggestion.albumTitle)
            advance()
        case .failed:
            // Stay on the current photo so a failed assign can be retried
            // instead of silently skipping the photo out of the session.
            lastAssignError = albumManager.lastError
        }
    }

    /// Assigns the current photo to an explicitly chosen album name (the
    /// "pick other" path), then advances.
    ///
    /// - Note for M3-D: this path is invoked when the user overrides suggestions
    ///   or picks from the full album list. Comparing `name` against
    ///   `currentSuggestions.first?.albumTitle` before `advance()` would let
    ///   M3-D distinguish a correction from a confirmation.
    func assignTo(albumNamed name: String) async {
        guard let asset = current else { return }
        let result = await albumManager.assignAndResolve(asset, toAlbumNamed: name)
        switch result {
        case .added(let albumID):
            sortedCount += 1
            lastAssignError = nil
            decisionLog.record(asset: asset, albumName: name, albumLocalIdentifier: albumID)
            recordCorrectionIfNeeded(asset: asset, albumName: name)
            advance()
        case .alreadyMember:
            // No-op assign — do not record a phantom undo entry (S-1).
            sortedCount += 1
            lastAssignError = nil
            recordCorrectionIfNeeded(asset: asset, albumName: name)
            advance()
        case .failed:
            // Stay on the current photo so a failed assign can be retried
            // instead of silently skipping the photo out of the session.
            lastAssignError = albumManager.lastError
        }
    }

    /// Skips the current photo without assigning it to any album.
    func skip() {
        advance()
    }

    // MARK: - Batch assign

    /// Assigns several queued photos to one album in a single action.
    ///
    /// Each successful assignment is recorded in the decision log (so Undo works
    /// per photo) and as a correction (the user explicitly chose the album — a
    /// label for future suggestions). Assigned photos are removed from the queue
    /// in place, preserving the session's `sortedCount` and the current position
    /// (unlike a full `buildQueue()`, which resets the counters).
    ///
    /// - Returns: the number of photos successfully assigned.
    @discardableResult
    func batchAssign(_ assets: [PHAsset], toAlbumNamed name: String) async -> Int {
        var assignedIDs = Set<String>()
        for asset in assets {
            let result = await albumManager.assignAndResolve(asset, toAlbumNamed: name)
            switch result {
            case .added(let albumID):
                assignedIDs.insert(asset.localIdentifier)
                decisionLog.record(asset: asset, albumName: name, albumLocalIdentifier: albumID)
                correctionStore?.record(assetID: asset.localIdentifier, albumName: name, modelID: modelID)
            case .alreadyMember:
                // Asset is already a member — count it as removed-from-queue
                // (so it leaves the inbox) but do NOT record a phantom undo
                // entry (S-1). Skip correction recording too: the user did not
                // re-make a choice the suggester needs to learn from.
                assignedIDs.insert(asset.localIdentifier)
            case .failed:
                lastAssignError = albumManager.lastError
            }
        }
        guard !assignedIDs.isEmpty else { return 0 }

        // Remove the assigned photos from the queue in place. Adjust the current
        // index by however many removed photos sat before it so the user stays
        // on (or near) the same spot.
        let removedBeforeCurrent = queue[..<min(currentIndex, queue.count)]
            .filter { assignedIDs.contains($0.localIdentifier) }
            .count
        queue.removeAll { assignedIDs.contains($0.localIdentifier) }
        currentIndex = max(0, currentIndex - removedBeforeCurrent)
        if currentIndex >= queue.count { isSorting = false }
        sortedCount += assignedIDs.count
        recomputeSuggestions()
        return assignedIDs.count
    }

    // MARK: - Cheap count for discoverability

    /// Cheap count of photos eligible for sorting (embedded AND not in any
    /// album), without building the full queue. Drives the grid's "N to sort"
    /// affordance. Safe to call on the main actor whenever the library or index
    /// changes.
    func unsortedCount() -> Int {
        let albumMembers = albumManager.albums.reduce(into: Set<String>()) { set, album in
            set.formUnion(albumManager.memberAssetIDs(of: album.id))
        }
        let embedded = store.embeddedAssetIDs(modelID: modelID)
        return SortingCoordinator.filterInbox(
            allAssetIDs: photoController.assets.map(\.localIdentifier),
            embedded: embedded,
            albumMembers: albumMembers
        ).count
    }

    // MARK: - Grid tap-to-sort

    /// Album suggestions for an arbitrary asset (the grid's tap-to-sort flow),
    /// independent of the inbox queue. Returns [] if the asset has no stored
    /// embedding yet (e.g. indexing still running).
    func suggestions(for asset: PHAsset) -> [AlbumSuggestion] {
        suggester.suggestions(
            for: asset.localIdentifier,
            modelID: modelID,
            store: store,
            albumManager: albumManager,
            corrections: correctionStore
        )
    }

    // MARK: - Private

    /// Records a correction when the chosen album differs from the top suggestion
    /// (or there was no suggestion). Corrections feed back into future rankings
    /// via `AlbumSuggester`.
    private func recordCorrectionIfNeeded(asset: PHAsset, albumName: String) {
        guard let correctionStore else { return }
        if albumName != currentSuggestions.first?.albumTitle {
            correctionStore.record(assetID: asset.localIdentifier, albumName: albumName, modelID: modelID)
        }
    }

    private func advance() {
        currentIndex += 1
        if currentIndex >= queue.count {
            isSorting = false
        }
        recomputeSuggestions()
    }

    private func recomputeSuggestions() {
        guard let asset = current else {
            currentSuggestions = []
            return
        }
        currentSuggestions = suggester.suggestions(
            for: asset.localIdentifier,
            modelID: modelID,
            store: store,
            albumManager: albumManager,
            corrections: correctionStore
        )
    }
}

// MARK: - Environment key

private struct SortingCoordinatorKey: EnvironmentKey {
    static let defaultValue: SortingCoordinator? = nil
}

extension EnvironmentValues {
    var sortingCoordinator: SortingCoordinator? {
        get { self[SortingCoordinatorKey.self] }
        set { self[SortingCoordinatorKey.self] = newValue }
    }
}
